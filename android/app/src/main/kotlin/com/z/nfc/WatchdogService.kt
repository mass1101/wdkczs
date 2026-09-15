package com.z.nfc

import android.app.Service
import android.content.Intent
import android.os.IBinder
import android.util.Log
import io.flutter.plugin.common.MethodChannel

class WatchdogService : Service() {
    companion object {
        const val TAG = "WatchdogService"
        const val CHANNEL = "watchdog_channel"
        const val TIMEOUT_MS = 60000L
        const val CHECK_INTERVAL_MS = 15000L

        var lastHeartbeatTime = System.currentTimeMillis()
        var isRunning = false
        var methodChannel: MethodChannel? = null
    }

    private val checkRunnable = object : Runnable {
        override fun run() {
            checkHeartbeat()
            handler.postDelayed(this, CHECK_INTERVAL_MS)
        }
    }
    private val handler = android.os.Handler(android.os.Looper.getMainLooper())

    override fun onCreate() {
        super.onCreate()
        isRunning = true
        handler.post(checkRunnable)
        Log.d(TAG, "Watchdog service started")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        isRunning = false
        handler.removeCallbacks(checkRunnable)
        Log.d(TAG, "Watchdog service destroyed")
        super.onDestroy()
    }

    private fun checkHeartbeat() {
        val now = System.currentTimeMillis()
        val elapsed = now - lastHeartbeatTime
        if (elapsed > TIMEOUT_MS) {
            Log.w(TAG, "Heartbeat timeout! Elapsed: ${elapsed}ms")
            methodChannel?.invokeMethod("onTimeout", null)
        }
    }
}
