package com.terminal

import android.Manifest
import android.app.Activity
import android.app.AlertDialog
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.system.Os
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.TextView
import java.io.File
import java.net.Inet4Address
import java.net.NetworkInterface
import java.security.SecureRandom

object DebugFeatures {
    const val PORT = 35565
    @Volatile var state = "正在启动"

    @Synchronized fun token(): String {
        val directory = File("/data/data/com.terminal/no_backup")
        check(directory.isDirectory || directory.mkdirs()) { "cannot create private debug settings" }
        val file = File(directory, "debug-remote-token")
        if (file.isFile) return file.readText().trim().also { check(it.matches(Regex("[0-9a-f]{64}"))) }
        val bytes = ByteArray(32).also { SecureRandom().nextBytes(it) }
        val value = bytes.joinToString("") { "%02x".format(it) }
        val temporary = File.createTempFile(".remote-", ".tmp", directory)
        try {
            temporary.writeText(value + "\n")
            Os.chmod(temporary.absolutePath, 0x180)
            check(temporary.renameTo(file)) { "cannot save debug access token" }
        } finally { temporary.delete() }
        return value
    }

    fun addresses(): List<String> = try {
        NetworkInterface.getNetworkInterfaces().toList().flatMap { network ->
            network.inetAddresses.toList().filterIsInstance<Inet4Address>()
                .filter { !it.isLoopbackAddress && !it.isLinkLocalAddress }.map { "http://${it.hostAddress}:$PORT" }
        }.distinct()
    } catch (_: Exception) { listOf("http://127.0.0.1:$PORT") }

    fun attach(activity: Activity, root: ViewGroup) {
        val service = Intent(activity, DebugRemoteService::class.java)
        if (Build.VERSION.SDK_INT >= 26) activity.startForegroundService(service) else activity.startService(service)
        if (activity.checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED) {
            activity.requestPermissions(arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE, Manifest.permission.WRITE_EXTERNAL_STORAGE), 35565)
        }
        if (root is LinearLayout) {
            val control = TextView(activity).apply {
                text = "调试服务 :35565 · 连接信息"
                textSize = 13f
                setTextColor(0xffb8dfff.toInt())
                setPadding(16, 16, 16, 16)
                isClickable = true
                isFocusable = true
                setOnClickListener {
                    val info = "${addresses().joinToString("\n")}\n状态：$state\n\n访问令牌：\n${token()}"
                    AlertDialog.Builder(activity).setTitle("远程调试")
                        .setMessage(info).setPositiveButton("复制连接信息") { _, _ ->
                            val clipboard = activity.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                            clipboard.setPrimaryClip(ClipData.newPlainText("远程调试", info))
                        }.setNeutralButton("停止服务") { _, _ -> activity.stopService(service) }
                        .setNegativeButton("关闭", null).show()
                }
            }
            root.addView(control, 0, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        }
    }
}