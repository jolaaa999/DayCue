package com.daycue.android.platform.overlay

import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.PixelFormat
import android.os.IBinder
import android.animation.ValueAnimator
import android.util.Log
import android.view.animation.DecelerateInterpolator
import android.view.Gravity
import android.view.WindowManager
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.platform.ComposeView
import androidx.compose.ui.platform.ViewCompositionStrategy
import androidx.core.app.NotificationCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import androidx.lifecycle.setViewTreeLifecycleOwner
import androidx.savedstate.SavedStateRegistry
import androidx.savedstate.SavedStateRegistryController
import androidx.savedstate.SavedStateRegistryOwner
import androidx.savedstate.setViewTreeSavedStateRegistryOwner
import com.daycue.android.R
import com.daycue.android.domain.radial.RadialAction
import com.daycue.android.platform.notify.NotificationChannels
import com.daycue.android.platform.platformDependenciesOrNull
import com.daycue.android.ui.DayCueRoutes
import com.daycue.android.ui.overlay.FloatingBallContent
import com.daycue.android.ui.overlay.FloatingBallWindowSize
import com.daycue.android.ui.overlay.RadialMenuCatalog
import com.daycue.android.ui.overlay.RadialMenuContent
import com.daycue.android.ui.theme.DayCueTheme
import com.daycue.android.ui.theme.ThemeMode
import com.daycue.android.ui.theme.resolveDark
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

private const val TAG = "DayCueOverlay"

/**
 * 悬浮窗的边长（dp），不是可见球径。
 *
 * 球本身仍是 64dp，窗口比它大 12dp，多出来的边距用来画阴影/发光；
 * 窗口尺寸卡成球径会把阴影全部裁掉。
 */
private val BallWindowSize = FloatingBallWindowSize

/** 吸边后与屏幕边缘留的空隙，太小会贴死边框看起来像被裁掉。 */
private const val EDGE_MARGIN_DP = 6

/** 吸边动画时长：短到不拖沓，长到能看出「滑过去」而不是瞬移。 */
private const val SNAP_DURATION_MS = 220L

/** 球的初始纵向位置：屏幕高度的 42%，单手拇指自然停留的高度。 */
private const val BALL_INITIAL_Y_RATIO = 0.42f

/**
 * 扇环外半径（dp）。
 *
 * 必须与 ui/overlay/RadialMenuSurface.kt 里的 RingOuterRadius 保持一致：
 * 展开前要按这个值把球挪到环放得下的位置，两边不一致就会出现「菜单被屏幕边缘切掉」。
 */
private const val RING_OUTER_RADIUS_DP = 148

/**
 * 桌面悬浮球的前台服务。
 *
 * 为什么必须是前台服务：Android 8+ 的后台服务会被系统直接杀掉，
 * 用普通 Service 挂一个长期存在的窗口，结果是「用户开了悬浮球，过几分钟它自己不见了」，
 * 而且没有任何报错。代价是必须显示一条不可取消的常驻通知——这是系统的交换条件，
 * 不是我们偷懒，也不能藏起来。
 *
 * 刻意不做的事：
 * - 不在开机广播里自动拉起（Android 12+ 禁止后台启动前台服务，强行做只会被系统拦掉）；
 * - 不用 START_STICKY（服务被杀后重启时没有前台上下文重新加窗口，会留下一个空服务）。
 */
class FloatingBallService : Service() {

    private val owner = OverlayLifecycleOwner()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    private var windowManager: WindowManager? = null
    private var overlayView: ComposeView? = null
    private var layoutParams: WindowManager.LayoutParams? = null

    /** 吸边动画。拖拽/收起时要能打断它，否则它会继续把窗口往旧目标拽。 */
    private var snapAnimator: ValueAnimator? = null

    /** 展开态。窗口尺寸随之切换：收起=球大小，展开=全屏。 */
    private val expanded = mutableStateOf(false)

    /** 球心在屏幕坐标系里的位置；展开时菜单围绕它绘制。 */
    private val ballCenter = mutableStateOf(Offset.Zero)

    /** 展开前球的原始位置（屏幕边角）。展开时球会被临时挪进来，收起时要放回去。 */
    private var preExpandCenter: Offset? = null

    /** 外观偏好。悬浮球不是 Activity，读不到 Compose 的主题，只能自己查一次设置。 */
    private val themeRaw = mutableStateOf<String?>(null)

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        isRunning = true
        windowManager = getSystemService(Context.WINDOW_SERVICE) as? WindowManager
        owner.onCreate()
        // 渠道必须先建：Android 8+ 上没有渠道的通知会被静默丢弃，
        // 结果就是 startForeground 抛异常、服务启动失败，而日志里只有一句「未找到渠道」。
        NotificationChannels.ensure(this)
        try {
            startForeground(NOTIFICATION_ID, buildNotification())
        } catch (e: Throwable) {
            // 例如用户关了本渠道通知、或系统拒绝该前台服务类型。没有前台状态就不该继续持有窗口，
            // 否则会留下一个随时被杀、用户也不知道它存在的服务。
            Log.e(TAG, "启动前台服务失败，放弃悬浮球", e)
            stopSelf()
            return
        }
        refreshTheme()
        attachOverlay()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == OverlayController.ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }
        // 幂等重挂：服务进程还在、但窗口被系统收回或压根没布局成功时，
        // 再 startService 一次就能把球救回来。真机上确实出现过「服务在跑、窗口在、
        // 但界面是空的、点也点不动」的状态，没有这条就只能杀了进程重来。
        // 只在确认窗口已经不可用（被系统收回 / 自检判定异常）时重挂；
        // 早期版本用 isAttachedToWindow 判断，结果 onCreate 挂窗和 onStartCommand 抢在同一帧，
        // 同一个服务挂了两个窗口：上面那个是空白的，把下面的球挡住而且吃掉了触摸。
        if (overlayView == null) {
            Log.i(TAG, "收到启动请求但悬浮窗已不存在，重新挂载")
            attachOverlay()
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        snapAnimator?.cancel()
        isRunning = false
        expanded.value = false
        overlayView?.let { view ->
            runCatching { windowManager?.removeView(view) }
                .onFailure { Log.w(TAG, "移除悬浮窗失败", it) }
        }
        overlayView = null
        owner.onDestroy()
        scope.cancel()
        super.onDestroy()
    }

    // ---- 窗口 ----

    private fun attachOverlay() {
        val manager = windowManager ?: run {
            Log.e(TAG, "拿不到 WindowManager，悬浮球无法创建")
            stopSelf()
            return
        }
        val sizePx = windowSizePx()
        val metrics = resources.displayMetrics
        val params = WindowManager.LayoutParams(
            sizePx,
            sizePx,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            // 不可获焦：悬浮球不能抢输入法焦点，也不能拦返回键
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = metrics.widthPixels - sizePx - dp(EDGE_MARGIN_DP)
            y = (metrics.heightPixels * BALL_INITIAL_Y_RATIO).toInt()
        }
        layoutParams = params
        ballCenter.value = Offset(params.x + sizePx / 2f, params.y + sizePx / 2f)

        val view = ComposeView(this).apply {
            // 非 Activity 宿主必须自己提供 LifecycleOwner，否则 ComposeView 在 attach 时抛
            // "ViewTreeLifecycleOwner not found from androidx.compose.ui.platform.ComposeView"
            setViewTreeLifecycleOwner(owner)
            // Compose 1.7 起 AndroidComposeView.onAttachedToWindow 会强校验 SavedStateRegistryOwner，
            // 只给 LifecycleOwner 会在窗口 attach 的瞬间抛
            // IllegalStateException: Composed into the View which doesn't propagateViewTreeSavedStateRegistryOwner!
            // 这个异常发生在 onAttachedToWindow 里，包不进去 try/catch，必须在挂载前就补齐。
            setViewTreeSavedStateRegistryOwner(owner)
            setViewCompositionStrategy(ViewCompositionStrategy.DisposeOnDetachedFromWindow)
        }
        overlayView = view
        view.addOnAttachStateChangeListener(object : android.view.View.OnAttachStateChangeListener {
            override fun onViewAttachedToWindow(v: android.view.View) {
                Log.i(TAG, "悬浮窗已 attach：" + v.width + "x" + v.height)
            }
            override fun onViewDetachedFromWindow(v: android.view.View) {
                Log.i(TAG, "悬浮窗已 detach")
            }
        })
        runCatching { manager.addView(view, params) }
            .onSuccess {
                Log.i(TAG, "悬浮窗 added: x=" + params.x + " y=" + params.y + " size=" + sizePx)
                // 挂窗之后再 setContent。真机实测：先 setContent 再 addView 存在「窗口加上了、
                // 画面一片空白、点击也穿透到桌面」的状态，改成窗口就位后再设置内容才稳定出图。
                view.post {
                    if (overlayView === view) setOverlayContent(view)
                }
                verifyLaidOut(view)
            }
            .onFailure {
                Log.e(TAG, "添加悬浮窗失败", it)
                stopSelf()
            }
    }

    /**
     * 挂载后自检布局结果。
     *
     * 真机上出现过 addView 成功、窗口也在，但 Compose 视图宽度一直是 0、画面上什么都没有、
     * 点击也穿透到桌面（悬浮窗的输入遮挡按像素不透明度计算，空白窗口等于不存在）。
     * 这种情况重挂一次通常就好，所以这里做一次延迟复检；只重试一次，避免布局持续失败时反复重建。
     */
    private fun verifyLaidOut(view: ComposeView) {
        view.postDelayed({
            if (overlayView !== view) return@postDelayed
            if (view.width > 0 && view.height > 0) {
                Log.i(TAG, "悬浮窗布局正常：" + view.width + "x" + view.height)
                return@postDelayed
            }
            Log.w(TAG, "悬浮窗布局异常（宽高为 0），重挂一次")
            runCatching { windowManager?.removeView(view) }
            overlayView = null
            attachOverlay()
        }, 700)
    }

    /** 悬浮球/扇区菜单的界面内容。窗口就位后才调用，原因见 addView 处的注释。 */
    private fun setOverlayContent(view: ComposeView) {
        view.setContent {
            val mode = ThemeMode.fromRaw(themeRaw.value)
            // 菜单模型只建一次：每次重组都新建会让 remember 的 key 一直变，
            // 白白丢掉缓存下来的当前层级计算结果。
            val menuModel = remember { RadialMenuCatalog.model() }
            DayCueTheme(darkTheme = mode.resolveDark()) {
                if (expanded.value) {
                    RadialMenuContent(
                        model = menuModel,
                        anchor = ballCenter.value,
                        onAction = { action -> perform(action) },
                        onDismiss = { collapse() },
                    )
                } else {
                    FloatingBallContent(
                        onTap = {
                            Log.i(TAG, "悬浮球收到点击，准备展开")
                            expand()
                        },
                        onDrag = { dx, dy -> moveBy(dx, dy) },
                        // 松手后吸边：球被拖到屏幕中间时会一直挡内容，吸到左右边缘才符合"挂件"的直觉
                        onDragEnd = { snapToEdge() },
                    )
                }
            }
        }
    }

    /** 拖动：按增量移动窗口，并夹在屏幕内（拖出屏幕就再也点不到了）。 */
    private fun moveBy(dx: Float, dy: Float) {
        val manager = windowManager ?: return
        val params = layoutParams ?: return
        val view = overlayView ?: return
        val metrics = resources.displayMetrics
        val size = params.width
        params.x = (params.x + dx.toInt()).coerceIn(0, maxOf(0, metrics.widthPixels - size))
        params.y = (params.y + dy.toInt()).coerceIn(0, maxOf(0, metrics.heightPixels - size))
        ballCenter.value = Offset(params.x + size / 2f, params.y + size / 2f)
        runCatching { manager.updateViewLayout(view, params) }
    }

    /** 悬浮窗边长（px）。窗口比可见球大一圈，见 BallWindowSize 的注释。 */
    private fun windowSizePx(): Int =
        (BallWindowSize.value * resources.displayMetrics.density).toInt()

    /**
     * 松手后吸附到最近的左右边缘。
     *
     * 为什么必须要：球被拖到屏幕中间后会一直挡在内容上，用户下次还得再拖一次；
     * 吸附到边框后既让出内容区域，又固定在拇指好够的位置。
     * 纵向不吸附，只夹进可见范围——纵向吸附会违背用户「放到这个高度」的意图。
     */
    private fun snapToEdge() {
        val manager = windowManager ?: return
        val params = layoutParams ?: return
        val view = overlayView ?: return
        if (expanded.value) return
        val metrics = resources.displayMetrics
        val size = params.width
        val margin = dp(EDGE_MARGIN_DP)
        val left = margin
        val right = maxOf(left, metrics.widthPixels - size - margin)
        val targetX = if (params.x + size / 2 < metrics.widthPixels / 2) left else right
        val targetY = params.y.coerceIn(margin, maxOf(margin, metrics.heightPixels - size - margin))
        animateTo(targetX, targetY)
    }

    /** 把窗口平滑移动到目标位置；拖动期间再次吸边会打断上一次动画，不会两个动画抢着改坐标。 */
    private fun animateTo(targetX: Int, targetY: Int) {
        val manager = windowManager ?: return
        val params = layoutParams ?: return
        val view = overlayView ?: return
        snapAnimator?.cancel()
        val startX = params.x
        val startY = params.y
        if (startX == targetX && startY == targetY) {
            ballCenter.value = Offset(params.x + params.width / 2f, params.y + params.height / 2f)
            return
        }
        val size = params.width
        snapAnimator = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = SNAP_DURATION_MS
            interpolator = DecelerateInterpolator()
            addUpdateListener { animator ->
                val t = animator.animatedValue as Float
                params.x = (startX + (targetX - startX) * t).toInt()
                params.y = (startY + (targetY - startY) * t).toInt()
                ballCenter.value = Offset(params.x + size / 2f, params.y + size / 2f)
                runCatching { manager.updateViewLayout(view, params) }
            }
            start()
        }
    }

    /** 展开：窗口变成全屏，菜单围绕球心绘制，点击空白处可以关闭。 */
    private fun expand() {
        val manager = windowManager ?: return
        val params = layoutParams ?: return
        val view = overlayView ?: return
        if (expanded.value) return
        snapAnimator?.cancel()
        refreshTheme()

        // 把球挪到「整个扇环都能放下」的位置，再展开。
        //
        // 为什么不直接在绘制时把环心往内夹：那样球和菜单会错开（球在屏幕边、菜单在中间），
        // 手指停在球上会被算成「选中某个扇区」——这是真机上实测到的误操作。
        // 改成先把球挪进去，环心就永远等于球心，视觉与手指始终一致。
        val metrics = resources.displayMetrics
        val outerPx = (dp(RING_OUTER_RADIUS_DP) + dp(8)).toFloat()
        val size = params.width
        val centerX = params.x + size / 2f
        val centerY = params.y + size / 2f
        val maxX = maxOf(outerPx, metrics.widthPixels - outerPx)
        val maxY = maxOf(outerPx, metrics.heightPixels - outerPx)
        val targetX = centerX.coerceIn(outerPx, maxX)
        val targetY = centerY.coerceIn(outerPx, maxY)
        if (targetX != centerX || targetY != centerY) {
            preExpandCenter = Offset(centerX, centerY)
            params.x = (targetX - size / 2f).toInt()
            params.y = (targetY - size / 2f).toInt()
            ballCenter.value = Offset(targetX, targetY)
            runCatching { manager.updateViewLayout(view, params) }
        }
        params.width = WindowManager.LayoutParams.MATCH_PARENT
        params.height = WindowManager.LayoutParams.MATCH_PARENT
        params.x = 0
        params.y = 0
        expanded.value = true
        runCatching { manager.updateViewLayout(view, params) }
            .onSuccess { Log.i(TAG, "已展开：全屏菜单窗口") }
            .onFailure { Log.w(TAG, "展开悬浮窗失败", it) }
    }

    /** 收起：窗口缩回球大小，位置回到展开前的球心，视觉上球「没动」。 */
    private fun collapse() {
        val manager = windowManager ?: return
        val params = layoutParams ?: return
        val view = overlayView ?: return
        if (!expanded.value) return
        expanded.value = false
        val size = windowSizePx()
        val metrics = resources.displayMetrics
        // 展开时为了放下整圈扇环把球挪进来过，收起时要放回原位，
        // 否则用户点一次球，球就永久往屏幕中间缩了一截。
        val center = preExpandCenter ?: ballCenter.value
        preExpandCenter = null
        ballCenter.value = center
        params.width = size
        params.height = size
        params.x = (center.x - size / 2f).toInt().coerceIn(0, maxOf(0, metrics.widthPixels - size))
        params.y = (center.y - size / 2f).toInt().coerceIn(0, maxOf(0, metrics.heightPixels - size))
        runCatching { manager.updateViewLayout(view, params) }
            .onFailure { Log.w(TAG, "收起悬浮窗失败", it) }
    }

    /** 执行扇区动作：先收起菜单，再打开 App 到对应页面。 */
    private fun perform(action: RadialAction) {
        collapse()
        val route = when (action) {
            is RadialAction.OpenCapture -> DayCueRoutes.capture(action.intent)
            is RadialAction.Navigate -> action.route
            RadialAction.OpenApp -> DayCueRoutes.TODAY
        }
        Log.i(TAG, "悬浮球动作 -> " + route)
        OverlayController.openApp(this, route)
    }

    /**
     * 读取外观偏好。
     *
     * 只读一次、展开时再读：悬浮球覆盖在别人的界面上，主题跟 App 内设置走才不会出现
     * 「App 是深色、悬浮球是浅色」的割裂。读不到就用系统深色状态兜底。
     */
    private fun refreshTheme() {
        val dependencies = platformDependenciesOrNull() ?: return
        scope.launch {
            runCatching { dependencies.settingsRepository.themeMode() }
                .onSuccess { themeRaw.value = it }
                .onFailure { Log.w(TAG, "读取外观偏好失败，按系统深色处理", it) }
        }
    }

    // ---- 通知 ----

    private fun buildNotification(): Notification {
        val open = PendingIntent.getActivity(
            this,
            0,
            OverlayController.appIntent(this),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val stop = PendingIntent.getService(
            this,
            1,
            Intent(this, FloatingBallService::class.java).setAction(OverlayController.ACTION_STOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Builder(this, NotificationChannels.ASSISTANT)
            .setSmallIcon(R.drawable.ic_launcher_foreground)
            .setContentTitle(getString(R.string.overlay_notify_title))
            .setContentText(getString(R.string.overlay_notify_text))
            .setOngoing(true)
            .setSilent(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setContentIntent(open)
            .addAction(0, getString(R.string.overlay_notify_stop), stop)
            .build()
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()

    companion object {
        private const val NOTIFICATION_ID = 4310

        /**
         * 是否真的有窗口挂在外面。
         *
         * 用静态标记而不是查询系统：没有公开 API 能查「我这进程的悬浮球在不在」。
         * 每次 onStartCommand 拉起时系统会复用同一个实例，标记因此是准的。
         */
        @Volatile
        var isRunning: Boolean = false
            private set
    }
}

/**
 * 给 ComposeView 用的最小 LifecycleOwner。
 *
 * Service 不是 LifecycleOwner，而 ComposeView 在 attach 时找不到 ViewTreeLifecycleOwner 会直接抛异常。
 * 这里只需要 CREATED→RESUMED→DESTROYED 这条最简单的状态变化，不需要 SavedStateRegistry——
 * 悬浮球里的界面状态（当前展开到第几级菜单）本来就不该跨进程恢复。
 */
private class OverlayLifecycleOwner : LifecycleOwner, SavedStateRegistryOwner {
    private val registry = LifecycleRegistry(this)

    // 悬浮球里没有需要跨进程恢复的状态，但 ComposeView 在 attach 时会检查这个 owner 是否存在，
    // 所以必须提供一个真实的 SavedStateRegistry（传 null 恢复即可），不能用空实现糊弄。
    private val savedStateController = SavedStateRegistryController.create(this)

    override val lifecycle: Lifecycle get() = registry

    override val savedStateRegistry: SavedStateRegistry get() = savedStateController.savedStateRegistry

    fun onCreate() {
        savedStateController.performRestore(null)
        registry.currentState = Lifecycle.State.CREATED
        registry.currentState = Lifecycle.State.RESUMED
    }

    fun onDestroy() {
        registry.currentState = Lifecycle.State.DESTROYED
    }
}
