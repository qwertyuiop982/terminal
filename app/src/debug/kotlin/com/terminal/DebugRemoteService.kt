package com.terminal

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder
import java.util.concurrent.Executors

/** Owns the Debug-only listener independently of Activity rotation and PTY lifetime. */
class DebugRemoteService : Service() {
    private val startup = Executors.newSingleThreadExecutor()
    @Volatile private var stopped = false
    @Volatile private var server: DebugRemoteServer? = null

    override fun onCreate() {
        super.onCreate()
        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26) manager.createNotificationChannel(
            NotificationChannel("debug-remote", "远程调试服务", NotificationManager.IMPORTANCE_LOW),
        )
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        val activity = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), flags)
        val stop = PendingIntent.getService(this, 1, Intent(this, javaClass).setAction("stop"), flags)
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, "debug-remote") else Notification.Builder(this)
        startForeground(35565, builder.setSmallIcon(android.R.drawable.stat_notify_sync)
            .setContentTitle("Terminal 远程调试 :35565").setContentText("点击查看地址与访问令牌")
            .setContentIntent(activity).setOngoing(true)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "停止", stop).build())
        startup.execute {
            try {
                val layout = Rootfs.ensure(this)
                if (stopped) return@execute
                val created = DebugRemoteServer(this, layout, DebugFeatures.token())
                synchronized(this) {
                    if (stopped) { created.close(); return@execute }
                    server = created
                    created.start()
                }
                DebugFeatures.state = "已监听 0.0.0.0:${DebugFeatures.PORT}"
            } catch (error: Exception) {
                DebugFeatures.state = "启动失败：${error.message}"
                stopSelf()
            }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == "stop") stopSelf()
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null
    override fun onDestroy() {
        synchronized(this) { stopped = true; server?.close(); server = null }
        startup.shutdownNow()
        if (!DebugFeatures.state.startsWith("启动失败")) DebugFeatures.state = "已停止"
        super.onDestroy()
    }
}