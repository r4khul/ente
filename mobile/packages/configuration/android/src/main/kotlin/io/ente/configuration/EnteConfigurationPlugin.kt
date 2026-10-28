package io.ente.configuration

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class EnteConfigurationPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private lateinit var executor: ExecutorService
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        executor = Executors.newSingleThreadExecutor()
        channel = MethodChannel(binding.binaryMessenger, "io.ente.configuration/secure_storage")
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "flush") {
            result.notImplemented()
            return
        }
        val name = call.argument<Map<String, String>>("options")
            ?.get("sharedPreferencesName")?.takeIf { it.isNotEmpty() } ?: "FlutterSecureStorage"
        executor.execute {
            try {
                val committed = context.getSharedPreferences(name, Context.MODE_PRIVATE).edit().commit()
                mainHandler.post {
                    if (committed) {
                        result.success(null)
                    } else {
                        result.error("storageCommitFailed", "Secure storage could not be persisted", null)
                    }
                }
            } catch (e: Exception) {
                mainHandler.post {
                    result.error("storageCommitFailed", "Secure storage could not be persisted", null)
                }
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        executor.shutdown()
    }
}
