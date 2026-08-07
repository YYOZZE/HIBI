package com.hibi.jideshi_hibi

import android.content.Context
import android.net.wifi.WifiManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var multicastLock: WifiManager.MulticastLock? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "hibi/network")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "acquireMulticastLock" -> {
                        try {
                            val wifiManager = applicationContext
                                .getSystemService(Context.WIFI_SERVICE) as WifiManager
                            if (multicastLock == null) {
                                multicastLock = wifiManager.createMulticastLock("hibi_lan_discovery").apply {
                                    setReferenceCounted(false)
                                }
                            }
                            if (multicastLock?.isHeld != true) multicastLock?.acquire()
                            result.success(true)
                        } catch (error: Throwable) {
                            result.error("MULTICAST_LOCK", error.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        if (multicastLock?.isHeld == true) multicastLock?.release()
        multicastLock = null
        super.onDestroy()
    }

    override fun onPause() {
        if (multicastLock?.isHeld == true) multicastLock?.release()
        super.onPause()
    }

    override fun onResume() {
        super.onResume()
        if (multicastLock != null && multicastLock?.isHeld != true) {
            try {
                multicastLock?.acquire()
            } catch (_: Throwable) {
            }
        }
    }
}
