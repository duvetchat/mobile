package chat.duvet

import android.app.NotificationManager
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.media.AudioManager
import android.os.Build
import android.os.PersistableBundle
import android.os.PowerManager
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// AudioServiceActivity: voice notes play through audio_service's engine, which
// gives them Android's media controls (VoiceNoteHandler).
class MainActivity : AudioServiceActivity() {
    // The screen goes off at the ear in an earpiece call (lib/main.dart).
    private var proximity: PowerManager.WakeLock? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "chat.duvet/proximity").setMethodCallHandler { call, result ->
            when (call.method) {
                "hold" -> {
                    hold(call.arguments as Boolean)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        // The app's sounds keep quiet in Do not disturb and on silent or vibrate (lib/data/sounds.dart).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "chat.duvet/ringer").setMethodCallHandler { call, result ->
            when (call.method) {
                "state" -> result.success(ringer())
                else -> result.notImplemented()
            }
        }
        // The recovery key's copy (lib/encryption/recovery_key.dart): marked sensitive, which neither the system's
        // preview of a copy nor a keyboard's clipboard history shows or keeps, and taken back while it's still there.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "chat.duvet/clipboard")
            .setMethodCallHandler { call, result ->
                val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                val text = call.arguments as String
                when (call.method) {
                    "copySensitive" -> {
                        val clip = ClipData.newPlainText("Duvet", text)
                        // ClipDescription.EXTRA_IS_SENSITIVE (Android 13), which keyboards read before it too.
                        val sensitive = PersistableBundle()
                        sensitive.putBoolean("android.content.extra.IS_SENSITIVE", true)
                        clip.description.setExtras(sensitive)
                        clipboard.setPrimaryClip(clip)
                        result.success(null)
                    }
                    // Whether the clipboard held it and it went; null while it can't be read (Android 10 lets only
                    // the app in front read it).
                    "clearIf" -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && !hasWindowFocus()) {
                        result.success(null)
                    } else {
                        val clip = clipboard.primaryClip
                        val holds = clip != null && clip.itemCount > 0 && clip.getItemAt(0).text?.toString() == text
                        if (holds && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                            clipboard.clearPrimaryClip()
                        } else if (holds) {
                            clipboard.setPrimaryClip(ClipData.newPlainText("", ""))
                        }
                        result.success(holds)
                    }
                    else -> result.notImplemented()
                }
            }
        // What Gradle brought into the APK, for the licence page (lib/licenses.dart): the build writes the libraries it
        // checked and the notices Google's AARs embed into its assets (app/build.gradle.kts). Null for one it didn't.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "chat.duvet/licenses").setMethodCallHandler { call, result ->
            when (call.method) {
                "read" -> try {
                    result.success(assets.open(call.arguments as String).bufferedReader().use { it.readText() })
                } catch (e: java.io.IOException) {
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        // The phone's model, which names this installation's device among the user's (lib/e2e/bootstrap.dart).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "chat.duvet/device").setMethodCallHandler { call, result ->
            when (call.method) {
                "model" -> result.success(Build.MODEL)
                else -> result.notImplemented()
            }
        }
        // The launcher icon picked in Appearance (LauncherIcon).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "chat.duvet/icon").setMethodCallHandler { call, result ->
            when (call.method) {
                "get" -> result.success(LauncherIcon.picked(this))
                "pick" -> {
                    LauncherIcon.pick(this, call.arguments as String)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        LauncherIcon.resume(this)
        // A screen share's foreground service (ScreenCaptureService): "start"
        // answers once it is in the foreground.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "chat.duvet/screen").setMethodCallHandler { call, result ->
            val service = Intent(this, ScreenCaptureService::class.java)
            when (call.method) {
                "start" -> if (ScreenCaptureService.running) {
                    result.success(null)
                } else try {
                    // One answer per call: a start still waiting is told it was replaced.
                    ScreenCaptureService.started?.invoke(IllegalStateException("another screen share started"))
                    ScreenCaptureService.started = { error ->
                        if (error == null) result.success(null) else result.error("screen", error.message, null)
                    }
                    // Not startForegroundService: see ScreenCaptureService.
                    startService(service)
                } catch (e: RuntimeException) {
                    // Not allowed to start now (Android 8 and later, from the background).
                    ScreenCaptureService.started = null
                    result.error("screen", e.message, null)
                }
                "stop" -> {
                    stopService(service)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun ringer(): Map<String, Any> {
        val audio = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val mode = when (audio.ringerMode) {
            AudioManager.RINGER_MODE_SILENT -> "silent"
            AudioManager.RINGER_MODE_VIBRATE -> "vibrate"
            else -> "normal"
        }
        // Unknown (the filter can't be read) counts as not disturbed.
        val filter = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).currentInterruptionFilter
        } else {
            NotificationManager.INTERRUPTION_FILTER_ALL
        }
        val dnd = filter != NotificationManager.INTERRUPTION_FILTER_ALL &&
            filter != NotificationManager.INTERRUPTION_FILTER_UNKNOWN
        return mapOf("mode" to mode, "dnd" to dnd)
    }

    private fun hold(on: Boolean) {
        val power = getSystemService(Context.POWER_SERVICE) as PowerManager
        if (!power.isWakeLockLevelSupported(PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK)) return
        val lock = proximity ?: power.newWakeLock(PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK, "duvet:proximity")
            .apply { setReferenceCounted(false) }
            .also { proximity = it }
        if (on) {
            if (!lock.isHeld) lock.acquire()
        } else if (lock.isHeld) {
            // Still at the ear: the screen comes back once the phone moves away.
            lock.release(PowerManager.RELEASE_FLAG_WAIT_FOR_NO_PROXIMITY)
        }
    }

    override fun onDestroy() {
        hold(false)
        super.onDestroy()
    }
}
