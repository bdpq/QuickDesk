package com.quickcoder.quickdesk_android

import android.content.ContentValues
import android.content.Context
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.webkit.MimeTypeMap
import java.io.File

/**
 * 被控端接收文件的公共目录发布。
 *
 * Android 10+ 通过 MediaStore.Downloads 写入「下载/QuickDesk」，无需存储权限；
 * 旧版本没有该集合，直接返回 null，由 Dart 侧使用 app 私有外部目录兜底。
 */
object FileStore {

    fun publishToDownloads(
        context: Context,
        sourcePath: String,
        displayName: String,
    ): String? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null
        val source = File(sourcePath)
        if (!source.isFile) return null

        val resolver = context.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, displayName)
            put(MediaStore.Downloads.MIME_TYPE, mimeTypeOf(displayName))
            put(
                MediaStore.Downloads.RELATIVE_PATH,
                Environment.DIRECTORY_DOWNLOADS + "/QuickDesk",
            )
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
            ?: return null
        return try {
            val out = resolver.openOutputStream(uri)
                ?: throw IllegalStateException("MediaStore output stream unavailable")
            out.use { stream -> source.inputStream().use { it.copyTo(stream) } }
            values.clear()
            values.put(MediaStore.Downloads.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
            Environment.DIRECTORY_DOWNLOADS + "/QuickDesk/" + displayName
        } catch (_: Throwable) {
            try {
                resolver.delete(uri, null, null)
            } catch (_: Throwable) {
            }
            null
        }
    }

    private fun mimeTypeOf(name: String): String {
        val ext = name.substringAfterLast('.', "").lowercase()
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext)
            ?: "application/octet-stream"
    }
}
