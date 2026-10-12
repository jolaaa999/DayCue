package com.daycue.android.ui

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext
import com.daycue.android.AppContainer
import com.daycue.android.DayCueApplication

/**
 * 取依赖容器的唯一入口。
 *
 * 为什么每次都用 applicationContext 再取 container：Compose 会随配置变化重建 Activity，
 * 若把 Activity 的 Context 存进 ViewModel 就会泄漏；容器本来就挂在 Application 上，
 * 从这里取到的实例在所有页面与进程生命周期内都是同一个。
 */
@Composable
fun rememberContainer(): AppContainer {
    val context: Context = LocalContext.current
    return remember(context) {
        (context.applicationContext as DayCueApplication).container
    }
}
