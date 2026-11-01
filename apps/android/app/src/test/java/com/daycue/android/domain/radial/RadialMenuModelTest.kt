package com.daycue.android.domain.radial

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 环形多级菜单的导航模型测试。
 *
 * 覆盖三类容易被忽略的行为：子级与动作互斥、无效下标不崩、路径失效时停在能到达的层级
 * （界面状态与模型不同步在真实设备上一定会发生，例如返回键把路径清空之后又收到了一个拖拽松手事件）。
 */
class RadialMenuModelTest {

    private val capture = RadialItem("capture", "记录", children = listOf(
        RadialItem("text", "文字", RadialAction.OpenCapture("text")),
        RadialItem("voice", "语音", RadialAction.OpenCapture("voice")),
    ))

    private val openApp = RadialItem("app", "打开", action = RadialAction.OpenApp)

    private val model = RadialMenuModel(RadialRing("根", listOf(capture, openApp)))

    @Test
    fun `根层有两个扇区`() {
        assertEquals(2, model.rootRing().items.size)
        assertEquals(2, model.ring(emptyList()).items.size)
        assertEquals(0, model.depth(emptyList()))
    }

    @Test
    fun `选中有子级的扇区进入下一级`() {
        val selection = model.select(emptyList(), 0)
        assertEquals(RadialSelection.DrillDown(listOf(0)), selection)
        val child = model.ring(listOf(0))
        assertEquals("记录", child.title)
        assertEquals(2, child.items.size)
        assertEquals(1, model.depth(listOf(0)))
    }

    @Test
    fun `选中动作扇区产生 Commit`() {
        assertEquals(RadialSelection.Commit(RadialAction.OpenApp), model.select(emptyList(), 1))
        assertEquals(
            RadialSelection.Commit(RadialAction.OpenCapture("voice")),
            model.select(listOf(0), 1),
        )
    }

    @Test
    fun `下标越界返回 Ignored 而不抛异常`() {
        assertEquals(RadialSelection.Ignored, model.select(emptyList(), 99))
        assertEquals(RadialSelection.Ignored, model.select(emptyList(), -1))
        assertEquals(RadialSelection.Ignored, model.select(listOf(0), 5))
    }

    @Test
    fun `路径失效时停在能到达的层级`() {
        // 路径指向一个叶子扇区之后再往下一级取值，不应该崩，也不应该返回空环
        val ring = model.ring(listOf(1, 0))
        assertEquals("根", ring.title)
        assertTrue(ring.items.isNotEmpty())
    }

    @Test
    fun `back 逐级回退且根层回退结果是空路径`() {
        assertEquals(listOf(0), model.back(listOf(0, 1)))
        assertEquals(emptyList<Int>(), model.back(listOf(0)))
        assertEquals(emptyList<Int>(), model.back(emptyList()))
    }

    @Test
    fun `同时声明子级与动作的扇区会被拒绝`() {
        val error = runCatching {
            RadialItem("bad", "坏", action = RadialAction.OpenApp, children = listOf(openApp, capture))
        }.exceptionOrNull()
        assertTrue("应以 IllegalArgumentException 失败，实际：" + error, error is IllegalArgumentException)
    }

    @Test
    fun `只有一个子级的扇区会被拒绝`() {
        val error = runCatching {
            RadialItem("single", "单项", children = listOf(openApp))
        }.exceptionOrNull()
        assertTrue("应以 IllegalArgumentException 失败，实际：" + error, error is IllegalArgumentException)
    }

    @Test
    fun `空菜单层会被拒绝`() {
        val error = runCatching { RadialRing("空", emptyList()) }.exceptionOrNull()
        assertTrue("应以 IllegalArgumentException 失败，实际：" + error, error is IllegalArgumentException)
    }
}
