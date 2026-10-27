package com.daycue.android.ui.common

import android.graphics.BitmapFactory
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * 本机图片预览（缩略图）。
 *
 * 为什么不引入 Coil / Glide：全 App 需要显示图片的地方只有「刚拍/刚选的那一张」和它的缩略图，
 * 为一个页面加一整个图片库（连同磁盘缓存、网络层）不划算，也会拖慢构建。
 *
 * 关键点是 [decodeSampled] 里的采样：手机相册里的原图常见 4000×3000，
 * 整张解码成 Bitmap 大约占 48MB，界面上只用它显示 180dp 高的一小块，
 * 直接解码会在低端机上直接 OOM。这里先读尺寸、再按 2 的幂降采样。
 */
@Composable
fun LocalImage(
    path: String,
    contentDescription: String?,
    modifier: Modifier = Modifier,
    cornerRadius: Dp = 12.dp,
    // 缩略图用 Crop（主体更大，好认），确认「是不是这张」时用 Fit（裁掉的正是要看的部分）。
    contentScale: ContentScale = ContentScale.Crop,
) {
    // 换一张图时 path 会变，remember 以 path 为 key，避免停留在上一张。
    var image by remember(path) { mutableStateOf<ImageBitmap?>(null) }
    var failed by remember(path) { mutableStateOf(false) }

    LaunchedEffect(path) {
        failed = false
        val loaded = withContext(Dispatchers.IO) { runCatching { decodeSampled(path) }.getOrNull() }
        image = loaded
        failed = loaded == null
    }

    Box(
        modifier = modifier
            .clip(RoundedCornerShape(cornerRadius))
            .background(MaterialTheme.colorScheme.surfaceContainerHigh),
        contentAlignment = Alignment.Center,
    ) {
        val current = image
        when {
            current != null -> Image(
                bitmap = current,
                contentDescription = contentDescription,
                modifier = Modifier.fillMaxSize(),
                contentScale = contentScale,
            )

            // 解码失败要说出来。显示一个空框会让用户以为图片没保存成功。
            failed -> Text(
                text = "这张图读不出来了",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )

            else -> Unit
        }
    }
}

/** 按目标宽度做 2 的幂采样解码；文件不存在或不是图片时返回 null。 */
private fun decodeSampled(path: String, targetPx: Int = 720): ImageBitmap? {
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeFile(path, bounds)
    if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null

    // 长边降采样到 targetPx 附近：每次翻倍，直到再翻一倍就小于目标为止。
    val longestSide = maxOf(bounds.outWidth, bounds.outHeight)
    var sample = 1
    while (longestSide / (sample * 2) >= targetPx) {
        sample *= 2
    }
    val options = BitmapFactory.Options().apply { inSampleSize = sample }
    return BitmapFactory.decodeFile(path, options)?.asImageBitmap()
}
