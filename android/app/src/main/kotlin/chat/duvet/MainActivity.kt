package chat.duvet

import android.app.NotificationManager
import android.content.Context
import android.media.AudioManager
import android.os.Build
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
