package com.daycue.android.platform.media

import android.content.Context
import android.media.MediaRecorder
import android.os.Build
import android.os.SystemClock
import android.util.Log
import com.daycue.android.core.DayCueId
import com.daycue.android.platform.permission.PermissionCenter
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.io.File

/**
 * 录音。
 *
 * 输出 AAC/m4a：iOS 端同样是 m4a，后端 /v1/transcriptions 接受 audio 类型的原始字节，
 * 双端同格式能避免转码带来的时长与音质问题。
 *
 * 三条刻意的行为：
 * 1. 没有录音权限时 start() 返回 false 而不抛异常——权限被拒是产品明确预期的一条路径，
 *    抛异常只会逼调用方到处写 try/catch；
 * 2. 最长 10 分钟自动停止，避免用户忘了关而把设备存储写满；
 * 3. 停止时如果文件为空（时长太短、设备没给出有效数据），删掉并返回 null，
 *    绝不返回一个后续播放必然失败的路径。
 */
class AudioRecorder(private val context: Context) {

    private val appContext: Context = context.applicationContext
    private val mediaStore = MediaStore(appContext)

    // 只用来驱动秒表与兜底的自动停止，不承载任何业务状态。
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    private val _isRecording = MutableStateFlow(false)
    val isRecording: StateFlow<Boolean> = _isRecording.asStateFlow()

    private val _elapsedSeconds = MutableStateFlow(0L)
    val elapsedSeconds: StateFlow<Long> = _elapsedSeconds.asStateFlow()

    private val lock = Any()
    private var recorder: MediaRecorder? = null
    private var outputFile: File? = null
    private var ticker: Job? = null
    private var startedAtMillis = 0L

    /** 自动停止后调用方还没来取的文件；stop() 会把它交出去。 */
    private var completedFile: File? = null

    fun start(): Boolean {
        if (_isRecording.value) return false

        // 权限判断放在最前面：没有权限就创建 MediaRecorder 只会拿到一个初始化失败的实例。
        if (!PermissionCenter.hasRecording(appContext)) {
            Log.w(TAG, "未授予录音权限，start() 直接返回 false")
            return false
        }

        val file = mediaStore.newAudioFile(DayCueId.new())
        val newRecorder = try {
            createRecorder()
        } catch (e: Exception) {
            Log.w(TAG, "创建录音器失败", e)
            return false
        }

        return try {
            newRecorder.setAudioSource(MediaRecorder.AudioSource.MIC)
            newRecorder.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            newRecorder.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            newRecorder.setAudioEncodingBitRate(AUDIO_BIT_RATE)
            newRecorder.setAudioSamplingRate(AUDIO_SAMPLE_RATE)
            newRecorder.setOutputFile(file.absolutePath)
            // 系统级的时长上限：即使进程被挂起、协程被冻住，原生层也会在 10 分钟时回调。
            newRecorder.setMaxDuration((MAX_RECORDING_SECONDS * 1000L).toInt())
            newRecorder.setOnInfoListener { _, what, _ ->
                if (what == MediaRecorder.MEDIA_RECORDER_INFO_MAX_DURATION_REACHED) {
                    Log.i(TAG, "到达 10 分钟上限，自动结束录音")
                    finish()
                }
            }
            newRecorder.prepare()
            newRecorder.start()

            synchronized(lock) {
                recorder = newRecorder
                outputFile = file
                startedAtMillis = SystemClock.elapsedRealtime()
                completedFile = null
            }
            _elapsedSeconds.value = 0L
            _isRecording.value = true
            startTicker()
            true
        } catch (e: Exception) {
            // IOException（prepare 失败）、IllegalStateException（设备被占用）：一律当「这次没启动成功」。
            Log.w(TAG, "启动录音失败", e)
            runCatching { newRecorder.release() }
            mediaStore.deleteQuietly(file)
            synchronized(lock) {
                recorder = null
                outputFile = null
            }
            false
        }
    }

    /**
     * 停止并返回录音文件。
     *
     * 如果录音已经因为 10 分钟上限自动结束，这里会把那份文件交出来（而不是返回 null），
     * 否则调用方会以为录音丢了。
     */
    fun stop(): File? {
        val active = synchronized(lock) { recorder }
        if (active != null) finish()
        return synchronized(lock) {
            completedFile.also { completedFile = null }
        }
    }

    /** 取消：收尾并删文件。用于用户主动放弃这次录音。 */
    fun cancel() {
        val active = synchronized(lock) { recorder }
        if (active != null) finish()
        val abandoned = synchronized(lock) {
            val file = completedFile ?: outputFile
            completedFile = null
            outputFile = null
            file
        }
        mediaStore.deleteQuietly(abandoned)
        _isRecording.value = false
        _elapsedSeconds.value = 0L
    }

    /**
     * 收尾：停表、停止、释放、校验文件。
     *
     * 可以被多处调用（用户点停止、系统回调到时长上限、秒表兜底），
     * 所以先用「谁拿到 recorder 谁负责」的方式保证只执行一次。
     */
    private fun finish(): File? {
        ticker?.cancel()
        ticker = null
        val active = synchronized(lock) {
            val current = recorder
            recorder = null
            current
        } ?: return null
        val file = synchronized(lock) {
            outputFile.also { outputFile = null }
        }
        _isRecording.value = false
        _elapsedSeconds.value = 0L

        val completed = try {
            active.stop()
            active.release()
            if (file != null && file.exists() && file.length() > 0L) {
                file
            } else {
                // 太短或设备没写出有效数据：删掉，不把一个必然播不了的路径交给界面。
                Log.w(TAG, "录音结果为空，按失败处理并删除文件")
                mediaStore.deleteQuietly(file)
                null
            }
        } catch (e: RuntimeException) {
            // stop() 在「没收到任何有效音频数据」时会抛，这属于可预期的情况。
            Log.w(TAG, "停止录音失败（多半是没有有效音频数据）", e)
            runCatching { active.reset() }
            runCatching { active.release() }
            mediaStore.deleteQuietly(file)
            null
        }

        synchronized(lock) { completedFile = completed }
        return completed
    }

    private fun startTicker() {
        ticker = scope.launch {
            while (isActive) {
                delay(TICK_MILLIS)
                val started = synchronized(lock) { startedAtMillis }
                if (started == 0L) break
                val elapsed = (SystemClock.elapsedRealtime() - started) / 1000L
                _elapsedSeconds.value = elapsed
                // 兜底：万一没有收到系统的时长回调，也不能让录音无限延长。
                if (elapsed >= MAX_RECORDING_SECONDS) {
                    finish()
                    break
                }
            }
        }
    }

    /** 31 起要求传 Context 的新构造器；旧构造器只是标记废弃，功能仍然可用。 */
    @Suppress("DEPRECATION")
    private fun createRecorder(): MediaRecorder =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) MediaRecorder(appContext) else MediaRecorder()

    private companion object {
        const val TAG = "DayCueAudioRecorder"
        const val MAX_RECORDING_SECONDS = 10L * 60L
        const val TICK_MILLIS = 1000L
        const val AUDIO_BIT_RATE = 96_000
        const val AUDIO_SAMPLE_RATE = 44_100
    }
}
