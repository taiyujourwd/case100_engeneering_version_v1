android {
    namespace = "com.sensor.case100_engeneering_version_v1"

    compileSdk = 36

    defaultConfig {
        applicationId = "com.sensor.case100_engeneering_version_v1"
        minSdk = 24
        targetSdk = 35   // 需要 36 也可一起升，但先穩定編得過
        versionCode = 1
        versionName = "1.0.0"
        multiDexEnabled = true
    }

    // 建議先用 debug 簽章，之後再換 release 簽章
    buildTypes {
        release {
            isMinifyEnabled = false
            isShrinkResources = false
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    // Flutter 3.35 的建議：JDK 17
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
}

dependencies {
    implementation("androidx.multidex:multidex:2.0.1")
}

flutter {
    source = "../.."
}