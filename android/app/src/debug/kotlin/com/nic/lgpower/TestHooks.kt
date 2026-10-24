package com.nic.lgpower

import android.os.Process
import android.os.SystemClock
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

/**
 * Native half of the phone-lab hooks (contract: LGPowerWidget/.plans/phonelab-app-log-schema.md).
 * Marks are logged here rather than in Dart so they still land when no engine is running.
 * The release and profile source sets carry an empty object with the same entry points.
 */
object TestHooks {
    private const val TAG = "LgpTest"

    private var channel: MethodChannel? = null
    @Volatile private var enabled = true

    init {
        log("start", JSONObject().put("wall", System.currentTimeMillis()).put("pid", Process.myPid()).put("build", "debug"))
    }

    fun attach(engine: FlutterEngine) {
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, "com.nic.lgpower/test")
    }

    fun detach() {
        channel = null
    }

    private fun log(ev: String, fields: JSONObject) {
        if (!enabled) return
        val o = JSONObject().put("app", "f").put("t", SystemClock.uptimeMillis()).put("ev", ev)
        for (k in fields.keys()) o.put(k, fields.get(k))
        Log.i(TAG, o.toString())
    }

    fun mark(id: String) = log("mark", JSONObject().put("id", id).put("wall", System.currentTimeMillis()))

    fun setEnabled(on: Boolean) {
        enabled = on
        channel?.invokeMethod("enabled", on)
    }

    /** [done] gets the reply JSON; always called once, on the main thread. */
    fun widgets(done: (String) -> Unit) {
        val c = channel
        if (c == null) {
            done(noEngine())
            return
        }
        var answered = false
        c.invokeMethod("widgets", null, object : MethodChannel.Result {
            override fun success(result: Any?) { if (!answered) { answered = true; done(result as? String ?: noEngine()) } }
            override fun error(code: String, message: String?, details: Any?) { if (!answered) { answered = true; done(noEngine()) } }
            override fun notImplemented() { if (!answered) { answered = true; done(noEngine()) } }
        })
    }

    private fun noEngine() = JSONObject()
        .put("app", "f").put("t", SystemClock.uptimeMillis()).put("ev", "widgets")
        .put("ok", false).put("err", "no engine").toString()
}
