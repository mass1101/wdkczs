package com.z.wgkczs

import android.content.Context
import android.content.Intent
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class WatchdogPlugin {
    companion object {
        private const val CHANNEL = "watchdog_channel"

        fun register(engine: FlutterEngine, context: Context) {
            val channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            WatchdogService.methodChannel = channel

            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        val intent = Intent(context, WatchdogService::class.java)
                        context.startService(intent)
                        result.success(true)
                    }
                    "stop" -> {
                        val intent = Intent(context, WatchdogService::class.java)
                        context.stopService(intent)
                        result.success(true)
                    }
                    "heartbeat" -> {
                        WatchdogService.lastHeartbeatTime = System.currentTimeMillis()
                        result.success(true)
                    }
                    "isRunning" -> {
                        result.success(WatchdogService.isRunning)
                    }
                    else -> {
                        result.notImplemented()
                    }
                }
            }
        }
    }
}
