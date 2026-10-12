// 根构建脚本：只声明插件版本，具体配置在 app/build.gradle.kts。
// 插件一律 apply false，避免根工程自己也被当成 Android 模块。
plugins {
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.kotlin.android) apply false
    alias(libs.plugins.kotlin.compose) apply false
    alias(libs.plugins.kotlin.serialization) apply false
    alias(libs.plugins.ksp) apply false
}
