package com.daycue.android

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import com.daycue.android.ui.DayCueApp
import com.daycue.android.ui.theme.DayCueTheme

/**
 * 唯一的 Activity。
 *
 * 刻意不做多 Activity：状态与返回栈全部交给 Navigation Compose，
 * 这样「记录 -> 详情 -> 返回」的逻辑与 iOS 端的 NavigationStack 是一一对应的。
 * Intent 里的数据（分享进来的文字、图片）也在这里解析后交给界面层。
 */
class MainActivity : ComponentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // targetSdk 35 起系统强制边到边，主动开启才能拿到 insets 并自己处理，而不是被系统裁切。
        enableEdgeToEdge()
        setContent {
            DayCueTheme {
                DayCueApp()
            }
        }
    }
}
