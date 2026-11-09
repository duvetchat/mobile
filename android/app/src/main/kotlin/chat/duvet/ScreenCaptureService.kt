package chat.duvet

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

// Android 10 and later capture the screen only under a foreground service of
// the screen capture type. flutter_background's carries the microphone type
// alone: it starts with every type it has, and on Android 14 a screen capture
// type fails to start before the user's consent. So this one starts after the
// consent and before the capture (lib/data/webrtc_engine.dart, openScreen).
class ScreenCaptureService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val error = try {
            foreground()
            null
        } catch (e: Exception) {
            stopSelf()
            e
        }
        started?.invoke(error)
        started = null
        return START_NOT_STICKY
    }

    private fun foreground() {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL, "Screen sharing", NotificationManager.IMPORTANCE_LOW)
            )
            Notification.Builder(this, CHANNEL)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val notification = builder
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Sharing your screen")
            .setOngoing(true)
            .setContentIntent(
                PendingIntent.getActivity(
                    this, 0, Intent(this, MainActivity::class.java),
                    PendingIntent.FLAG_IMMUTABLE,
                )
            )
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
        } else {
            startForeground(ID, notification)
        }
    }

    companion object {
        private const val CHANNEL = "screen"
        private const val ID = 7

        // Told once the service is in the foreground (null) or why it isn't:
        // onStartCommand runs on the main thread, as MainActivity's channel does.
        var started: ((Exception?) -> Unit)? = null
    }
}
