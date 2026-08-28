package io.ente.photos.platform.devicefoldertransfer

import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.MediaStore
import android.util.Log
import java.io.IOException
import org.json.JSONArray
import org.json.JSONObject

internal class DeviceFolderTransferService(private val context: Context) {
    fun supportedOperations(): List<String> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) listOf("copy", "move") else emptyList()

    fun eligibleDestinationIDs(
        operation: String?,
        sourceFolderID: String,
        candidateIDs: List<String>,
        sourceLocalIDs: List<String>,
    ): List<String> {
        val resolvedOperation = operation ?: return emptyList()
        if (!supportsOperation(resolvedOperation)) return emptyList()
        val sourceItems = sourceLocalIDs.map(::mediaItem)
        if (sourceItems.any { it == null }) return emptyList()
        val resolvedSourceItems = sourceItems.filterNotNull()
        if (resolvedSourceItems.any { it.bucketID != sourceFolderID }) return emptyList()
        if (resolvedSourceItems.isEmpty()) return emptyList()
        return candidateIDs.filter { candidateID ->
            val target = destination(candidateID) ?: return@filter false
            resolvedSourceItems.all { source ->
                transferPlan(resolvedOperation, source, target) != null
            }
        }
    }

    fun transfer(
        transferID: String?,
        recoveryContext: Map<String, Any>?,
        operation: String,
        sourceFolderID: String,
        targetFolderID: String,
        sourceLocalIDs: List<String>,
    ): Map<String, Any> {
        val destinations = mutableMapOf<String, TransferredMediaItem>()
        val failures = mutableMapOf<String, String>()
        val pendingMoves = mutableMapOf<String, PendingMove>()
        if (!supportsOperation(operation)) {
            sourceLocalIDs.forEach { failures[it] = "unsupported" }
            return result(destinations, failures)
        }
        if (operation == "move" && (transferID == null || recoveryContext == null)) {
            sourceLocalIDs.forEach { failures[it] = "failed" }
            return result(destinations, failures)
        }
        fun persistProgress() {
            transferID?.let {
                persistRecoveryResult(
                    it,
                    recoveryContext,
                    result(destinations, failures),
                    pendingMoves,
                )
            }
        }
        val target = destination(targetFolderID)
        if (target == null || sourceFolderID == targetFolderID) {
            sourceLocalIDs.forEach { failures[it] = "ineligibleDestination" }
            return result(destinations, failures)
        }
        sourceLocalIDs.forEach { localID ->
            if (localID.toLongOrNull() == null) {
                failures[localID] = "missingSource"
                return@forEach
            }
            var shouldPersistRecovery = false
            var preparedMove: PendingMove? = null

            fun restoreUncheckpointedMove() {
                preparedMove?.let { pending ->
                    if (destinations.containsKey(localID) && !pendingMoves.containsKey(localID)) {
                        pendingMoves[localID] = pending
                        destinations.remove(localID)
                    }
                }
            }

            try {
                val source = mediaItem(localID)
                if (source == null) {
                    failures[localID] = "missingSource"
                } else if (source.bucketID != sourceFolderID) {
                    failures[localID] = "missingSource"
                } else {
                    val plan = transferPlan(operation, source, target)
                    if (plan == null) {
                        failures[localID] = "ineligibleDestination"
                    } else if (operation == "copy") {
                        destinations[localID] = copy(source, target, plan.anchor)
                    } else {
                        try {
                            val moved = move(
                                source,
                                target,
                                plan,
                                onPrepared = { pending ->
                                    preparedMove = pending
                                    pendingMoves[localID] = pending
                                    persistProgress()
                                },
                            )
                            destinations[localID] = moved
                            pendingMoves.remove(localID)
                            shouldPersistRecovery = true
                        } catch (error: Exception) {
                            preparedMove?.let { pending ->
                                if (isRolledBack(pending)) {
                                    pendingMoves.remove(localID)
                                    destinations.remove(localID)
                                    shouldPersistRecovery = true
                                }
                            }
                            throw error
                        }
                    }
                }
                if (shouldPersistRecovery) persistProgress()
            } catch (security: SecurityException) {
                restoreUncheckpointedMove()
                failures[localID] = "permissionDenied"
            } catch (error: Exception) {
                restoreUncheckpointedMove()
                Log.e(
                    TAG,
                    "Failed to $operation media=$localID from=$sourceFolderID to=$targetFolderID " +
                        "relativePath=${target.relativePath}",
                    error,
                )
                failures[localID] = "failed"
            }
        }
        val result = result(destinations, failures, pendingMoves)
        return result
    }

    fun pendingRecoveries(): List<Map<String, Any>> =
        context.getSharedPreferences(RECOVERY_PREFS, Context.MODE_PRIVATE)
            .all
            .mapNotNull { (transferID, raw) ->
                (raw as? String)?.let { repairRecovery(transferID, it) }
                    ?.let { recoveryRecord(transferID, it) }
            }

    fun markCloudMoveCompleted(transferID: String): Boolean {
        val preferences = context.getSharedPreferences(RECOVERY_PREFS, Context.MODE_PRIVATE)
        val raw = preferences.getString(transferID, null) ?: return false
        val json = try {
            JSONObject(raw)
        } catch (error: Exception) {
            Log.e(TAG, "Could not update device-folder transfer recovery result", error)
            return false
        }
        json.put("cloudMoveCompleted", true)
        return preferences.edit().putString(transferID, json.toString()).commit()
    }

    private fun repairRecovery(transferID: String, raw: String): String? {
        val json = try {
            JSONObject(raw)
        } catch (error: Exception) {
            Log.e(TAG, "Could not repair device-folder transfer recovery record", error)
            return null
        }
        val pendingMoves = json.optJSONObject("pendingMoves") ?: return raw
        if (pendingMoves.length() == 0) return raw
        val destinations = json.optJSONObject("destinations") ?: JSONObject().also {
            json.put("destinations", it)
        }
        val failures = json.optJSONObject("failures") ?: JSONObject().also {
            json.put("failures", it)
        }
        val sourceIDs = buildList { pendingMoves.keys().forEach(::add) }
        for (sourceID in sourceIDs) {
            val pending = try {
                PendingMove.fromJson(pendingMoves.getJSONObject(sourceID))
            } catch (error: Exception) {
                Log.e(TAG, "Could not parse pending device-folder move", error)
                return null
            }
            when (pending.kind) {
                PendingMoveKind.copyDelete -> {
                    val sourceExists = mediaExists(pending.sourceUri)
                    val destinationUri = pending.destinationUri ?: return null
                    val destinationExists = mediaExists(destinationUri)
                    if (sourceExists) {
                        val removed = !destinationExists ||
                            runCatching {
                                context.contentResolver.delete(destinationUri, null, null) == 1 ||
                                    !mediaExists(destinationUri)
                            }.getOrDefault(false)
                        if (!removed) return null
                        destinations.remove(sourceID)
                        failures.put(sourceID, "failed")
                    } else if (destinationExists) {
                        destinations.put(sourceID, pending.destination.toJson())
                        failures.remove(sourceID)
                    } else {
                        destinations.remove(sourceID)
                        failures.put(sourceID, "failed")
                    }
                }

                PendingMoveKind.relocate -> {
                    val state = mediaState(pending.sourceUri) ?: return null
                    when (state) {
                        MediaState(pending.targetRelativePath, pending.destination.displayName) -> {
                            destinations.put(sourceID, pending.destination.toJson())
                            failures.remove(sourceID)
                        }

                        MediaState(pending.sourceRelativePath, pending.sourceDisplayName) -> {
                            destinations.remove(sourceID)
                            failures.put(sourceID, "failed")
                        }

                        else -> return null
                    }
                }
            }
            pendingMoves.remove(sourceID)
        }
        val updated = json.toString()
        val persisted = context.getSharedPreferences(RECOVERY_PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(transferID, updated)
            .commit()
        return updated.takeIf { persisted }
    }

    private fun recoveryRecord(transferID: String, raw: String): Map<String, Any>? {
        return try {
            val json = JSONObject(raw)
            val failures = json.getJSONObject("failures")
            val destinationMap = mutableMapOf<String, Map<String, Any?>>()
            val failureMap = mutableMapOf<String, String>()
            val destinations = json.optJSONObject("destinations")
            destinations?.keys()?.forEach { key ->
                val destination = destinations.getJSONObject(key)
                destinationMap[key] = mapOf(
                    "localID" to destination.getString("localID"),
                    "displayName" to destination.getString("displayName"),
                )
            }
            if (destinations == null) {
                json.optJSONObject("destinationLocalIDs")?.let { legacy ->
                    legacy.keys().forEach { key ->
                        val destinationID = legacy.getString(key)
                        destinationMap[key] = mapOf(
                            "localID" to destinationID,
                            "displayName" to mediaItem(destinationID)?.displayName,
                        )
                    }
                }
            }
            failures.keys().forEach { key -> failureMap[key] = failures.getString(key) }
            val recovery = mutableMapOf<String, Any>(
                "transferID" to transferID,
                "sourceFolderID" to json.getString("sourceFolderID"),
                "targetFolderID" to json.getString("targetFolderID"),
                "ownerID" to json.getLong("ownerID"),
                "sourceLocalIDs" to json.getJSONArray("sourceLocalIDs").let { array ->
                    List(array.length()) { index -> array.getString(index) }
                },
                "sourceRecordIDs" to json.optJSONObject("sourceRecordIDs").let { records ->
                    buildMap {
                        records?.keys()?.forEach { key -> put(key, records.getLong(key)) }
                    }
                },
                "cloudMoveCompleted" to json.optBoolean("cloudMoveCompleted", false),
                "destinations" to destinationMap,
                "failures" to failureMap,
            )
            if (json.has("cloudMoveSourceCollectionID")) {
                recovery["cloudMoveSourceCollectionID"] =
                    json.getLong("cloudMoveSourceCollectionID")
            }
            if (json.has("cloudMoveSourceLocalIDs")) {
                recovery["cloudMoveSourceLocalIDs"] =
                    json.getJSONArray("cloudMoveSourceLocalIDs").let { array ->
                        List(array.length()) { index -> array.getString(index) }
                    }
            }
            if (json.has("cloudMoveSourceUploadedFileIDs")) {
                recovery["cloudMoveSourceUploadedFileIDs"] =
                    json.getJSONObject("cloudMoveSourceUploadedFileIDs").let { records ->
                        buildMap {
                            records.keys().forEach { key ->
                                val ids = records.getJSONArray(key)
                                put(key, List(ids.length()) { index -> ids.getLong(index) })
                            }
                        }
                    }
            }
            recovery
        } catch (error: Exception) {
            Log.e(TAG, "Could not read device-folder transfer recovery record", error)
            null
        }
    }

    fun acknowledgeRecovery(transferID: String): Boolean =
        context.getSharedPreferences(RECOVERY_PREFS, Context.MODE_PRIVATE)
            .edit()
            .remove(transferID)
            .commit()

    fun mediaUri(localID: String): Uri? {
        return mediaItem(localID)?.uri
    }

    private fun mediaItem(localID: String): MediaItem? {
        val id = localID.toLongOrNull() ?: return null
        return context.contentResolver.query(
            MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL, id),
            arrayOf(
                MediaStore.Files.FileColumns.MEDIA_TYPE,
                MediaStore.MediaColumns.VOLUME_NAME,
                MediaStore.MediaColumns.DISPLAY_NAME,
                MediaStore.MediaColumns.SIZE,
                MediaStore.Images.ImageColumns.DATE_TAKEN,
                MediaStore.MediaColumns.BUCKET_ID,
                MediaStore.MediaColumns.MIME_TYPE,
                MediaStore.MediaColumns.RELATIVE_PATH,
            ),
            null,
            null,
            null,
        )?.use { cursor ->
            if (!cursor.moveToFirst()) return@use null
            val mediaType = cursor.getInt(0)
            val volumeName = cursor.getString(1) ?: return@use null
            val displayName = cursor.getString(2) ?: return@use null
            val size = cursor.takeUnless { it.isNull(3) }?.getLong(3)
            val dateTaken = cursor.takeUnless { it.isNull(4) }?.getLong(4)
            val bucketID = cursor.getString(5) ?: return@use null
            val mimeType = cursor.takeUnless { it.isNull(6) }?.getString(6)
            val relativePath = cursor.getString(7) ?: return@use null
            val collection = mediaCollection(mediaType, volumeName) ?: return@use null
            MediaItem(
                ContentUris.withAppendedId(collection, id),
                mediaType,
                displayName,
                volumeName,
                size,
                dateTaken,
                bucketID,
                mimeType,
                relativePath,
            )
        }
    }

    private fun mediaCollection(mediaType: Int, volumeName: String): Uri? =
        when (mediaType) {
            MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE ->
                MediaStore.Images.Media.getContentUri(volumeName)

            MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO ->
                MediaStore.Video.Media.getContentUri(volumeName)

            else -> null
        }

    private fun result(
        destinations: Map<String, TransferredMediaItem>,
        failures: Map<String, String>,
        pendingMoves: Map<String, PendingMove> = emptyMap(),
    ) = mapOf(
        "destinations" to destinations.mapValues { it.value.toChannelMap() },
        "failures" to failures,
        "requiresRecovery" to pendingMoves.isNotEmpty(),
    )

    private fun persistRecoveryResult(
        transferID: String,
        recoveryContext: Map<String, Any>?,
        result: Map<String, Any>,
        pendingMoves: Map<String, PendingMove>,
    ) {
        val preferences = context.getSharedPreferences(RECOVERY_PREFS, Context.MODE_PRIVATE)
        val existing = preferences.getString(transferID, null)
        val json = existing?.let(::JSONObject) ?: JSONObject()
        recoveryContext?.forEach { (key, value) ->
            json.put(key, jsonValue(value))
        }
        json.apply {
            put("destinations", jsonValue(result["destinations"] as Map<*, *>))
            put("failures", JSONObject(result["failures"] as Map<*, *>))
            put(
                "pendingMoves",
                JSONObject().apply {
                    pendingMoves.forEach { (sourceID, pending) ->
                        put(sourceID, pending.toJson())
                    }
                },
            )
            remove("destinationLocalIDs")
        }
        check(preferences
            .edit()
            .putString(transferID, json.toString())
            .commit()) { "Could not persist device-folder transfer recovery record" }
    }

    private fun destination(bucketID: String): DeviceFolderDestination? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null
        return context.contentResolver.query(
            MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL),
            arrayOf(
                MediaStore.MediaColumns.RELATIVE_PATH,
                MediaStore.MediaColumns.VOLUME_NAME,
            ),
            "${MediaStore.Images.Media.BUCKET_ID}=? AND " +
                "${MediaStore.MediaColumns.IS_PENDING}=0",
            arrayOf(bucketID),
            null,
        )?.use { cursor ->
            if (!cursor.moveToFirst()) return@use null
            val relativePath = cursor.getString(0) ?: return@use null
            val volumeName = cursor.getString(1) ?: return@use null
            DeviceFolderDestination(bucketID, relativePath, volumeName)
        }
    }

    private fun copy(
        source: MediaItem,
        target: DeviceFolderDestination,
        anchor: Uri?,
        onCreated: (TransferredMediaItem) -> Unit = {},
    ): TransferredMediaItem {
        val resolver = context.contentResolver
        val mimeType = source.mimeType ?: resolver.getType(source.uri) ?: "application/octet-stream"
        val collection = destinationCollection(source.mediaType, target.volumeName)
        val displayName = availableDisplayName(target, source.displayName)
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, displayName)
            put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
            put(MediaStore.MediaColumns.RELATIVE_PATH, target.relativePath)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
            source.dateTaken?.let {
                put(MediaStore.Images.ImageColumns.DATE_TAKEN, it)
            }
        }
        val destination = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            resolver.insert(collection, values, placementExtras(anchor))
        } else {
            resolver.insert(collection, values)
        } ?: error("Could not create destination")
        val transferred = TransferredMediaItem(destination, displayName)
        return try {
            onCreated(transferred)
            val inputStream = resolver.openInputStream(source.uri)
                ?: throw IOException("Could not open source")
            val outputStream = resolver.openOutputStream(destination)
                ?: throw IOException("Could not open destination")
            val copiedBytes = inputStream.use { input ->
                outputStream.use { output -> input.copyTo(output) }
            }
            if (source.size != null && copiedBytes != source.size) {
                throw IOException("Copied byte count does not match source")
            }
            val published = resolver.update(destination, ContentValues().apply {
                put(MediaStore.MediaColumns.IS_PENDING, 0)
            }, null, null)
            if (published != 1) throw IOException("Could not publish destination")
            transferred
        } catch (error: Exception) {
            val removed = runCatching { resolver.delete(destination, null, null) }
                .getOrDefault(0)
            if (removed != 1) {
                Log.e(TAG, "Could not remove incomplete destination=$destination")
            }
            throw error
        }
    }

    private fun move(
        source: MediaItem,
        target: DeviceFolderDestination,
        plan: MediaTransferPlan,
        onPrepared: (PendingMove) -> Unit,
    ): TransferredMediaItem {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) error("Unsupported Android version")
        if (plan.requiresCopy) {
            lateinit var pending: PendingMove
            val destination = copy(source, target, plan.anchor) { created ->
                pending = PendingMove(
                    kind = PendingMoveKind.copyDelete,
                    sourceUri = source.uri,
                    destinationUri = created.uri,
                    destination = created,
                    sourceDisplayName = source.displayName,
                    sourceRelativePath = source.relativePath,
                    targetRelativePath = target.relativePath,
                )
                onPrepared(pending)
            }
            if (context.contentResolver.delete(source.uri, null, null) != 1) {
                val rolledBack = context.contentResolver.delete(destination.uri, null, null) == 1
                throw IOException(
                    "Could not remove source after copying; destination rollback=$rolledBack",
                )
            }
            return destination
        }
        val displayName = availableDisplayName(target, source.displayName)
        val destination = TransferredMediaItem(source.uri, displayName)
        onPrepared(
            PendingMove(
                kind = PendingMoveKind.relocate,
                sourceUri = source.uri,
                destinationUri = null,
                destination = destination,
                sourceDisplayName = source.displayName,
                sourceRelativePath = source.relativePath,
                targetRelativePath = target.relativePath,
            ),
        )
        val updated = context.contentResolver.update(
            source.uri,
            ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, displayName)
                put(MediaStore.MediaColumns.RELATIVE_PATH, target.relativePath)
            },
            null,
            null,
        )
        if (updated != 1) throw IOException("MediaStore could not move source")
        try {
            verifyMove(source, target, displayName)
        } catch (error: Exception) {
            val rolledBack = runCatching {
                context.contentResolver.update(
                    source.uri,
                    ContentValues().apply {
                        put(MediaStore.MediaColumns.DISPLAY_NAME, source.displayName)
                        put(MediaStore.MediaColumns.RELATIVE_PATH, source.relativePath)
                    },
                    null,
                    null,
                ) == 1
            }.getOrDefault(false)
            throw IOException("MediaStore did not confirm move; rollback=$rolledBack", error)
        }
        return destination
    }

    private fun transferPlan(
        operation: String,
        source: MediaItem,
        target: DeviceFolderDestination,
    ): MediaTransferPlan? {
        val anchor = destinationAnchorUri(target, source.mediaType)
        val requiresCopy = operation == "copy" || source.volumeName != target.volumeName
        if (!requiresCopy && !supportsMediaTypeAtPath(source.mediaType, target.relativePath)) {
            return null
        }
        if (
            requiresCopy &&
            anchor == null &&
            !supportsMediaTypeAtPath(source.mediaType, target.relativePath)
        ) {
            return null
        }
        return MediaTransferPlan(anchor, requiresCopy)
    }

    private fun isRolledBack(pending: PendingMove): Boolean =
        when (pending.kind) {
            PendingMoveKind.copyDelete ->
                mediaExists(pending.sourceUri) &&
                    (pending.destinationUri == null || !mediaExists(pending.destinationUri))

            PendingMoveKind.relocate ->
                mediaState(pending.sourceUri) ==
                    MediaState(pending.sourceRelativePath, pending.sourceDisplayName)
        }

    private fun mediaExists(uri: Uri): Boolean =
        context.contentResolver.query(
            uri,
            arrayOf(MediaStore.MediaColumns._ID),
            null,
            null,
            null,
        )?.use { it.moveToFirst() } ?: false

    private fun mediaState(uri: Uri): MediaState? =
        context.contentResolver.query(
            uri,
            arrayOf(
                MediaStore.MediaColumns.RELATIVE_PATH,
                MediaStore.MediaColumns.DISPLAY_NAME,
            ),
            null,
            null,
            null,
        )?.use { cursor ->
            if (!cursor.moveToFirst()) return@use null
            val relativePath = cursor.getString(0) ?: return@use null
            val displayName = cursor.getString(1) ?: return@use null
            MediaState(relativePath, displayName)
        }

    private fun jsonValue(value: Any): Any = when (value) {
        is Map<*, *> -> JSONObject().apply {
            value.forEach { (key, nestedValue) ->
                if (key is String && nestedValue != null) put(key, jsonValue(nestedValue))
            }
        }

        is Collection<*> -> JSONArray().apply {
            value.forEach { nestedValue ->
                if (nestedValue != null) put(jsonValue(nestedValue))
            }
        }

        else -> value
    }

    private fun supportsOperation(operation: String?): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.R &&
            (operation == "copy" || operation == "move")

    private fun availableDisplayName(target: DeviceFolderDestination, sourceName: String): String {
        if (!containsDisplayName(target, sourceName)) return sourceName

        val extensionStart = sourceName.lastIndexOf('.').takeIf { it > 0 } ?: sourceName.length
        val baseName = sourceName.substring(0, extensionStart)
        val extension = sourceName.substring(extensionStart)
        var suffix = 1
        var candidate: String
        do {
            candidate = "$baseName ($suffix)$extension"
            suffix++
        } while (containsDisplayName(target, candidate))
        return candidate
    }

    private fun containsDisplayName(target: DeviceFolderDestination, displayName: String): Boolean =
        context.contentResolver.query(
            MediaStore.Files.getContentUri(target.volumeName),
            arrayOf(MediaStore.MediaColumns._ID),
            "${MediaStore.MediaColumns.RELATIVE_PATH}=? AND " +
                "${MediaStore.MediaColumns.DISPLAY_NAME}=? AND " +
                "${MediaStore.MediaColumns.IS_PENDING}=0",
            arrayOf(target.relativePath, displayName),
            null,
        )?.use { it.moveToFirst() } ?: false

    private fun verifyMove(
        source: MediaItem,
        target: DeviceFolderDestination,
        displayName: String,
    ) {
        val actual = context.contentResolver.query(
            source.uri,
            arrayOf(
                MediaStore.MediaColumns.RELATIVE_PATH,
                MediaStore.MediaColumns.DISPLAY_NAME,
            ),
            null,
            null,
            null,
        )?.use { cursor ->
            if (!cursor.moveToFirst()) return@use null
            cursor.getString(0) to cursor.getString(1)
        }
        if (actual?.first != target.relativePath || actual?.second != displayName) {
            throw IOException("MediaStore did not confirm move")
        }
    }

    private fun destinationCollection(mediaType: Int, volumeName: String): Uri =
        if (mediaType == MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO) {
            MediaStore.Video.Media.getContentUri(volumeName)
        } else {
            MediaStore.Images.Media.getContentUri(volumeName)
        }

    private fun placementExtras(anchor: Uri?): Bundle? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && anchor != null) {
            Bundle().apply { putParcelable(MediaStore.QUERY_ARG_RELATED_URI, anchor) }
        } else {
            null
        }

    private fun destinationAnchorUri(
        destination: DeviceFolderDestination,
        mediaType: Int,
    ): Uri? {
        val id = context.contentResolver.query(
            MediaStore.Files.getContentUri(destination.volumeName),
            arrayOf(MediaStore.MediaColumns._ID),
            "${MediaStore.Images.Media.BUCKET_ID}=? AND " +
                "${MediaStore.Files.FileColumns.MEDIA_TYPE}=? AND " +
                "${MediaStore.MediaColumns.IS_PENDING}=0",
            arrayOf(destination.bucketID, mediaType.toString()),
            null,
        )?.use { cursor -> if (cursor.moveToFirst()) cursor.getLong(0) else null }
            ?: return null
        val collection = mediaCollection(mediaType, destination.volumeName) ?: return null
        return ContentUris.withAppendedId(collection, id)
    }

    private fun supportsMediaTypeAtPath(mediaType: Int, relativePath: String): Boolean {
        val primaryDirectory = relativePath.substringBefore('/').trim()
        return when (mediaType) {
            MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE ->
                primaryDirectory.equals(Environment.DIRECTORY_DCIM, ignoreCase = true) ||
                    primaryDirectory.equals(Environment.DIRECTORY_PICTURES, ignoreCase = true)

            MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO ->
                primaryDirectory.equals(Environment.DIRECTORY_DCIM, ignoreCase = true) ||
                    primaryDirectory.equals(Environment.DIRECTORY_MOVIES, ignoreCase = true) ||
                    primaryDirectory.equals(Environment.DIRECTORY_PICTURES, ignoreCase = true)

            else -> false
        }
    }

    private companion object {
        const val TAG = "DeviceFolderTransfer"
        const val RECOVERY_PREFS = "device_folder_transfer_recovery"
    }

    private data class DeviceFolderDestination(
        val bucketID: String,
        val relativePath: String,
        val volumeName: String,
    )

    private data class MediaItem(
        val uri: Uri,
        val mediaType: Int,
        val displayName: String,
        val volumeName: String,
        val size: Long?,
        val dateTaken: Long?,
        val bucketID: String,
        val mimeType: String?,
        val relativePath: String,
    )

    private data class MediaTransferPlan(
        val anchor: Uri?,
        val requiresCopy: Boolean,
    )

    private data class TransferredMediaItem(
        val uri: Uri,
        val displayName: String,
    ) {
        val localID: String
            get() = ContentUris.parseId(uri).toString()

        fun toChannelMap(): Map<String, String> = mapOf(
            "localID" to localID,
            "displayName" to displayName,
        )

        fun toJson(): JSONObject = JSONObject(toChannelMap())
    }

    private enum class PendingMoveKind { copyDelete, relocate }

    private data class PendingMove(
        val kind: PendingMoveKind,
        val sourceUri: Uri,
        val destinationUri: Uri?,
        val destination: TransferredMediaItem,
        val sourceDisplayName: String,
        val sourceRelativePath: String,
        val targetRelativePath: String,
    ) {
        fun toJson(): JSONObject = JSONObject().apply {
            put("kind", kind.name)
            put("sourceUri", sourceUri.toString())
            destinationUri?.let { put("destinationUri", it.toString()) }
            put("destination", destination.toJson())
            put("sourceDisplayName", sourceDisplayName)
            put("sourceRelativePath", sourceRelativePath)
            put("targetRelativePath", targetRelativePath)
        }

        companion object {
            fun fromJson(json: JSONObject): PendingMove {
                val destination = json.getJSONObject("destination")
                val destinationUri = json.optString("destinationUri")
                    .takeIf(String::isNotEmpty)
                    ?.let(Uri::parse)
                return PendingMove(
                    kind = PendingMoveKind.valueOf(json.getString("kind")),
                    sourceUri = Uri.parse(json.getString("sourceUri")),
                    destinationUri = destinationUri,
                    destination = TransferredMediaItem(
                        uri = destinationUri ?: Uri.parse(json.getString("sourceUri")),
                        displayName = destination.getString("displayName"),
                    ),
                    sourceDisplayName = json.getString("sourceDisplayName"),
                    sourceRelativePath = json.getString("sourceRelativePath"),
                    targetRelativePath = json.getString("targetRelativePath"),
                )
            }
        }
    }

    private data class MediaState(
        val relativePath: String,
        val displayName: String,
    )
}
