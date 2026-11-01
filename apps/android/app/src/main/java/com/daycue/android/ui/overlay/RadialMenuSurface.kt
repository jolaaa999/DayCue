package com.daycue.android.ui.overlay

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.wrapContentSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import com.daycue.android.domain.radial.RadialAction
import com.daycue.android.domain.radial.RadialGeometry
import com.daycue.android.domain.radial.RadialHit
import com.daycue.android.domain.radial.RadialMenuModel
import com.daycue.android.domain.radial.RadialPoint
import com.daycue.android.domain.radial.RadialSelection
import com.daycue.android.domain.radial.RadialTapOutcome
import com.daycue.android.domain.radial.resolveRadialTap
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlin.math.cos
import kotlin.math.roundToInt
import kotlin.math.sin

/**
 * 悬浮球可见部分的直径（64dp，满足 48dp 最小触控目标）。
 */
private val BallSize = 64.dp

/**
 * 悬浮窗的边长。
 *
 * 比球本身大 12dp：这点余量用来画投影和外发光。窗口尺寸卡死等于球径时，
 * 任何阴影都会被窗口边界裁掉，球看起来会像一张贴上去的圆纸片。
 */
private val BallWindowSize = 76.dp

/** 扇环内半径：圆内区域留给「关闭 / 返回」，也避免手指按在中心误选扇区。 */
private val RingInnerRadius = 64.dp

/** 扇环外半径。取 148dp：单手持机时拇指从球心够到边缘约 2.3cm，再大就需要换手。 */
private val RingOuterRadius = 148.dp

/** 扇区之间的角度间隙。没有间隙时两块同色扇区会连成一片，看不出边界。 */
private const val SectorGapDegrees = 2.5f

/**
 * 展开后短暂忽略手势的时长。
 *
 * 为什么必须有：点球展开时，同一个手指的后续事件（甚至系统重发的 MOVE/UP）会落到刚刚变大、
 * 内容换过的全屏窗口上，被识别成「选中某个扇区」。真机上这表现为
 * 「点一下球，App 自己跳到了一个我没选的页面」。宁可牺牲 250ms 的即时响应，
 * 也不能让一次点击产生一个用户没做过的选择。
 */
private const val ArmDelayMillis = 250L

/** 标签盒尺寸：给「新课程」这种三字标签留够宽度，避免折行。 */
private val LabelBox = 64.dp

/** 展开/切换层级的入场动画时长。 */
private const val EnterMillis = 260

/** 选中后先播完退场动画再执行动作，避免「点完菜单硬切到 App」。 */
private const val ExitMillis = 120

/**
 * 悬浮球本体。
 *
 * 手势分两个 pointerInput：点击用 detectTapGestures、拖动用 detectDragGestures——
 * 前者在移动超过 slop 后会自动取消，所以轻点和拖动不会互相抢事件。
 *
 * [onDragEnd] 在手指抬起时回调，用于让服务把球吸附到最近的屏幕边缘；
 * 不做这一步的话，球被拖到屏幕中间后就会一直停在中间挡内容。
 */
@Composable
fun FloatingBallContent(
    onTap: () -> Unit,
    onDrag: (Float, Float) -> Unit,
    onDragEnd: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = MaterialTheme.colorScheme
    var pressed by remember { mutableStateOf(false) }
    var dragging by remember { mutableStateOf(false) }

    // 按下缩一点、拖动再放大一点：手指压上去要有反馈，否则在壁纸上很难判断点到没有
    val scale by animateFloatAsState(
        targetValue = when {
            dragging -> 1.06f
            pressed -> 0.92f
            else -> 1f
        },
        animationSpec = spring(dampingRatio = 0.55f, stiffness = Spring.StiffnessHigh),
        label = "ballScale",
    )

    Box(
        modifier = modifier
            .fillMaxSize()
            .pointerInput(Unit) {
                detectTapGestures(
                    onPress = {
                        pressed = true
                        tryAwaitRelease()
                        pressed = false
                    },
                    onTap = { onTap() },
                )
            }
            .pointerInput(Unit) {
                detectDragGestures(
                    onDragStart = {
                        dragging = true
                        pressed = false
                    },
                    onDrag = { change, dragAmount ->
                        // 必须 consume：不消费的话父级滚动/点击会同时收到这条手势
                        change.consume()
                        onDrag(dragAmount.x, dragAmount.y)
                    },
                    onDragEnd = {
                        dragging = false
                        onDragEnd()
                    },
                    onDragCancel = {
                        dragging = false
                        onDragEnd()
                    },
                )
            },
        contentAlignment = Alignment.Center,
    ) {
        Canvas(
            Modifier
                .fillMaxSize()
                .graphicsLayer {
                    scaleX = scale
                    scaleY = scale
                },
        ) {
            val ballRadius = BallSize.toPx() / 2f
            val center = Offset(size.width / 2f, size.height / 2f)

            // 外发光：球贴在壁纸上时靠它把边界「托」出来
            drawCircle(
                brush = Brush.radialGradient(
                    colors = listOf(colors.primary.copy(alpha = 0.30f), colors.primary.copy(alpha = 0f)),
                    center = center,
                    radius = size.minDimension / 2f,
                ),
                radius = size.minDimension / 2f,
                center = center,
            )
            // 本体：斜向渐变，比纯色多一层体积感
            drawCircle(
                brush = Brush.linearGradient(
                    colors = listOf(colors.primary, colors.primaryContainer),
                    start = Offset(center.x - ballRadius, center.y - ballRadius),
                    end = Offset(center.x + ballRadius, center.y + ballRadius),
                ),
                radius = ballRadius,
                center = center,
            )
            // 内圈留白，做成「环里一个字」的样子，比纯色圆更容易在壁纸上被认出来
            drawCircle(
                color = colors.surface.copy(alpha = 0.94f),
                radius = ballRadius * 0.74f,
                center = center,
            )
            // 顶部高光，弱到几乎看不出，但去掉球就变扁平
            drawArc(
                color = androidx.compose.ui.graphics.Color.White.copy(alpha = 0.35f),
                startAngle = 200f,
                sweepAngle = 140f,
                useCenter = false,
                topLeft = Offset(center.x - ballRadius * 0.86f, center.y - ballRadius * 0.86f),
                size = Size(ballRadius * 1.72f, ballRadius * 1.72f),
                style = Stroke(width = ballRadius * 0.10f),
            )
        }
        Text(
            text = "记",
            style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.SemiBold,
            color = colors.primary,
        )
    }
}

/**
 * 环形多级扇区菜单。
 *
 * [anchor] 是悬浮球在窗口坐标系里的中心点；窗口本身在展开时是全屏的，
 * 所以这里算出来的位置与用户看到的球心一致，菜单就像从球上长出来一样。
 *
 * 交互约定（写死，不做「智能猜测」）：
 * - 点扇区：有下级就进入下级，没有下级就执行；
 * - 拖到扇区再松手：执行该扇区（与点击同义，给拇指更省力的用法）；
 * - 点圆心的「关闭 / 返回」：关闭菜单，或退回上一级；
 * - 点环外空白：关闭菜单，什么也不做。
 */
@Composable
fun RadialMenuContent(
    model: RadialMenuModel,
    anchor: Offset,
    onAction: (RadialAction) -> Unit,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = MaterialTheme.colorScheme
    val density = LocalDensity.current
    val outerPx = with(density) { RingOuterRadius.toPx() }
    val innerPx = with(density) { RingInnerRadius.toPx() }
    val edgePaddingPx = with(density) { 8.dp.toPx() }
    val labelBoxPx = with(density) { LabelBox.toPx() }
    val scope = rememberCoroutineScope()

    var path by remember { mutableStateOf<List<Int>>(emptyList()) }
    var hover by remember { mutableIntStateOf(-1) }
    // 刚展开的一瞬间不接管手势（原因见 ArmDelayMillis）
    var armed by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        delay(ArmDelayMillis)
        armed = true
    }
    val ring = remember(path, model) { model.ring(path) }
    val count = ring.items.size

    // 入场动画：0=完全收起，1=完全展开。切换层级时重播，让「进下一级」有明确的空间感。
    val appear = remember { Animatable(0f) }
    var exiting by remember { mutableStateOf(false) }
    LaunchedEffect(path) {
        appear.snapTo(if (path.isEmpty()) 0.72f else 0.86f)
        appear.animateTo(
            targetValue = 1f,
            animationSpec = spring(dampingRatio = 0.72f, stiffness = Spring.StiffnessMediumLow),
        )
    }
    // 第三种扇区底色：ColorScheme 没有 surfaceHigh 这一档，用 onSurface 叠极低透明度得到，
    // 这样浅色/深色主题下都不需要写死颜色。必须在组合期算好，DrawScope 里不能再调 @Composable。
    val altSectorColor = blendOver(colors.onSurface, colors.surface, 0.06f)

    // 高亮扇区的外扩量：有选中时微微外扩，给出「我选的就是这块」的即时反馈
    val hoverPop by animateFloatAsState(
        targetValue = if (hover >= 0) 1f else 0f,
        animationSpec = spring(dampingRatio = 0.6f, stiffness = Spring.StiffnessMedium),
        label = "hoverPop",
    )

    // 区分两种「点了没反应」：菜单根本没组合出来，还是组合了但触摸事件没送到。
    LaunchedEffect(ring, path) {
        android.util.Log.i("DayCueOverlay", "扇区菜单已组合：" + ring.title + "，" + count + " 个扇区，path=" + path)
    }

    BoxWithConstraints(modifier.fillMaxSize()) {
        val widthPx = constraints.maxWidth.toFloat()
        val heightPx = constraints.maxHeight.toFloat()

        // 兜底夹取：服务在展开前已把球挪到环放得下的位置，这里再夹一次防御屏幕旋转/分屏等变化
        val center = remember(anchor, widthPx, heightPx, outerPx, edgePaddingPx) {
            val minX = outerPx + edgePaddingPx
            val maxX = maxOf(minX, widthPx - outerPx - edgePaddingPx)
            val minY = outerPx + edgePaddingPx
            val maxY = maxOf(minY, heightPx - outerPx - edgePaddingPx)
            RadialPoint(
                x = anchor.x.coerceIn(minX, maxX),
                y = anchor.y.coerceIn(minY, maxY),
            )
        }
        val centerOffset = Offset(center.x, center.y)

        fun indexAt(position: Offset): Int {
            val hit = RadialGeometry.hitTest(
                point = RadialPoint(position.x, position.y),
                center = center,
                innerRadius = innerPx,
                outerRadius = outerPx,
                count = count,
            )
            return if (hit is RadialHit.Sector) hit.index else -1
        }

        /** 先播退场动画再执行，避免菜单「啪」一下消失、App 直接盖上来。 */
        fun exitThen(block: () -> Unit) {
            if (exiting) return
            exiting = true
            scope.launch {
                appear.animateTo(0f, tween(ExitMillis))
                block()
            }
        }

        fun commit(index: Int) {
            when (val selection = model.select(path, index)) {
                is RadialSelection.DrillDown -> {
                    path = selection.path
                    hover = -1
                }
                is RadialSelection.Commit -> exitThen { onAction(selection.action) }
                RadialSelection.Ignored -> Unit
            }
        }

        fun dismiss() {
            exitThen(onDismiss)
        }

        fun tapAt(position: Offset) {
            // 命中优先级全部落在纯逻辑里（domain/radial/RadialTapResolver），
            // 这里只负责把结果翻译成 UI 动作——这样优先级可以用 JVM 测试锁住，
            // 而不是靠真机手点去发现「点圆心怎么把菜单关了」。
            when (
                val outcome = resolveRadialTap(
                    path = path,
                    position = RadialPoint(position.x, position.y),
                    center = RadialPoint(center.x, center.y),
                    innerRadius = innerPx,
                    outerRadius = outerPx,
                    count = count,
                    armed = armed,
                    exiting = exiting,
                )
            ) {
                RadialTapOutcome.Dismiss -> dismiss()
                RadialTapOutcome.Back -> path = model.back(path)
                is RadialTapOutcome.Commit -> commit(outcome.index)
                RadialTapOutcome.Ignore -> Unit
            }
        }

        // 视觉层：整体以环心为原点做缩放淡入，手势层留在这个缩放之外，命中区域永远是 1:1 的
        Box(
            modifier = Modifier
                .fillMaxSize()
                .graphicsLayer {
                    val scale = appear.value
                    scaleX = scale
                    scaleY = scale
                    alpha = ((scale - 0.6f) / 0.4f).coerceIn(0f, 1f)
                    transformOrigin = TransformOrigin(
                        if (widthPx > 0f) center.x / widthPx else 0.5f,
                        if (heightPx > 0f) center.y / heightPx else 0.5f,
                    )
                },
        ) {
            Canvas(Modifier.fillMaxSize()) {
                // 轻遮罩：不遮住底下的界面会读不清扇区上的字，遮太重又像是打开了新页面
                drawRect(color = colors.scrim.copy(alpha = 0.36f))

                // 环外投影：让整圈菜单从背景里浮起来
                drawCircle(
                    brush = Brush.radialGradient(
                        colors = listOf(colors.primary.copy(alpha = 0.18f), colors.primary.copy(alpha = 0f)),
                        center = centerOffset,
                        radius = outerPx * 1.16f,
                    ),
                    radius = outerPx * 1.16f,
                    center = centerOffset,
                )

                val sweep = 360f / count
                ring.items.forEachIndexed { index, _ ->
                    val selected = index == hover
                    // 高亮块往外多长一点，用 hoverPop 平滑过渡，不靠瞬间换色
                    val grow = if (selected) (6.dp.toPx() * hoverPop) else 0f
                    val r = outerPx + grow
                    drawSector(
                        center = centerOffset,
                        radius = r,
                        startDegrees = RadialGeometry.START_ROTATION_DEGREES + sweep * index + SectorGapDegrees / 2f,
                        sweepDegrees = sweep - SectorGapDegrees,
                        brush = if (selected) {
                            Brush.radialGradient(
                                colors = listOf(colors.primary, colors.primary.copy(alpha = 0.82f)),
                                center = centerOffset,
                                radius = r,
                            )
                        } else {
                            // 奇偶扇区给两种极接近的底色，扇区之间的边界因此不需要描边也能看清
                            Brush.radialGradient(
                                colors = listOf(
                                    if (index % 2 == 0) colors.surface else colors.surfaceVariant,
                                    if (index % 2 == 0) colors.surfaceVariant else altSectorColor,
                                ),
                                center = centerOffset,
                                radius = r,
                            )
                        },
                    )
                }

                // 圆心：把扇形汇聚的尖角挡住，顺便当「关闭 / 返回」的按钮底
                drawCircle(color = colors.surface, radius = innerPx, center = centerOffset)
                drawCircle(
                    brush = Brush.radialGradient(
                        colors = listOf(colors.primary.copy(alpha = 0.16f), colors.primary.copy(alpha = 0.04f)),
                        center = centerOffset,
                        radius = innerPx,
                    ),
                    radius = innerPx - 2f,
                    center = centerOffset,
                )
                drawCircle(
                    color = colors.primary.copy(alpha = 0.22f),
                    radius = innerPx - 2f,
                    center = centerOffset,
                    style = Stroke(width = 1.5.dp.toPx()),
                )
            }

            // 扇区标签
            ring.items.forEachIndexed { index, item ->
                val labelRadius = (innerPx + outerPx) / 2f
                val point = RadialGeometry.pointAt(
                    center = center,
                    radius = labelRadius,
                    angleDegrees = RadialGeometry.sectorMidAngle(index, count),
                )
                // 盒子按「标签中心点」对齐：offset 减半个盒子，盒子内部再居中，
                // 这样任意字数（1～4 字）都落在扇区正中，不会因为文本宽度不同而偏。
                Box(
                    modifier = Modifier
                        .offset {
                            IntOffset(
                                (point.x - labelBoxPx / 2f).roundToInt(),
                                (point.y - labelBoxPx / 2f).roundToInt(),
                            )
                        }
                        .size(LabelBox)
                        .wrapContentSize(Alignment.Center),
                ) {
                    Text(
                        text = item.label,
                        style = MaterialTheme.typography.bodyLarge,
                        fontWeight = if (index == hover) FontWeight.SemiBold else FontWeight.Medium,
                        textAlign = TextAlign.Center,
                        maxLines = 1,
                        softWrap = false,
                        color = if (index == hover) colors.onPrimary else colors.onSurface,
                    )
                }
            }

            // 圆心文字：一级是「关闭」，进了子级是「返回」。
            // 盒子必须是「直径」而不是「半径」——写成半径会让文字整体偏出半个半径，
            // 这正是之前「字不在正中心」的原因。
            Box(
                modifier = Modifier
                    .offset {
                        IntOffset(
                            (center.x - innerPx).roundToInt(),
                            (center.y - innerPx).roundToInt(),
                        )
                    }
                    .size(RingInnerRadius * 2)
                    .wrapContentSize(Alignment.Center),
            ) {
                Text(
                    text = if (path.isEmpty()) "关闭" else "返回",
                    style = MaterialTheme.typography.labelLarge,
                    fontWeight = FontWeight.Medium,
                    color = colors.primary,
                )
            }

            // 当前层的层级提示：让用户知道自己在第几级，而不是只靠圆心文字猜
            if (path.isNotEmpty()) {
                val widthGuess = with(density) { 120.dp.toPx() }
                Box(
                    modifier = Modifier
                        .offset {
                            IntOffset(
                                (center.x - widthGuess / 2f).roundToInt(),
                                (center.y + outerPx + with(density) { 10.dp.toPx() }).roundToInt(),
                            )
                        }
                        .size(width = 120.dp, height = 28.dp)
                        .wrapContentSize(Alignment.Center),
                ) {
                    Text(
                        text = ring.title,
                        style = MaterialTheme.typography.labelMedium,
                        textAlign = TextAlign.Center,
                        color = colors.onSurface,
                    )
                }
            }
        }

        // 手势层放在最后（覆盖整屏）。用 Box 撑满并接管输入的写法，避免和上面的 Canvas 抢事件：
        // Canvas 不消费输入，点按只会落到这一层。注意它不在缩放层里，命中区域始终与屏幕 1:1。
        Box(
            modifier = Modifier
                .fillMaxSize()
                .pointerInput(count, center, innerPx, outerPx, path, armed, exiting) {
                    detectTapGestures(onTap = { position -> tapAt(position) })
                }
                .pointerInput(count, center, innerPx, outerPx, path, armed, exiting) {
                    detectDragGestures(
                        onDragStart = { position -> if (armed && !exiting) hover = indexAt(position) },
                        onDrag = { change, _ ->
                            if (!armed || exiting) return@detectDragGestures
                            hover = indexAt(change.position)
                            change.consume()
                        },
                        onDragEnd = {
                            val index = hover
                            hover = -1
                            if (armed && !exiting && index >= 0) commit(index)
                        },
                        onDragCancel = { hover = -1 },
                    )
                },
        )
    }
}

/**
 * 把一层半透明色压到底色上，得到一个实色。
 *
 * 用途：Material3 的 ColorScheme 没有「比 surfaceVariant 再深半档」的颜色，
 * 而扇区需要第三种底色才能看出层次；这里按 alpha 混合，避免把颜色写死。
 */
private fun blendOver(top: Color, bottom: Color, topAlpha: Float): Color = Color(
    red = top.red * topAlpha + bottom.red * (1f - topAlpha),
    green = top.green * topAlpha + bottom.green * (1f - topAlpha),
    blue = top.blue * topAlpha + bottom.blue * (1f - topAlpha),
)

/** 画一块扇区（用渐变填充，避免大面积纯色显得平板）。 */
private fun DrawScope.drawSector(
    center: Offset,
    radius: Float,
    startDegrees: Float,
    sweepDegrees: Float,
    brush: Brush,
) {
    // DrawScope 只按矩形画弧，所以这里把扇区顶点搬到椭圆中心，得到一个标准扇形
    val topLeft = Offset(center.x - radius, center.y - radius)
    drawArc(
        brush = brush,
        startAngle = startDegrees,
        sweepAngle = sweepDegrees,
        useCenter = true,
        topLeft = topLeft,
        size = Size(radius * 2f, radius * 2f),
    )
}

/** 供服务计算窗口尺寸用：窗口比球大一圈，留出投影空间。 */
internal val FloatingBallWindowSize = BallWindowSize
