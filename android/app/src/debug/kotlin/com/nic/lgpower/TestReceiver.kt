package com.nic.lgpower

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper

class TestReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            "com.nic.lgpower.TEST_MARK" -> TestHooks.mark(intent.getStringExtra("id") ?: "")
            "com.nic.lgpower.TEST_LOG" -> TestHooks.setEnabled(intent.getBooleanExtra("on", true))
            "com.nic.lgpower.TEST_WIDGETS" -> {
                val pending = goAsync()
                var finished = false
                fun finish(json: String) {
                    if (finished) return
                    finished = true
                    pending.resultCode = if (json.contains("\"ok\":true")) -1 else 0
                    pending.resultData = json
                    pending.finish()
                }
                // A destroyed engine never answers; the broadcast must still end
                Handler(Looper.getMainLooper()).postDelayed({ finish("{\"app\":\"f\",\"ev\":\"widgets\",\"ok\":false,\"err\":\"no answer\"}") }, 3000)
                TestHooks.widgets(::finish)
            }
        }
    }
}
