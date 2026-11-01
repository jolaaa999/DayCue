package com.daycue.android.domain.radial

/**
 * 扇区被选中后要执行的动作。
 *
 * 刻意只描述「意图」，不引用 Intent / Context：菜单结构因此可以在 JVM 单测里完整验证，
 * 而「意图怎么变成一次导航」留在平台层。
 */
sealed interface RadialAction {
    /** 打开记录页并预设输入方式（voice / text / image）。 */
    data class OpenCapture(val intent: String) : RadialAction

    /** 直接跳到某条路由。 */
    data class Navigate(val route: String) : RadialAction

    /** 打开 App 的今天页。 */
    data object OpenApp : RadialAction
}

/**
 * 一个扇区。
 *
 * [children] 非空时表示它是「下一级菜单」而不是动作扇区：此时 [action] 必须为空。
 * 这条约束在 init 里强制，避免出现「既有子级又有动作」时到底该执行哪个的歧义。
 */
data class RadialItem(
    val id: String,
    val label: String,
    val action: RadialAction? = null,
    val children: List<RadialItem> = emptyList(),
) {
    init {
        require(children.isEmpty() || action == null) {
            "扇区 " + id + " 同时声明了子级与动作，语义冲突"
        }
        require(children.isEmpty() || children.size >= 2) {
            "扇区 " + id + " 的子级少于 2 个：只有一项的下级菜单是在浪费一次点击"
        }
    }

    val hasChildren: Boolean get() = children.isNotEmpty()
}

/** 一层菜单 = 一组扇区。 */
data class RadialRing(val title: String, val items: List<RadialItem>) {
    init {
        require(items.isNotEmpty()) { "菜单层不能为空：" + title }
    }
}

/** 选中一个扇区之后发生的事。 */
sealed interface RadialSelection {
    /** 进入下一级，新的路径是 [path]（各级下标）。 */
    data class DrillDown(val path: List<Int>) : RadialSelection

    /** 抵达动作扇区，执行 [action]。 */
    data class Commit(val action: RadialAction) : RadialSelection

    /** 无效下标（界面状态与模型不同步时），什么都不做。 */
    data object Ignored : RadialSelection
}

/**
 * 环形多级扇区菜单的导航模型。
 *
 * 用「下标路径」而不是持有节点引用来表示当前位置：
 * 路径是不可变值，重组、进程重建、单测都能照样还原到同一层。
 */
class RadialMenuModel(private val root: RadialRing) {

    fun rootRing(): RadialRing = root

    /** 按路径取当前这一层。路径失效时停在最后一个能到达的层级，不抛异常。 */
    fun ring(path: List<Int>): RadialRing {
        var current = root
        for (index in path) {
            val item = current.items.getOrNull(index) ?: return current
            if (!item.hasChildren) return current
            current = RadialRing(item.label, item.children)
        }
        return current
    }

    /** 深度：0 表示还没进任何子级。 */
    fun depth(path: List<Int>): Int = path.size

    /** 选中当前层的第 [index] 个扇区。 */
    fun select(path: List<Int>, index: Int): RadialSelection {
        val current = ring(path)
        val item = current.items.getOrNull(index) ?: return RadialSelection.Ignored
        if (item.hasChildren) return RadialSelection.DrillDown(path + index)
        val action = item.action ?: return RadialSelection.Ignored
        return RadialSelection.Commit(action)
    }

    /** 返回上一级；已经在根层时返回空路径（调用方据此关闭菜单）。 */
    fun back(path: List<Int>): List<Int> = if (path.isEmpty()) emptyList() else path.dropLast(1)
}
