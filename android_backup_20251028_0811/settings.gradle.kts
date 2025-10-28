pluginManagement {
    // 讓 Flutter 的 Gradle 外掛可被解析
    val flutterSdk: String = run {
        val lp = File(rootDir, "local.properties")
        val fromLocal = if (lp.exists()) {
            lp.readLines().firstOrNull { it.trim().startsWith("flutter.sdk=") }
                ?.substringAfter("=")?.trim()
        } else null
        fromLocal ?: System.getenv("FLUTTER_SDK")
        ?: error("請在 android/local.properties 設定：flutter.sdk=<Flutter SDK 路徑> 或設環境變數 FLUTTER_SDK")
    }
    includeBuild("$flutterSdk/packages/flutter_tools/gradle")

    repositories {
        gradlePluginPortal()
        google()
        mavenCentral()
    }

    // 只需要宣告 Flutter 的 loader 版本
    plugins {
        id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    }
}

rootProject.name = "case100_engeneering_version_v1"
include(":app")