package com.daycue.android.ui

import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import com.daycue.android.ui.capture.CaptureScreen
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
import com.daycue.android.ui.settings.SettingsScreen
import com.daycue.android.ui.task.TaskListScreen
import com.daycue.android.ui.theme.DayCueTheme
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

    const val CAPTURE = "capture"
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

    fun noteDetail(noteId: String): String = "note/" + noteId

    fun courseEdit(courseId: String): String = "course/" + courseId

    fun placeEdit(placeId: String?): String = "place/" + (placeId ?: ID_NEW)

    fun ruleEdit(placeId: String, ruleId: String?): String =
        "place/" + placeId + "/rule/" + (ruleId ?: ID_NEW)
}

/** 底栏入口。mark 用单个汉字代替图标：少引一个 material-icons 依赖，也避免了图标语义不敢翻译的问题。 */
private data class BottomEntry(val route: String, val label: String, val mark: String)

private val BOTTOM_ENTRIES = listOf(
    BottomEntry(DayCueRoutes.TODAY, "今天", "今"),
    BottomEntry(DayCueRoutes.RECORDS, "记录", "记"),
    BottomEntry(DayCueRoutes.MEMORY, "记忆", "忆"),
    BottomEntry(DayCueRoutes.SETTINGS, "设置", "设"),
)

/**
 * 应用根界面：主题 + 导航 + 底栏。
 *
 * 底栏只出现在四个顶层入口上；课表、待办、追问、导入这些是「从今天页钻进去」的页面，
 * 它们带返回键而不是底栏，否则用户会以为底栏切换是「返回上一层」。
 */
@Composable
fun DayCueApp() {
    DayCueTheme {
        val navController = rememberNavController()
        val backStackEntry by navController.currentBackStackEntryAsState()
        val currentRoute = backStackEntry?.destination?.route

        Scaffold(
            bottomBar = {
                if (BOTTOM_ENTRIES.any { it.route == currentRoute }) {
                    NavigationBar {
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
                                icon = { Text(entry.mark, style = MaterialTheme.typography.labelLarge) },
                                label = { Text(entry.label) },
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
                        onOpenCapture = { navController.navigate(DayCueRoutes.CAPTURE) },
                        onOpenNote = { noteId -> navController.navigate(DayCueRoutes.noteDetail(noteId)) },
                    )
                }

                composable(DayCueRoutes.RECORDS) {
                    NoteListScreen(
                        onOpenNote = { noteId -> navController.navigate(DayCueRoutes.noteDetail(noteId)) },
                        onNewCapture = { navController.navigate(DayCueRoutes.CAPTURE) },
                    )
                }

                composable(DayCueRoutes.MEMORY) {
                    MemoryScreen()
                }

                composable(DayCueRoutes.SETTINGS) {
                    SettingsScreen(
                        onOpenPlaces = { navController.navigate(DayCueRoutes.PLACE_LIST) },
                    )
                }

                composable(DayCueRoutes.CAPTURE) {
                    CaptureScreen(onBack = { navController.popBackStack() })
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
    }
}
