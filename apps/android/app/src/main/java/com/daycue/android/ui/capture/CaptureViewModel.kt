package com.daycue.android.ui.capture

import android.net.Uri
import android.os.SystemClock
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.daycue.android.AppContainer
import com.daycue.android.core.DayCueTime
import com.daycue.android.data.repository.NewTask
import com.daycue.android.network.DayCueApiException
import com.daycue.android.domain.contract.ContractDue
import com.daycue.android.domain.contract.ContractErrorCodes
import com.daycue.android.domain.contract.ExtractionRequest
import com.daycue.android.domain.contract.ExtractionRequestSource
import com.daycue.android.domain.model.CaptureStatus
import com.daycue.android.domain.model.DueKind
import com.daycue.android.domain.model.NoteOriginKind
import com.daycue.android.domain.model.ProposalItemKind
import com.daycue.android.platform.ocr.OcrOutcome
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

/** 图片文字识别的四个阶段。界面必须区分「还没跑完」「认出了字」「图上没字」「识别本身失败」。 */
enum class OcrPhase { RECOGNIZING, DONE, EMPTY, FAILED }

/** 刚保存到本机的图片。界面要拿它显示缩略图，用户才能确认自己选的是哪张。 */
data class SavedImage(
    val captureId: String,
    val path: String,
    val savedAtMillis: Long,
    val ocrPhase: OcrPhase = OcrPhase.RECOGNIZING,
    /** 识别/编辑后的文字；null 表示还没有文字可用。 */
    val ocrText: String? = null,
)

/** 刚保存到本机的文字记录。留着它是为了让「先保存、再提取待办」这两下点得通。 */
data class SavedText(
    val captureId: String,
    val text: String,
)

/** 刚保存到本机的录音。 */
data class SavedAudio(
    val captureId: String,
    val path: String,
    val seconds: Long,
    val savedAtMillis: Long,
)

/**
 * 保存笔记前的草稿。
 *
 * 为什么不直接落库：识别出来的文字是「机器的读数」，标题取哪一行、正文要不要删几行，
 * 只有用户自己能判断。所以先把标题与正文摆出来让用户改，点保存才写 note 表。
 */
data class NoteDraft(
    val title: String,
    val body: String,
    val sourceLabel: String,
)

/**
 * 解析候选。
 *
 * 保留 itemId、due 的原始形态与证据原文：确认页要能说清「这条是从哪句话来的、截止是哪天」，
 * 而落库时也需要这些字段（origin_item_id、due_kind 等）。
 */
data class CandidateItem(
    val itemId: String,
    val isTask: Boolean,
    val kindName: String,
    val title: String,
    val detail: String?,
    val evidence: String,
    val dueKind: DueKind,
    val dueInstant: Instant?,
    val dueLocalDate: LocalDate?,
    val dueText: String,
    val courseHint: String?,
    val notes: List<String>,
)

/**
 * 「提取待办」要解析哪一条。
 *
 * 关键是 captureId 必须明确：
 * - 输入框有字：这是新内容，还没有对应记录（needsSave=true），落库后再解析；
 * - 输入框空了但刚保存过：直接用那条记录，captureId 就是它的 id；
 * - 两者都没有：null，界面如实说没东西可提取，不去猜。
 */
internal data class ExtractTarget(
    val captureId: String?,
    val text: String,
    val needsSave: Boolean,
)

/** 解析目标的选择规则。抽成纯函数便于回归验证：绑定错记录比报错更糟。 */
internal fun resolveExtractTarget(typed: String, saved: SavedText?): ExtractTarget? {
    val trimmed = typed.trim()
    return when {
        trimmed.isNotEmpty() -> ExtractTarget(captureId = null, text = trimmed, needsSave = true)
        saved != null -> ExtractTarget(captureId = saved.captureId, text = saved.text, needsSave = false)
        else -> null
    }
}

/**
 * 用户一开始写新内容，之前那条「刚保存」的绑定就必须失效。
 *
 * 否则会出现最难查的那类错：输入框里明明是 B，点提取却解析了上一次的 A。
 */
internal fun savedTextAfterEdit(typed: String, saved: SavedText?): SavedText? =
    if (typed.isNotBlank()) null else saved

data class CaptureUiState(
    val text: String = "",
    val isRecording: Boolean = false,
    val elapsedSeconds: Long = 0,
    val busy: Boolean = false,
    val notice: String? = null,
    val error: String? = null,
    val transcript: String? = null,
    /** 刚拍/刚选的图片；null 表示这次还没有图片。 */
    val savedImage: SavedImage? = null,
    /** 刚录的音；null 表示这次还没有录音。 */
    val savedAudio: SavedAudio? = null,
    /** 刚保存的文字记录：输入框已经清空后，仍然能对这条记录做「提取待办」。 */
    val savedText: SavedText? = null,
    /** 待确认的笔记草稿；null 表示没有打开保存笔记的确认框。 */
    val noteDraft: NoteDraft? = null,
    /** 正在写笔记：防止连点写出两条一模一样的笔记。 */
    val savingNote: Boolean = false,
    /** 刚保存成功的笔记 id，界面据此给一个「打开笔记」的入口。 */
    val savedNoteId: String? = null,
    /** 正在编辑的 OCR 文字；null 表示没有打开编辑框。 */
    val ocrEditDraft: String? = null,
    /** 解析候选与确认页状态。 */
    val candidates: List<CandidateItem> = emptyList(),
    val selectedCandidateIds: Set<String> = emptySet(),
    val confirmVisible: Boolean = false,
    val extractionModeName: String? = null,
    val extracting: Boolean = false,
    val savingCandidates: Boolean = false,
    /** 候选归属的那条 capture：确认保存后要挂上来源。 */
    val extractCaptureId: String? = null,
)

/**
 * 记录页的提交逻辑。
 *
 * 顺序是硬约束：**先落库，再谈网络**。任何一次提交都必须先产生一条 local 状态的记录，
 * 后面转写或解析失败只能改状态。没配后端时只提示「已保存到本机」，
 * 绝不把「没有解析」说成「解析成功」。
 *
 * 这一版把「解析」拆成了独立动作：保存只负责落库（离线也能用），
 * 提取待办/笔记必须由用户点，解析结果再进确认页，确认之后才写 task / note。
 */
class CaptureViewModel(private val container: AppContainer) : ViewModel() {

    private val zone: ZoneId = ZoneId.systemDefault()

    /** 系统听写进行中：录音机的状态流此时必须让位，见 init 里的采集器。 */
    private var speechActive = false
    private var speechTicker: Job? = null

    private val _state = MutableStateFlow(CaptureUiState())
    val state: StateFlow<CaptureUiState> = _state.asStateFlow()

    init {
        viewModelScope.launch {
            container.audioRecorder.isRecording.collect { recording ->
                // 系统听写占用同一个"正在录音"界面位，此时不能用录音机的状态把它覆盖掉。
                if (!speechActive) _state.update { it.copy(isRecording = recording) }
            }
        }
        viewModelScope.launch {
            container.audioRecorder.elapsedSeconds.collect { seconds ->
                if (!speechActive) _state.update { it.copy(elapsedSeconds = seconds) }
            }
        }
    }

    fun onTextChange(value: String) {
        _state.update {
            it.copy(text = value, error = null, notice = null, savedText = savedTextAfterEdit(value, it.savedText))
        }
    }

    fun clearMessages() {
        _state.update { it.copy(error = null, notice = null) }
    }

    /** 用户在系统相机/相册里按了返回：不算错误，也不该留一条空记录。 */
    fun reportCancelled() {
        _state.update { it.copy(notice = "已取消，没有保存任何内容。", error = null) }
    }

    fun reportPermissionDenied(message: String) {
        _state.update { it.copy(error = message, notice = null) }
    }

    /** 拿不到临时拍照地址：说不清原因时就直说相机走不通，别让用户以为拍成功了。 */
    fun reportCameraUnavailable() {
        _state.update { it.copy(error = "无法创建相机临时文件，可以改用「选图」。", notice = null) }
    }

    fun reportCopied(count: Int) {
        _state.update { it.copy(notice = "已复制 " + count + " 个字的文字。", error = null) }
    }

    // ---------------- 文字 ----------------

    /** 只落库，不做解析。解析是独立动作（见 [extractFromText]）。 */
    fun submitText() {
        val text = _state.value.text.trim()
        if (text.isEmpty()) {
            _state.update { it.copy(error = "请先输入要点，再提交。", notice = null) }
            return
        }
        viewModelScope.launch {
            _state.update { it.copy(busy = true, error = null, notice = null, transcript = null) }
            val captureId = saveTextCapture(text)
            _state.update {
                it.copy(
                    busy = false,
                    text = "",
                    // 不再把状态显示名拼进来：LOCAL 的显示名本身就是「已保存到本机」，
                    // 拼在一起会读成「已保存到本机（已保存到本机）」。
                    notice = if (captureId == null) {
                        "保存到本机失败。"
                    } else {
                        "已保存到本机。要整理成笔记或待办，点「提取待办」。"
                    },
                    error = if (captureId == null) "保存到本机失败" else null,
                    // 保存后输入框清空，但这条记录还在：接下来点「提取待办」要能直接用它。
                    savedText = captureId?.let { SavedText(captureId = it, text = text) } ?: it.savedText,
                )
            }
        }
    }

    private suspend fun saveTextCapture(text: String): String? =
        runCatching { container.captureRepository.saveText(text, zone) }.getOrNull()

    // ---------------- 图片 ----------------

    /**
     * 拍照或选图的结果。先把图片落到 App 目录，再写记录，最后在本机识别文字。
     *
     * 保存成功后把路径放回状态：界面要立刻显示这张图，否则用户只能看到一句「已保存」，
     * 根本不知道选中的是不是自己刚拍的那张。
     * 再次选图时先撤掉上一张——「换一张」不该在数据库里堆出两条一模一样的记录。
     */
    fun submitImage(uri: Uri) {
        viewModelScope.launch {
            _state.value.savedImage?.let { discard(it) }
            _state.update {
                it.copy(
                    busy = true,
                    error = null,
                    notice = null,
                    transcript = null,
                    savedImage = null,
                    savedNoteId = null,
                    ocrEditDraft = null,
                    // 切到图片输入后，之前那条文字记录的绑定作废：
                    // 免得「提取待办」把上一轮存下的文字又解析一遍。
                    savedText = null,
                )
            }
            val file = runCatching { container.mediaStore.persistPickedImage(uri) }.getOrNull()
            if (file == null) {
                _state.update {
                    it.copy(busy = false, error = "无法读取这张图片（可能已被删除，或系统没有授予访问权限）。")
                }
                return@launch
            }
            val saved = runCatching { container.captureRepository.saveImage(file.absolutePath, null, zone) }
            saved.onFailure { error ->
                _state.update { it.copy(busy = false, error = error.message ?: "保存图片失败") }
            }.onSuccess { captureId ->
                _state.update {
                    it.copy(
                        busy = false,
                        savedImage = SavedImage(
                            captureId = captureId,
                            path = file.absolutePath,
                            savedAtMillis = container.timeSource.now().toEpochMilli(),
                            ocrPhase = OcrPhase.RECOGNIZING,
                        ),
                        notice = "图片已保存到本机，正在识别上面的文字…",
                    )
                }
                // 识别走本机模型（离线），结果写进 ocr_text。
                // 它只负责「把图上的字取出来」：判断哪句是待办、要不要生成笔记，仍然要用户点确认。
                val outcome = container.imageTextRecognizer.recognize(file.absolutePath)
                val text = (outcome as? OcrOutcome.Text)?.text
                if (text != null) {
                    runCatching { container.captureRepository.attachOcrText(captureId, text) }
                }
                _state.update { current ->
                    val image = current.savedImage
                    // 识别期间用户可能已经换了一张或删掉了：只有还是同一张时才回填结果。
                    if (image == null || image.captureId != captureId) {
                        current
                    } else {
                        val phase = when (outcome) {
                            is OcrOutcome.Text -> OcrPhase.DONE
                            OcrOutcome.Empty -> OcrPhase.EMPTY
                            OcrOutcome.Failed -> OcrPhase.FAILED
                        }
                        current.copy(
                            savedImage = image.copy(ocrPhase = phase, ocrText = text),
                            notice = when (phase) {
                                OcrPhase.DONE -> "已认出 " + (text?.length ?: 0) + " 个字的文字，可以在下面核对。"
                                OcrPhase.EMPTY -> "未识别到文字，图片已保存。"
                                else -> "识别文字失败，图片已保存。"
                            },
                        )
                    }
                }
            }
        }
    }

    /** 删除刚保存的这张图：记录与文件一起删，避免留下一张没人引用的图占空间。 */
    fun discardSavedImage() {
        val current = _state.value.savedImage ?: return
        viewModelScope.launch {
            discard(current)
            _state.update {
                it.copy(
                    savedImage = null,
                    savedNoteId = null,
                    ocrEditDraft = null,
                    notice = "已删除这张图片，没有留下记录。",
                    error = null,
                )
            }
        }
    }

    private suspend fun discard(image: SavedImage) {
        runCatching { container.captureRepository.delete(image.captureId) }
        container.mediaStore.deleteQuietly(File(image.path))
    }

    // ---------------- 识别文字的编辑与保存笔记 ----------------

    fun openOcrEdit() {
        val text = _state.value.savedImage?.ocrText
        if (text.isNullOrBlank()) {
            _state.update { it.copy(error = "现在没有可编辑的文字。", notice = null) }
            return
        }
        _state.update { it.copy(ocrEditDraft = text, error = null) }
    }

    fun onOcrEditChange(value: String) {
        _state.update { it.copy(ocrEditDraft = value) }
    }

    fun dismissOcrEdit() {
        _state.update { it.copy(ocrEditDraft = null) }
    }

    /**
     * 保存对识别文字的修改。
     *
     * 走 applyUserEdit：它会把 user_edited 置位，之后任何晚到的机器结果都不能覆盖用户改过的文字。
     */
    fun saveOcrEdit() {
        val draft = _state.value.ocrEditDraft ?: return
        val image = _state.value.savedImage ?: return
        val trimmed = draft.trim()
        if (trimmed.isEmpty()) {
            _state.update { it.copy(error = "文字不能为空；不想保留就删除这张图片。", notice = null) }
            return
        }
        viewModelScope.launch {
            val done = runCatching { container.captureRepository.applyUserEdit(image.captureId, trimmed) }.isSuccess
            _state.update {
                it.copy(
                    ocrEditDraft = null,
                    savedImage = if (done) image.copy(ocrText = trimmed, ocrPhase = OcrPhase.DONE) else image,
                    notice = if (done) "已保存你的修改；之后的识别结果不会覆盖它。" else null,
                    error = if (done) null else "保存修改失败",
                )
            }
        }
    }

    /** 打开「保存为笔记」的确认框：标题默认取首个非空行，正文是识别出的全文。 */
    fun openNoteDraft() {
        val text = _state.value.savedImage?.ocrText
        if (text.isNullOrBlank()) {
            _state.update { it.copy(error = "现在没有可保存为笔记的文字。", notice = null) }
            return
        }
        _state.update {
            it.copy(noteDraft = NoteDraft(title = titleFromText(text), body = text, sourceLabel = "来自图片识别"), error = null)
        }
    }

    fun onNoteDraftTitleChange(value: String) {
        _state.update { current -> current.copy(noteDraft = current.noteDraft?.copy(title = value)) }
    }

    fun onNoteDraftBodyChange(value: String) {
        _state.update { current -> current.copy(noteDraft = current.noteDraft?.copy(body = value)) }
    }

    fun dismissNoteDraft() {
        _state.update { it.copy(noteDraft = null) }
    }

    /**
     * 保存笔记（完全离线，不写记忆、不建提醒）。
     *
     * 两处防连点：savingNote 挡住保存过程中的重复点击；保存成功后草稿立即关闭，
     * 按钮也换成「打开笔记」，第二次点击没有可点的东西。
     */
    fun saveNoteDraft() {
        val draft = _state.value.noteDraft ?: return
        if (_state.value.savingNote) return
        val title = draft.title.trim()
        val body = draft.body.trim()
        if (title.isEmpty() || body.isEmpty()) {
            _state.update { it.copy(error = "标题和正文都要有内容才能保存。", notice = null) }
            return
        }
        val image = _state.value.savedImage
        viewModelScope.launch {
            _state.update { it.copy(savingNote = true, error = null) }
            val noteId = runCatching {
                container.noteRepository.create(
                    title = title,
                    body = body,
                    originKind = if (image != null) NoteOriginKind.CAPTURE else NoteOriginKind.MANUAL,
                    // 来源图与捕获记录始终挂着：这条笔记从哪张图来，永远能查回去。
                    originCaptureId = image?.captureId,
                    occurredAt = image?.let { Instant.ofEpochMilli(it.savedAtMillis) },
                    zone = zone,
                )
            }.getOrNull()
            _state.update {
                it.copy(
                    savingNote = false,
                    noteDraft = if (noteId == null) draft else null,
                    savedNoteId = noteId ?: it.savedNoteId,
                    notice = if (noteId != null) "已保存为笔记。" else null,
                    error = if (noteId == null) "保存笔记失败" else null,
                )
            }
        }
    }

    /** 标题取首个非空行，并限制长度：一段板书的首行常常很长，整句当标题会把列表撑坏。 */
    private fun titleFromText(text: String): String {
        val firstLine = text.lineSequence().map { it.trim() }.firstOrNull { it.isNotEmpty() } ?: "未命名笔记"
        return if (firstLine.length <= TITLE_LIMIT) firstLine else firstLine.take(TITLE_LIMIT) + "…"
    }

    // ---------------- 录音 ----------------

    fun startRecording() {
        // 优先系统听写：本机有识别服务时就不用上传音频，也不需要后端配置 ASR。
        if (runCatching { container.systemSpeechInput.isAvailable() }.getOrDefault(false)) {
            startSpeechListening()
            return
        }
        val started = runCatching { container.audioRecorder.start() }.getOrDefault(false)
        _state.update {
            if (started) {
                it.copy(error = null, notice = "正在录音，再次点击停止。", transcript = null)
            } else {
                it.copy(error = "录音启动失败。可能是麦克风被其他应用占用，或系统拒绝了录音权限。", notice = null)
            }
        }
    }

    fun stopRecording() {
        // 系统听写没有音频文件，停在这里等系统回最终结果，交给 finishSpeech 落库。
        if (speechActive) {
            runCatching { container.systemSpeechInput.stop() }
            _state.update { it.copy(notice = "正在识别…") }
            return
        }
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
                _state.update {
                    it.copy(
                        savedAudio = SavedAudio(
                            captureId = captureId,
                            path = file.absolutePath,
                            seconds = seconds,
                            savedAtMillis = container.timeSource.now().toEpochMilli(),
                        ),
                        notice = "录音已保存到本机（" + seconds.toString() + " 秒），回放一下确认录进去了没有。",
                    )
                }
                transcribe(captureId, file)
                _state.update { it.copy(busy = false) }
            }
        }
    }

    fun cancelRecording() {
        if (speechActive) {
            runCatching { container.systemSpeechInput.cancel() }
            endSpeechSession()
            _state.update { it.copy(isRecording = false, elapsedSeconds = 0, transcript = null, notice = "已取消听写，没有保存任何内容。", error = null) }
            return
        }
        runCatching { container.audioRecorder.cancel() }
        _state.update { it.copy(notice = "已取消录音，没有保存任何内容。", error = null) }
    }

    // ---------------- 系统听写 ----------------

    /** 听写进行中：与录音共用 isRecording / elapsedSeconds，界面无需区分两条通道。 */
    private fun startSpeechListening() {
        speechActive = true
        _state.update {
            it.copy(
                isRecording = true,
                elapsedSeconds = 0,
                busy = false,
                error = null,
                transcript = null,
                notice = "正在听写，说完点「停止并保存」。",
            )
        }
        speechTicker?.cancel()
        speechTicker = viewModelScope.launch {
            val startedAt = SystemClock.elapsedRealtime()
            while (isActive) {
                delay(500)
                _state.update { it.copy(elapsedSeconds = (SystemClock.elapsedRealtime() - startedAt) / 1000L) }
            }
        }
        runCatching {
            container.systemSpeechInput.start(
                onPartial = { text -> _state.update { it.copy(transcript = text) } },
                onFinal = { text -> finishSpeech(text, null) },
                onError = { message -> finishSpeech(null, message) },
            )
        }.onFailure { error ->
            finishSpeech(null, "系统听写启动失败：" + (error.message ?: "未知原因"))
        }
    }

    private fun endSpeechSession() {
        speechActive = false
        speechTicker?.cancel()
        speechTicker = null
    }

    /**
     * 听写收尾。成功就把文字当成一条普通文字记录落库——
     * 这样"提取待办"走的是同一条已验证过的路径，不需要为语音新开一套解析逻辑。
     */
    private fun finishSpeech(text: String?, failure: String?) {
        if (!speechActive) return
        endSpeechSession()
        _state.update { it.copy(isRecording = false) }
        val clean = text?.trim().orEmpty()
        if (clean.isEmpty()) {
            _state.update {
                it.copy(
                    error = "语音听写没有结果：" + (failure ?: "未知原因") + " 可以重试，或改用文字输入。",
                    notice = null,
                )
            }
            return
        }
        viewModelScope.launch {
            val captureId = runCatching { container.captureRepository.saveText(clean, zone) }.getOrNull()
            if (captureId == null) {
                _state.update { it.copy(transcript = clean, error = "听写成功但保存到本机失败。", notice = null) }
                return@launch
            }
            _state.update {
                it.copy(
                    transcript = clean,
                    error = null,
                    savedText = SavedText(captureId = captureId, text = clean),
                    notice = "语音识别完成（系统听写），点「提取待办」整理成待办或笔记。",
                )
            }
        }
    }

    /** 删除刚录的这段音频：记录与文件一起删。 */
    fun discardSavedAudio() {
        val current = _state.value.savedAudio ?: return
        viewModelScope.launch {
            runCatching { container.captureRepository.delete(current.captureId) }
            container.mediaStore.deleteQuietly(File(current.path))
            _state.update { it.copy(savedAudio = null, notice = "已删除这段录音，没有留下记录。", error = null) }
        }
    }

    // ---------------- 解析（独立动作 + 确认页） ----------------

    /** 把当前输入框里的文字送去解析。文字会先落库，解析结果进确认页。 */
    fun extractFromText() {
        val target = resolveExtractTarget(_state.value.text, _state.value.savedText)
        if (target == null) {
            _state.update { it.copy(error = "这里没有可解析的文字。先写几个字，或对图片点「提取待办」。", notice = null) }
            return
        }
        viewModelScope.launch {
            _state.update { it.copy(extracting = true, error = null, notice = null) }
            if (!target.needsSave) {
                val captureId = requireNotNull(target.captureId)
                // 记录可能在别处被删掉了：这时候不能拿一个不存在的 capture 去解析，
                // 否则解析出来的候选会挂在一个悬空的来源上。
                if (container.captureRepository.find(captureId) == null) {
                    _state.update {
                        it.copy(
                            extracting = false,
                            savedText = null,
                            error = "那条记录已经被删除了。重新写一遍，或对图片点「提取待办」。",
                        )
                    }
                    return@launch
                }
                // 用过一次就解开绑定：同一条记录重复解析只会产生重复候选。
                _state.update { it.copy(savedText = null) }
                extractCandidates(captureId, target.text, ExtractionRequestSource.SourceType.TEXT)
                return@launch
            }
            val captureId = saveTextCapture(target.text)
            if (captureId == null) {
                _state.update { it.copy(extracting = false, error = "保存到本机失败，无法提取。") }
                return@launch
            }
            // 落库后立刻清空输入框并记住这条记录，两个动作可以连着点。
            _state.update { it.copy(text = "", savedText = SavedText(captureId = captureId, text = target.text)) }
            extractCandidates(captureId, target.text, ExtractionRequestSource.SourceType.TEXT)
        }
    }

    /** 对识别出的图片文字做解析：来源标成 ocr，并挂在同一张图的 capture 上。 */
    fun extractFromImage() {
        val image = _state.value.savedImage
        val text = image?.ocrText?.trim()
        if (image == null || text.isNullOrEmpty()) {
            _state.update { it.copy(error = "这张图还没有可解析的文字。", notice = null) }
            return
        }
        viewModelScope.launch {
            _state.update { it.copy(extracting = true, error = null, notice = null) }
            extractCandidates(image.captureId, text, ExtractionRequestSource.SourceType.OCR)
        }
    }

    fun toggleCandidate(itemId: String) {
        _state.update { current ->
            val selected = current.selectedCandidateIds
            current.copy(
                selectedCandidateIds = if (itemId in selected) selected - itemId else selected + itemId,
            )
        }
    }

    fun dismissConfirm() {
        _state.update {
            it.copy(confirmVisible = false, candidates = emptyList(), selectedCandidateIds = emptySet())
        }
    }

    /**
     * 只保存用户勾选的那些条目。
     *
     * 这是整条链路上唯一会写 task / note 的地方：模型给的是候选，用户点的是决定。
     * 保存后立刻清空候选，所以连点不会写出两份。
     */
    fun saveSelectedCandidates() {
        val current = _state.value
        if (current.savingCandidates) return
        val chosen = current.candidates.filter { it.itemId in current.selectedCandidateIds }
        if (chosen.isEmpty()) {
            _state.update { it.copy(error = "没有选中任何条目。", notice = null) }
            return
        }
        val captureId = current.extractCaptureId
        viewModelScope.launch {
            _state.update { it.copy(savingCandidates = true, error = null) }
            var tasks = 0
            var notes = 0
            var failure: String? = null
            chosen.forEach { item ->
                val result = runCatching {
                    if (item.isTask) {
                        container.taskRepository.create(
                            NewTask(
                                title = item.title,
                                detail = item.detail,
                                dueKind = item.dueKind,
                                dueInstant = item.dueInstant,
                                dueLocalDate = item.dueLocalDate,
                                zone = zone,
                                courseHint = item.courseHint,
                                originCaptureId = captureId,
                                originItemId = item.itemId,
                            ),
                        )
                    } else {
                        container.noteRepository.create(
                            title = item.title,
                            body = item.detail ?: item.evidence,
                            originKind = NoteOriginKind.CAPTURE,
                            courseHint = item.courseHint,
                            originCaptureId = captureId,
                            originItemId = item.itemId,
                            zone = zone,
                        )
                    }
                }
                result.onSuccess { if (item.isTask) tasks++ else notes++ }
                result.onFailure { error -> failure = error.message ?: "写入失败" }
            }
            _state.update {
                it.copy(
                    savingCandidates = false,
                    confirmVisible = false,
                    candidates = emptyList(),
                    selectedCandidateIds = emptySet(),
                    notice = "已按你的确认保存：" + notes + " 条笔记、" + tasks + " 条待办。",
                    error = failure,
                )
            }
        }
    }

    private suspend fun extractCandidates(
        captureId: String,
        text: String,
        sourceType: ExtractionRequestSource.SourceType,
    ) {
        // 没配后端就到此为止，并且说清楚「哪些功能仍然可用」，不把整页都说成不可用。
        if (container.settingsRepository.isPurelyLocal()) {
            _state.update {
                it.copy(
                    extracting = false,
                    error = "没有配置后端地址与令牌，无法提取。图片保存、录音回放与手动保存笔记不受影响。",
                    notice = null,
                )
            }
            return
        }
        container.captureRepository.markExtracting(captureId)
        val request = ExtractionRequest(
            captureId = captureId,
            source = ExtractionRequestSource(type = sourceType, text = text),
            recordedAt = DayCueTime.utcString(container.timeSource.now()),
            timezone = zone.id,
        )
        runCatching { container.apiClient.extract(request) }
            .onSuccess { response ->
                container.captureRepository.markStatus(captureId, CaptureStatus.EXTRACTED)
                val items = response.items.map { item ->
                    val instant = if (item.due.kind == DueKind.DATETIME) {
                        DayCueTime.parseInstantOrNull(item.due.utc ?: "")
                            ?: DayCueTime.parseLocalDateTimeOrNull(item.due.local ?: "", zone)
                    } else {
                        null
                    }
                    val date = if (item.due.kind == DueKind.DATE) {
                        DayCueTime.parseLocalDateOrNull(item.due.local ?: "")
                    } else {
                        null
                    }
                    CandidateItem(
                        itemId = item.itemId,
                        isTask = item.kind == ProposalItemKind.TASK,
                        kindName = if (item.kind == ProposalItemKind.TASK) "待办" else "笔记",
                        title = item.title,
                        detail = item.detail,
                        evidence = item.sourceEvidence,
                        dueKind = item.due.kind,
                        dueInstant = instant,
                        dueLocalDate = date,
                        dueText = dueText(item.due),
                        courseHint = item.courseHint,
                        notes = buildList {
                            addAll(item.ambiguities.map { ambiguity -> ambiguity.message })
                            if (item.isDeadlineOnly) add("只设了截止日，没有提醒时间")
                        },
                    )
                }
                _state.update {
                    it.copy(
                        extracting = false,
                        extractCaptureId = captureId,
                        candidates = items,
                        // 默认全选：用户点「提取待办」的目的就是要整理，
                        // 但每一条都能取消勾选，保存前也会再报一次数量。
                        selectedCandidateIds = items.map { item -> item.itemId }.toSet(),
                        confirmVisible = items.isNotEmpty(),
                        extractionModeName = response.mode.displayName,
                        notice = if (items.isEmpty()) {
                            "解析完成，但没有可确认的条目。"
                        } else {
                            "解析出 " + items.size + " 条候选，确认后才会写入。"
                        },
                    )
                }
            }
            .onFailure { error ->
                // 记录已经落库，失败只改状态：这条记录仍然在「今天」页的待处理里。
                container.captureRepository.markStatus(captureId, CaptureStatus.FAILED)
                _state.update {
                    it.copy(
                        extracting = false,
                        error = "提取失败：" + (error.message ?: "未知错误") + "（记录已保存到本机，可稍后重试）",
                        notice = null,
                    )
                }
            }
    }

    // ---------------- 录音转写 ----------------

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
            // 服务端明确说「没有配置转写供应商」时不改记录状态、也不说成失败：
            // 这不是这条录音的数据出了问题，而是能力没配；录音照样能回放、能手动整理。
            val notConfigured = (error as? DayCueApiException)?.code == ContractErrorCodes.SERVICE_UNAVAILABLE
            if (notConfigured) {
                _state.update {
                    it.copy(
                        notice = "录音已保存到本机，可回放。服务端还没配置语音转写，配好之后可以再转写。",
                        error = null,
                    )
                }
                return@onFailure
            }
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
            val instant = DayCueTime.parseInstantOrNull(due.utc ?: "")
                ?: DayCueTime.parseLocalDateTimeOrNull(due.local ?: "", zone)
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
        if (speechActive) runCatching { container.systemSpeechInput.cancel() }
        endSpeechSession()
        if (_state.value.isRecording) runCatching { container.audioRecorder.cancel() }
    }

    companion object {
        /** 标题长度上限：太长的首行当标题会把列表行撑成一段正文。 */
        private const val TITLE_LIMIT = 40

        fun factory(container: AppContainer): ViewModelProvider.Factory = viewModelFactory {
            initializer { CaptureViewModel(container) }
        }
    }
}
