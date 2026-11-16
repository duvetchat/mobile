import java.util.Properties

// The release key, kept out of the repository: android/key.properties (see
// key.properties.example). Without it, release builds sign with the debug key.
val keyProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) file.inputStream().use { load(it) }
}

plugins {
    id("com.android.application")
    id("com.google.gms.google-services")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "chat.duvet"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // flutter_local_notifications' Android side uses java.time, which older Androids get from desugaring.
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "chat.duvet"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (keyProperties.isNotEmpty()) {
            create("release") {
                // A leading ~/ is the user's home, as in a shell.
                storeFile = file(
                    keyProperties.getProperty("storeFile").replaceFirst(Regex("^~/"), System.getProperty("user.home") + "/"),
                )
                storePassword = keyProperties.getProperty("storePassword")
                keyAlias = keyProperties.getProperty("keyAlias")
                keyPassword = keyProperties.getProperty("keyPassword")
            }
        }
    }

    // The app's fonts go in the APK as they are, not deflated: the engine maps a stored file, and inflates a deflated
    // one whole on the main thread at the first text that names its family. That first text is the first frame's,
    // which names Inter (four faces), Roboto (three) and Twemoji (2 MB, the fallback of every style). Named one by
    // one: the fonts that packages bring and the app never names would only make the APK larger. About 3 MB more
    // APK (test/fonts_stored_test.dart keeps this list and pubspec.yaml's together).
    androidResources {
        noCompress +=
            listOf(
                "assets/fonts/Fraunces.ttf",
                "assets/fonts/Inter-Regular.ttf",
                "assets/fonts/Inter-Medium.ttf",
                "assets/fonts/Inter-SemiBold.ttf",
                "assets/fonts/Inter-Bold.ttf",
                "assets/fonts/Roboto-Regular.ttf",
                "assets/fonts/Roboto-Medium.ttf",
                "assets/fonts/Roboto-Bold.ttf",
                "assets/fonts/FiraMono-Regular.ttf",
                "assets/fonts/Twemoji.ttf",
                // The icons (LucideIcons).
                "lucide_icons_flutter/assets/lucide.ttf",
            )
    }

    buildTypes {
        release {
            signingConfig =
                if (keyProperties.isNotEmpty()) signingConfigs.getByName("release")
                else signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
