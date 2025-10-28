import com.android.build.api.dsl.ApplicationExtension
import com.android.build.api.dsl.LibraryExtension

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}

subprojects {
    // Library 模組（包含所有 plugin 子專案，如 isar_flutter_libs）
    plugins.withId("com.android.library") {
        extensions.configure<LibraryExtension> {
            compileSdk = 36
            defaultConfig {
                minSdk = 24
                targetSdk = 35
            }
            // 只有在缺 namespace 的情況下補上（避免覆蓋別人）
            if (namespace.isNullOrEmpty() && project.group.toString() == "dev.isar.isar_flutter_libs") {
                namespace = "dev.isar.isar_flutter_libs"
            }
        }
    }
}
