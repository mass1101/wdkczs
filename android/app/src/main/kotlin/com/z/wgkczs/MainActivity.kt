package com.z.wgkczs

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val overlayChannelName = "com.z.wgkczs/overlay"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        GeofencePlugin.register(flutterEngine, applicationContext)
        WatchdogPlugin.register(flutterEngine, applicationContext)

        val overlayChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            overlayChannelName
        )
        overlayChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "bringToForeground" -> {
                    runOnUiThread {
                        moveTaskToBack(false)
                    }
                    result.success(true)
                }
                "moveToBack" -> {
                    runOnUiThread {
                        moveTaskToBack(true)
                    }
                    result.success(true)
                }
                "getOverlayStatus" -> {
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }
}