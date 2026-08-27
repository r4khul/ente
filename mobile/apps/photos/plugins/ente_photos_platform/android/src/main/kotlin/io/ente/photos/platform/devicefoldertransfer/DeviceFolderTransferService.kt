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
        allowsReplacementLocalID: Boolean,
        candidateIDs: List<String>,
        sourceLocalIDs: List<String>,
    ): List<String> {
        if (!supportsOperation(operation)) return emptyList()
        val sourceItems = sourceLocalIDs.mapNotNull(::mediaItem)
        if (sourceItems.any { it.bucketID != sourceFolderID }) return emptyList()
        val sourceMediaTypes = sourceItems.map { it.mediaType }.toSet()
        if (sourceMediaTypes.isEmpty()) return emptyList()
        return candidateIDs.filter { candidateID ->
            val target = destination(candidateID) ?: return@filter false
            if (operation == "move" && !allowsReplacementLocalID &&
                sourceItems.any { it.volumeName != target.volumeName }
            ) {
                return@filter false
            }
            sourceMediaTypes.all { mediaType ->
                if (operation == "move" && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    true
                } else if (operation == "move") {
                    supportsMediaTypeAtPath(mediaType, target.relativePath)
                } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    destinationAnchorUri(target, mediaType) != null ||
                        supportsMediaTypeAtPath(mediaType, target.relativePath)
                } else {
                    supportsMediaTypeAtPath(mediaType, target.relativePath)
                }
            }
        }
    }

    fun transfer(
        transferID: String?,
        recoveryContext: Map<String, Any>?,
        operation: String,
        sourceFolderID: String,
        targetFolderID: String,
        allowsReplacementLocalID: Boolean,
        sourceLocalIDs: List<String>,
    ): Map<String, Any> {
        val successes = mutableListOf<String>()
        val destinationLocalIDs = mutableMapOf<String, String>()
        val failures = mutableMapOf<String, String>()
        if (!supportsOperation(operation)) {
            sourceLocalIDs.forEach { failures[it] = "unsupported" }
            return result(successes, destinationLocalIDs, failures)
        }
        fun persistProgress() {
            transferID?.let {
                persistRecoveryResult(
                    it,
                    recoveryContext,
                    result(successes, destinationLocalIDs, failures),
                )
            }
        }
        val target = destination(targetFolderID)
        if (target == null || sourceFolderID == targetFolderID) {
            sourceLocalIDs.forEach { failures[it] = "ineligibleDestination" }
            return result(successes, destinationLocalIDs, failures).also { persistProgress() }
        }
        persistProgress()
        sourceLocalIDs.forEach { localID ->
            val id = localID.toLongOrNull()
            if (id == null) {
                failures[localID] = "missingSource"
                return@forEach
            }
            try {
                val source = mediaItem(localID)
                val targetAnchor = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    source?.let { destinationAnchorUri(target, it.mediaType) }
                } else {
                    null
                }
                if (source == null) {
                    failures[localID] = "missingSource"
                } else if (source.bucketID != sourceFolderID) {
                    failures[localID] = "missingSource"
                } else if (
                    (operation == "copy" || source.volumeName != target.volumeName) &&
                    targetAnchor == null &&
                    !supportsMediaTypeAtPath(source.mediaType, target.relativePath)
                ) {
                    failures[localID] = "ineligibleDestination"
                } else if (operation == "copy") {
                    destinationLocalIDs[localID] = localID(copy(source, target, targetAnchor))
                    successes += localID
                } else if (operation == "move") {
                    destinationLocalIDs[localID] = move(
                        source,
                        target,
                        targetAnchor,
                        allowsReplacementLocalID,
                    )
                    successes += localID
                } else {
                    failures[localID] = "unsupported"
                }
            } catch (_: LocalIDChangeNotAllowedException) {
                failures[localID] = "unsupported"
            } catch (security: SecurityException) {
                failures[localID] = "permissionDenied"
            } catch (error: Exception) {
                Log.e(
                    TAG,
                    "Failed to $operation media=$localID from=$sourceFolderID to=$targetFolderID " +
                        "relativePath=${target.relativePath}",
                    error,
                )
                failures[localID] = "failed"
            }
            persistProgress()
        }
        val result = result(successes, destinationLocalIDs, failures)
        transferID?.let { persistRecoveryResult(it, recoveryContext, result) }
        return result
    }

    fun pendingRecoveries(): List<Map<String, Any>> =
        context.getSharedPreferences(RECOVERY_PREFS, Context.MODE_PRIVATE)
            .all
            .mapNotNull { (transferID, raw) ->
                (raw as? String)?.let { recoveryRecord(transferID, it) }
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

    private fun recoveryRecord(transferID: String, raw: String): Map<String, Any>? {
        return try {
            val json = JSONObject(raw)
            val destinationIDs = json.getJSONObject("destinationLocalIDs")
            val failures = json.getJSONObject("failures")
            val destinationMap = mutableMapOf<String, String>()
            val failureMap = mutableMapOf<String, String>()
            destinationIDs.keys().forEach { key -> destinationMap[key] = destinationIDs.getString(key) }
            failures.keys().forEach { key -> failureMap[key] = failures.getString(key) }
            val recovery = mutableMapOf<String, Any>(
                "transferID" to transferID,
                "sourceFolderID" to json.getString("sourceFolderID"),
                "targetFolderID" to json.getString("targetFolderID"),
                "ownerID" to json.getLong("ownerID"),
                "sourceLocalIDs" to json.getJSONArray("sourceLocalIDs").let { array ->
                    List(array.length()) { index -> array.getString(index) }
                },
                "cloudMoveCompleted" to json.optBoolean("cloudMoveCompleted", false),
                "successLocalIDs" to json.getJSONArray("successLocalIDs").let { array ->
                    List(array.length()) { index -> array.getString(index) }
                },
                "destinationLocalIDs" to destinationMap,
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
        successes: List<String>,
        destinationLocalIDs: Map<String, String>,
        failures: Map<String, String>,
    ) = mapOf(
        "successLocalIDs" to successes,
        "destinationLocalIDs" to destinationLocalIDs,
        "failures" to failures,
    )

    private fun persistRecoveryResult(
        transferID: String,
        recoveryContext: Map<String, Any>?,
        result: Map<String, Any>,
    ) {
        val preferences = context.getSharedPreferences(RECOVERY_PREFS, Context.MODE_PRIVATE)
        val existing = preferences.getString(transferID, null)
        val json = existing?.let(::JSONObject) ?: JSONObject()
        recoveryContext?.forEach { (key, value) ->
            json.put(key, if (value is Collection<*>) JSONArray(value) else value)
        }
        json.apply {
            put("successLocalIDs", JSONArray(result["successLocalIDs"] as List<*>))
            put("destinationLocalIDs", JSONObject(result["destinationLocalIDs"] as Map<*, *>))
            put("failures", JSONObject(result["failures"] as Map<*, *>))
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
    ): Uri {
        val resolver = context.contentResolver
        val mimeType = source.mimeType ?: resolver.getType(source.uri) ?: "application/octet-stream"
        val collection = destinationCollection(source.mediaType, target.volumeName)
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, source.displayName)
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
        return try {
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
            destination
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
        anchor: Uri?,
        allowsReplacementLocalID: Boolean,
    ): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) error("Unsupported Android version")
        if (source.volumeName != target.volumeName) {
            if (!allowsReplacementLocalID) throw LocalIDChangeNotAllowedException()
            val destination = copy(source, target, anchor)
            if (context.contentResolver.delete(source.uri, null, null) != 1) {
                val rolledBack = context.contentResolver.delete(destination, null, null) == 1
                throw IOException(
                    "Could not remove source after copying; destination rollback=$rolledBack",
                )
            }
            return localID(destination)
        }
        val displayName = availableDisplayName(target, source.displayName)
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
        return source.uri.lastPathSegment ?: error("Missing MediaStore ID")
    }

    private fun localID(uri: Uri): String = ContentUris.parseId(uri).toString()

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

    private class LocalIDChangeNotAllowedException : Exception()
}
