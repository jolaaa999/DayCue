plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
    alias(libs.plugins.ksp)
}

android {
    namespace = "com.daycue.android"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.daycue.android"
        // minSdk 26：java.time 从 API 26 起进系统库，领域层可以放心用 ZonedDateTime，
        // 不必引入 desugaring。这也与设计文档「提议 API 26 起」一致。
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
    }

    packaging {
        resources.excludes += "/META-INF/{AL2.0,LGPL2.1}"
    }

    testOptions {
        unitTests {
            // 领域层单测不应该碰 android.*，这里只是给 Log 之类的兜底，
            // 避免「未实现的方法抛异常」把纯逻辑测试一起带崩。
            isReturnDefaultValues = true
        }
    }

    sourceSets {
        // 把 KSP 导出的 schema 挂进 androidTest 的 assets。
        // 为什么必须挂：MigrationTestHelper 是在设备上通过 Instrumentation 的 assets 去读
        // 「上一版的建表快照」，目录不在 assets 里就只会在真机上抛 FileNotFoundException，
        // 本地编译期完全看不出来；挂上之后迁移测试才真的能验到 MIGRATION_1_2。
        getByName("androidTest").assets.srcDir("$projectDir/schemas")
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

ksp {
    // Room 的 schema 导出：MIGRATION 写错时，Room 会在构建期比对导出文件并直接失败。
    // 首次构建会生成 app/schemas/，该目录应当入库（当前仓库里还没有，因为本机没有 SDK）。
    arg("room.schemaLocation", projectDir.path + "/schemas")
}

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.activity.compose)

    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.graphics)
    implementation(libs.androidx.compose.ui.tooling.preview)
    implementation(libs.androidx.compose.material3)
    implementation(libs.androidx.navigation.compose)

    implementation(libs.androidx.room.runtime)
    implementation(libs.androidx.room.ktx)
    ksp(libs.androidx.room.compiler)

    implementation(libs.androidx.work.runtime.ktx)

    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.kotlinx.serialization.json)

    // HTTP：只用 OkHttp 做传输，它不依赖 GMS，也没有「无 Google 服务就不能用」的问题。
    implementation(libs.okhttp)

    // 定位：刻意不引入 com.google.android.gms:play-services-location。
    // 无 GMS 设备上它会直接抛异常，而本项目要求「没有定位能力时明确降级」。
    // 系统 LocationManager 在所有设备上都有，所以默认实现走它；
    // 确实需要 GMS FusedLocationProvider 的分支再自行放开下面这行（版本号已在 version catalog 里）：
    // implementation(libs.play.services.location)

    debugImplementation(libs.androidx.compose.ui.tooling)

    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)

    // DAO 测试需要真实 SQLite（Room 的内存库跑不了纯 JVM 单测），所以放在 androidTest 里。
    androidTestImplementation(libs.androidx.test.junit)
    androidTestImplementation(libs.androidx.room.testing)
    androidTestImplementation(libs.kotlinx.coroutines.test)
    androidTestImplementation(platform(libs.androidx.compose.bom))
    androidTestImplementation(libs.androidx.espresso.core)
}
