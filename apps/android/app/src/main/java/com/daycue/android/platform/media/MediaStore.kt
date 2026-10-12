package com.daycue.android.platform.media

import android.content.Context
import android.net.Uri
import android.util.Log
import com.daycue.android.core.Sha256
import java.io.File
import java.io.IOException
import java.security.MessageDigest

/**
 * 录音与图片的本地存放。
 *
 * 全部放在 context.filesDir/daycue/media/ 下，而不是外部存储：
 * 1. 私有目录不需要任何存储权限，这也符合「拒绝任何权限都不能让 App 不可用」这条约束；
 * 2. 不需要通知系统媒体库去扫描，用户也不会在图库里看到一堆「录音 12 秒」。
 */
class MediaStore(private val context: Context) {

    private val appContext: Context = context.applicationContext

    private fun mediaDir(): File {
        val dir = File(appContext.filesDir, MEDIA_DIR)
        if (!dir.exists() && !dir.mkdirs()) {
            Log.w(TAG, "创建媒体目录失败：" + dir.absolutePath)
        }
        return dir
    }

    fun newAudioFile(captureId: String): File = File(mediaDir(), "audio_" + sanitize(captureId) + ".m4a")

    fun newImageFile(captureId: String): File = File(mediaDir(), "image_" + sanitize(captureId) + ".jpg")

    /**
     * 把用户从系统选择器挑来的图片复制进私有目录。
     *
     * 为什么必须复制：选择器给的 URI 只是一个临时授权，进程重启或授权过期后就打不开了，
     * 那时候用户在记录详情里看到的是一张裂图。复制进私有目录才是真正「保存下来」。
     * 文件名用内容哈希（内容寻址）：同一张图重复挑选不会堆出多份。
     */
    fun persistPickedImage(uri: Uri): File? {
        val extension = extensionFor(appContext.contentResolver.getType(uri))
        val temp = File(appContext.cacheDir, "daycue-picked-" + System.currentTimeMillis() + "." + extension)
        return try {
            val input = appContext.contentResolver.openInputStream(uri)
            if (input == null) {
                Log.w(TAG, "无法打开图片输入流：" + uri)
                null
            } else {
                input.use { source -> temp.outputStream().use { target -> source.copyTo(target) } }
                val target = File(mediaDir(), "picked_" + sha256(temp) + "." + extension)
                when {
                    target.exists() -> {
                        temp.delete()
                        target
                    }

                    temp.renameTo(target) -> target

                    else -> {
                        temp.copyTo(target, overwrite = true)
                        temp.delete()
                        target
                    }
                }
            }
        } catch (e: IOException) {
            Log.w(TAG, "保存选择的图片失败", e)
            temp.delete()
            null
        } catch (e: SecurityException) {
            // URI 授权已失效：明确失败，让界面提示用户重新选择。
            Log.w(TAG, "没有读取该图片的授权：" + uri, e)
            temp.delete()
            null
        }
    }

    /**
     * 文件内容的 SHA-256（小写十六进制）。
     *
     * 逐块计算而不是一次读进内存：录音最长 10 分钟，整段放进字节数组是没必要的内存压力。
     * 读文件失败会抛 [IOException]，绝不返回空串假装成功——空哈希会让内容寻址撞在一起。
     */
    fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val read = input.read(buffer)
                if (read <= 0) break
                digest.update(buffer, 0, read)
            }
        }
        // 复用 Identifiers 里的十六进制格式化，保证与幂等键用的是同一种写法。
        return Sha256.hex(digest.digest())
    }

    /** 删除失败不该让调用方（例如「取消录音」）跟着失败，但也不能静默：留下日志即可。 */
    fun deleteQuietly(file: File?) {
        if (file == null) return
        try {
            if (file.exists() && !file.delete()) {
                Log.w(TAG, "文件删除失败：" + file.absolutePath)
            }
        } catch (e: SecurityException) {
            Log.w(TAG, "文件删除被拒绝：" + file.absolutePath, e)
        }
    }

    /** 捕获 id 来自 UUID，这里仍做一次清洗：文件名不允许路径分隔符，否则会写到目录之外。 */
    private fun sanitize(raw: String): String =
        raw.map { if (it.isLetterOrDigit() || it == '-' || it == '_') it else '_' }.joinToString("")

    private fun extensionFor(mimeType: String?): String = when (mimeType) {
        "image/png" -> "png"
        "image/webp" -> "webp"
        "image/heic", "image/heif" -> "heic"
        else -> "jpg"
    }

    private companion object {
        const val TAG = "DayCueMediaStore"
        const val MEDIA_DIR = "daycue/media"
    }
}
