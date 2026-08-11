package com.hibi.jideshi_hibi

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.PowerManager
import android.provider.Settings
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var multicastLock: WifiManager.MulticastLock? = null
    private var updateWakeLock: PowerManager.WakeLock? = null

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
                    "acquireWakeLock" -> {
                        try {
                            val pm = applicationContext
                                .getSystemService(Context.POWER_SERVICE) as PowerManager
                            if (updateWakeLock == null) {
                                @Suppress("DEPRECATION")
                                updateWakeLock = pm.newWakeLock(
                                    PowerManager.PARTIAL_WAKE_LOCK,
                                    "hibi:app_update_download",
                                ).apply { setReferenceCounted(false) }
                            }
                            if (updateWakeLock?.isHeld != true) {
                                updateWakeLock?.acquire(90 * 60 * 1000L)
                            }
                            result.success(true)
                        } catch (error: Throwable) {
                            result.error("WAKE_LOCK", error.message, null)
                        }
                    }
                    "releaseWakeLock" -> {
                        try {
                            if (updateWakeLock?.isHeld == true) updateWakeLock?.release()
                            result.success(true)
                        } catch (error: Throwable) {
                            result.error("WAKE_LOCK", error.message, null)
                        }
                    }
                    "startUpdateDownloadForeground" -> {
                        try {
                            val args = call.arguments as? Map<*, *>
                            startOrUpdateDownloadService(
                                action = UpdateDownloadForegroundService.ACTION_START,
                                args = args,
                            )
                            result.success(true)
                        } catch (error: Throwable) {
                            result.error("UPDATE_FGS", error.message, null)
                        }
                    }
                    "updateUpdateDownloadForeground" -> {
                        try {
                            val args = call.arguments as? Map<*, *>
                            if (!UpdateDownloadForegroundService.isRunning) {
                                startOrUpdateDownloadService(
                                    action = UpdateDownloadForegroundService.ACTION_START,
                                    args = args,
                                )
                            } else {
                                startOrUpdateDownloadService(
                                    action = UpdateDownloadForegroundService.ACTION_UPDATE,
                                    args = args,
                                )
                            }
                            result.success(true)
                        } catch (error: Throwable) {
                            result.error("UPDATE_FGS", error.message, null)
                        }
                    }
                    "stopUpdateDownloadForeground" -> {
                        try {
                            val args = call.arguments as? Map<*, *>
                            val clear = (args?.get("clear") as? Boolean) ?: true
                            val intent = Intent(
                                this,
                                UpdateDownloadForegroundService::class.java,
                            ).apply {
                                action = UpdateDownloadForegroundService.ACTION_STOP
                                putExtra(UpdateDownloadForegroundService.EXTRA_CLEAR, clear)
                            }
                            // stop 不需要前台启动；普通 startService 即可
                            startService(intent)
                            result.success(true)
                        } catch (error: Throwable) {
                            result.error("UPDATE_FGS", error.message, null)
                        }
                    }
                    "isIgnoringBatteryOptimizations" -> {
                        try {
                            val pm = applicationContext
                                .getSystemService(Context.POWER_SERVICE) as PowerManager
                            result.success(pm.isIgnoringBatteryOptimizations(packageName))
                        } catch (error: Throwable) {
                            result.error("BATTERY_OPT", error.message, null)
                        }
                    }
                    "requestIgnoreBatteryOptimizations" -> {
                        try {
                            val pm = applicationContext
                                .getSystemService(Context.POWER_SERVICE) as PowerManager
                            if (pm.isIgnoringBatteryOptimizations(packageName)) {
                                result.success(true)
                            } else {
                                val intent = Intent(
                                    Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                                    Uri.parse("package:$packageName"),
                                )
                                startActivity(intent)
                                result.success(false)
                            }
                        } catch (error: Throwable) {
                            result.error("BATTERY_OPT", error.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun startOrUpdateDownloadService(action: String, args: Map<*, *>?) {
        val intent = Intent(this, UpdateDownloadForegroundService::class.java).apply {
            this.action = action
            putExtra(
                UpdateDownloadForegroundService.EXTRA_TITLE,
                (args?.get("title") as? String) ?: "正在下载更新",
            )
            putExtra(
                UpdateDownloadForegroundService.EXTRA_BODY,
                (args?.get("body") as? String) ?: "下载进行中",
            )
            putExtra(
                UpdateDownloadForegroundService.EXTRA_PROGRESS,
                (args?.get("progress") as? Number)?.toInt() ?: 0,
            )
            putExtra(
                UpdateDownloadForegroundService.EXTRA_MAX_PROGRESS,
                (args?.get("maxProgress") as? Number)?.toInt() ?: 0,
            )
            putExtra(
                UpdateDownloadForegroundService.EXTRA_INDETERMINATE,
                (args?.get("indeterminate") as? Boolean) ?: true,
            )
            putExtra(
                UpdateDownloadForegroundService.EXTRA_ONGOING,
                (args?.get("ongoing") as? Boolean) ?: true,
            )
        }
        ContextCompat.startForegroundService(this, intent)
    }

    override fun onDestroy() {
        if (multicastLock?.isHeld == true) multicastLock?.release()
        multicastLock = null
        // 下载 WakeLock 由前台服务持有；此处仅释放 Activity 侧遗留锁
        try {
            if (updateWakeLock?.isHeld == true) updateWakeLock?.release()
        } catch (_: Throwable) {
        }
        updateWakeLock = null
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
