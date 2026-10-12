package com.daycue.android.ui.followup

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.daycue.android.AppContainer
import com.daycue.android.core.DayCueTime
import com.daycue.android.domain.model.FollowUpState
import com.daycue.android.domain.model.NoteOriginKind
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.time.Instant
import java.time.LocalTime
import java.time.ZoneId
import java.time.temporal.ChronoUnit

/** 「稍后」的三个选项。理由写在选项上，避免用户以为可以任意挑时间。 */
enum class SnoozeOption(val displayName: String) {
    FIFTEEN_MINUTES("15 分钟后"),
    ONE_HOUR("1 小时后"),
    TOMORROW_MORNING("明天早上"),
}

data class FollowUpItem(
    val followUpId: String,
    val courseName: String,
    val state: FollowUpState,
    val scheduledAt: Instant,
    val deliveredAt: Instant?,
    val snoozeUntil: Instant?,
    val attempt: Int,
    val whyNow: String,
)

data class AnsweredItem(
    val followUpId: String,
    val courseName: String,
    val answeredAt: Instant?,
    val replyText: String?,
    val audioPath: String?,
    val noteId: String?,
)

data class FollowUpUiState(
    val outstanding: List<FollowUpItem> = emptyList(),
    val answered: List<AnsweredItem> = emptyList(),
    val drafts: Map<String, String> = emptyMap(),
    val recordingId: String? = null,
    val elapsedSeconds: Long = 0,
    val busy: Boolean = false,
    val message: String? = null,
    val error: String? = null,
)

/**
 * 课后追问。
 *
 * 「为什么现在问」不是装饰：追问最容易被当成骚扰，所以每条都要能回答
 * 「哪节课、什么时候结束、按什么策略、第几次」——这些字段全部来自 FollowUpRecord 与课程名，
 * 不允许界面自己编一段解释。
 */
class FollowUpViewModel(private val container: AppContainer) : ViewModel() {

    private val zone: ZoneId = ZoneId.systemDefault()

    private val _state = MutableStateFlow(FollowUpUiState())
    val state: StateFlow<FollowUpUiState> = _state.asStateFlow()

    init {
        viewModelScope.launch {
            container.followUpRepository.observeOutstanding().collect { records ->
                val items = records.map { record -> toItem(record) }
                _state.update { it.copy(outstanding = items) }
            }
        }
        viewModelScope.launch {
            container.audioRecorder.isRecording.collect { recording ->
                if (!recording) _state.update { it.copy(elapsedSeconds = 0) }
            }
        }
        viewModelScope.launch {
            container.audioRecorder.elapsedSeconds.collect { seconds ->
                _state.update { it.copy(elapsedSeconds = seconds) }
            }
        }
        refreshAnswered()
    }

    fun clearMessages() {
        _state.update { it.copy(message = null, error = null) }
    }

    fun onDraftChange(followUpId: String, text: String) {
        _state.update { it.copy(drafts = it.drafts + (followUpId to text), error = null) }
    }

    fun answer(followUpId: String) {
        val text = _state.value.drafts[followUpId]?.trim().orEmpty()
        if (text.isEmpty()) {
            _state.update { it.copy(error = "请先把回复内容写下来。") }
            return
        }
        viewModelScope.launch {
            _state.update { it.copy(busy = true, error = null, message = null) }
            val courseName = _state.value.outstanding.firstOrNull { it.followUpId == followUpId }?.courseName
            runCatching {
                container.followUpRepository.answer(
                    followUpId = followUpId,
                    text = text,
                    zone = zone,
                    courseHint = courseName,
                )
            }.onSuccess { result ->
                val archived = if (result.archivedNoteFailed) {
                    "但课堂记录没有归档成功（数据库写入失败），回复本身已经保存。"
                } else {
                    "并已归档为一条" + NoteOriginKind.FOLLOW_UP.displayName + "。"
                }
                _state.update {
                    it.copy(
                        busy = false,
                        drafts = it.drafts - followUpId,
                        message = "回复已保存，" + archived,
                    )
                }
                refreshAnswered()
            }.onFailure { error ->
                _state.update { it.copy(busy = false, error = error.message ?: "保存回复失败") }
            }
        }
    }

    /**
     * 稍后：同一个追问只改时间，不新建第二条（设计文档 8.2）。
     * 「明天早上」取次日 08:00，而不是「今天早上」——用户点它的时候今天早上的课多半已经上完了。
     */
    fun snooze(followUpId: String, option: SnoozeOption) {
        viewModelScope.launch {
            val now = container.timeSource.now()
            val until = when (option) {
                SnoozeOption.FIFTEEN_MINUTES -> now.plus(15, ChronoUnit.MINUTES)
                SnoozeOption.ONE_HOUR -> now.plus(1, ChronoUnit.HOURS)
                SnoozeOption.TOMORROW_MORNING -> DayCueTime.atLocal(
                    DayCueTime.localDateOf(now, zone).plusDays(1),
                    LocalTime.of(8, 0),
                    zone,
                )
            }
            runCatching { container.followUpRepository.snooze(followUpId, until) }
                .onSuccess {
                    _state.update {
                        it.copy(message = "已推迟到 " + DayCueTime.displayDateTime(until, zone) + "。", error = null)
                    }
                    container.reminderScheduler.cancelFollowUp(followUpId)
                }
                .onFailure { error ->
                    _state.update { it.copy(error = error.message ?: "推迟失败") }
                }
        }
    }

    /** 跳过 ≠ 已学会：这里只记状态，不写任何「已掌握」的记忆。 */
    fun skip(followUpId: String) {
        viewModelScope.launch {
            runCatching {
                container.followUpRepository.skip(followUpId)
                container.reminderScheduler.cancelFollowUp(followUpId)
            }.onSuccess {
                _state.update { it.copy(message = "已跳过这次追问。跳过只代表这次不问，不代表你已经掌握。", error = null) }
            }.onFailure { error ->
                _state.update { it.copy(error = error.message ?: "跳过失败") }
            }
        }
    }

    fun startRecording(followUpId: String) {
        if (_state.value.recordingId != null) {
            _state.update { it.copy(error = "已经有一段录音在进行中。") }
            return
        }
        val started = runCatching { container.audioRecorder.start() }.getOrDefault(false)
        _state.update {
            if (started) {
                it.copy(recordingId = followUpId, error = null, message = "正在录音，说完点「停止并保存」。")
            } else {
                it.copy(error = "录音启动失败。可能是麦克风被其他应用占用，或系统拒绝了录音权限。")
            }
        }
    }

    /**
     * 语音回复：音频先落盘并挂到追问上，再尝试转写。
     *
     * 转写成功才有文字，而追问的关闭需要文字——所以这里如实告诉用户
     * 「音频已保存、追问仍待回复」，而不是偷偷替他把状态改成已回复。
     */
    fun stopRecording() {
        val followUpId = _state.value.recordingId ?: return
        viewModelScope.launch {
            val seconds = _state.value.elapsedSeconds
            val file = runCatching { container.audioRecorder.stop() }.getOrNull()
            _state.update { it.copy(recordingId = null) }
            if (file == null) {
                _state.update { it.copy(error = "录音没有生成文件，这段语音没有保存。") }
                return@launch
            }
            _state.update { it.copy(busy = true, error = null, message = null) }
            runCatching {
                container.followUpRepository.attachAudioReply(
                    followUpId = followUpId,
                    mediaPath = file.absolutePath,
                    transcript = null,
                )
            }.onFailure { error ->
                _state.update { it.copy(busy = false, error = error.message ?: "保存语音回复失败") }
            }.onSuccess {
                _state.update { it.copy(busy = false, message = "语音回复已保存到本机（" + seconds.toString() + " 秒）。") }
                transcribe(followUpId, file)
            }
        }
    }

    fun cancelRecording() {
        runCatching { container.audioRecorder.cancel() }
        _state.update { it.copy(recordingId = null, message = "已取消录音，没有保存任何内容。", error = null) }
    }

    private suspend fun transcribe(followUpId: String, file: File) {
        if (container.settingsRepository.isPurelyLocal()) {
            _state.update {
                it.copy(
                    message = "语音已保存到本机；未配置后端，无法转写。追问仍保持待回复，可以补一条文字回复。",
                )
            }
            return
        }
        runCatching {
            val bytes = withContext(Dispatchers.IO) { file.readBytes() }
            container.apiClient.transcribe(
                audioBytes = bytes,
                mimeType = mimeTypeOf(file.name),
                language = null,
                timezone = zone.id,
            )
        }.onSuccess { response ->
            _state.update { it.copy(message = "转写完成（" + response.mode.displayName + "），正在按文字内容归档。") }
            runCatching {
                container.followUpRepository.answer(
                    followUpId = followUpId,
                    text = response.text,
                    zone = zone,
                    courseHint = _state.value.outstanding.firstOrNull { it.followUpId == followUpId }?.courseName,
                )
            }.onSuccess {
                refreshAnswered()
            }.onFailure { error ->
                _state.update { it.copy(error = "转写成功但归档失败：" + (error.message ?: "未知错误")) }
            }
        }.onFailure { error ->
            _state.update {
                it.copy(
                    error = "转写失败：" + (error.message ?: "未知错误"),
                    message = "音频已保存到本机，追问仍保持待回复。",
                )
            }
        }
    }

    fun refreshAnswered() {
        viewModelScope.launch {
            // 已回复列表：仓储只暴露了「未完成」的追问，历史回复要走 DAO 只读查询。
            // 写入仍然全部经过仓储（answer / attachAudioReply），这里不直接改表。
            val records = runCatching { container.database.followUpDao().listAnswered(50) }.getOrDefault(emptyList())
            val items = records.map { record ->
                val replies = runCatching { container.followUpRepository.repliesFor(record.id) }.getOrDefault(emptyList())
                val text = replies.firstOrNull { it.text != null }?.text
                AnsweredItem(
                    followUpId = record.id,
                    courseName = courseNameOf(record.courseId),
                    answeredAt = record.deliveredAtUtc ?: record.scheduledAtUtc,
                    replyText = text,
                    audioPath = replies.firstOrNull { it.mediaPath != null }?.mediaPath,
                    noteId = replies.firstOrNull { it.noteId != null }?.noteId,
                )
            }
            _state.update { it.copy(answered = items) }
        }
    }

    private suspend fun toItem(record: com.daycue.android.data.local.entity.FollowUpRecord): FollowUpItem {
        val courseName = courseNameOf(record.courseId)
        val course = runCatching { container.scheduleRepository.findCourse(record.courseId) }.getOrNull()
        val instance = runCatching { container.scheduleRepository.findInstance(record.courseInstanceId) }.getOrNull()

        val why = StringBuilder()
        if (instance != null) {
            why.append("《").append(courseName).append("》在 ")
                .append(DayCueTime.displayDateTime(instance.endsAtUtc, zone)).append(" 结束")
        } else {
            why.append(courseName).append(" 的这次课：原始课程时间已不可查")
        }
        if (course != null) {
            why.append("；追问策略：").append(course.followUpMode.displayName)
            if (course.followUpEnabled) {
                why.append("，课后 ").append(course.followUpDelayMinutes.toString()).append(" 分钟询问")
            } else {
                why.append("（当前这门课的追问是关闭的）")
            }
        }
        why.append("；第 ").append((record.attempt + 1).toString()).append(" 次询问")
        val snoozed = record.snoozeUntilUtc
        if (record.state == FollowUpState.SNOOZED && snoozed != null) {
            why.append("。你点过「稍后」，将在 ").append(DayCueTime.displayDateTime(snoozed, zone)).append(" 再问")
        }

        return FollowUpItem(
            followUpId = record.id,
            courseName = courseName,
            state = record.state,
            scheduledAt = record.scheduledAtUtc,
            deliveredAt = record.deliveredAtUtc,
            snoozeUntil = snoozed,
            attempt = record.attempt,
            whyNow = why.toString(),
        )
    }

    private suspend fun courseNameOf(courseId: String): String =
        runCatching { container.scheduleRepository.findCourse(courseId)?.name }.getOrNull()
            ?.takeIf { it.isNotBlank() } ?: "已删除的课程"

    private fun mimeTypeOf(fileName: String): String = when (fileName.substringAfterLast('.', "").lowercase()) {
        "m4a", "mp4" -> "audio/mp4"
        "3gp" -> "audio/3gpp"
        "wav" -> "audio/wav"
        "ogg", "opus" -> "audio/ogg"
        "amr" -> "audio/amr"
        else -> "application/octet-stream"
    }

    override fun onCleared() {
        if (_state.value.recordingId != null) runCatching { container.audioRecorder.cancel() }
    }

    companion object {
        fun factory(container: AppContainer): ViewModelProvider.Factory = viewModelFactory {
            initializer { FollowUpViewModel(container) }
        }
    }
}
