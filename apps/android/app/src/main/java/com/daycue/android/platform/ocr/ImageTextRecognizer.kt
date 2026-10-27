package com.daycue.android.platform.ocr

import android.content.Context
import android.net.Uri
import android.util.Log
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.Text
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import java.io.File
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * 图片里的文字识别（离线）。
 *
 * 为什么用 ML Kit 的中文模型而不是调后端：
 * 1. 拍照记板书这件事经常发生在教室/地铁这种没网的地方，能不能认出字不该取决于网络；
 * 2. 中文模型是随 APK 一起打包的（不是 Play Services 动态下载的那一版），装好就能用，不会出现「第一次识别要等模型下载」；
 * 3. 转写、结构化解析仍然要后端，但「图片里有几个字」这种事没必要上传。
 *
 * 识别范围只是「把图上的字取出来」，它不判断哪句话是待办、也不生成笔记。
 * 这条界线很重要：OCR 结果是证据，结构化解析才是结论，两者混在一起就会把一堆噪声当事实写进库。
 */
/** 识别结果。四个状态必须分开：把「没文字」和「识别失败」混成 null，界面就只能含糊其辞。 */
sealed interface OcrOutcome {
    data class Text(val text: String) : OcrOutcome

    /** 识别跑完了，图上看不到文字。 */
    data object Empty : OcrOutcome

    /** 文件打不开或识别过程出错——和「没有文字」是两件事。 */
    data object Failed : OcrOutcome
}

class ImageTextRecognizer(private val context: Context) {

    private val client by lazy {
        // 惰性初始化：没拍过照的用户不该在启动时加载识别器（它要占几十 MB 内存）。
        TextRecognition.getClient(ChineseTextRecognizerOptions.Builder().build())
    }

    /**
     * 识别一张本地图片里的文字。
     *
     * 失败不抛给界面：OCR 失败不该阻止一条记录被保存，用户至少还有那张图。
     * 但失败与「没有文字」必须分别返回，界面才能说清到底是哪一种。
     */
    suspend fun recognize(path: String): OcrOutcome = withContext(Dispatchers.IO) {
        val file = File(path)
        if (!file.exists()) return@withContext OcrOutcome.Failed
        runCatching {
            val image = InputImage.fromFilePath(context, Uri.fromFile(file))
            val text = client.process(image).awaitText().text
            if (text.isBlank()) OcrOutcome.Empty else OcrOutcome.Text(text)
        }.onFailure { error ->
            Log.w(TAG, "图片文字识别失败：" + path, error)
        }.getOrDefault(OcrOutcome.Failed)
    }

    /** ML Kit 返回的是 Task；这里转成挂起函数，避免为了一个 await 再引 kotlinx-coroutines-play-services。 */
    private suspend fun com.google.android.gms.tasks.Task<Text>.awaitText(): Text =
        suspendCancellableCoroutine { continuation ->
            addOnSuccessListener { result -> continuation.resume(result) }
            addOnFailureListener { error -> continuation.resumeWithException(error) }
    }

    private companion object {
        const val TAG = "DayCueOcr"
    }
}
