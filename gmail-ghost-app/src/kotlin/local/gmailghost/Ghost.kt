package local.gmailghost

import android.content.Context
import android.util.Base64
import java.security.MessageDigest

/**
 * Installs the ghost's own files (bundled in this app) into /data/local/tmp/gmailghost on this
 * Googlebook and keeps the ghost running, through the app's own adb connection. Every check is one
 * short adb session. The ghost's runtime (Python, Playwright and Chromium, about 500 MB) and the
 * signed-in Gmail profiles are too big for an app and are put there once by the setup script; this
 * app reports it plainly when they are missing.
 */
object Ghost {
    const val DIR = "/data/local/tmp/gmailghost"
    private val FILES = listOf("ghost.sh", "env.sh", "node-wrap.sh", "ghostd.py")
    private val lock = Any()

    class Result(val reachable: Boolean, val running: Boolean, val stoppedByUser: Boolean, val text: String)

    /** Installs changed files (restarting the ghost then) and makes sure the ghost is running. */
    fun check(ctx: Context): Result = synchronized(lock) {
        val adb = Adb.connect(ctx)
            ?: return Result(false, false, false, if (Adb.provisioned(ctx))
                "Wireless debugging on this Googlebook is not reachable right now."
            else "The app has no adb key yet.")
        adb.use {
            val runtime = it.exec("[ -x $DIR/rt/lib/ld-linux-x86-64.so.2 ] && echo yes").trim()
            if (runtime != "yes")
                return Result(true, false, false, "The ghost's runtime is missing from $DIR/rt, so the ghost cannot run. Run the setup script once.")
            val changed = install(ctx, it)
            val action = if (changed) "restart" else "ensure"
            val said = it.exec("sh $DIR/ghost.sh $action 2>&1").trim()
            val status = it.exec("sh $DIR/ghost.sh status 2>&1").trim()
            val first = status.lineSequence().firstOrNull() ?: ""
            Result(true, first == "running", status.contains("stopped by you"),
                (if (changed) "Installed newer ghost files. " else "") + "Ghost said: $said\n$status")
        }
    }

    /** Copies every bundled file whose fingerprint differs from the device's copy. True if any changed. */
    private fun install(ctx: Context, adb: AdbClient): Boolean {
        var changed = false
        adb.exec("mkdir -p $DIR/logs && chmod 700 $DIR")
        for (name in FILES) {
            val bytes = ctx.assets.open(name).use { it.readBytes() }
            val want = sha256(bytes)
            val have = adb.exec("sha256sum $DIR/$name 2>/dev/null").trim().substringBefore(' ')
            if (have == want) continue
            // Write a new copy beside the old one, check it, then put it in place in one step (a
            // running ghost keeps using the old copy until it is restarted).
            val mode = if (name.endsWith(".sh")) "755" else "644"
            val b64 = Base64.encodeToString(bytes, Base64.NO_WRAP)
            adb.exec(": > $DIR/.$name.b64")
            for (chunk in b64.chunked(3000)) adb.exec("echo -n '$chunk' >> $DIR/.$name.b64")
            val got = adb.exec("base64 -d $DIR/.$name.b64 > $DIR/.$name.new && chmod $mode $DIR/.$name.new && sha256sum $DIR/.$name.new")
                .trim().substringBefore(' ')
            if (got != want) throw java.io.IOException("the copy of $name did not arrive intact")
            adb.exec("mv -f $DIR/.$name.new $DIR/$name")
            changed = true
        }
        return changed
    }

    private fun sha256(b: ByteArray) =
        MessageDigest.getInstance("SHA-256").digest(b).joinToString("") { "%02x".format(it) }
}
