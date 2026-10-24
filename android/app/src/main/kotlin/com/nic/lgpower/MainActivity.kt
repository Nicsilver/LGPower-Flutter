package com.nic.lgpower

import android.hardware.ConsumerIrManager
import android.view.KeyEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

private const val IR_CHANNEL = "com.nic.lgpower/ir"
private const val VOLUME_CHANNEL = "com.nic.lgpower/volume_buttons"
private const val WIFI_CHANNEL = "com.nic.lgpower/wifi"

class MainActivity : FlutterActivity() {
    private var volumeChannel: MethodChannel? = null
    private var volumeListening = false
    private val wifiRadio by lazy { WifiRadio(this) }

    // Flutter's HardwareKeyboard only sees the volume keys once something has
    // keyboard focus (flutter/flutter#95121), so they are caught here instead.
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        val direction = when (event.keyCode) {
            KeyEvent.KEYCODE_VOLUME_UP -> "up"
            KeyEvent.KEYCODE_VOLUME_DOWN -> "down"
            else -> null
        }
        if (direction == null || !volumeListening) return super.dispatchKeyEvent(event)
        if (event.action == KeyEvent.ACTION_DOWN) volumeChannel?.invokeMethod("press", direction)
        return true
    }

    // The lock only works with the app in front, so it never outlives the activity being visible.
    override fun onStop() {
        wifiRadio.release()
        super.onStop()
    }

    override fun onDestroy() {
        wifiRadio.release()
        super.onDestroy()
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        TestHooks.detach()
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        TestHooks.attach(flutterEngine)

        volumeChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, VOLUME_CHANNEL).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> { volumeListening = true; result.success(null) }
                    "stop" -> { volumeListening = false; result.success(null) }
                    else -> result.notImplemented()
                }
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, WIFI_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "acquire" -> result.success(wifiRadio.acquire())
                "release" -> { wifiRadio.release(); result.success(false) }
                "isHeld" -> result.success(wifiRadio.isHeld)
                "wifiInfo" -> result.success(wifiRadio.info())
                else -> result.notImplemented()
            }
        }

        val irManager = getSystemService(CONSUMER_IR_SERVICE) as? ConsumerIrManager

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, IR_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "hasIrEmitter" -> result.success(irManager?.hasIrEmitter() == true)
                "transmit" -> {
                    if (irManager?.hasIrEmitter() != true) {
                        result.error("no_emitter", "No IR blaster on this phone", null)
                        return@setMethodCallHandler
                    }
                    val carrierHz = (call.argument<Int>("carrierHz") ?: 38000)
                    @Suppress("UNCHECKED_CAST")
                    val pattern = (call.argument<List<Int>>("pattern") ?: emptyList()).toIntArray()
                    runCatching { irManager.transmit(carrierHz, pattern) }
                        .onSuccess { result.success(null) }
                        .onFailure { e -> result.error("transmit_failed", e.message, null) }
                }
                else -> result.notImplemented()
            }
        }
    }
}
