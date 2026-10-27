package com.daycue.android.ui.common

import android.media.MediaPlayer
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.daycue.android.ui.theme.DayCueSpacing
import kotlinx.coroutines.delay
import java.io.File

/**
 * 本机音频回放。
 *
 * 为什么用 MediaPlayer 而不是 ExoPlayer：这里只播一段几 MB 的本地录音，
 * 不需要流式、不需要 DRM、不需要播放列表，为一个播放条引入 ExoPlayer 不划算。
 *
 * 状态全部留在 composable 内部：播放是纯界面行为，没有业务含义，
 * 塞进 ViewModel 只会让「这条记录是什么」和「现在播到第几秒」混在一起。
 */
@Composable
fun AudioPlaybackBar(
    path: String,
    modifier: Modifier = Modifier,
) {
    var prepared by remember(path) { mutableStateOf(false) }
    var playing by remember(path) { mutableStateOf(false) }
    var durationMs by remember(path) { mutableStateOf(0) }
    var positionMs by remember(path) { mutableStateOf(0) }
    var failed by remember(path) { mutableStateOf(false) }

    val player = remember(path) { MediaPlayer() }

    DisposableEffect(path) {
        player.setOnPreparedListener {
            prepared = true
            durationMs = it.duration.coerceAtLeast(0)
        }
        player.setOnCompletionListener {
            playing = false
            positionMs = 0
        }
        player.setOnErrorListener { _, _, _ ->
            failed = true
            playing = false
            true
        }
        val opened = runCatching {
            player.setDataSource(path)
            player.prepareAsync()
        }
        if (opened.isFailure) failed = true
        // 离开页面必须释放：MediaPlayer 持有原生解码器，泄漏几个就会把播放器资源用光。
        onDispose { runCatching { player.release() } }
    }

    // 播放中轮询进度。200ms 足够让进度条看起来是连续的，又不会每帧都跨线程读一次。
    LaunchedEffect(playing) {
        while (playing) {
            positionMs = runCatching { player.currentPosition }.getOrDefault(0)
            delay(200)
        }
    }

    val exists = remember(path) { File(path).exists() }

    Column(modifier = modifier) {
        if (!exists || failed) {
            Text(
                text = if (!exists) "录音文件不在了（可能被系统清理过）。" else "这段录音打不开。",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.error,
            )
            return@Column
        }

        Row(verticalAlignment = Alignment.CenterVertically) {
            DayCueButton(
                text = when {
                    !prepared -> "加载中…"
                    playing -> "暂停"
                    positionMs > 0 -> "继续"
                    else -> "播放"
                },
                onClick = {
                    if (playing) {
                        runCatching { player.pause() }
                        playing = false
                    } else {
                        runCatching { player.start() }
                        playing = true
                    }
                },
                enabled = prepared,
                style = DayCueButtonStyle.Tonal,
            )
            Spacer(Modifier.width(DayCueSpacing.Medium))
            Text(
                text = clock(positionMs) + " / " + clock(durationMs),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Spacer(Modifier.height(DayCueSpacing.XSmall))
        LinearProgressIndicator(
            progress = {
                if (durationMs <= 0) 0f else (positionMs.toFloat() / durationMs).coerceIn(0f, 1f)
            },
            modifier = Modifier
                .fillMaxWidth()
                .height(3.dp),
        )
    }
}

/** 毫秒 → m:ss。录音都是几分钟量级，不值得为它做「1 小时以上」的分支。 */
private fun clock(ms: Int): String {
    val totalSeconds = (ms.coerceAtLeast(0)) / 1000
    val minutes = totalSeconds / 60
    val seconds = totalSeconds % 60
    return minutes.toString() + ":" + seconds.toString().padStart(2, '0')
}
