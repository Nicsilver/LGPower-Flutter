package com.nic.lgpower

import android.hardware.ConsumerIrManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

private const val IR_CHANNEL = "com.nic.lgpower/ir"

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

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
