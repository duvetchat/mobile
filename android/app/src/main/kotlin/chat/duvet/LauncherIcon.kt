package chat.duvet

import android.app.Service
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.IBinder

// The launcher icons to pick between in Appearance (lib/data/launcher_icon.dart):
// an activity-alias each in the manifest, the violet one on unless the black one is.
object LauncherIcon {
    private const val PREFS = "launcher_icon"
    private const val PICKED = "picked"
    private val aliases = mapOf("violet" to "chat.duvet.IconViolet", "black" to "chat.duvet.IconBlack")

    private fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun shown(context: Context): String {
        val black = ComponentName(context, aliases.getValue("black"))
        val on = context.packageManager.getComponentEnabledSetting(black) ==
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED
        return if (on) "black" else "violet"
    }

    /** The one picked, whether the launcher shows it yet or not. */
    fun picked(context: Context): String = prefs(context).getString(PICKED, null) ?: shown(context)

    /** Kept for when the app is left: LauncherIconService changes it then. */
    fun pick(context: Context, name: String) {
        if (name !in aliases) return
        prefs(context).edit().putString(PICKED, name).apply()
        resume(context)
    }

    /** One picked and not shown yet (the app was killed first) waits to be left again. */
    fun resume(context: Context) {
        if (prefs(context).getString(PICKED, null) == null) return
        try {
            context.startService(Intent(context, LauncherIconService::class.java))
        } catch (e: RuntimeException) {
            // Not allowed to start now (from the background): the next launch tries again.
        }
    }

    fun apply(context: Context) {
        val name = prefs(context).getString(PICKED, null) ?: return
        prefs(context).edit().remove(PICKED).commit()
        if (name == shown(context)) return
        // The new one on before the old one goes off: the app is never without a launcher entry.
        for ((icon, alias) in aliases.entries.sortedByDescending { it.key == name }) {
            val state = if (icon == name) {
                PackageManager.COMPONENT_ENABLED_STATE_ENABLED
            } else {
                PackageManager.COMPONENT_ENABLED_STATE_DISABLED
            }
            context.packageManager.setComponentEnabledSetting(
                ComponentName(context, alias),
                state,
                PackageManager.DONT_KILL_APP
            )
        }
    }
}

// Changing a launcher entry under a running app makes many launchers close it,
// so the icon picked changes once the app is swiped away, or once this service
// ends with the app left in the background.
class LauncherIconService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int = START_NOT_STICKY

    override fun onTaskRemoved(rootIntent: Intent?) {
        LauncherIcon.apply(this)
        stopSelf()
    }

    override fun onDestroy() {
        LauncherIcon.apply(this)
        super.onDestroy()
    }
}
