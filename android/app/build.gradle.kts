import groovy.json.JsonOutput
import groovy.json.JsonSlurper
import java.util.Properties
import java.util.zip.ZipFile
import org.gradle.api.artifacts.component.ModuleComponentIdentifier

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
    id("app.cash.licensee")
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

// The licences of what Gradle brings into the APK (#403), which the licence page lists (lib/licenses.dart): a build
// fails on a library under a licence this list doesn't accept, or one that names none, and writes those it checked
// into the APK's assets (licenses/artifacts.json), each with the licences its POM names. Each licence here has its
// text in assets/licenses/android, which the page shows once with every library under it (test/licenses_test.dart
// keeps the two together). The list holds what ships, so a library under another licence stops the build until that
// licence is accepted here, with its text. Nothing under the GPL, the LGPL or the AGPL.
licensee {
    allow("Apache-2.0")
    allow("BSD-3-Clause")
    // Google's own terms, which Play services and Firebase ship under, and ML Kit's.
    allowUrl("https://developer.android.com/studio/terms.html") {
        because("the Android Software Development Kit License Agreement")
    }
    allowUrl("https://developers.google.com/ml-kit/terms") { because("the ML Kit Terms of Service") }
    // libwebrtc (io.github.webrtc-sdk:android) names the 3-Clause BSD licence at opensource.org's newer address, which
    // SPDX doesn't list. The page shows its own notices (tool/libwebrtc_notices.py).
    allowUrl("https://opensource.org/license/bsd-3-clause/") { because("BSD-3-Clause") }
    // AudioSwitch (com.github.davidliu:audioswitch, from JitPack) points at its upstream's LICENSE.txt: the Apache
    // License 2.0, as its own LICENSE.txt is at the commit flutter_webrtc pins.
    allowUrl("https://github.com/twilio/audioswitch/blob/master/LICENSE.txt") { because("Apache-2.0") }
    // Flutter's engine, whose POMs name no licence: Flutter's build puts its notices on the page.
    ignoreDependencies("io.flutter") { because("Flutter's engine, whose notices Flutter's own build gathers") }
    bundleAndroidAsset.set(true)
    androidAssetReportPath.set("licenses/artifacts.json")
}

// Play services', Firebase's and ML Kit's AARs embed the notices of what they build in: third_party_licenses.txt, and
// in third_party_licenses.json where each part's notice starts in it and how many bytes it takes. The page shows them,
// as Google's own licence screen would (#403): each build writes them into the APK's assets, each text once with the
// parts that have it (licenses/google.json), as AARs repeat many.
abstract class GoogleNotices : DefaultTask() {
    @get:InputFiles
    @get:PathSensitive(PathSensitivity.NAME_ONLY)
    abstract val libraries: ConfigurableFileCollection

    @get:OutputDirectory
    abstract val assets: DirectoryProperty

    @TaskAction
    fun write() {
        val parts = mutableMapOf<String, MutableSet<String>>()
        for (aar in libraries.files.filter { it.name.endsWith(".aar") }) {
            ZipFile(aar).use { zip ->
                val index = zip.getEntry("third_party_licenses.json") ?: return@use
                val texts = zip.getEntry("third_party_licenses.txt") ?: return@use
                val bytes = zip.getInputStream(texts).use { it.readBytes() }
                @Suppress("UNCHECKED_CAST")
                val notices = JsonSlurper().parse(zip.getInputStream(index), "UTF-8") as Map<String, Map<String, Int>>
                for ((part, at) in notices) {
                    val text = String(bytes, at.getValue("start"), at.getValue("length"), Charsets.UTF_8)
                    parts.getOrPut(text) { sortedSetOf() } += part
                }
            }
        }
        val notices = parts.entries.sortedBy { it.value.first() }.map { mapOf("parts" to it.value, "text" to it.key) }
        assets.file("licenses/google.json").get().asFile.run {
            parentFile.mkdirs()
            writeText(JsonOutput.toJson(notices))
        }
    }
}

androidComponents {
    onVariants { variant ->
        val notices =
            tasks.register<GoogleNotices>("${variant.name}GoogleNotices") {
                libraries.from(
                    variant.runtimeConfiguration.incoming
                        .artifactView { componentFilter { it is ModuleComponentIdentifier } }
                        .files,
                )
            }
        variant.sources.assets?.addGeneratedSourceDirectory(notices, GoogleNotices::assets)
    }
}
