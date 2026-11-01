package com.daycue.android.platform.speech

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer

/**
 * 系统语音听写（[SpeechRecognizer]）。
 *
 * 为什么走系统而不是后端：部分部署环境里后端根本没有 ASR 供应商，
 * 而绝大多数手机自带听写服务，端侧识别不产生任何外部调用与费用。
 * 代价是 [SpeechRecognizer] 只能"边听边识别"，不能像后端那样把一段现成音频丢进去，
 * 所以走这条通道时不会留下音频文件——这是接口限制，不是取舍不当。
 *
 * 三条刻意的约束：
 * 1. 所有 [SpeechRecognizer] 调用都切到主线程：它在非主线程创建会直接抛异常，
 *    而调用方（ViewModel）不保证在哪个调度器上；
 * 2. 失败一律给可读原因，绝不返回编造的文本；
 * 3. [isAvailable] 只做"服务在不在"的静态判断，不启动识别、不占麦克风，
 *    可以在任何线程反复调用。
 */
class SystemSpeechInput(context: Context) {

    private val appContext: Context = context.applicationContext
    private val main = Handler(Looper.getMainLooper())

    private var recognizer: SpeechRecognizer? = null
    private var onPartial: ((String) -> Unit)? = null
    private var onFinal: ((String) -> Unit)? = null
    private var onError: ((String) -> Unit)? = null
    private var delivered = false

    /** 是否正在听写。供 ViewModel 判断"停止/取消"该走哪条通道。 */
    val isListening: Boolean get() = recognizer != null

    /** 静态判断本机有没有可用的听写服务。没有服务时调用方应回退到后端转写。 */
    fun isAvailable(): Boolean =
        runCatching { SpeechRecognizer.isRecognitionAvailable(appContext) }.getOrDefault(false)

    /**
     * 开始听写。
     *
     * [onPartial] 给实时文字（界面可以边听边显示），[onFinal] 与 [onError] 互斥且只触发一次。
     * 语言固定 zh-CN：本应用是中文产品，让系统按其他语言识别只会得到更差的结果。
     */
    fun start(onPartial: (String) -> Unit, onFinal: (String) -> Unit, onError: (String) -> Unit) {
        this.onPartial = onPartial
        this.onFinal = onFinal
        this.onError = onError
        delivered = false
        onMain {
            destroyQuietly()
            val created = runCatching { SpeechRecognizer.createSpeechRecognizer(appContext) }.getOrNull()
            if (created == null) {
                deliverError("系统听写服务创建失败，可能没有安装语音识别组件。")
                return@onMain
            }
            created.setRecognitionListener(listener)
            recognizer = created
            val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                putExtra(RecognizerIntent.EXTRA_LANGUAGE, LANGUAGE_TAG)
                putExtra(RecognizerIntent.EXTRA_LANGUAGE_PREFERENCE, LANGUAGE_TAG)
                putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
                putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
                putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, appContext.packageName)
            }
            runCatching { created.startListening(intent) }
                .onFailure { deliverError("系统听写启动失败：" + (it.message ?: "未知原因")) }
        }
    }

    /** 正常结束：让系统把最终结果吐出来，不做兜底拼接。 */
    fun stop() {
        onMain {
            val active = recognizer ?: return@onMain
            runCatching { active.stopListening() }
        }
    }

    /** 用户主动取消：直接销毁，不产生任何结果。 */
    fun cancel() {
        delivered = true
        onMain { destroyQuietly() }
    }

    private val listener = object : RecognitionListener {
        override fun onReadyForSpeech(params: Bundle?) = Unit
        override fun onBeginningOfSpeech() = Unit
        override fun onRmsChanged(rmsdB: Float) = Unit
        override fun onBufferReceived(buffer: ByteArray?) = Unit
        override fun onEndOfSpeech() = Unit
        override fun onEvent(eventType: Int, params: Bundle?) = Unit

        override fun onPartialResults(partialResults: Bundle?) {
            val text = firstResult(partialResults) ?: return
            if (!delivered) onPartial?.invoke(text)
        }

        override fun onResults(results: Bundle?) {
            val text = firstResult(results)
            val trimmed = text?.trim().orEmpty()
            if (trimmed.isEmpty()) {
                deliverError("没有识别到语音内容。可以重试，或改用文字输入。")
            } else {
                deliverFinal(trimmed)
            }
            destroyQuietly()
        }

        override fun onError(error: Int) {
            // ERROR_CLIENT 多半是用户取消或系统主动打断，不该当成失败报给用户。
            if (error == SpeechRecognizer.ERROR_CLIENT) {
                destroyQuietly()
                return
            }
            deliverError(describe(error))
            destroyQuietly()
        }
    }

    private fun firstResult(bundle: Bundle?): String? =
        bundle?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()

    private fun deliverFinal(text: String) {
        if (delivered) return
        delivered = true
        onFinal?.invoke(text)
    }

    private fun deliverError(message: String) {
        if (delivered) return
        delivered = true
        onError?.invoke(message)
    }

    private fun destroyQuietly() {
        val active = recognizer
        recognizer = null
        if (active != null) runCatching { active.destroy() }
    }

    private fun onMain(block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) block() else main.post(block)
    }

    companion object {
        const val LANGUAGE_TAG = "zh-CN"

        /**
         * 错误码翻译。这里只区分用户能采取动作的几类：
         * 重说、联网、授权、稍后再试。其余情况不值得把数字丢给用户。
         */
        fun describe(error: Int): String = when (error) {
            SpeechRecognizer.ERROR_NO_MATCH,
            SpeechRecognizer.ERROR_SPEECH_TIMEOUT ->
                "没有听清。请靠近麦克风重说一次，或改用文字输入。"
            SpeechRecognizer.ERROR_NETWORK,
            SpeechRecognizer.ERROR_NETWORK_TIMEOUT,
            SpeechRecognizer.ERROR_SERVER ->
                "系统听写需要联网（部分机型的识别在云端），请检查网络后重试。"
            SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS ->
                "没有录音权限，系统听写无法启动。"
            SpeechRecognizer.ERROR_RECOGNIZER_BUSY ->
                "系统听写正忙，稍等一秒再试。"
            SpeechRecognizer.ERROR_AUDIO ->
                "麦克风读取失败，可能被其他应用占用。"
            else -> "系统听写出错（错误码 " + error.toString() + "）。"
        }
    }
}
