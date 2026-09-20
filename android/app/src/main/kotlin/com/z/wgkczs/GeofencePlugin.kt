package com.z.wgkczs

import android.content.Context
import android.content.Intent
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class GeofencePlugin {
    companion object {
        private const val CHANNEL = "geofence_native_channel"

        fun register(engine: FlutterEngine, context: Context) {
            val channel = MethodChannel(
                engine.dartExecutor.binaryMessenger,
                CHANNEL
            )
            GeofenceService.methodChannel = channel

            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        val intent = Intent(context, GeofenceService::class.java)
                        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
                            context.startForegroundService(intent)
                        } else {
                            context.startService(intent)
                        }
                        result.success(true)
                    }
                    "stop" -> {
                        val intent = Intent(context, GeofenceService::class.java)
                        context.stopService(intent)
                        result.success(true)
                    }
                    "isRunning" -> {
                        result.success(GeofenceService.isRunning)
                    }
                    "reload" -> {
                        GeofenceService.reload()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }
}