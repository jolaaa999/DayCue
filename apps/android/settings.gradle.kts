// Gradle 设置：全部版本号集中在 gradle/libs.versions.toml，本文件不做版本声明。
pluginManagement {
    repositories {
        // 顺序有意为之：Android 插件只在 google() 里发布，先查它可以少走一次网络往返。
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    // 禁止在模块里再声明仓库，避免「同一个依赖来自两个仓库」这种难以复现的问题。
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "DayCueAndroid"
include(":app")
