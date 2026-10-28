import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

// 高德 Android SDK Key（从 gitignore 的 amap_key.properties 读取，注入 manifest 占位符，避免入库）。
val amapKeyProperties = Properties()
val amapKeyFile = rootProject.file("amap_key.properties")
if (amapKeyFile.exists()) {
    amapKeyProperties.load(FileInputStream(amapKeyFile))
}
val amapApiKey = amapKeyProperties.getProperty("amap.apiKey", "")

android {
    namespace = "com.runloop.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.runloop.app"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // AMap Key 通过占位符注入（值来自 gitignore 的 amap_key.properties）。
        manifestPlaceholders["AMAP_API_KEY"] = amapApiKey
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = rootProject.file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // 高德地图 SDK（运行时依赖，插件自身为 compileOnly，需宿主 App 提供）。
    // 版本与 amap_flutter_map 3.0.0 的 compileOnly 'com.amap.api:3dmap:8.1.0' 一致，
    // 避免编译期(8.1.0)与运行期版本不匹配导致 NoSuchMethodError/NoSuchFieldError。
    implementation("com.amap.api:3dmap:8.1.0")
    // 高德定位 SDK（运行时依赖），与 amap_flutter_location 3.0.0 的 compileOnly 5.6.0 一致。
    implementation("com.amap.api:location:5.6.0")
}
