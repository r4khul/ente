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

internal class DeviceFolderTransferService(private val context: Context) {
    fun supportedOperations(): List<String> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) listOf("copy", "move") else emptyList()

    fun eligibleDestinationIDs(
        operation: String?,
        sourceFolderID: String,
        candidateIDs: List<String>,
        sourceLocalIDs: List<String>,
    ): List<String> {
        if (!supports(operation)) return emptyList()
        val sources = sourceLocalIDs.map(::mediaItem)
        if (sources.isEmpty() || sources.any { it?.bucketID != sourceFolderID }) return emptyList()
        return candidateIDs.filter { candidateID ->
            val target = destination(candidateID) ?: return@filter false
            sources.filterNotNull().all { plan(operation!!, it, target) != null }
        }
    }

    fun transfer(
        operation: String,
        sourceFolderID: String,
        targetFolderID: String,
        sourceLocalIDs: List<String>,
    ): Map<String, Any> {
        val destinations = mutableMapOf<String, Map<String, String>>()
        val failures = mutableMapOf<String, String>()
        if (!supports(operation)) {
            sourceLocalIDs.forEach { failures[it] = "unsupported" }
            return result(destinations, failures)
        }
        val target = destination(targetFolderID)
        if (target == null || targetFolderID == sourceFolderID) {
            sourceLocalIDs.forEach { failures[it] = "ineligibleDestination" }
            return result(destinations, failures)
        }
        sourceLocalIDs.forEach { localID ->
            try {
                val source = mediaItem(localID)
                if (source == null || source.bucketID != sourceFolderID) {
                    failures[localID] = "missingSource"
                    return@forEach
                }
                val plan = plan(operation, source, target)
                if (plan == null) {
                    failures[localID] = "ineligibleDestination"
                    return@forEach
                }
                destinations[localID] = if (operation == "copy") {
                    copy(source, target, plan.anchor)
                } else if (plan.requiresCopy) {
                    val copied = copy(source, target, plan.anchor)
                    if (context.contentResolver.delete(source.uri, null, null) != 1) {
                        throw IOException("Could not remove source after copying")
                    }
                    copied
                } else {
                    relocate(source, target)
                }
            } catch (error: SecurityException) {
                failures[localID] = "permissionDenied"
            } catch (error: Exception) {
                Log.e(TAG, "Could not $operation media=$localID", error)
                failures[localID] = "failed"
            }
        }
        return result(destinations, failures)
    }

    fun mediaUri(localID: String): Uri? = mediaItem(localID)?.uri

    private fun result(
        destinations: Map<String, Map<String, String>>,
        failures: Map<String, String>,
    ): Map<String, Any> = mapOf("destinations" to destinations, "failures" to failures)

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
            val name = cursor.getString(2) ?: return@use null
            val bucketID = cursor.getString(5) ?: return@use null
            if (cursor.getString(7) == null) return@use null
            val collection = mediaCollection(mediaType, volumeName) ?: return@use null
            MediaItem(
                ContentUris.withAppendedId(collection, id),
                mediaType,
                volumeName,
                name,
                cursor.takeUnless { it.isNull(3) }?.getLong(3),
                cursor.takeUnless { it.isNull(4) }?.getLong(4),
                bucketID,
                cursor.takeUnless { it.isNull(6) }?.getString(6),
            )
        }
    }

    private fun destination(bucketID: String): Destination? =
        context.contentResolver.query(
            MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL),
            arrayOf(MediaStore.MediaColumns.RELATIVE_PATH, MediaStore.MediaColumns.VOLUME_NAME),
            "${MediaStore.Images.Media.BUCKET_ID}=? AND ${MediaStore.MediaColumns.IS_PENDING}=0",
            arrayOf(bucketID),
            null,
        )?.use { cursor ->
            if (cursor.moveToFirst()) {
                cursor.getString(0)?.let { path ->
                    cursor.getString(1)?.let { volume -> Destination(bucketID, path, volume) }
                }
            } else {
                null
            }
        }

    private fun copy(source: MediaItem, target: Destination, anchor: Uri?): Map<String, String> {
        val resolver = context.contentResolver
        val name = availableDisplayName(target, source.displayName)
        val destination = resolver.insert(
            destinationCollection(source.mediaType, target.volumeName),
            ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                put(MediaStore.MediaColumns.MIME_TYPE, source.mimeType ?: resolver.getType(source.uri))
                put(MediaStore.MediaColumns.RELATIVE_PATH, target.relativePath)
                put(MediaStore.MediaColumns.IS_PENDING, 1)
                source.dateTaken?.let { put(MediaStore.Images.ImageColumns.DATE_TAKEN, it) }
            },
            placementExtras(anchor),
        ) ?: throw IOException("Could not create destination")
        val copied = resolver.openInputStream(source.uri)?.use { input ->
            resolver.openOutputStream(destination)?.use { output -> input.copyTo(output) }
                ?: throw IOException("Could not open destination")
        } ?: throw IOException("Could not open source")
        if (source.size != null && copied != source.size) throw IOException("Copied byte count does not match source")
        if (resolver.update(destination, ContentValues().apply {
                put(MediaStore.MediaColumns.IS_PENDING, 0)
            }, null, null) != 1) {
            throw IOException("Could not publish destination")
        }
        return mapOf("localID" to ContentUris.parseId(destination).toString(), "displayName" to name)
    }

    private fun relocate(source: MediaItem, target: Destination): Map<String, String> {
        val name = availableDisplayName(target, source.displayName)
        if (context.contentResolver.update(source.uri, ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                put(MediaStore.MediaColumns.RELATIVE_PATH, target.relativePath)
            }, null, null) != 1) {
            throw IOException("MediaStore could not move source")
        }
        return mapOf("localID" to ContentUris.parseId(source.uri).toString(), "displayName" to name)
    }

    private fun plan(operation: String, source: MediaItem, target: Destination): Plan? {
        val requiresCopy = operation == "copy" || source.volumeName != target.volumeName
        val anchor = destinationAnchorUri(target, source.mediaType)
        if (!requiresCopy && !supportsMediaTypeAtPath(source.mediaType, target.relativePath)) return null
        if (requiresCopy && anchor == null && !supportsMediaTypeAtPath(source.mediaType, target.relativePath)) return null
        return Plan(anchor, requiresCopy)
    }

    private fun availableDisplayName(target: Destination, sourceName: String): String {
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

    private fun containsDisplayName(target: Destination, displayName: String): Boolean =
        context.contentResolver.query(
            MediaStore.Files.getContentUri(target.volumeName),
            arrayOf(MediaStore.MediaColumns._ID),
            "${MediaStore.MediaColumns.RELATIVE_PATH}=? AND ${MediaStore.MediaColumns.DISPLAY_NAME}=? AND ${MediaStore.MediaColumns.IS_PENDING}=0",
            arrayOf(target.relativePath, displayName),
            null,
        )?.use { it.moveToFirst() } ?: false

    private fun destinationAnchorUri(target: Destination, mediaType: Int): Uri? {
        val id = context.contentResolver.query(
            MediaStore.Files.getContentUri(target.volumeName),
            arrayOf(MediaStore.MediaColumns._ID),
            "${MediaStore.Images.Media.BUCKET_ID}=? AND ${MediaStore.Files.FileColumns.MEDIA_TYPE}=? AND ${MediaStore.MediaColumns.IS_PENDING}=0",
            arrayOf(target.bucketID, mediaType.toString()),
            null,
        )?.use { if (it.moveToFirst()) it.getLong(0) else null } ?: return null
        return mediaCollection(mediaType, target.volumeName)?.let { ContentUris.withAppendedId(it, id) }
    }

    private fun mediaCollection(mediaType: Int, volumeName: String): Uri? = when (mediaType) {
        MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE -> MediaStore.Images.Media.getContentUri(volumeName)
        MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO -> MediaStore.Video.Media.getContentUri(volumeName)
        else -> null
    }

    private fun destinationCollection(mediaType: Int, volumeName: String): Uri =
        mediaCollection(mediaType, volumeName) ?: error("Unsupported media type")

    private fun placementExtras(anchor: Uri?): Bundle? =
        anchor?.let { Bundle().apply { putParcelable(MediaStore.QUERY_ARG_RELATED_URI, it) } }

    private fun supportsMediaTypeAtPath(mediaType: Int, path: String): Boolean {
        val directory = path.substringBefore('/').trim()
        return when (mediaType) {
            MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE ->
                directory.equals(Environment.DIRECTORY_DCIM, true) || directory.equals(Environment.DIRECTORY_PICTURES, true)
            MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO ->
                directory.equals(Environment.DIRECTORY_DCIM, true) ||
                    directory.equals(Environment.DIRECTORY_MOVIES, true) ||
                    directory.equals(Environment.DIRECTORY_PICTURES, true)
            else -> false
        }
    }

    private fun supports(operation: String?): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && (operation == "copy" || operation == "move")

    private data class Destination(val bucketID: String, val relativePath: String, val volumeName: String)
    private data class Plan(val anchor: Uri?, val requiresCopy: Boolean)
    private data class MediaItem(
        val uri: Uri,
        val mediaType: Int,
        val volumeName: String,
        val displayName: String,
        val size: Long?,
        val dateTaken: Long?,
        val bucketID: String,
        val mimeType: String?,
    )

    private companion object { const val TAG = "DeviceFolderTransfer" }
}
