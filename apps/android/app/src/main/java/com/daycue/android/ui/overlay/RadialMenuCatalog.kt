package com.daycue.android.ui.overlay

import com.daycue.android.domain.radial.RadialAction
import com.daycue.android.domain.radial.RadialItem
import com.daycue.android.domain.radial.RadialMenuModel
import com.daycue.android.domain.radial.RadialRing
import com.daycue.android.ui.DayCueRoutes

/**
 * 悬浮球扇区菜单的实际内容。
 *
 * 放在 ui 层而不是 domain 层，是因为它需要 [DayCueRoutes] 里的路由常量；
 * domain 层的 [RadialMenuModel] 因此保持与 Android/路由无关，能被 JVM 单测直接覆盖。
 *
 * 一条硬规则：**菜单里只出现已经存在的页面**。
 * 不为了「看起来完整」放一个还没实现的入口——用户点进去发现是空壳，比没有这个入口更糟。
 * 语音对话入口要等指令链路（阶段 3）真正落地之后再加进来。
 */
object RadialMenuCatalog {

    fun model(): RadialMenuModel = RadialMenuModel(root())

    fun root(): RadialRing = RadialRing(
        title = "要做什么",
        items = listOf(
            RadialItem(
                id = "capture",
                label = "记录",
                children = listOf(
                    RadialItem(
                        id = "capture_text",
                        label = "文字",
                        action = RadialAction.OpenCapture(DayCueRoutes.CAPTURE_INTENT_TEXT),
                    ),
                    RadialItem(
                        id = "capture_voice",
                        label = "语音",
                        action = RadialAction.OpenCapture(DayCueRoutes.CAPTURE_INTENT_VOICE),
                    ),
                    RadialItem(
                        id = "capture_image",
                        label = "拍照",
                        action = RadialAction.OpenCapture(DayCueRoutes.CAPTURE_INTENT_IMAGE),
                    ),
                ),
            ),
            RadialItem(
                id = "task",
                label = "待办",
                children = listOf(
                    RadialItem(id = "task_list", label = "待办", action = RadialAction.Navigate(DayCueRoutes.TASKS)),
                    RadialItem(id = "today", label = "今天", action = RadialAction.Navigate(DayCueRoutes.TODAY)),
                ),
            ),
            RadialItem(
                id = "schedule",
                label = "课表",
                children = listOf(
                    RadialItem(
                        id = "schedule_week",
                        label = "本周",
                        action = RadialAction.Navigate(DayCueRoutes.SCHEDULE),
                    ),
                    RadialItem(
                        id = "schedule_import",
                        label = "导入",
                        action = RadialAction.Navigate(DayCueRoutes.ICS_IMPORT),
                    ),
                    RadialItem(
                        id = "schedule_new",
                        label = "新课程",
                        action = RadialAction.Navigate(DayCueRoutes.courseEdit(DayCueRoutes.COURSE_ID_NEW)),
                    ),
                ),
            ),
            RadialItem(
                id = "memory",
                label = "记忆",
                children = listOf(
                    RadialItem(id = "memory_list", label = "记忆", action = RadialAction.Navigate(DayCueRoutes.MEMORY)),
                    RadialItem(id = "records", label = "记录", action = RadialAction.Navigate(DayCueRoutes.RECORDS)),
                ),
            ),
            RadialItem(id = "app", label = "打开", action = RadialAction.OpenApp),
        ),
    )
}
