package local.gmailghost

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences

object Prefs {
    fun get(c: Context): SharedPreferences = c.getSharedPreferences("state", Context.MODE_PRIVATE)
}

/**
 * Remembers the last check and tells you, with one notification, when the ghost has not been running
 * for 30 minutes (unless you stopped it yourself), because Mark as read cannot work then. The
 * notification goes away by itself as soon as a check finds the ghost running again.
 */
object Status {
    private const val CHANNEL = "not-running"
    private const val NOTE_ID = 1
    private const val ALERT_AFTER_MS = 30 * 60_000L
    const val LAST_CHECK = "lastCheck"
    const val LAST_OK = "lastOk"
    const val LAST_TEXT = "lastText"
    private const val DOWN_SINCE = "downSince"

    fun record(c: Context, r: Ghost.Result) {
        val now = System.currentTimeMillis()
        val p = Prefs.get(c)
        val e = p.edit().putLong(LAST_CHECK, now).putString(LAST_TEXT, r.text)
        if (r.running || r.stoppedByUser) {
            e.putLong(LAST_OK, now).remove(DOWN_SINCE).apply()
            c.getSystemService(NotificationManager::class.java).cancel(NOTE_ID)
        } else {
            if (!p.contains(DOWN_SINCE)) e.putLong(DOWN_SINCE, now)
            e.apply()
            maybeAlert(c, r.text)
        }
    }

    fun recordError(c: Context, error: String) =
        record(c, Ghost.Result(false, false, false, "The check failed: $error"))

    private fun maybeAlert(c: Context, reason: String) {
        val since = Prefs.get(c).getLong(DOWN_SINCE, System.currentTimeMillis())
        if (System.currentTimeMillis() - since < ALERT_AFTER_MS) return
        val nm = c.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CHANNEL, "Not running", NotificationManager.IMPORTANCE_DEFAULT))
        val open = PendingIntent.getActivity(c, 0, Intent(c, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        nm.notify(NOTE_ID, Notification.Builder(c, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat)
            .setContentTitle("Gmail Ghost is not running, so Mark as read cannot work")
            .setContentText(reason.lineSequence().first())
            .setStyle(Notification.BigTextStyle().bigText(reason.lineSequence().take(3).joinToString("\n")))
            .setContentIntent(open)
            .setOnlyAlertOnce(true)
            .build())
    }
}
