package local.gmailghost

import android.app.Activity
import android.graphics.Color
import android.graphics.Typeface
import android.os.Bundle
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import java.text.DateFormat
import java.util.Date

/**
 * A normal app window (closing it never affects the ghost). It shows whether the ghost is running
 * and what it did last, and lets you check it right now.
 */
class MainActivity : Activity() {
    private lateinit var state: TextView
    private lateinit var details: TextView
    private lateinit var result: TextView
    private lateinit var checkButton: Button

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val pad = (16 * resources.displayMetrics.density).toInt()
        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(pad, pad, pad, pad)
        }
        fun text(size: Float, bold: Boolean = false) = TextView(this).apply {
            textSize = size
            if (bold) typeface = Typeface.DEFAULT_BOLD
            setPadding(0, pad / 2, 0, pad / 2)
            setTextIsSelectable(true)
        }
        state = text(22f, true)
        details = text(15f)
        result = text(14f)
        checkButton = Button(this).apply { text = "Check now"; setOnClickListener { runCheck() } }
        val about = text(14f).apply {
            text = "Gmail Ghost marks emails read for the Notification Keeper's Mark as read button. " +
                "It runs on this Googlebook itself, in a hidden browser that is already signed in to " +
                "your Gmail accounts, so it needs neither the Linux Terminal nor a window.\n\n" +
                "This app starts the ghost again after every restart, checks it every 15 minutes and " +
                "tells you with a notification if it has not been running for 30 minutes.\n\n" +
                "The ghost and its log are kept in ${Ghost.DIR} on this Googlebook. Nothing is ever deleted."
        }
        column.addView(state)
        column.addView(details)
        column.addView(checkButton)
        column.addView(result)
        column.addView(about)
        setContentView(ScrollView(this).apply { addView(column) })
        show()
    }

    override fun onResume() {
        super.onResume()
        show()
    }

    private fun show() {
        val p = Prefs.get(this)
        val lastCheck = p.getLong(Status.LAST_CHECK, 0)
        val text = p.getString(Status.LAST_TEXT, "") ?: ""
        val values = text.lineSequence().mapNotNull { line ->
            val i = line.indexOf('=')
            if (i > 0) line.substring(0, i) to line.substring(i + 1) else null
        }.toMap()
        val running = text.lineSequence().any { it == "running" }
        when {
            lastCheck == 0L -> {
                state.text = "Not checked yet"
                state.setTextColor(Color.LTGRAY)
            }
            running -> {
                state.text = "Running"
                state.setTextColor(Color.rgb(0x6d, 0xd5, 0x8c))
            }
            else -> {
                state.text = "Not running"
                state.setTextColor(Color.rgb(0xf2, 0x8b, 0x82))
            }
        }
        val lines = ArrayList<String>()
        values["since"]?.toLongOrNull()?.takeIf { it > 0 }?.let { lines.add("Running since: ${time(it * 1000)}") }
        values["daemon_starts"]?.toIntOrNull()?.let { lines.add("Ghost starts since then: $it") }
        values["last_result"]?.takeIf { it.isNotBlank() }?.let { lines.add("Last result: $it") }
        if (lastCheck > 0) lines.add("Last check by this app: ${time(lastCheck)}")
        if (!running && text.isNotEmpty()) lines.add(text.lineSequence().first())
        details.text = lines.joinToString("\n")
    }

    private fun runCheck() {
        checkButton.isEnabled = false
        result.text = "Checking..."
        Thread {
            val msg = try {
                val r = Ghost.check(applicationContext)
                Status.record(applicationContext, r)
                if (r.running) "The ghost is running." else r.text.lineSequence().first()
            } catch (e: Exception) {
                Status.recordError(applicationContext, e.toString())
                "The check failed: $e"
            }
            runOnUiThread {
                result.text = msg
                checkButton.isEnabled = true
                show()
            }
        }.start()
    }

    private fun time(ms: Long): String =
        DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.MEDIUM).format(Date(ms))
}
