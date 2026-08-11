package com.hibi.jideshi_hibi

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat

/**
 * 应用更新包下载前台服务：锁屏/黑屏时仍保持进程可调度，
 * 并持有 PARTIAL_WAKE_LOCK + WIFI_MODE_FULL_HIGH_PERF，降低断流概率。
 */
class UpdateDownloadForegroundService : Service() {
    companion object {
        const val CHANNEL_ID = "hibi_app_update_download"
        const val CHANNEL_NAME = "应用更新下载"
        const val NOTIFICATION_ID = 92031

        const val ACTION_START = "com.hibi.jideshi_hibi.UPDATE_DOWNLOAD_START"
        const val ACTION_UPDATE = "com.hibi.jideshi_hibi.UPDATE_DOWNLOAD_UPDATE"
        const val ACTION_STOP = "com.hibi.jideshi_hibi.UPDATE_DOWNLOAD_STOP"

        const val EXTRA_TITLE = "title"
        const val EXTRA_BODY = "body"
        const val EXTRA_PROGRESS = "progress"
        const val EXTRA_MAX_PROGRESS = "max_progress"
        const val EXTRA_INDETERMINATE = "indeterminate"
        const val EXTRA_ONGOING = "ongoing"
        const val EXTRA_CLEAR = "clear"

        @Volatile
        var isRunning: Boolean = false
            private set
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        ensureChannel()
        acquireLocks()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                val clear = intent.getBooleanExtra(EXTRA_CLEAR, true)
                releaseLocks()
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    stopForeground(if (clear) STOP_FOREGROUND_REMOVE else STOP_FOREGROUND_DETACH)
                } else {
                    @Suppress("DEPRECATION")
                    stopForeground(clear)
                }
                isRunning = false
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_START, ACTION_UPDATE, null -> {
                val notification = buildNotification(intent)
                startAsForeground(notification)
                isRunning = true
            }
        }
        return START_STICKY
    }

    /**
     * Android 15+ dataSync 前台服务有最长运行时限；超时后系统会回调此处。
     * 释放锁并结束服务，Dart 侧 Range 续传会在回到前台后接管。
     */
    override fun onTimeout(startId: Int, fgsType: Int) {
        releaseLocks()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_DETACH)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(false)
        }
        isRunning = false
        stopSelf(startId)
        super.onTimeout(startId, fgsType)
    }

    override fun onDestroy() {
        releaseLocks()
        isRunning = false
        super.onDestroy()
    }

    private fun startAsForeground(notification: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun buildNotification(intent: Intent?): Notification {
        val title = intent?.getStringExtra(EXTRA_TITLE) ?: "正在下载更新"
        val body = intent?.getStringExtra(EXTRA_BODY) ?: "下载进行中"
        val progress = intent?.getIntExtra(EXTRA_PROGRESS, 0) ?: 0
        val maxProgress = intent?.getIntExtra(EXTRA_MAX_PROGRESS, 0) ?: 0
        val indeterminate = intent?.getBooleanExtra(EXTRA_INDETERMINATE, true) ?: true
        val ongoing = intent?.getBooleanExtra(EXTRA_ONGOING, true) ?: true

        val launch = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
        val contentIntent = if (launch != null) {
            PendingIntent.getActivity(
                this,
                0,
                launch,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        } else {
            null
        }

        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(body)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setOnlyAlertOnce(true)
            .setOngoing(ongoing)
            .setSilent(true)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .setPriority(NotificationCompat.PRIORITY_LOW)

        if (contentIntent != null) {
            builder.setContentIntent(contentIntent)
        }

        if (maxProgress > 0 || indeterminate) {
            builder.setProgress(
                if (indeterminate) 0 else maxProgress,
                if (indeterminate) 0 else progress,
                indeterminate,
            )
        }

        return builder.build()
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java) ?: return
        val existing = manager.getNotificationChannel(CHANNEL_ID)
        if (existing != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            CHANNEL_NAME,
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "希比应用更新包下载进度"
            setShowBadge(false)
            enableVibration(false)
            setSound(null, null)
        }
        manager.createNotificationChannel(channel)
    }

    private fun acquireLocks() {
        try {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            if (wakeLock == null) {
                @Suppress("DEPRECATION")
                wakeLock = pm.newWakeLock(
                    PowerManager.PARTIAL_WAKE_LOCK,
                    "hibi:update_download_fgs",
                ).apply { setReferenceCounted(false) }
            }
            if (wakeLock?.isHeld != true) {
                wakeLock?.acquire(90 * 60 * 1000L)
            }
        } catch (_: Throwable) {
        }

        try {
            val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            if (wifiLock == null) {
                @Suppress("DEPRECATION")
                wifiLock = wifi.createWifiLock(
                    WifiManager.WIFI_MODE_FULL_HIGH_PERF,
                    "hibi:update_download_wifi",
                ).apply { setReferenceCounted(false) }
            }
            if (wifiLock?.isHeld != true) {
                wifiLock?.acquire()
            }
        } catch (_: Throwable) {
        }
    }

    private fun releaseLocks() {
        try {
            if (wakeLock?.isHeld == true) wakeLock?.release()
        } catch (_: Throwable) {
        }
        wakeLock = null
        try {
            if (wifiLock?.isHeld == true) wifiLock?.release()
        } catch (_: Throwable) {
        }
        wifiLock = null
    }
}
