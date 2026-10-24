package com.nic.lgpower

import io.flutter.embedding.engine.FlutterEngine

/** Release and profile stand-in for the debug test hooks: nothing is registered. */
object TestHooks {
    @Suppress("UNUSED_PARAMETER")
    fun attach(engine: FlutterEngine) {}
    fun detach() {}
}
