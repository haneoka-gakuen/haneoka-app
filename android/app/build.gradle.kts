import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// The release key: android/key.properties, written by the release workflow
// from repository secrets. Builds without it are signed with the debug key.
val release = Properties().apply {
    rootProject.file("key.properties").takeIf { it.exists() }?.inputStream()?.use { load(it) }
}

val androidTargetAbis = mapOf("android-arm64" to "arm64-v8a", "android-x64" to "x86_64")
val requestedAndroidTargets = project.findProperty("target-platform")?.toString()?.trim()
val requestedAndroidAbis = if (requestedAndroidTargets.isNullOrEmpty()) {
    androidTargetAbis.values.toList()
} else {
    requestedAndroidTargets.split(',').map { target ->
        androidTargetAbis[target.trim()] ?: error("Unsupported Flutter Android target: $target")
    }.distinct()
}

android {
    namespace = "org.haneoka.haneoka"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    splits.abi {
        reset()
        include(*requestedAndroidAbis.toTypedArray())
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "org.haneoka.haneoka"
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        if (project.findProperty("split-per-abi")?.toString()?.toBoolean() != true) {
            ndk.abiFilters.clear()
            ndk.abiFilters.addAll(requestedAndroidAbis)
        }
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (release.containsKey("storeFile")) {
            create("release") {
                storeFile = file(release.getProperty("storeFile"))
                storePassword = release.getProperty("storePassword")
                keyAlias = release.getProperty("keyAlias")
                keyPassword = release.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
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
    // Shizuku lends the app the shell user's access to Android/data on Android 11+.
    implementation("dev.rikka.shizuku:api:13.1.5")
    implementation("dev.rikka.shizuku:provider:13.1.5")
    implementation("dev.rikka.shizuku:aidl:13.1.5")
}
