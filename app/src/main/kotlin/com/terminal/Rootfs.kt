package com.terminal

import android.content.Context
import android.os.Build
import java.io.File
import java.io.FileOutputStream

/**
 * 创建 shell 使用的可写前缀。
 *
 * HOME 是 files/home，USR 是 files/usr。应用 targetSdk 为 28，低于
 * Android 10 对应用数据目录内 execve() 的限制，因此 dash 可以直接安装到
 * files/usr/bin 下执行。
 */
object Rootfs {
    fun ensure(context: Context): Layout {
        val files = context.filesDir
        val home = File(files, "home")
        val usr = File(files, "usr")
        val directories = listOf(
            home,
            File(usr, "bin"),
            File(usr, "sbin"),
            File(usr, "lib"),
            File(usr, "libexec"),
            File(usr, "include"),
            File(usr, "share/doc"),
            File(usr, "share/man"),
            File(usr, "share/terminfo"),
            File(usr, "share/locale"),
            File(usr, "opt"),
            File(usr, "etc/apt/sources.list.d"),
            File(usr, "etc/apt/apt.conf.d"),
            File(usr, "etc/apt/preferences.d"),
            File(usr, "etc/apt/trusted.gpg.d"),
            File(usr, "etc/dpkg/origins"),
            File(usr, "var/lib/apt/lists"),
            File(usr, "var/lib/apt/archives"),
            File(usr, "var/lib/dpkg/info"),
            File(usr, "var/lib/dpkg/updates"),
            File(usr, "var/cache/apt/archives/partial"),
            File(usr, "var/log/apt"),
            File(usr, "var/run"),
            File(usr, "var/tmp"),
            File(usr, "tmp"),
        )
        directories.forEach { it.mkdirs() }
        val shellFile = shell(context, usr)
        writeIfMissing(File(usr, "etc/passwd"), passwd(home, shellFile))
        writeIfMissing(File(usr, "etc/group"), group())
        writeIfMissing(File(usr, "etc/hosts"), hosts())
        writeIfMissing(File(usr, "etc/resolv.conf"), resolv())
        writeIfMissing(File(usr, "etc/profile"), profile(home, usr))
        writeIfMissing(File(usr, "etc/apt/sources.list"), "# package sources are added later\n")
        writeIfMissing(File(usr, "etc/apt/apt.conf"), aptConf(usr))
        writeIfMissing(File(usr, "etc/dpkg/dpkg.cfg"), "# dpkg is not installed yet\n")
        writeIfMissing(File(usr, "etc/dpkg/origins/terminal"), origins())
        writeIfMissing(File(usr, "var/lib/dpkg/status"), "")
        writeIfMissing(File(usr, "var/lib/dpkg/available"), "")
        writeIfMissing(File(usr, "var/log/dpkg.log"), "")
        File(usr, "tmp").setWritable(true, true)
        File(usr, "var/tmp").setWritable(true, true)
        return Layout(home, usr, shellFile)
    }

    fun environment(layout: Layout): Array<String> {
        val home = layout.home.absolutePath
        val usr = layout.usr.absolutePath
        val path = listOf(
            "$usr/bin",
            "$usr/sbin",
            "$usr/libexec",
            "/system/bin",
        ).joinToString(":")
        return arrayOf(
            "HOME=$home",
            "USR=$usr",
            "PREFIX=$usr",
            "TMPDIR=$usr/tmp",
            // dash -i 是交互式 shell，只读取 $ENV；没有这一项 /etc/profile 不会生效。
            "ENV=$usr/etc/profile",
            "SHELL=${layout.shell.absolutePath}",
            "PATH=$path",
            "LANG=C.UTF-8",
            "TERM=xterm-256color",
            "USER=terminal",
            "LOGNAME=terminal",
        )
    }

    private fun shell(context: Context, usr: File): File {
        val abi = Build.SUPPORTED_ABIS.firstOrNull() ?: "arm64-v8a"
        val asset = when {
            abi.startsWith("arm64") -> "bin/dash-arm64-v8a"
            abi.contains("armeabi") || abi.contains("arm") -> "bin/dash-armeabi-v7a"
            else -> throw IllegalStateException("unsupported ABI $abi")
        }
        val dash = File(usr, "bin/dash")
        val sh = File(usr, "bin/sh")
        install(context, asset, dash)
        if (!sh.isFile || sh.length() != dash.length()) {
            dash.copyTo(sh, overwrite = true)
        }
        sh.setReadable(true, false)
        sh.setExecutable(true, false)
        return sh
    }

    private fun install(context: Context, asset: String, destination: File) {
        destination.parentFile?.mkdirs()
        val temporary = File(destination.parentFile, destination.name + ".tmp")
        context.assets.open(asset).use { input ->
            FileOutputStream(temporary).use { output -> input.copyTo(output) }
        }
        // 始终覆盖安装：仅按文件长度比较无法感知同体积的新二进制。
        if (destination.exists()) destination.delete()
        if (!temporary.renameTo(destination)) {
            temporary.copyTo(destination, overwrite = true)
            temporary.delete()
        }
        destination.setReadable(true, false)
        destination.setExecutable(true, false)
    }

    private fun writeIfMissing(file: File, content: String) {
        if (!file.exists()) file.writeText(content)
    }

    private fun passwd(home: File, shell: File): String {
        return "terminal:x:0:0:terminal:${home.absolutePath}:${shell.absolutePath}\n"
    }

    private fun group(): String = "terminal:x:0:terminal\n"

    private fun hosts(): String = "127.0.0.1 localhost\n::1 localhost\n"

    private fun resolv(): String = "nameserver 8.8.8.8\nnameserver 1.1.1.1\n"

    private fun origins(): String = "Vendor: terminal\nLabel: terminal\n"

    private fun profile(home: File, usr: File): String {
        return listOf(
            "export HOME=${home.absolutePath}",
            "export USR=${usr.absolutePath}",
            "export PREFIX=\$USR",
            "export TMPDIR=\$USR/tmp",
            "export PATH=\$USR/bin:\$USR/sbin:\$USR/libexec:/system/bin",
            "export LANG=C.UTF-8",
            "export TERM=xterm-256color",
            "cd \"\$HOME\" || true",
        ).joinToString(separator = "\n", postfix = "\n")
    }

    private fun aptConf(usr: File): String {
        val root = usr.absolutePath
        return listOf(
            "Dir \"$root\";",
            "Dir::State \"$root/var/lib/apt\";",
            "Dir::State::lists \"$root/var/lib/apt/lists\";",
            "Dir::Cache \"$root/var/cache/apt\";",
            "Dir::Etc \"$root/etc/apt\";",
            "Dir::Log \"$root/var/log/apt\";",
            "Dir::Bin::Dpkg \"/system/bin/dpkg\";",
        ).joinToString(separator = "\n", postfix = "\n")
    }

    data class Layout(val home: File, val usr: File, val shell: File)
}