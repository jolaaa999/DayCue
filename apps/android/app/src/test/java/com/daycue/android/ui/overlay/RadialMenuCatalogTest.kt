package com.daycue.android.ui.overlay

import com.daycue.android.domain.radial.RadialAction
import com.daycue.android.domain.radial.RadialItem
import com.daycue.android.ui.DayCueRoutes
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 悬浮球菜单内容的静态约束测试。
 *
 * 这里检查的不是「点击后真的跳到了那一页」（那需要真机），而是三条能静态证明的契约：
 * 1) 每个叶子扇区都有动作，每个有子级的扇区都没有动作（不会出现点了没反应）；
 * 2) id 全局唯一（埋点与去重都靠它）；
 * 3) 动作指向的路由都是 App 里真实存在的路由，不写死未来才有的页面。
 */
class RadialMenuCatalogTest {

    private val root = RadialMenuCatalog.root()

    private fun walk(items: List<RadialItem>, visit: (RadialItem) -> Unit) {
        items.forEach { item ->
            visit(item)
            walk(item.children, visit)
        }
    }

    @Test
    fun `根层是五个扇区`() {
        assertEquals(5, root.items.size)
    }

    @Test
    fun `每个叶子都有动作且每个分支都没有动作`() {
        walk(root.items) { item ->
            if (item.hasChildren) {
                assertEquals("分支扇区不该有动作：" + item.id, null, item.action)
            } else {
                assertTrue("叶子扇区必须有动作：" + item.id, item.action != null)
            }
        }
    }

    @Test
    fun `扇区 id 全局唯一`() {
        val ids = mutableListOf<String>()
        walk(root.items) { ids.add(it.id) }
        assertEquals(ids.size, ids.toSet().size)
    }

    @Test
    fun `扇区标签不超过四个字`() {
        walk(root.items) { item ->
            assertTrue("标签太长，扇区里会折行：" + item.label, item.label.length <= 4)
        }
    }

    @Test
    fun `跳转路由都是已存在的页面`() {
        val allowed = setOf(
            DayCueRoutes.TODAY,
            DayCueRoutes.TASKS,
            DayCueRoutes.SCHEDULE,
            DayCueRoutes.ICS_IMPORT,
            DayCueRoutes.MEMORY,
            DayCueRoutes.RECORDS,
        )
        walk(root.items) { item ->
            when (val action = item.action) {
                is RadialAction.Navigate -> {
                    val known = action.route in allowed || action.route == DayCueRoutes.courseEdit(DayCueRoutes.COURSE_ID_NEW)
                    assertTrue("路由不存在：" + action.route, known)
                }
                is RadialAction.OpenCapture -> {
                    val intents = setOf(
                        DayCueRoutes.CAPTURE_INTENT_TEXT,
                        DayCueRoutes.CAPTURE_INTENT_VOICE,
                        DayCueRoutes.CAPTURE_INTENT_IMAGE,
                    )
                    assertTrue("未知的输入方式：" + action.intent, action.intent in intents)
                }
                RadialAction.OpenApp, null -> Unit
            }
        }
    }
}
