package com.terminal

import android.content.Context
import android.content.res.AssetManager
import android.net.ConnectivityManager
import android.os.Build
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.security.MessageDigest

/**
 * 创建 shell 使用的可写前缀。
 *
 * HOME 是 files/home，USR 是 files/usr。应用 targetSdk 为 28，低于
 * Android 10 对应用数据目录内 execve() 的限制，因此 dash 可以直接安装到
 * files/usr/bin 下执行。
 */
object Rootfs {
    private const val PREFIX_VERSION_FILE = "VERSION"
    private const val PREFIX_MANIFEST_FILE = "MANAGED_FILES"
    private const val PREFIX_MARKER_FILE = ".terminal-prefix-version"

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
            File(usr, "etc/apt/keyrings"),
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
        installPrefix(context, usr)
        val shellFile = shell(context, usr)
        writeIfMissing(File(usr, "etc/passwd"), passwd(home, shellFile))
        writeIfMissing(File(usr, "etc/group"), group())
        writeIfMissing(File(usr, "etc/hosts"), hosts())
        ensureResolver(context, usr)
        writeIfMissing(File(usr, "etc/profile"), profile(home, usr))
        migrateProfile(File(usr, "etc/profile"))
        writeIfMissing(File(usr, "etc/apt/sources.list"), "# package sources are added later\n")
        ensureAptConfig(usr)

        ensureDpkgConfig(usr)
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
        ).joinToString(":")
        return arrayOf(
            "HOME=$home",
            "USR=$usr",
            "PREFIX=$usr",
            "TMPDIR=$usr/tmp",
            "LD_LIBRARY_PATH=$usr/lib",
            "SSL_CERT_FILE=$usr/etc/ssl/cert.pem",
            "SSL_CERT_DIR=/apex/com.android.conscrypt/cacerts:/system/etc/security/cacerts",
            "TERMINFO=$usr/share/terminfo",
            "APT_CONFIG=$usr/etc/apt/apt.conf",
            "DPKG_ROOT=$usr",
            "DPKG_ADMINDIR=$usr/var/lib/dpkg",
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

    private fun installPrefix(context: Context, usr: File) {
        val abi = supportedAbi()
        val assetRoot = "prefix/$abi"
        val expectedVersion = try {
            context.assets.open("$assetRoot/$PREFIX_VERSION_FILE").bufferedReader().use { it.readText().trim() }
        } catch (_: IOException) {
            // The extension prefix is optional while the dash-only APK is usable.
            return
        }
        if (expectedVersion.isEmpty()) return

        val marker = File(usr, PREFIX_MARKER_FILE)
        val installedVersion = marker.takeIf { it.isFile }?.readText()?.trim()
        if (installedVersion == expectedVersion && prefixLooksComplete(usr)) {
            installBusyboxLinks(usr)
            return
        }

        val expectedFiles = context.assets.open("$assetRoot/$PREFIX_MANIFEST_FILE").bufferedReader().useLines { lines ->
            lines.map { it.substringAfter(' ', "") }.filter { it.isNotEmpty() }.toSet()
        }
        marker.delete()
        removeOldManagedFiles(usr)
        File(usr, PREFIX_MANIFEST_FILE).delete()
        extractAssetTree(context.assets, assetRoot, usr, assetRoot, expectedFiles)
        if (!prefixLooksComplete(usr)) throw IOException("incomplete APK prefix assets")
        installBusyboxLinks(usr)
        marker.writeText("$expectedVersion\n")
    }

    private fun prefixLooksComplete(usr: File): Boolean {
        val manifest = File(usr, PREFIX_MANIFEST_FILE)
        if (!manifest.isFile) return false
        val managed = manifest.useLines { lines ->
            lines.mapNotNull { line ->
                val separator = line.indexOf(' ')
                if (separator > 0) line.substring(separator + 1) else null
            }.toSet()
        }
        val required = listOf(
            "bin/dpkg",
            "bin/dpkg-realpath",
            "share/dpkg/sh/dpkg-error.sh",
            "bin/busybox",
            "bin/openssl",
            "etc/ssl/cert.pem",
            "bin/file",
            "lib/libmagic.so",
            "share/busybox/applets",
            "share/misc/magic.mgc",
        )
        return required.all { it in managed } && managed.all { relative ->
            val file = File(usr, relative)
            file.isFile && !isSymbolicLink(file)
        }
    }

    private fun removeOldManagedFiles(usr: File) {
        val manifest = File(usr, PREFIX_MANIFEST_FILE)
        if (!manifest.isFile) return // Legacy installs had no inventory: preserve their contents.
        val packageOwned = dpkgOwnedPaths(usr)
        val root = try {
            usr.canonicalFile
        } catch (_: IOException) {
            return
        }
        val rootPrefix = root.path + File.separator
        manifest.forEachLine { line ->
            val separator = line.indexOf(' ')
            if (separator != 64) return@forEachLine
            val hash = line.substring(0, separator)
            val relative = line.substring(separator + 1)
            if (!hash.matches(Regex("[0-9a-f]{64}")) || relative.isEmpty() ||
                relative in packageOwned) return@forEachLine
            val path = File(root, relative)
            val canonical = try {
                path.canonicalFile
            } catch (_: IOException) {
                return@forEachLine
            }
            if (!canonical.path.startsWith(rootPrefix) || isSymbolicLink(path) || !canonical.isFile) {
                return@forEachLine
            }
            val digest = MessageDigest.getInstance("SHA-256")
            canonical.inputStream().use { input ->
                val buffer = ByteArray(8192)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    digest.update(buffer, 0, count)
                }
            }
            if (digest.digest().joinToString("") { "%02x".format(it) } == hash) {
                canonical.delete()
            }
        }
    }

    private fun dpkgOwnedPaths(usr: File): Set<String> {
        val info = File(usr, "var/lib/dpkg/info")
        return info.listFiles { file -> file.isFile && file.name.endsWith(".list") && !isSymbolicLink(file) }
            ?.flatMap { list ->
                list.useLines { lines ->
                    lines.filter { it.startsWith('/') }.map { it.removePrefix("/") }.toList()
                }
            }?.toSet().orEmpty()
    }

    private fun isSymbolicLink(file: File): Boolean = try {
        OsConstants.S_ISLNK(Os.lstat(file.absolutePath).st_mode)
    } catch (_: Exception) {
        false
    }

    private fun readSymbolicLink(file: File): String? = try {
        Os.readlink(file.absolutePath)
    } catch (_: Exception) {
        null
    }

    private fun installBusyboxLinks(usr: File) {
        val busybox = File(usr, "bin/busybox")
        val manifest = File(usr, "share/busybox/applets")
        if (!busybox.isFile || !manifest.isFile) return
        val bin = File(usr, "bin")
        manifest.forEachLine { name ->
            if (!name.matches(Regex("[a-z0-9-]+"))) return@forEachLine
            val link = File(bin, name)
            if (readSymbolicLink(link) == "busybox") return@forEachLine
            if (!link.exists() && !isSymbolicLink(link)) Os.symlink("busybox", link.absolutePath)
        }
    }

    private fun extractAssetTree(
        assets: AssetManager,
        assetPath: String,
        destination: File,
        rootAssetPath: String,
        expectedFiles: Set<String>,
    ) {
        val entries = assets.list(assetPath).orEmpty()
        destination.mkdirs()
        entries.forEach { name ->
            if (assetPath == rootAssetPath && name == PREFIX_VERSION_FILE) return@forEach
            val childAsset = "$assetPath/$name"
            val target = File(destination, name)
            val children = assets.list(childAsset).orEmpty()
            if (children.isNotEmpty()) {
                extractAssetTree(assets, childAsset, target, rootAssetPath, expectedFiles)
            } else if (name == PREFIX_MANIFEST_FILE ||
                childAsset.removePrefix("$rootAssetPath/") in expectedFiles) {
                copyAsset(assets, childAsset, target)
            } else {
                target.mkdirs()
            }
        }
    }

    private fun copyAsset(assets: AssetManager, assetPath: String, destination: File) {
        if (destination.exists() || isSymbolicLink(destination)) return
        destination.parentFile?.mkdirs()
        val temporary = File.createTempFile(".${destination.name}.", ".tmp", destination.parentFile)
        try {
            assets.open(assetPath).use { input ->
                FileOutputStream(temporary).use { output -> input.copyTo(output) }
            }
            temporary.setReadable(true, true)
            if (assetPath.matches(Regex("prefix/[^/]+/(bin|sbin|libexec)/.+"))) {
                temporary.setExecutable(true, true)
            }
            try {
                Os.link(temporary.absolutePath, destination.absolutePath)
            } catch (error: ErrnoException) {
                if (error.errno != OsConstants.EEXIST) throw IOException("cannot install $assetPath", error)
            }
        } finally {
            temporary.delete()
        }
    }

    private fun supportedAbi(): String {
        val abi = Build.SUPPORTED_ABIS.firstOrNull() ?: "arm64-v8a"
        return when {
            abi.startsWith("arm64") -> "arm64-v8a"
            abi.contains("armeabi") || abi.contains("arm") -> "armeabi-v7a"
            else -> throw IllegalStateException("unsupported ABI $abi")
        }
    }

    private fun shell(context: Context, usr: File): File {
        val asset = when (supportedAbi()) {
            "arm64-v8a" -> "bin/dash-arm64-v8a"
            else -> "bin/dash-armeabi-v7a"
        }
        val dash = File(usr, "bin/dash")
        val sh = File(usr, "bin/sh")
        val packageOwned = dpkgOwnedPaths(usr)
        if ("bin/dash" in packageOwned || "bin/sh" in packageOwned) {
            throw IOException("a package owns the app-managed shell; remove the conflicting package")
        }
        install(context, asset, dash)
        if (!sh.isFile || !sh.readBytes().contentEquals(dash.readBytes())) {
            dash.copyTo(sh, overwrite = true)
        }
        sh.setReadable(true, true)
        sh.setExecutable(true, true)
        return sh
    }

    private fun install(context: Context, asset: String, destination: File) {
        destination.parentFile?.mkdirs()
        val temporary = File.createTempFile(".${destination.name}.", ".tmp", destination.parentFile)
        try {
            context.assets.open(asset).use { input ->
                FileOutputStream(temporary).use { output -> input.copyTo(output) }
            }
            temporary.setReadable(true, true)
            temporary.setExecutable(true, true)
            if (!temporary.renameTo(destination)) throw IOException("cannot update $asset")
        } finally {
            temporary.delete()
        }
    }

    private fun writeIfMissing(file: File, content: String) {
        if (!file.exists()) {
            file.parentFile?.mkdirs()
            file.writeText(content)
        }
    }

    private fun passwd(home: File, shell: File): String {
        return "terminal:x:0:0:terminal:${home.absolutePath}:${shell.absolutePath}\n"
    }

    private fun group(): String = "terminal:x:0:terminal\n"

    private fun hosts(): String = "127.0.0.1 localhost\n::1 localhost\n"

    private fun resolv(): String = "nameserver 8.8.8.8\nnameserver 1.1.1.1\n"

    private fun origins(): String = "Vendor: terminal\nLabel: terminal\n"

    private fun ensureResolver(context: Context, usr: File) {
        val config = File(usr, "etc/resolv.conf")
        val managed = File(usr, "etc/.resolv.conf.managed")
        val servers = try {
            val connectivity = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            connectivity?.activeNetwork?.let { connectivity.getLinkProperties(it) }
                ?.dnsServers?.mapNotNull { it.hostAddress?.substringBefore('%') }?.distinct().orEmpty()
        } catch (_: SecurityException) {
            emptyList()
        }
        if (servers.isEmpty()) {
            writeIfMissing(config, resolv())
            return
        }
        val updated = servers.joinToString(separator = "\n", postfix = "\n") { "nameserver $it" }
        if (!config.exists() || config.readText() == resolv() ||
            (managed.isFile && config.readText() == managed.readText())) {
            config.writeText(updated)
            managed.writeText(updated)
        }
    }

    private fun profile(home: File, usr: File): String {
        return listOf(
            "export HOME=${home.absolutePath}",
            "export USR=${usr.absolutePath}",
            "export PREFIX=\$USR",
            "export TMPDIR=\$USR/tmp",
            "export LD_LIBRARY_PATH=\$USR/lib",
            "export TERMINFO=\$USR/share/terminfo",
            "export PATH=\$USR/bin:\$USR/sbin:\$USR/libexec",
            "export LANG=C.UTF-8",
            "export TERM=xterm-256color",
            "cd \"\$HOME\" || true",
        ).joinToString(separator = "\n", postfix = "\n")
    }

    private fun migrateProfile(file: File) {
        if (!file.isFile) return
        val original = file.readText()
        val updated = original.replace("\$USR/libexec:/system/bin", "\$USR/libexec")
        if (updated != original) file.writeText(updated)
    }

    private fun ensureDpkgConfig(usr: File) {
        val file = File(usr, "etc/dpkg/dpkg.cfg")
        val admindir = File(usr, "var/lib/dpkg").absolutePath
        val logFile = File(usr, "var/log/dpkg.log").absolutePath
        val current = if (file.isFile) file.readText() else ""
        if (!file.isFile || current.contains("dpkg is not installed yet")) {
            file.parentFile?.mkdirs()
            file.writeText("admindir $admindir\ninstdir ${usr.absolutePath}\nlog $logFile\nforce-script-chrootless\nforce-not-root\n")
            return
        }
        replaceConfigLines(
            file,
            listOf(
                "admindir" to "admindir $admindir",
                "instdir" to "instdir ${usr.absolutePath}",
                "log" to "log $logFile",
                "force-script-chrootless" to "force-script-chrootless",
                "force-not-root" to "force-not-root",
            ),
        )
    }

    private fun ensureAptConfig(usr: File) {
        val file = File(usr, "etc/apt/apt.conf")
        if (!file.isFile) {
            file.parentFile?.mkdirs()
            file.writeText(aptConf(usr))
            return
        }
        val root = usr.absolutePath
        replaceConfigLines(
            file,
            listOf(
                "Dir" to "Dir \"$root\";",
                "Dir::State" to "Dir::State \"$root/var/lib/apt\";",
                "Dir::State::lists" to "Dir::State::lists \"$root/var/lib/apt/lists\";",
                "Dir::State::status" to "Dir::State::status \"$root/var/lib/dpkg/status\";",
                "Dir::Cache" to "Dir::Cache \"$root/var/cache/apt\";",
                "Dir::Etc" to "Dir::Etc \"$root/etc/apt\";",
                "Dir::Log" to "Dir::Log \"$root/var/log/apt\";",
                "Dir::Bin::methods" to "Dir::Bin::methods \"$root/libexec/apt/methods\";",
                "Dir::Bin::apt-key" to "Dir::Bin::apt-key \"$root/bin/apt-key\";",
                "Dir::Bin::Dpkg" to "Dir::Bin::Dpkg \"$root/bin/dpkg\";",
                "DPkg::Path" to "DPkg::Path \"$root/bin:$root/sbin:$root/libexec\";",
                "APT::Sandbox::User" to "APT::Sandbox::User \"\";",
            ),
        )
    }

    private fun replaceConfigLines(file: File, replacements: List<Pair<String, String>>) {
        val original = if (file.isFile) file.readText() else ""
        val lines = if (original.isBlank()) {
            mutableListOf()
        } else {
            original.lineSequence().toMutableList()
        }
        replacements.forEach { (key, replacement) ->
            val index = lines.indexOfFirst { candidate ->
                val trimmed = candidate.trim()
                !trimmed.startsWith("#") &&
                    (trimmed == key ||
                        trimmed.startsWith("$key ") ||
                        trimmed.startsWith("$key\t") ||
                        trimmed.startsWith("$key="))
            }
            if (index >= 0) {
                lines[index] = replacement
            } else {
                lines += replacement
            }
        }
        val updated = lines.joinToString("\n").trimEnd() + "\n"
        if (!file.isFile || original != updated) {
            file.parentFile?.mkdirs()
            file.writeText(updated)
        }
    }

    private fun aptConf(usr: File): String {
        val root = usr.absolutePath
        return listOf(
            "Dir \"$root\";",
            "Dir::State \"$root/var/lib/apt\";",
            "Dir::State::lists \"$root/var/lib/apt/lists\";",
            "Dir::State::status \"$root/var/lib/dpkg/status\";",
            "Dir::Cache \"$root/var/cache/apt\";",
            "Dir::Etc \"$root/etc/apt\";",
            "Dir::Log \"$root/var/log/apt\";",
            "Dir::Bin::methods \"$root/libexec/apt/methods\";",
            "Dir::Bin::apt-key \"$root/bin/apt-key\";",
            "Dir::Bin::Dpkg \"$root/bin/dpkg\";",
            "DPkg::Path \"$root/bin:$root/sbin:$root/libexec\";",
            "APT::Sandbox::User \"\";",
        ).joinToString(separator = "\n", postfix = "\n")
    }

    data class Layout(val home: File, val usr: File, val shell: File)
}