package com.z.wgkczs

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.ServiceInfo
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.Bundle
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

class GeofenceService : Service(), LocationListener {

    companion object {
        const val TAG = "GeofenceService"
        const val CHANNEL_NAME = "geofence_native_channel"
        const val NOTIFICATION_CHANNEL_ID = "geofence_alerts"
        const val FOREGROUND_NOTIFICATION_ID = 3001

        @Volatile var methodChannel: MethodChannel? = null
        @Volatile var isRunning = false

        fun reload() {
            GeofenceServiceHolder.lastFencesJson = null
        }
    }

    private object GeofenceServiceHolder {
        @Volatile var lastFencesJson: String? = null
        @Volatile var lastIntervalSeconds = 30
    }

    private lateinit var prefs: SharedPreferences
    private lateinit var locationManager: LocationManager
    private var fencesJson: List<FenceData> = emptyList()
    private var previousMatchedId: String? = null
    private var intervalMs = 30000L
    private var wakeLock: PowerManager.WakeLock? = null

    private data class FenceData(
        val id: String,
        val name: String,
        val slotNumber: Int,
        val enabled: Boolean,
        val points: List<Pair<Double, Double>>,
        val icCardId: String?,
        val idCardId: String?,
        val cardLibraryMode: Boolean,
        val rollingCode: Boolean,
    )

    override fun onCreate() {
        super.onCreate()
        prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        locationManager = getSystemService(Context.LOCATION_SERVICE) as LocationManager
        startAsForeground()
        isRunning = true
        Log.d(TAG, "Geofence service started")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startAsForeground()
        startLocationUpdates()
        return START_STICKY
    }

    override fun onDestroy() {
        isRunning = false
        stopLocationUpdates()
        releaseWakeLock()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun startAsForeground() {
        createNotificationChannel()
        val contentIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M)
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            else PendingIntent.FLAG_UPDATE_CURRENT
        )
        val notification: Notification = NotificationCompat.Builder(
            this, NOTIFICATION_CHANNEL_ID
        )
            .setContentTitle("电子围栏监控中")
            .setContentText("正在后台监控围栏位置")
            .setSmallIcon(android.R.drawable.ic_menu_mylocation)
            .setOngoing(true)
            .setContentIntent(contentIntent)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                FOREGROUND_NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION
            )
        } else {
            startForeground(FOREGROUND_NOTIFICATION_ID, notification)
        }

        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "$packageName:geofence"
        ).apply {
            setReferenceCounted(false)
            acquire(24 * 60 * 60 * 1000L)
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            NOTIFICATION_CHANNEL_ID,
            "围栏提醒",
            NotificationManager.IMPORTANCE_HIGH
        ).apply {
            description = "进入/离开电子围栏时提醒"
        }
        getSystemService(NotificationManager::class.java)
            .createNotificationChannel(channel)
    }

    private fun startLocationUpdates() {
        loadFencesFromPrefs()
        try {
            if (locationManager.isProviderEnabled(LocationManager.GPS_PROVIDER)) {
                locationManager.requestLocationUpdates(
                    LocationManager.GPS_PROVIDER,
                    intervalMs,
                    0f,
                    this
                )
            }
            if (locationManager.isProviderEnabled(LocationManager.NETWORK_PROVIDER)) {
                locationManager.requestLocationUpdates(
                    LocationManager.NETWORK_PROVIDER,
                    intervalMs,
                    0f,
                    this
                )
            }
        } catch (e: SecurityException) {
            Log.w(TAG, "location permission missing: ${e.message}")
        }
    }

    private fun stopLocationUpdates() {
        try {
            locationManager.removeUpdates(this)
        } catch (_: Exception) {}
    }

    private fun releaseWakeLock() {
        wakeLock?.let {
            if (it.isHeld) it.release()
        }
        wakeLock = null
    }

    private fun loadFencesFromPrefs() {
        val jsonStr = prefs.getString("flutter.geofence_list", null)
        if (jsonStr == null || jsonStr == GeofenceServiceHolder.lastFencesJson) {
            return
        }
        GeofenceServiceHolder.lastFencesJson = jsonStr
        val interval = readIntPref("flutter.geofence_check_interval", 30)
        GeofenceServiceHolder.lastIntervalSeconds = interval
        intervalMs = (interval.coerceAtLeast(5)) * 1000L

        val list = mutableListOf<FenceData>()
        try {
            val arr = JSONArray(jsonStr)
            for (i in 0 until arr.length()) {
                val obj = arr.getJSONObject(i)
                val pointsArr = obj.optJSONArray("points") ?: continue
                val points = mutableListOf<Pair<Double, Double>>()
                for (j in 0 until pointsArr.length()) {
                    val p = pointsArr.getJSONObject(j)
                    points.add(
                        Pair(
                            p.optDouble("latitude", 0.0),
                            p.optDouble("longitude", 0.0)
                        )
                    )
                }
                list.add(
                    FenceData(
                        id = obj.getString("id"),
                        name = obj.optString("name", ""),
                        slotNumber = obj.optInt("slotNumber", 0),
                        enabled = obj.optBoolean("enabled", true),
                        points = points,
                        icCardId = if (obj.isNull("icCardId")) null else obj.optString("icCardId"),
                        idCardId = if (obj.isNull("idCardId")) null else obj.optString("idCardId"),
                        cardLibraryMode = obj.optBoolean("cardLibraryMode", false),
                        rollingCode = obj.optBoolean("rollingCode", false),
                    )
                )
            }
        } catch (e: Exception) {
            Log.w(TAG, "parse fences failed: ${e.message}")
        }
        fencesJson = list
        previousMatchedId = null
        Log.d(TAG, "loaded ${fencesJson.size} fences, interval=${interval}s")
    }

    private fun readIntPref(key: String, default: Int): Int {
        val value = prefs.all[key] ?: return default
        return when (value) {
            is Int -> value
            is Long -> value.toInt()
            is Float -> value.toInt()
            is Double -> value.toInt()
            is String -> value.toIntOrNull() ?: default
            else -> default
        }
    }

    override fun onLocationChanged(location: Location) {
        loadFencesFromPrefs()
        val gcj = wgs84ToGcj02(location.latitude, location.longitude)
        emitPosition(gcj.first, gcj.second)
        val match = findMatchingFence(gcj.first, gcj.second)
        if (match != null) {
            val entering = previousMatchedId != match.id
            if (entering) {
                Log.d(TAG, "entered fence ${match.name}")
                showNotification("进入围栏", "已进入围栏\"${match.name}\"")
                emitToFlutter("enter", match, gcj.first, gcj.second)
            }
            previousMatchedId = match.id
        } else {
            if (previousMatchedId != null) {
                val prev = fencesJson.firstOrNull { it.id == previousMatchedId }
                if (prev != null) {
                    Log.d(TAG, "exited fence ${prev.name}")
                    showNotification("离开围栏", "已离开围栏\"${prev.name}\"")
                    emitToFlutter("exit", prev, gcj.first, gcj.second)
                }
            }
            previousMatchedId = null
        }
    }

    override fun onProviderEnabled(provider: String) {}

    override fun onProviderDisabled(provider: String) {}

    override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}

    private fun findMatchingFence(lat: Double, lng: Double): FenceData? {
        var lastMatch: FenceData? = null
        for (fence in fencesJson) {
            if (!fence.enabled) continue
            if (fence.points.size < 3) continue
            if (isPointInPolygon(lat, lng, fence.points)) {
                lastMatch = fence
            }
        }
        return lastMatch
    }

    private fun isPointInPolygon(lat: Double, lng: Double, polygon: List<Pair<Double, Double>>): Boolean {
        var i = 0
        var j = polygon.size - 1
        var inside = false
        while (i < polygon.size) {
            val pi = polygon[i]
            val pj = polygon[j]
            if ((pi.first > lat) != (pj.first > lat)) {
                val intersectLng = pj.second +
                    (lat - pj.first) / (pi.first - pj.first) *
                    (pi.second - pj.second)
                if (lng < intersectLng) {
                    inside = !inside
                }
            }
            j = i
            i++
        }
        return inside
    }

    private fun emitPosition(lat: Double, lng: Double) {
        try {
            methodChannel?.invokeMethod(
                "onPosition",
                mapOf("latitude" to lat, "longitude" to lng)
            )
        } catch (e: Exception) {
            Log.w(TAG, "emitPosition failed: ${e.message}")
        }
    }

    private fun emitToFlutter(event: String, fence: FenceData, lat: Double, lng: Double) {
        val data = mapOf(
            "event" to event,
            "fenceId" to fence.id,
            "fenceName" to fence.name,
            "slotNumber" to fence.slotNumber,
            "icCardId" to (fence.icCardId ?: ""),
            "idCardId" to (fence.idCardId ?: ""),
            "cardLibraryMode" to fence.cardLibraryMode,
            "rollingCode" to fence.rollingCode,
            "latitude" to lat,
            "longitude" to lng,
        )
        try {
            methodChannel?.invokeMethod("onFenceEvent", data)
        } catch (e: Exception) {
            Log.w(TAG, "emit failed: ${e.message}")
        }
    }

    private fun showNotification(title: String, body: String) {
        val contentIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M)
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            else PendingIntent.FLAG_UPDATE_CURRENT
        )
        val notification: Notification = NotificationCompat.Builder(
            this, NOTIFICATION_CHANNEL_ID
        )
            .setContentTitle(title)
            .setContentText(body)
            .setSmallIcon(android.R.drawable.ic_menu_mylocation)
            .setAutoCancel(true)
            .setContentIntent(contentIntent)
            .build()
        getSystemService(NotificationManager::class.java)
            .notify(FOREGROUND_NOTIFICATION_ID + 1, notification)
    }

    private fun wgs84ToGcj02(lat: Double, lng: Double): Pair<Double, Double> {
        if (lng < 72.004 || lng > 137.8347 || lat < 0.8293 || lat > 55.8271) {
            return Pair(lat, lng)
        }
        val pi = 3.14159265358979324
        val a = 6378245.0
        val ee = 0.00669342162296594323
        val dLat = transformLat(lng - 105.0, lat - 35.0)
        val dLng = transformLng(lng - 105.0, lat - 35.0)
        val radLat = lat / 180.0 * pi
        var magic = sin(radLat)
        magic = 1 - ee * magic * magic
        val sqrtMagic = sqrt(magic)
        val latOffset = (dLat * 180.0) / ((a * (1 - ee)) / (magic * sqrtMagic) * pi)
        val lngOffset = (dLng * 180.0) / (a / sqrtMagic * cos(radLat) * pi)
        return Pair(lat + latOffset, lng + lngOffset)
    }

    private fun transformLat(x: Double, y: Double): Double {
        var ret = -100.0 +
            2.0 * x +
            3.0 * y +
            0.2 * y * y +
            0.1 * x * y +
            0.2 * sqrt(abs(x))
        ret += (20.0 * sin(6.0 * x * 3.14159265358979324) +
            20.0 * sin(2.0 * x * 3.14159265358979324)) * 2.0 / 3.0
        ret += (20.0 * sin(y * 3.14159265358979324) +
            40.0 * sin(y / 3.0 * 3.14159265358979324)) * 2.0 / 3.0
        ret += (160.0 * sin(y / 12.0 * 3.14159265358979324) +
            320 * sin(y * 3.14159265358979324 / 30.0)) * 2.0 / 3.0
        return ret
    }

    private fun transformLng(x: Double, y: Double): Double {
        var ret = 300.0 +
            x +
            2.0 * y +
            0.1 * x * x +
            0.1 * x * y +
            0.1 * sqrt(abs(x))
        ret += (20.0 * sin(6.0 * x * 3.14159265358979324) +
            20.0 * sin(2.0 * x * 3.14159265358979324)) * 2.0 / 3.0
        ret += (20.0 * sin(x * 3.14159265358979324) +
            40.0 * sin(x / 3.0 * 3.14159265358979324)) * 2.0 / 3.0
        ret += (150.0 * sin(x / 12.0 * 3.14159265358979324) +
            300.0 * sin(x / 30.0 * 3.14159265358979324)) * 2.0 / 3.0
        return ret
    }
}