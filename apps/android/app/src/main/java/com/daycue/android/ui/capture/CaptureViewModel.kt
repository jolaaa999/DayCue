package com.daycue.android.ui.capture

import android.net.Uri
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.daycue.android.AppContainer
import com.daycue.android.core.DayCueTime
import com.daycue.android.domain.contract.ContractDue
import com.daycue.android.domain.contract.ExtractionRequest
import com.daycue.android.domain.contract.ExtractionRequestSource
import com.daycue.android.domain.model.CaptureStatus
import com.daycue.android.domain.model.DueKind
import com.daycue.android.domain.model.ProposalItemKind
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.time.ZoneId

/** 解析候选的展示形态。候选在这里只用于「告诉用户解析出了什么」，不代替用户落库。 */
data class ExtractedItemView(
    val kindName: String,
    val title: String,
    val dueText: String,
    val notes: List<String>,
)

data class ExtractionView(
    val modeName: String,
    val items: List<ExtractedItemView>,
    val warnings: List<String>,
)

data class CaptureUiState(
    val text: String = "",
    val isRecording: Boolean = false,
    val elapsedSeconds: Long = 0,
    val busy: Boolean = false,
    val notice: String? = null,
    val error: String? = null,
    val transcript: String? = null,
    val extraction: ExtractionView? = null,
)

/**
 * 记录页的提交逻辑。
 *
 * 顺序是硬约束：**先落库，再谈网络**。任何一次提交都必须先产生一条 local 状态的记录，
 * 后面转写或解析失败只能改状态。没配后端时只提示「已保存到本机」，
 * 绝不把「没有解析」说成「解析成功」。
 */
class CaptureViewModel(private val container: AppContainer) : ViewModel() {

    private val zone: ZoneId = ZoneId.systemDefault()

    private val _state = MutableStateFlow(CaptureUiState())
    val state: StateFlow<CaptureUiState> = _state.asStateFlow()

    init {
        viewModelScope.launch {
            container.audioRecorder.isRecording.collect { recording ->
                _state.update { it.copy(isRecording = recording) }
            }
        }
        viewModelScope.launch {
            container.audioRecorder.elapsedSeconds.collect { seconds ->
                _state.update { it.copy(elapsedSeconds = seconds) }
            }
        }
    }

    fun onTextChange(value: String) {
        _state.update { it.copy(text = value, error = null, notice = null) }
    }

    fun clearMessages() {
        _state.update { it.copy(error = null, notice = null) }
    }

    fun dismissExtraction() {
        _state.update { it.copy(extraction = null, transcript = null) }
    }

    fun submitText() {
        val text = _state.value.text.trim()
        if (text.isEmpty()) {
            _state.update { it.copy(error = "请先输入要点，再提交。", notice = null) }
            return
        }
        viewModelScope.launch {
            _state.update { it.copy(busy = true, error = null, notice = null, extraction = null, transcript = null) }
            val captureId = runCatching { container.captureRepository.saveText(text, zone) }.getOrElse { error ->
                _state.update { it.copy(busy = false, error = error.message ?: "保存到本机失败") }
                return@launch
            }
            _state.update {
                it.copy(
                    text = "",
                    notice = "已保存到本机（" + CaptureStatus.LOCAL.displayName + "）。",
                )
            }
            extract(captureId, text)
            _state.update { it.copy(busy = false) }
        }
    }

    /** 拍照或选图的结果。先把图片落到 App 目录，再写记录。 */
    fun submitImage(uri: Uri) {
        viewModelScope.launch {
            _state.update { it.copy(busy = true, error = null, notice = null, extraction = null, transcript = null) }
            val file = runCatching { container.mediaStore.persistPickedImage(uri) }.getOrNull()
            if (file == null) {
                _state.update {
                    it.copy(busy = false, error = "无法读取这张图片（可能已被删除，或系统没有授予访问权限）。")
                }
                return@launch
            }
            val saved = runCatching {
                container.captureRepository.saveImage(file.absolutePath, null, zone)
            }
            saved.onFailure { error ->
                _state.update { it.copy(busy = false, error = error.message ?: "保存图片失败") }
            }.onSuccess {
                // 图片 OCR 没有接入，这里不做任何「识别」动作，状态如实停在「已保存到本机」。
                _state.update {
                    it.copy(
                        busy = false,
                        notice = "图片已保存，可在记录详情里补充文字。（本机文件：" + file.name + "）",
                    )
                }
            }
        }
    }

    fun reportPermissionDenied(message: String) {
        _state.update { it.copy(error = message, notice = null, busy = false) }
    }

    fun reportCameraUnavailable() {
        _state.update {
            it.copy(
                error = "无法创建照片文件：系统没有授予相册写入权限。请改用「选图」，或到系统设置里为本应用开启存储权限。",
                notice = null,
            )
        }
    }

    fun reportCancelled() {
        _state.update { it.copy(notice = "已取消，没有保存任何内容。", error = null) }
    }

    fun startRecording() {
        val started = runCatching { container.audioRecorder.start() }.getOrDefault(false)
        _state.update {
            if (started) {
                it.copy(error = null, notice = "正在录音，再次点击停止。", extraction = null, transcript = null)
            } else {
                it.copy(error = "录音启动失败。可能是麦克风被其他应用占用，或系统拒绝了录音权限。", notice = null)
            }
        }
    }

    fun stopRecording() {
        viewModelScope.launch {
            // 秒数必须在 stop() 之前读：停止后计时会被重置。
            val seconds = _state.value.elapsedSeconds
            val file = runCatching { container.audioRecorder.stop() }.getOrNull()
            if (file == null) {
                _state.update { it.copy(error = "录音没有生成文件，这段录音没有保存。", notice = null) }
                return@launch
            }
            _state.update { it.copy(busy = true, error = null, notice = null) }
            val saved = runCatching { container.captureRepository.saveAudio(file.absolutePath, zone, seconds) }
            saved.onFailure { error ->
                _state.update { it.copy(busy = false, error = error.message ?: "保存录音失败") }
            }.onSuccess { captureId ->
                _state.update { it.copy(notice = "录音已保存到本机（" + seconds.toString() + " 秒）。") }
                transcribe(captureId, file)
                _state.update { it.copy(busy = false) }
            }
        }
    }

    fun cancelRecording() {
        runCatching { container.audioRecorder.cancel() }
        _state.update { it.copy(notice = "已取消录音，没有保存任何内容。", error = null) }
    }

    /** 文字记录走解析接口。没配后端就到此为止，不伪造结果。 */
    private suspend fun extract(captureId: String, text: String) {
        if (container.settingsRepository.isPurelyLocal()) {
            _state.update { it.copy(notice = "已保存到本机，未配置后端，稍后可手动整理。") }
            return
        }
        container.captureRepository.markExtracting(captureId)
        val request = ExtractionRequest(
            captureId = captureId,
            source = ExtractionRequestSource(type = ExtractionRequestSource.SourceType.TEXT, text = text),
            recordedAt = DayCueTime.utcString(container.timeSource.now()),
            timezone = zone.id,
        )
        runCatching { container.apiClient.extract(request) }
            .onSuccess { response ->
                container.captureRepository.markStatus(captureId, CaptureStatus.EXTRACTED)
                val items = response.items.map { item ->
                    ExtractedItemView(
                        kindName = if (item.kind == ProposalItemKind.TASK) "待办" else "笔记",
                        title = item.title,
                        dueText = dueText(item.due),
                        notes = buildList {
                            addAll(item.ambiguities.map { ambiguity -> ambiguity.message })
                            if (item.isDeadlineOnly) add("只设了截止日，尚未设置提醒时间")
                            if (item.requiresClarification) add("这条还需要你确认后才能执行")
                        },
                    )
                }
                _state.update {
                    it.copy(
                        notice = "解析完成：" + items.size.toString() + " 条候选（" + response.mode.displayName + "）。候选尚未写入待办或笔记，可在对应页面手动整理。",
                        extraction = ExtractionView(
                            modeName = response.mode.displayName,
                            items = items,
                            warnings = response.warnings,
                        ),
                    )
                }
            }
            .onFailure { error ->
                // 记录已经落库，失败只改状态：这条记录仍然在「今天」页的待处理里。
                container.captureRepository.markStatus(captureId, CaptureStatus.FAILED)
                _state.update {
                    it.copy(
                        error = "解析失败：" + (error.message ?: "未知错误") + "（记录已保存到本机，可稍后重试）",
                        notice = null,
                    )
                }
            }
    }

    /** 录音转写。同样先落库：音频文件已经写盘，转写失败只影响文字。 */
    private suspend fun transcribe(captureId: String, file: File) {
        if (container.settingsRepository.isPurelyLocal()) {
            _state.update { it.copy(notice = "录音已保存到本机，未配置后端，稍后可手动整理。") }
            return
        }
        container.captureRepository.markExtracting(captureId)
        runCatching {
            val bytes = withContext(Dispatchers.IO) { file.readBytes() }
            container.apiClient.transcribe(
                audioBytes = bytes,
                mimeType = mimeTypeOf(file.name),
                language = null,
                timezone = zone.id,
            )
        }.onSuccess { response ->
            container.captureRepository.attachTranscript(captureId, response.text)
            container.captureRepository.markStatus(captureId, CaptureStatus.EXTRACTED)
            _state.update {
                it.copy(
                    notice = "转写完成（" + response.mode.displayName + "）。",
                    transcript = response.text,
                )
            }
        }.onFailure { error ->
            container.captureRepository.markStatus(captureId, CaptureStatus.FAILED)
            _state.update {
                it.copy(
                    error = "转写失败：" + (error.message ?: "未知错误") + "（音频已保存到本机，可稍后重试）",
                    notice = null,
                )
            }
        }
    }

    /**
     * 契约里的 due 是三种形态混合的，展示时必须按 kind 分开处理：
     * date 型只有年月日，绝不能显示成某个时刻。
     */
    private fun dueText(due: ContractDue): String = when (due.kind) {
        DueKind.NONE -> "无截止时间"
        DueKind.DATE -> due.local
            ?.let { raw -> DayCueTime.parseLocalDateOrNull(raw)?.let { date -> DayCueTime.localDateString(date) } }
            ?: "日期缺失"
        DueKind.DATETIME -> {
            val instant = DayCueTime.parseInstantOrNull(due.utc)
                ?: DayCueTime.parseLocalDateTimeOrNull(due.local, zone)
            instant?.let { DayCueTime.displayDateTime(it, zone) } ?: "时刻缺失"
        }
    }

    /** 录音容器格式随设备不同（m4a / 3gp / wav），按扩展名推断，避免一律当 mp4 导致服务端拒收。 */
    private fun mimeTypeOf(fileName: String): String = when (fileName.substringAfterLast('.', "").lowercase()) {
        "m4a", "mp4" -> "audio/mp4"
        "3gp" -> "audio/3gpp"
        "wav" -> "audio/wav"
        "ogg", "opus" -> "audio/ogg"
        "amr" -> "audio/amr"
        else -> "application/octet-stream"
    }

    override fun onCleared() {
        // 离开页面时不能让麦克风继续被占用：录音必须显式取消，而不是等系统回收。
        if (_state.value.isRecording) runCatching { container.audioRecorder.cancel() }
    }

    companion object {
        fun factory(container: AppContainer): ViewModelProvider.Factory = viewModelFactory {
            initializer { CaptureViewModel(container) }
        }
    }
}
