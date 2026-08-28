package io.ente.photos.platform.flutter

import android.app.Activity
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import io.ente.photos.platform.devicefoldertransfer.DeviceFolderTransferService
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.util.ArrayDeque
import java.util.concurrent.Executors

internal class DeviceFolderTransferChannelAdapter : MethodChannel.MethodCallHandler, PluginRegistry.ActivityResultListener {
    private lateinit var service: DeviceFolderTransferService
    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var pendingTransfer: (() -> Unit)? = null
    private var pendingResult: MethodChannel.Result? = null
    private var pendingLocalIDs: List<String> = emptyList()
    private var pendingConsentBatches: ArrayDeque<List<android.net.Uri>>? = null
    private var isConsentRequestInProgress = false
    private val transferExecutor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    private var isTransferInProgress = false
    @Volatile
    private var isDetached = false

    fun attach(binding: FlutterPlugin.FlutterPluginBinding) {
        isDetached = false
        service = DeviceFolderTransferService(binding.applicationContext)
    }

    fun attachActivity(binding: ActivityPluginBinding) {
        activityBinding?.removeActivityResultListener(this)
        activityBinding = binding
        activity = binding.activity
        binding.addActivityResultListener(this)
        startPendingConsentRequest()
    }

    fun detachActivity(cancelPendingTransfer: Boolean) {
        activityBinding?.removeActivityResultListener(this)
        activityBinding = null
        activity = null
        if (cancelPendingTransfer) completeWithFailures("cancelled")
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val arguments = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
        when (call.method) {
            "deviceFolderTransfer.supportedOperations" -> {
                result.success(service.supportedOperations())
            }
            "deviceFolderTransfer.eligibleDestinations" -> {
                val operation = arguments["operation"] as? String
                val ids = arguments["candidateFolderIDs"] as? List<*> ?: emptyList<Any>()
                val sourceLocalIDs = arguments["sourceLocalIDs"] as? List<*> ?: emptyList<Any>()
                transferExecutor.execute {
                    try {
                        val eligibleIDs = service.eligibleDestinationIDs(
                            operation,
                            arguments["sourceFolderID"] as? String ?: "",
                            ids.filterIsInstance<String>(),
                            sourceLocalIDs.filterIsInstance<String>(),
                        )
                        postToMain { result.success(eligibleIDs) }
                    } catch (error: Exception) {
                        postToMain {
                            result.error(
                                "device_folder_transfer_failed",
                                error.message,
                                null,
                            )
                        }
                    }
                }
            }
            "deviceFolderTransfer.transfer" -> {
                val transferID = arguments["transferID"] as? String
                val recoveryContext = (arguments["recoveryContext"] as? Map<*, *>)
                    ?.mapNotNull { (key, value) ->
                        (key as? String)?.let { stringKey ->
                            value?.let { stringKey to it }
                        }
                    }
                    ?.toMap()
                val operation = arguments["operation"] as? String
                val source = arguments["sourceFolderID"] as? String
                val target = arguments["targetFolderID"] as? String
                val ids = (arguments["sourceLocalIDs"] as? List<*>)?.filterIsInstance<String>()
                if (operation == null || source == null || target == null || ids == null) {
                    result.error("device_folder_transfer_invalid_arguments", null, null)
                } else {
                    requestConsentThenTransfer(
                        operation,
                        transferID,
                        recoveryContext,
                        source,
                        target,
                        ids,
                        result,
                    )
                }
            }
            "deviceFolderTransfer.pendingRecoveries" -> {
                transferExecutor.execute {
                    try {
                        val recoveries = service.pendingRecoveries()
                        postToMain { result.success(recoveries) }
                    } catch (error: Exception) {
                        postToMain {
                            result.error(
                                "device_folder_transfer_failed",
                                error.message,
                                null,
                            )
                        }
                    }
                }
            }
            "deviceFolderTransfer.markCloudMoveStarted",
            "deviceFolderTransfer.markCloudMoveCompleted" -> {
                val transferID = arguments["transferID"] as? String
                if (transferID == null) {
                    result.error("device_folder_transfer_invalid_arguments", null, null)
                } else {
                    transferExecutor.execute {
                        try {
                            val completed = if (
                                call.method == "deviceFolderTransfer.markCloudMoveStarted"
                            ) {
                                service.markCloudMoveStarted(transferID)
                            } else {
                                service.markCloudMoveCompleted(transferID)
                            }
                            postToMain {
                                if (completed) {
                                    result.success(null)
                                } else {
                                    result.error(
                                        "device_folder_transfer_recovery_persistence_failed",
                                        "Could not persist device-folder transfer recovery record",
                                        null,
                                    )
                                }
                            }
                        } catch (error: Exception) {
                            postToMain {
                                result.error(
                                    "device_folder_transfer_recovery_persistence_failed",
                                    error.message,
                                    null,
                                )
                            }
                        }
                    }
                }
            }
            "deviceFolderTransfer.acknowledgeRecovery" -> {
                val transferID = arguments["transferID"] as? String
                if (transferID == null) {
                    result.error("device_folder_transfer_invalid_arguments", null, null)
                } else {
                    transferExecutor.execute {
                        try {
                            val acknowledged = service.acknowledgeRecovery(transferID)
                            postToMain {
                                if (acknowledged) {
                                    result.success(null)
                                } else {
                                    result.error(
                                        "device_folder_transfer_recovery_persistence_failed",
                                        "Could not acknowledge device-folder transfer recovery record",
                                        null,
                                    )
                                }
                            }
                        } catch (error: Exception) {
                            postToMain {
                                result.error(
                                    "device_folder_transfer_recovery_persistence_failed",
                                    error.message,
                                    null,
                                )
                            }
                        }
                    }
                }
            }
            else -> result.notImplemented()
        }
    }

    fun detach() {
        detachActivity(cancelPendingTransfer = true)
        isDetached = true
        mainHandler.removeCallbacksAndMessages(null)
        transferExecutor.shutdown()
    }

    private fun requestConsentThenTransfer(
        operation: String,
        transferID: String?,
        recoveryContext: Map<String, Any>?,
        source: String,
        target: String,
        ids: List<String>,
        result: MethodChannel.Result,
    ) {
        if (pendingResult != null || isTransferInProgress) {
            result.error("device_folder_transfer_in_progress", "Another device folder transfer is in progress", null)
            return
        }
        isTransferInProgress = true
        pendingResult = result
        pendingLocalIDs = ids
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R || operation == "copy") {
            runTransfer(
                transferID,
                recoveryContext,
                operation,
                source,
                target,
                ids,
                result,
            )
            return
        }
        transferExecutor.execute {
            try {
                val uris = ids.mapNotNull(service::mediaUri)
                postToMain {
                    if (pendingResult !== result) return@postToMain
                    if (uris.isEmpty()) {
                        pendingTransfer = null
                        runTransfer(
                            transferID,
                            recoveryContext,
                            operation,
                            source,
                            target,
                            ids,
                            result,
                        )
                        return@postToMain
                    }
                    pendingTransfer = {
                        runTransfer(
                            transferID,
                            recoveryContext,
                            operation,
                            source,
                            target,
                            ids,
                            result,
                        )
                    }
                    pendingConsentBatches = ArrayDeque(
                        uris.chunked(MAX_CONSENT_URI_COUNT),
                    )
                    startPendingConsentRequest()
                }
            } catch (error: Exception) {
                postToMain {
                    completeWithError(error)
                }
            }
        }
    }

    private fun startPendingConsentRequest() {
        if (isConsentRequestInProgress) return
        val uris = pendingConsentBatches?.firstOrNull() ?: return
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            completeWithFailures("unsupported")
            return
        }
        val host = activity
        if (host == null) {
            return
        }
        try {
            isConsentRequestInProgress = true
            host.startIntentSenderForResult(
                MediaStore.createWriteRequest(host.contentResolver, uris).intentSender,
                REQUEST_WRITE_ACCESS,
                null,
                0,
                0,
                0,
            )
        } catch (_: Exception) {
            isConsentRequestInProgress = false
            completeWithFailures("failed")
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_WRITE_ACCESS) return false
        val result = pendingResult ?: return false
        isConsentRequestInProgress = false
        if (resultCode == Activity.RESULT_OK) {
            pendingConsentBatches?.let { batches ->
                if (batches.isNotEmpty()) batches.removeFirst()
            }
            if (pendingConsentBatches?.isNotEmpty() == true) {
                startPendingConsentRequest()
            } else {
                val transfer = pendingTransfer
                clearPendingConsent()
                transfer?.invoke()
            }
        } else {
            completeWithFailures("cancelled")
        }
        return true
    }

    private fun completeWithFailures(failure: String) {
        val result = pendingResult ?: return
        val localIDs = pendingLocalIDs
        clearPending()
        isTransferInProgress = false
        result.success(
            mapOf(
                "destinations" to emptyMap<String, Map<String, String>>(),
                "failures" to localIDs.associateWith { failure },
            ),
        )
    }

    private fun clearPending() {
        pendingResult = null
        pendingLocalIDs = emptyList()
        clearPendingConsent()
    }

    private fun clearPendingConsent() {
        pendingTransfer = null
        pendingConsentBatches = null
        isConsentRequestInProgress = false
    }

    private fun completeWithError(error: Exception) {
        val result = pendingResult ?: return
        clearPending()
        isTransferInProgress = false
        result.error(
            "device_folder_transfer_failed",
            error.message,
            null,
        )
    }

    private fun runTransfer(
        transferID: String?,
        recoveryContext: Map<String, Any>?,
        operation: String,
        source: String,
        target: String,
        ids: List<String>,
        result: MethodChannel.Result,
    ) {
        transferExecutor.execute {
            try {
                val transferResult = service.transfer(
                    transferID,
                    recoveryContext,
                    operation,
                    source,
                    target,
                    ids,
                )
                postToMain {
                    if (pendingResult !== result) return@postToMain
                    clearPending()
                    isTransferInProgress = false
                    result.success(transferResult)
                }
            } catch (error: Exception) {
                postToMain {
                    if (pendingResult === result) completeWithError(error)
                }
            }
        }
    }

    private fun postToMain(action: () -> Unit) {
        mainHandler.post {
            if (!isDetached) action()
        }
    }

    private companion object {
        const val REQUEST_WRITE_ACCESS = 8301
        const val MAX_CONSENT_URI_COUNT = 1900
    }
}
