package com.kagwno.wifi

// language: Kotlin, file: MainActivity.kt, target: Android 14 (API 34)

import android.content.Context
import android.content.Intent
import android.location.LocationManager
import android.net.wifi.WifiManager
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channel = "wifi_heatmap"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startScan" -> {
                        wifi.startScan()
                        result.success(wifi.scanResults.map(::toMap))
                    }
                    "getResults" -> result.success(wifi.scanResults.map(::toMap))
                    "isLocationEnabled" -> {
                        val lm = getSystemService(Context.LOCATION_SERVICE) as LocationManager
                        val enabled = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P)
                            lm.isLocationEnabled
                        else
                            lm.isProviderEnabled(LocationManager.GPS_PROVIDER) ||
                                lm.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
                        result.success(enabled)
                    }
                    "openLocationSettings" -> {
                        startActivity(Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS))
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun toMap(r: android.net.wifi.ScanResult) = mapOf(
        "ssid" to (r.SSID ?: ""),
        "bssid" to r.BSSID,
        "rssi" to r.level,
        "frequency" to r.frequency
    )
}