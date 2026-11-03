package local.gmailghost

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Base64
import android.util.Log

/** Starts the ghost again after every restart, and re-arms the checks after an app update. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED -> {
                EnsureJob.schedulePeriodic(context)
                EnsureJob.scheduleSoon(context, 10_000)
            }
        }
    }
}

/**
 * Commands that only the adb shell or the system can send: the manifest requires
 * android.permission.DUMP from the sender.
 *   PROVE:     answers a random nonce, so the app knows an adb connection really reaches Android's
 *              adb service and not something imitating it.
 *   PROVISION: stores the app's own paired adb key (PKCS#12, base64) in private storage.
 *   CHECK:     runs the restart check now (the same job a restart schedules).
 */
class ControlReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            "local.gmailghost.PROVE" -> {
                intent.getStringExtra("nonce")?.let { Adb.proven.add(it) }
                resultData = "proven"
            }
            "local.gmailghost.PROVISION" -> {
                val p12 = intent.getStringExtra("p12")
                val pass = intent.getStringExtra("pass")
                if (p12 == null || pass == null) {
                    resultData = "missing p12 or pass"
                    return
                }
                resultData = try {
                    Adb.storeKey(context, Base64.decode(p12, Base64.DEFAULT), pass)
                    EnsureJob.schedulePeriodic(context)
                    Log.i(Adb.TAG, "adb key provisioned")
                    "provisioned"
                } catch (e: Exception) {
                    "failed: $e"
                }
            }
            "local.gmailghost.CHECK" -> {
                EnsureJob.schedulePeriodic(context)
                EnsureJob.scheduleSoon(context, 0)
                resultData = "scheduled"
            }
        }
    }
}
