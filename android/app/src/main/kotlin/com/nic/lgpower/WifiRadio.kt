package com.nic.lgpower

import android.content.Context
import android.net.wifi.WifiManager
import android.os.Build
import android.util.Log

/** The Wi-Fi lock the remote holds while on screen, and the radio facts the connection report prints. */
class WifiRadio(context: Context) {
    private val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
    private var lock: WifiManager.WifiLock? = null
    private var failureLogged = false

    private val mode
        get() = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) WifiManager.WIFI_MODE_FULL_LOW_LATENCY
        else @Suppress("DEPRECATION") WifiManager.WIFI_MODE_FULL_HIGH_PERF

    @get:Synchronized val isHeld get() = lock?.isHeld == true

    /** Returns whether the lock is held afterwards; never throws, since the remote works fine without it. */
    @Synchronized
    fun acquire(): Boolean {
        try {
            val held = lock ?: wifi?.createWifiLock(mode, "lgpower:remote")
                ?.also { it.setReferenceCounted(false); lock = it }
                ?: return false
            if (!held.isHeld) held.acquire()
            return held.isHeld
        } catch (e: Exception) {
            logOnce("acquire", e)
            return false
        }
    }

    @Synchronized
    fun release() {
        try {
            lock?.takeIf { it.isHeld }?.release()
        } catch (e: Exception) {
            logOnce("release", e)
        }
    }

    /** Frequency, signal and link speed of the current network; null off Wi-Fi. No SSID, BSSID or addresses. */
    @Suppress("DEPRECATION")
    fun info(): Map<String, Int>? {
        val i = runCatching { wifi?.connectionInfo }.getOrNull() ?: return null
        // A phone off Wi-Fi reports a zero frequency and the "no signal" RSSI sentinel
        if (i.frequency <= 0 || i.rssi <= -127) return null
        return mapOf("frequencyMhz" to i.frequency, "rssiDbm" to i.rssi, "linkMbps" to i.linkSpeed)
    }

    private fun logOnce(what: String, e: Exception) {
        if (failureLogged) return
        failureLogged = true
        Log.w("WifiRadio", "$what failed: ${e.javaClass.simpleName}")
    }
}
