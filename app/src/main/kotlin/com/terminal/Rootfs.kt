package com.terminal

import android.content.Context
import android.content.res.AssetManager
import android.net.ConnectivityManager
import android.os.Build
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
    private const val SHELL_MARKER_FILE = ".terminal-shell-version"
    private val sha256Pattern = Regex("[0-9a-f]{64}")

    @Synchronized
    fun ensure(context: Context): Layout {
        val files = runtimeFiles(context)
        val home = File(files, "home")
        val usr = File(files, "usr")
        for (root in listOf(home, usr)) {
            if (isSymbolicLink(root)) throw IOException("private root is a symbolic link: $root")
            if (!root.isDirectory && !root.mkdirs()) throw IOException("cannot create private directory: $root")
        }
        val before = PrivatePermissions.audit(listOf(files.parentFile!!), repair = true)
        if (before.issues.isNotEmpty()) throw IOException(before.issues.joinToString("; "))
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
        directories.forEach { directory ->
            if (directory != home) prefixTarget(usr, directory.relativeTo(usr).invariantSeparatorsPath)
            if (!directory.isDirectory && !directory.mkdirs()) throw IOException("cannot create private directory: $directory")
        }
        installPrefix(context, usr)
        val shellFile = shell(context, usr)
        writeIfMissing(File(usr, "etc/passwd"), passwd(home, shellFile))
        writeIfMissing(File(usr, "etc/group"), group())
        writeIfMissing(File(usr, "etc/hosts"), hosts())
        ensureResolver(context, usr)
        writeIfMissing(File(usr, "etc/profile"), profile(home, usr))
        migrateLegacyConfigPaths(usr)
        migrateProfile(File(usr, "etc/profile"))
        writeIfMissing(File(usr, "etc/apt/sources.list"), "# package sources are added later\n")
        ensureAptConfig(usr)

        ensureDpkgConfig(usr)
        writeIfMissing(File(usr, "etc/dpkg/origins/terminal"), origins())
        writeIfMissing(File(usr, "var/lib/dpkg/status"), "")
        writeIfMissing(File(usr, "var/lib/dpkg/available"), "")
        writeIfMissing(File(usr, "var/log/dpkg.log"), "")
        PrivatePermissions.repairStateFiles(usr)
        val after = PrivatePermissions.audit(listOf(files.parentFile!!), repair = true)
        val report = PrivatePermissions.Report(after.directories, before.repaired + after.repaired, after.issues)
        writeConfigAtomically(File(usr, "var/log/terminal-permissions.log"), report.text())
        if (report.issues.isNotEmpty()) throw IOException(report.issues.joinToString("; "))
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
            "PWD=$home",
            "USR=$usr",
            "PREFIX=$usr",
            "TMPDIR=$usr/tmp",
            "LD_LIBRARY_PATH=$usr/lib",
            "SSL_CERT_FILE=$usr/etc/ssl/cert.pem",
            "SSL_CERT_DIR=/apex/com.android.conscrypt/cacerts:/system/etc/security/cacerts",
            "TERMINFO=$usr/share/terminal/terminfo",
            "TERMINFO_DIRS=$usr/share/terminal/terminfo:$usr/share/terminfo",
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

    private fun runtimeFiles(context: Context): File {
        if (context.packageName != PrivatePaths.PACKAGE_NAME) {
            throw IOException("application package does not match the compiled private prefix")
        }
        val appFiles = context.filesDir
        val files = File(PrivatePaths.FILES)
        try {
            val actual = Os.stat(appFiles.absolutePath)
            val preferred = Os.stat(files.absolutePath)
            if (actual.st_dev != preferred.st_dev || actual.st_ino != preferred.st_ino) {
                throw IOException("/data/data prefix does not belong to this Android user")
            }
        } catch (e: android.system.ErrnoException) {
            throw IOException("cannot access this application's /data/data prefix", e)
        }
        return files
    }

    private fun migrateLegacyConfigPaths(usr: File) {
        val files = mutableListOf(
            File(usr, "etc/profile"),
            File(usr, "etc/passwd"),
            File(usr, "etc/dpkg/dpkg.cfg"),
        )
        File(usr, "etc/apt").listFiles()?.filter {
            it.name == "apt.conf" || it.name.startsWith("sources.list")
        }?.let(files::addAll)
        File(usr, "etc/apt/sources.list.d").listFiles()?.filter {
            it.name.endsWith(".list") || it.name.endsWith(".sources")
        }?.let(files::addAll)
        for (directory in listOf("etc/apt/apt.conf.d", "etc/dpkg/dpkg.cfg.d")) {
            File(usr, directory).listFiles()?.let { entries -> files.addAll(entries) }
        }
        for (file in files) {
            if (!file.isFile || isSymbolicLink(file)) continue
            val relative = file.relativeTo(usr).invariantSeparatorsPath
            prefixTarget(usr, relative)
            val original = file.readText()
            val updated = PrivatePaths.migrateLegacyPaths(original)
            if (updated == original) continue
            // Keep the original outside apt's configuration directories so it is
            // neither overwritten nor loaded as a second source/config fragment.
            val backup = prefixTarget(usr, "var/backups/terminal-paths/$relative")
            if (isSymbolicLink(backup)) throw IOException("config backup is a symbolic link: $relative")
            if (!backup.exists()) {
                backup.parentFile?.mkdirs()
                writeConfigAtomically(backup, original)
            }
            writeConfigAtomically(file, updated)
        }
    }

    private fun writeConfigAtomically(file: File, contents: String) {
        if (isSymbolicLink(file)) throw IOException("config is a symbolic link: ${file.name}")
        val mode = if (file.exists()) Os.stat(file.absolutePath).st_mode and 0x1ff else 0x180
        val temporary = File.createTempFile(".config-", ".tmp", file.parentFile)
        try {
            FileOutputStream(temporary).use { output ->
                output.write(contents.toByteArray(Charsets.UTF_8))
                output.fd.sync()
            }
            Os.chmod(temporary.absolutePath, mode)
            if (!temporary.renameTo(file)) throw IOException("cannot migrate private config: ${file.name}")
        } finally {
            temporary.delete()
        }
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

        val manifestAsset = "$assetRoot/$PREFIX_MANIFEST_FILE"
        val manifestContents = context.assets.open(manifestAsset).bufferedReader().use { it.readText() }
        val expectedFiles = parseAssetManifest(manifestContents)
        val manifest = File(usr, PREFIX_MANIFEST_FILE)
        val marker = File(usr, PREFIX_MARKER_FILE)
        val installedVersion = marker.takeIf { it.isFile && !isSymbolicLink(it) }?.readText()?.trim()
        if (installedVersion == expectedVersion && manifest.isFile && !isSymbolicLink(manifest) &&
            manifest.readText() == manifestContents && prefixLooksComplete(usr, expectedFiles.keys)) {
            installBusyboxLinks(usr)
            return
        }

        // Keep the previous inventory until the new assets are complete. A failed upgrade
        // must be retryable without losing track of which old files belonged to the APK.
        removeOldManagedFiles(usr, expectedFiles)
        val localConfigs = setOf("etc/dpkg/dpkg.cfg", "etc/apt/apt.conf", "etc/apt/sources.list",
            "etc/resolv.conf", "etc/profile", "etc/passwd", "etc/group", "etc/hosts")
        expectedFiles.forEach { (relative, hash) ->
            val target = prefixTarget(usr, relative)
            // Runtime/user config edits survive a binary-only APK upgrade.
            if (relative in localConfigs && target.isFile && !isSymbolicLink(target)) return@forEach
            copyAsset(context.assets, "$assetRoot/$relative", target, hash)
        }
        if (!prefixLooksComplete(usr, expectedFiles.keys)) throw IOException("incomplete APK prefix assets")
        installBusyboxLinks(usr)
        install(context, manifestAsset, manifest)
        writeVersionMarker(marker, expectedVersion)
    }

    private fun parseAssetManifest(contents: String): Map<String, String> {
        val managed = LinkedHashMap<String, String>()
        contents.lineSequence().filter { it.isNotEmpty() }.forEach { line ->
            val separator = line.indexOf(' ')
            val relative = line.substringAfter(' ', "")
            if (separator != 64 || !line.substring(0, separator).matches(sha256Pattern) ||
                !safeRelativePath(relative) || relative == PREFIX_MANIFEST_FILE ||
                relative == PREFIX_VERSION_FILE || managed.put(relative, line.substring(0, separator)) != null) {
                throw IOException("invalid APK prefix manifest")
            }
        }
        if (managed.isEmpty()) throw IOException("empty APK prefix manifest")
        return managed
    }

    private fun safeRelativePath(relative: String): Boolean =
        relative.isNotEmpty() && !relative.contains('\\') && !relative.contains('\u0000') &&
            relative.split('/').all { it.isNotEmpty() && it != "." && it != ".." }

    private fun prefixTarget(usr: File, relative: String): File {
        val target = File(usr, relative)
        val root = usr.canonicalPath
        val parent = target.parentFile?.canonicalPath
        if (parent == null || (parent != root && !parent.startsWith("$root/"))) {
            throw IOException("prefix asset escapes private directory: $relative")
        }
        return target
    }

    private fun prefixLooksComplete(usr: File, managed: Set<String>): Boolean {
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

    private fun writeVersionMarker(marker: File, version: String) {
        val temporary = File.createTempFile(".prefix-version.", ".tmp", marker.parentFile)
        try {
            temporary.writeText("$version\n")
            if (!temporary.renameTo(marker)) throw IOException("cannot update APK prefix version")
        } finally {
            temporary.delete()
        }
    }

    private fun removeOldManagedFiles(usr: File, expectedFiles: Map<String, String>) {
        val manifest = File(usr, PREFIX_MANIFEST_FILE)
        if (!manifest.isFile || isSymbolicLink(manifest)) return // Preserve legacy installs and invalid inventories.
        val packageOwned = dpkgOwnedPaths(usr)
        val rootPrefix = try {
            usr.canonicalPath + File.separator
        } catch (_: IOException) {
            return
        }
        manifest.forEachLine { line ->
            val separator = line.indexOf(' ')
            if (separator != 64) return@forEachLine
            val hash = line.substring(0, separator)
            val relative = line.substring(separator + 1)
            if (!hash.matches(sha256Pattern) || !safeRelativePath(relative) ||
                relative in packageOwned || expectedFiles[relative] == hash) return@forEachLine
            val path = File(usr, relative)
            val canonical = try {
                path.canonicalFile
            } catch (_: IOException) {
                return@forEachLine
            }
            if (!canonical.path.startsWith(rootPrefix) || isSymbolicLink(path) || !path.isFile) {
                return@forEachLine
            }
            val digest = MessageDigest.getInstance("SHA-256")
            path.inputStream().use { input ->
                val buffer = ByteArray(8192)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    digest.update(buffer, 0, count)
                }
            }
            if (digest.digest().joinToString("") { "%02x".format(it) } == hash) {
                path.delete()
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

    private fun copyAsset(assets: AssetManager, assetPath: String, destination: File, expectedHash: String) {
        if (destination.exists() || isSymbolicLink(destination)) {
            if (isSymbolicLink(destination) || !fileHash(destination).equals(expectedHash, ignoreCase = true)) {
                throw IOException("APK asset conflicts with existing file: ${destination.relativeTo(destination.parentFile?.parentFile ?: destination)}")
            }
            return
        }
        destination.parentFile?.mkdirs()
        val temporary = File.createTempFile(".${destination.name}.", ".tmp", destination.parentFile)
        try {
            val digest = MessageDigest.getInstance("SHA-256")
            assets.open(assetPath).use { input ->
                FileOutputStream(temporary).use { output ->
                    val buffer = ByteArray(8192)
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        digest.update(buffer, 0, count)
                        output.write(buffer, 0, count)
                    }
                }
            }
            if (digest.digest().joinToString("") { "%02x".format(it) } != expectedHash) {
                throw IOException("APK asset checksum mismatch: $assetPath")
            }
            temporary.setReadable(true, true)
            if (assetPath.substringAfter("prefix/").substringAfter('/').let {
                    it.startsWith("bin/") || it.startsWith("sbin/") || it.startsWith("libexec/")
                }) {
                temporary.setExecutable(true, true)
            }
            // Android denies hard links in app data on some devices. rename is atomic on
            // this private filesystem; check again before it so existing files stay intact.
            if (destination.exists() || isSymbolicLink(destination)) return
            if (!temporary.renameTo(destination)) throw IOException("cannot install $assetPath")
        } finally {
            temporary.delete()
        }
    }

    private fun fileHash(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(8192)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
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
        val expectedHash = assetHash(context, asset)
            ?: throw IOException("missing verified shell checksum: $asset")
        val dash = File(usr, "bin/dash")
        val sh = File(usr, "bin/sh")
        val marker = File(usr, SHELL_MARKER_FILE)
        val packageOwned = dpkgOwnedPaths(usr)
        if ("bin/dash" in packageOwned || "bin/sh" in packageOwned) {
            throw IOException("a package owns the app-managed shell; remove the conflicting package")
        }
        if (marker.isFile && !isSymbolicLink(marker) &&
            marker.readText().trim() == expectedHash && dash.isFile && !isSymbolicLink(dash) &&
            sh.isFile && !isSymbolicLink(sh)) {
            sh.setReadable(true, true)
            sh.setExecutable(true, true)
            return sh
        }
        install(context, asset, dash, expectedHash)
        install(context, asset, sh, expectedHash)
        writeVersionMarker(marker, expectedHash)
        sh.setReadable(true, true)
        sh.setExecutable(true, true)
        return sh
    }

    private fun assetHash(context: Context, asset: String): String? {
        val name = asset.substringAfterLast('/')
        return try {
            context.assets.open("bin/SHA256SUMS").bufferedReader().useLines { lines ->
                lines.mapNotNull { line ->
                    val fields = line.trim().split(Regex("\\s+"), limit = 2)
                    if (fields.size == 2 && fields[1] == name && fields[0].matches(sha256Pattern)) {
                        fields[0]
                    } else null
                }.firstOrNull()
            }
        } catch (_: IOException) {
            null
        }
    }

    private fun install(context: Context, asset: String, destination: File, expectedHash: String? = null) {
        destination.parentFile?.mkdirs()
        val temporary = File.createTempFile(".${destination.name}.", ".tmp", destination.parentFile)
        try {
            val digest = MessageDigest.getInstance("SHA-256")
            context.assets.open(asset).use { input ->
                FileOutputStream(temporary).use { output ->
                    val buffer = ByteArray(8192)
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        digest.update(buffer, 0, count)
                        output.write(buffer, 0, count)
                    }
                }
            }
            if (expectedHash != null &&
                digest.digest().joinToString("") { "%02x".format(it) } != expectedHash) {
                throw IOException("APK asset checksum mismatch: $asset")
            }
            temporary.setReadable(true, true)
            if (asset.startsWith("bin/")) temporary.setExecutable(true, true)
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
            "export TERMINFO=\$USR/share/terminal/terminfo",
            "export TERMINFO_DIRS=\$USR/share/terminal/terminfo:\$USR/share/terminfo",
            "if [ -r \"\$TERMINFO/x/xterm-256color\" ]; then set -o emacs; fi",
            "export PATH=\$USR/bin:\$USR/sbin:\$USR/libexec",
            "export LANG=C.UTF-8",
            "export TERM=xterm-256color",
            "cd \"\$HOME\" || true",
        ).joinToString(separator = "\n", postfix = "\n")
    }

    private fun migrateProfile(file: File) {
        if (!file.isFile) return
        val original = file.readText()
        var updated = original.replace("\$USR/libexec:/system/bin", "\$USR/libexec")
            .replace(
                "export TERMINFO=\$USR/share/terminfo\n",
                "export TERMINFO=\$USR/share/terminal/terminfo\n" +
                    "export TERMINFO_DIRS=\$USR/share/terminal/terminfo:\$USR/share/terminfo\n",
            )
        val terminfoLine = "export TERMINFO_DIRS=\$USR/share/terminal/terminfo:\$USR/share/terminfo\n"
        if (!updated.contains("set -o emacs") && updated.contains(terminfoLine)) {
            updated = updated.replace(
                terminfoLine,
                terminfoLine + "if [ -r \"\$TERMINFO/x/xterm-256color\" ]; then set -o emacs; fi\n",
            )
        }
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