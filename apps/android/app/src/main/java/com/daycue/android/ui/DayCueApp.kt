package com.daycue.android.ui

import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.DateRange
import androidx.compose.material.icons.outlined.List
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import android.util.Log
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.dp
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import com.daycue.android.ui.capture.CaptureScreen
import com.daycue.android.ui.common.DayCueIcons
import com.daycue.android.ui.followup.FollowUpScreen
import com.daycue.android.ui.memory.MemoryScreen
import com.daycue.android.ui.note.NoteDetailScreen
import com.daycue.android.ui.note.NoteListScreen
import com.daycue.android.ui.place.PlaceEditScreen
import com.daycue.android.ui.place.PlaceListScreen
import com.daycue.android.ui.place.RuleEditScreen
import com.daycue.android.ui.schedule.CourseEditScreen
import com.daycue.android.ui.schedule.IcsImportScreen
import com.daycue.android.ui.schedule.ScheduleWeekScreen
import com.daycue.android.ui.settings.SettingsAccountScreen
import com.daycue.android.ui.settings.SettingsAdvancedScreen
import com.daycue.android.ui.settings.SettingsAppearanceScreen
import com.daycue.android.ui.settings.SettingsAssistantScreen
import com.daycue.android.ui.settings.SettingsDataScreen
import com.daycue.android.ui.settings.SettingsLocationScreen
import com.daycue.android.ui.settings.SettingsPermissionsScreen
import com.daycue.android.ui.settings.SettingsProactiveScreen
import com.daycue.android.ui.settings.SettingsScreen
import com.daycue.android.ui.settings.SettingsTermScreen
import com.daycue.android.ui.task.TaskListScreen
import com.daycue.android.ui.theme.DayCueTheme
import com.daycue.android.ui.theme.ThemeMode
import com.daycue.android.ui.theme.resolveDark
import com.daycue.android.ui.today.TodayScreen

/**
 * 路由常量集中在本文件。
 *
 * 为什么：路由字符串一旦散落到各页面的 navigate("...") 里，
 * 改一个 path 必然会漏改一处，而漏掉的那处只在运行时才报错。
 */
object DayCueRoutes {
    const val TODAY = "today"
    const val RECORDS = "records"
    const val MEMORY = "memory"
    const val SETTINGS = "settings"

    // 设置从「一页塞满」拆成「分组首页 + 二级页」，二级页各自是一条路由。
    const val SETTINGS_ACCOUNT = "settings/account"
    const val SETTINGS_PROACTIVE = "settings/proactive"
    const val SETTINGS_LOCATION = "settings/location"
    const val SETTINGS_TERM = "settings/term"
    const val SETTINGS_PERMISSIONS = "settings/permissions"
    const val SETTINGS_APPEARANCE = "settings/appearance"
    const val SETTINGS_DATA = "settings/data"
    const val SETTINGS_ADVANCED = "settings/advanced"

    /** 桌面悬浮球与（后续的）语音唤醒设置。 */
    const val SETTINGS_ASSISTANT = "settings/assistant"

    /**
     * 记录页带一个 intent 参数，用来表达「用户点的是哪一个入口」。
     *
     * 为什么不做三个独立页面：捕获流程（先落库、再转写/解析、失败保留内容）只有一份，
     * 复用它才不会有三条各自演化的分支；参数只决定进入后先摆出哪种输入。
     */
    const val CAPTURE = "capture?intent={intent}"
    const val CAPTURE_INTENT_VOICE = "voice"
    const val CAPTURE_INTENT_TEXT = "text"
    const val CAPTURE_INTENT_IMAGE = "image"

    const val TASKS = "tasks"
    const val SCHEDULE = "schedule"
    const val FOLLOW_UP = "followup"
    const val ICS_IMPORT = "schedule/ics"

    const val NOTE_DETAIL = "note/{noteId}"
    const val COURSE_EDIT = "course/{courseId}"
    const val PLACE_LIST = "places"
    const val PLACE_EDIT = "place/{placeId}"
    const val RULE_EDIT = "place/{placeId}/rule/{ruleId}"

    /** 新建课程复用同一条路由；用它而不是空串，是为了让 route 匹配与日志都还能读。 */
    const val COURSE_ID_NEW = "__new__"

    /**
     * 新建地点 / 新建规则也复用同一条路由。
     *
     * 用 "__new__" 而不是直接拼空串：NavController 的 route 匹配把空段当成分隔符，
     * "place//rule/" 这类路径既难读又容易匹配到别的路由。
     */
    const val ID_NEW = "__new__"

    fun capture(intent: String = ""): String =
        if (intent.isBlank()) "capture" else "capture?intent=" + intent

    fun noteDetail(noteId: String): String = "note/" + noteId

    fun courseEdit(courseId: String): String = "course/" + courseId

    fun placeEdit(placeId: String?): String = "place/" + (placeId ?: ID_NEW)

    fun ruleEdit(placeId: String, ruleId: String?): String =
        "place/" + placeId + "/rule/" + (ruleId ?: ID_NEW)
}

/** 底栏入口。图标统一用线性（Outlined）风格，不再用单个汉字代替图标。 */
private data class BottomEntry(val route: String, val label: String, val icon: ImageVector)

private val BOTTOM_ENTRIES = listOf(
    BottomEntry(DayCueRoutes.TODAY, "今天", Icons.Outlined.DateRange),
    BottomEntry(DayCueRoutes.RECORDS, "记录", Icons.Outlined.List),
    BottomEntry(DayCueRoutes.MEMORY, "记忆", DayCueIcons.Bookmark),
    BottomEntry(DayCueRoutes.SETTINGS, "设置", Icons.Outlined.Settings),
)

/**
 * 应用根界面：外观偏好 + 主题 + 导航 + 底栏。
 *
 * 外观偏好从设置仓储读，而不是直接读系统深色开关：用户在「设置 → 外观」里
 * 固定成浅色之后，App 就不该再跟着系统跳。读取是流式的，切主题不需要重启。
 */
@Composable
fun DayCueApp(
    /**
     * 外部（目前只有悬浮球）请求落到哪一页。null 表示没有待处理请求。
     *
     * 用 Flow 而不是构造参数里的字符串：Activity 可能已经在运行，
     * 后续请求要靠 onNewIntent 再次推过来，字符串参数接不住第二次。
     */
    pendingRoute: StateFlow<String?>? = null,
    onRouteConsumed: () -> Unit = {},
) {
    val container = rememberContainer()
    val rawMode by container.settingsRepository.observeThemeMode().collectAsState(initial = null)
    val mode = ThemeMode.fromRaw(rawMode)

    DayCueTheme(darkTheme = mode.resolveDark()) {
        val navController = rememberNavController()
        val backStackEntry by navController.currentBackStackEntryAsState()
        val currentRoute = backStackEntry?.destination?.route

        Scaffold(
            containerColor = MaterialTheme.colorScheme.background,
            bottomBar = {
                if (BOTTOM_ENTRIES.any { it.route == currentRoute }) {
                    NavigationBar(
                        containerColor = MaterialTheme.colorScheme.surface,
                        tonalElevation = 0.dp,
                    ) {
                        BOTTOM_ENTRIES.forEach { entry ->
                            NavigationBarItem(
                                selected = currentRoute == entry.route,
                                onClick = {
                                    if (currentRoute != entry.route) {
                                        navController.navigate(entry.route) {
                                            // 顶层入口之间不回退栈，避免「今天 → 记忆 → 记录」无限堆叠。
                                            popUpTo(navController.graph.findStartDestination().id) {
                                                saveState = true
                                            }
                                            launchSingleTop = true
                                            restoreState = true
                                        }
                                    }
                                },
                                icon = {
                                    Icon(
                                        imageVector = entry.icon,
                                        contentDescription = null,
                                        modifier = Modifier.padding(0.dp),
                                    )
                                },
                                label = { Text(entry.label, style = MaterialTheme.typography.labelMedium) },
                                // 选中态用同一个青绿容器色：底栏选中色与页面主色是同一个来源，
                                // 不再出现「按钮浅紫、导航墨绿」这种两套品牌色。
                                colors = NavigationBarItemDefaults.colors(
                                    selectedIconColor = MaterialTheme.colorScheme.onPrimaryContainer,
                                    selectedTextColor = MaterialTheme.colorScheme.onSurface,
                                    indicatorColor = MaterialTheme.colorScheme.primaryContainer,
                                    unselectedIconColor = MaterialTheme.colorScheme.onSurfaceVariant,
                                    unselectedTextColor = MaterialTheme.colorScheme.onSurfaceVariant,
                                ),
                            )
                        }
                    }
                }
            },
        ) { padding ->
            NavHost(
                navController = navController,
                startDestination = DayCueRoutes.TODAY,
                modifier = Modifier.padding(padding),
            ) {
                composable(DayCueRoutes.TODAY) {
                    TodayScreen(
                        onOpenTasks = { navController.navigate(DayCueRoutes.TASKS) },
                        onOpenSchedule = { navController.navigate(DayCueRoutes.SCHEDULE) },
                        onOpenFollowUp = { navController.navigate(DayCueRoutes.FOLLOW_UP) },
                        onOpenCapture = { intent -> navController.navigate(DayCueRoutes.capture(intent)) },
                        onOpenRecords = { navController.navigate(DayCueRoutes.RECORDS) },
                        onOpenSettings = { navController.navigate(DayCueRoutes.SETTINGS) },
                        onOpenNote = { noteId -> navController.navigate(DayCueRoutes.noteDetail(noteId)) },
                    )
                }

                composable(DayCueRoutes.RECORDS) {
                    NoteListScreen(
                        onOpenNote = { noteId -> navController.navigate(DayCueRoutes.noteDetail(noteId)) },
                        onNewCapture = { intent -> navController.navigate(DayCueRoutes.capture(intent)) },
                    )
                }

                composable(DayCueRoutes.MEMORY) {
                    MemoryScreen(
                        onOpenCapture = { navController.navigate(DayCueRoutes.capture(DayCueRoutes.CAPTURE_INTENT_TEXT)) },
                    )
                }

                composable(DayCueRoutes.SETTINGS) {
                    SettingsScreen(
                        onOpenAccount = { navController.navigate(DayCueRoutes.SETTINGS_ACCOUNT) },
                        onOpenProactive = { navController.navigate(DayCueRoutes.SETTINGS_PROACTIVE) },
                        onOpenLocation = { navController.navigate(DayCueRoutes.SETTINGS_LOCATION) },
                        onOpenTerm = { navController.navigate(DayCueRoutes.SETTINGS_TERM) },
                        onOpenPermissions = { navController.navigate(DayCueRoutes.SETTINGS_PERMISSIONS) },
                        onOpenAppearance = { navController.navigate(DayCueRoutes.SETTINGS_APPEARANCE) },
                        onOpenData = { navController.navigate(DayCueRoutes.SETTINGS_DATA) },
                        onOpenAdvanced = { navController.navigate(DayCueRoutes.SETTINGS_ADVANCED) },
                        onOpenAssistant = { navController.navigate(DayCueRoutes.SETTINGS_ASSISTANT) },
                    )
                }

                composable(DayCueRoutes.SETTINGS_ACCOUNT) {
                    SettingsAccountScreen(
                        onBack = { navController.popBackStack() },
                        onOpenAdvanced = { navController.navigate(DayCueRoutes.SETTINGS_ADVANCED) },
                    )
                }

                composable(DayCueRoutes.SETTINGS_PROACTIVE) {
                    SettingsProactiveScreen(onBack = { navController.popBackStack() })
                }

                composable(DayCueRoutes.SETTINGS_LOCATION) {
                    SettingsLocationScreen(
                        onBack = { navController.popBackStack() },
                        onOpenPlaces = { navController.navigate(DayCueRoutes.PLACE_LIST) },
                    )
                }

                composable(DayCueRoutes.SETTINGS_TERM) {
                    SettingsTermScreen(
                        onBack = { navController.popBackStack() },
                        onOpenSchedule = { navController.navigate(DayCueRoutes.SCHEDULE) },
                        onImportIcs = { navController.navigate(DayCueRoutes.ICS_IMPORT) },
                    )
                }

                composable(DayCueRoutes.SETTINGS_PERMISSIONS) {
                    SettingsPermissionsScreen(onBack = { navController.popBackStack() })
                }

                composable(DayCueRoutes.SETTINGS_APPEARANCE) {
                    SettingsAppearanceScreen(onBack = { navController.popBackStack() })
                }

                composable(DayCueRoutes.SETTINGS_DATA) {
                    SettingsDataScreen(onBack = { navController.popBackStack() })
                }

                composable(DayCueRoutes.SETTINGS_ADVANCED) {
                    SettingsAdvancedScreen(onBack = { navController.popBackStack() })
                }

                composable(DayCueRoutes.SETTINGS_ASSISTANT) {
                    SettingsAssistantScreen(onBack = { navController.popBackStack() })
                }

                composable(
                    route = DayCueRoutes.CAPTURE,
                    arguments = listOf(
                        navArgument("intent") {
                            type = NavType.StringType
                            defaultValue = ""
                        },
                    ),
                ) { entry ->
                    CaptureScreen(
                        onBack = { navController.popBackStack() },
                        initialIntent = entry.arguments?.getString("intent").orEmpty(),
                        // 保存为笔记之后直接进那条笔记：省一次「回记录页再找」。
                        onOpenNote = { noteId -> navController.navigate(DayCueRoutes.noteDetail(noteId)) },
                    )
                }

                composable(DayCueRoutes.PLACE_LIST) {
                    PlaceListScreen(
                        onBack = { navController.popBackStack() },
                        onEditPlace = { placeId -> navController.navigate(DayCueRoutes.placeEdit(placeId)) },
                        onEditRule = { placeId, ruleId ->
                            navController.navigate(DayCueRoutes.ruleEdit(placeId, ruleId))
                        },
                    )
                }

                composable(
                    route = DayCueRoutes.PLACE_EDIT,
                    arguments = listOf(navArgument("placeId") { type = NavType.StringType }),
                ) { entry ->
                    val raw = entry.arguments?.getString("placeId").orEmpty()
                    PlaceEditScreen(
                        placeId = raw.takeIf { it.isNotEmpty() && it != DayCueRoutes.ID_NEW },
                        onBack = { navController.popBackStack() },
                        // 保存成功后回到列表：用户在这里刚改了围栏，下一步多半是加规则看结果。
                        onSaved = { navController.popBackStack() },
                    )
                }

                composable(
                    route = DayCueRoutes.RULE_EDIT,
                    arguments = listOf(
                        navArgument("placeId") { type = NavType.StringType },
                        navArgument("ruleId") { type = NavType.StringType },
                    ),
                ) { entry ->
                    val placeId = entry.arguments?.getString("placeId").orEmpty()
                    val rawRuleId = entry.arguments?.getString("ruleId").orEmpty()
                    RuleEditScreen(
                        placeId = placeId,
                        ruleId = rawRuleId.takeIf { it.isNotEmpty() && it != DayCueRoutes.ID_NEW },
                        onBack = { navController.popBackStack() },
                    )
                }

                composable(DayCueRoutes.TASKS) {
                    TaskListScreen(onBack = { navController.popBackStack() })
                }

                composable(DayCueRoutes.SCHEDULE) {
                    ScheduleWeekScreen(
                        onBack = { navController.popBackStack() },
                        onEditCourse = { courseId -> navController.navigate(DayCueRoutes.courseEdit(courseId)) },
                        onImportIcs = { navController.navigate(DayCueRoutes.ICS_IMPORT) },
                    )
                }

                composable(DayCueRoutes.ICS_IMPORT) {
                    IcsImportScreen(onBack = { navController.popBackStack() })
                }

                composable(
                    route = DayCueRoutes.COURSE_EDIT,
                    arguments = listOf(navArgument("courseId") { type = NavType.StringType }),
                ) { entry ->
                    CourseEditScreen(
                        courseId = entry.arguments?.getString("courseId").orEmpty(),
                        onBack = { navController.popBackStack() },
                    )
                }

                composable(
                    route = DayCueRoutes.NOTE_DETAIL,
                    arguments = listOf(navArgument("noteId") { type = NavType.StringType }),
                ) { entry ->
                    NoteDetailScreen(
                        noteId = entry.arguments?.getString("noteId").orEmpty(),
                        onBack = { navController.popBackStack() },
                    )
                }

                composable(DayCueRoutes.FOLLOW_UP) {
                    FollowUpScreen(
                        onBack = { navController.popBackStack() },
                        onOpenNote = { noteId -> navController.navigate(DayCueRoutes.noteDetail(noteId)) },
                    )
                }
            }
        }

        // 悬浮球等外部入口带进来的路由。
        // 放在 Scaffold 之后：此时 NavHost 已经完成组合，navigate 不会因为「导航图还没建好」抛异常。
        val requestedRoute by (pendingRoute ?: remember { MutableStateFlow<String?>(null) }).collectAsState()
        LaunchedEffect(requestedRoute) {
            val route = requestedRoute ?: return@LaunchedEffect
            runCatching { navController.navigate(route) }
                .onFailure { Log.w("DayCueApp", "外部路由跳转失败：" + route, it) }
            onRouteConsumed()
        }
    }
}
