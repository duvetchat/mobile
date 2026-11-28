pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "8.11.1" apply false
    id("org.jetbrains.kotlin.android") version "2.2.20" apply false
    // Reads android/app/google-services.json, the Firebase project's, for push (lib/push).
    id("com.google.gms.google-services") version "4.6.0" apply false
    // Checks the licences of what Gradle brings into the APK (app/build.gradle.kts). 1.14.1 is its last release for
    // Gradle 8.
    id("app.cash.licensee") version "1.14.1" apply false
}

include(":app")
