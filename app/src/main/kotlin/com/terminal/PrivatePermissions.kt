package com.terminal

import android.os.Process
import android.system.Os
import android.system.OsConstants
import java.io.File
import java.io.IOException

/** Audit all private directories without following symlinks or granting another UID access. */
object PrivatePermissions {
    data class Report(val directories: Int, val repaired: List<String>, val issues: List<String>) {
        fun text(): String = buildString {
            append("uid=${Process.myUid()} directories=$directories repaired=${repaired.size} issues=${issues.size}\n")
            repaired.forEach { append("REPAIRED $it\n") }
            issues.forEach { append("ERROR $it\n") }
        }
    }

    fun audit(roots: List<File>, repair: Boolean): Report {
        var directories = 0
        val repaired = mutableListOf<String>()
        val issues = mutableListOf<String>()
        val pending = java.util.ArrayDeque<File>()
        pending.addAll(roots)
        while (pending.isNotEmpty()) {
            val directory = pending.removeFirst()
            try {
                val stat = Os.lstat(directory.absolutePath)
                if (OsConstants.S_ISLNK(stat.st_mode)) continue
                if (!OsConstants.S_ISDIR(stat.st_mode)) {
                    issues += "not a directory: ${directory.absolutePath}"
                    continue
                }
                directories++
                if (stat.st_uid != Process.myUid()) {
                    issues += "directory belongs to uid ${stat.st_uid}: ${directory.absolutePath}"
                    continue
                }
                if ((stat.st_mode and 0x1c0) != 0x1c0 && repair) {
                    Os.chmod(directory.absolutePath, (stat.st_mode and 0xfff) or 0x1c0)
                    repaired += directory.absolutePath
                }
                if (!Os.access(directory.absolutePath, OsConstants.R_OK or OsConstants.W_OK or OsConstants.X_OK)) {
                    issues += "directory lacks owner read/write/search access: ${directory.absolutePath}"
                    continue
                }
                val children = directory.listFiles()
                if (children == null) {
                    issues += "cannot list directory: ${directory.absolutePath}"
                    continue
                }
                children.forEach { child ->
                    val childStat = Os.lstat(child.absolutePath)
                    if (OsConstants.S_ISDIR(childStat.st_mode)) pending.add(child)
                }
            } catch (error: Exception) {
                issues += "${directory.absolutePath}: ${error.message}"
            }
        }
        return Report(directories, repaired, issues)
    }

    fun repairStateFiles(usr: File) {
        val fixed = listOf("status", "available", "status-old", "status-new", "lock", "lock-frontend")
        for (name in fixed) {
            val file = File(usr, "var/lib/dpkg/$name")
            val stat = try { Os.lstat(file.absolutePath) } catch (_: android.system.ErrnoException) { continue }
            if (!OsConstants.S_ISREG(stat.st_mode) || stat.st_uid != Process.myUid()) {
                throw IOException("dpkg state is not an App-owned regular file: $name")
            }
            if ((stat.st_mode and 0x180) != 0x180) {
                Os.chmod(file.absolutePath, (stat.st_mode and 0xfff) or 0x180)
            }
        }
    }
}