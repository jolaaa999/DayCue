package com.daycue.android.ui.place

import com.daycue.android.platform.location.GeoPoint

/**
 * 界面侧读「当前位置」的唯一入口。
 *
 * 为什么做成接口而不是让 ViewModel 直接调 LocationManager：
 * 「没有用户提供的位置就不允许保存」是本功能最重要的一条约束，
 * 而它的回归测试只有在这一步可替换时才能在 JVM 上真实跑起来（设备上没有定位也能断言「保存被拒绝」）。
 */
fun interface LocationPicker {

    /**
     * 读一次系统最近一次已知定位。
     *
     * 返回 null 表示**读不到**（没有权限、系统定位关闭、没有任何 provider 给过位置），
     * 绝不返回 (0,0) 之类的哨兵值：那个坐标在几内亚湾，用它当「用户的点」比失败更糟。
     */
    suspend fun currentPoint(): GeoPoint?
}
