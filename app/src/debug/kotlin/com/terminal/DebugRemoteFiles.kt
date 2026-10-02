package com.terminal

import android.system.Os
import android.system.OsConstants
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.security.MessageDigest

internal class RemoteError(val status: Int, message: String) : Exception(message)

/** All file operations use the App UID and preserve logical /data/data paths. */
internal class DebugRemoteFiles {
    val roots = listOf(PrivatePaths.FILES, "/storage/emulated/0")
    private val canonicalRoots = roots.map { File(it).canonicalPath }

    fun path(value: String, followLeaf: Boolean = true): File {
        if (value.isBlank() || value.contains('\u0000')) throw RemoteError(400, "absolute path is required")
        var raw = PrivatePaths.migrateLegacyPaths(value)
        if (raw == "~") raw = PrivatePaths.HOME
        if (raw.startsWith("~/")) raw = PrivatePaths.HOME + raw.removePrefix("~")
        if (!raw.startsWith('/')) throw RemoteError(400, "absolute path is required")
        val segments = mutableListOf<String>()
        for (part in raw.split('/')) when (part) {
            "", "." -> Unit
            ".." -> if (segments.isNotEmpty()) segments.removeAt(segments.lastIndex)
            else -> segments.add(part)
        }
        val file = File("/" + segments.joinToString("/"))
        val actual = if (!followLeaf && isLink(file)) File(file.parentFile!!.canonicalFile, file.name).path else file.canonicalPath
        if (canonicalRoots.none { actual == it || actual.startsWith("$it/") }) {
            throw RemoteError(403, "path is outside the private files and external storage roots")
        }
        return file
    }

    fun isLink(file: File): Boolean = try { OsConstants.S_ISLNK(Os.lstat(file.path).st_mode) }
        catch (error: android.system.ErrnoException) {
            if (error.errno == OsConstants.ENOENT) false else throw error
        }
    private fun exists(file: File) = file.exists() || isLink(file)
    private fun protectRoot(file: File) {
        if (canonicalRoots.any { file.canonicalPath == it }) throw RemoteError(403, "cannot replace or delete a storage root")
    }

    fun metadata(file: File): JSONObject {
        val stat = Os.lstat(file.path)
        val kind = when {
            OsConstants.S_ISLNK(stat.st_mode) -> "symlink"
            OsConstants.S_ISDIR(stat.st_mode) -> "directory"
            OsConstants.S_ISREG(stat.st_mode) -> "file"
            else -> "other"
        }
        return JSONObject().put("name", file.name).put("path", file.path).put("type", kind)
            .put("size", stat.st_size).put("modified", file.lastModified())
            .put("uid", stat.st_uid).put("gid", stat.st_gid).put("mode", Integer.toOctalString(stat.st_mode and 0xfff))
            .put("readable", file.canRead()).put("writable", file.canWrite())
            .also { if (kind == "symlink") it.put("target", Os.readlink(file.path)) }
    }

    @Synchronized fun list(value: String, offset: Int, limit: Int): JSONObject {
        val directory = path(value)
        if (!directory.isDirectory) throw RemoteError(400, "path is not a directory")
        val children = directory.listFiles()?.sortedWith(compareBy<File> { !it.isDirectory }.thenBy { it.name })
            ?: throw RemoteError(403, "directory cannot be read by this App UID")
        val entries = JSONArray()
        children.drop(offset.coerceAtLeast(0)).take(limit.coerceIn(1, 1000)).forEach { entries.put(metadata(it)) }
        return JSONObject().put("path", directory.path).put("total", children.size).put("entries", entries)
    }

    fun read(value: String): File {
        val file = path(value, false)
        if (isLink(file)) throw RemoteError(409, "read the symlink target explicitly")
        if (!file.isFile) throw RemoteError(404, "regular file not found")
        if (!file.canRead()) throw RemoteError(403, "file cannot be read by this App UID")
        return file
    }

    fun hash(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        FileInputStream(file).use { input ->
            val buffer = ByteArray(65536)
            while (true) { val count = input.read(buffer); if (count < 0) break; digest.update(buffer, 0, count) }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    @Synchronized fun write(value: String, content: ByteArray, overwrite: Boolean, expectedHash: String?): JSONObject {
        val file = path(value, false)
        protectRoot(file)
        if (isLink(file) || file.isDirectory) throw RemoteError(409, "target is a symlink or directory")
        if (file.exists() && !overwrite) throw RemoteError(409, "target exists; set overwrite explicitly")
        if (expectedHash != null && (!file.isFile || hash(file) != expectedHash)) throw RemoteError(409, "file changed since it was read")
        val parent = path(file.parent ?: throw RemoteError(400, "missing parent path"), true)
        if (!parent.isDirectory) throw RemoteError(404, "parent directory does not exist")
        val temporary = File.createTempFile(".remote-write-", ".tmp", parent)
        try {
            FileOutputStream(temporary).use { output -> output.write(content); output.fd.sync() }
            if (file.path.startsWith(PrivatePaths.FILES + "/")) {
                val mode = if (file.isFile) Os.lstat(file.path).st_mode and 0x1ff else 0x180
                Os.chmod(temporary.path, mode)
            }
            if (isLink(file)) throw RemoteError(409, "target changed to a symlink")
            if (!temporary.renameTo(file)) throw RemoteError(403, "cannot install file in this directory")
            return metadata(file).put("sha256", hash(file))
        } finally { temporary.delete() }
    }

    @Synchronized fun mkdir(value: String): JSONObject {
        val directory = path(value, false)
        if (exists(directory)) throw RemoteError(409, "target already exists")
        if (!directory.mkdirs()) throw RemoteError(403, "cannot create directory")
        return metadata(directory)
    }

    @Synchronized fun delete(value: String, recursive: Boolean): JSONObject {
        val file = path(value, false)
        protectRoot(file)
        if (!exists(file)) throw RemoteError(404, "path not found")
        if (file.isDirectory && !isLink(file) && !recursive && file.list()?.isNotEmpty() == true) {
            throw RemoteError(409, "directory is not empty; set recursive explicitly")
        }
        removeTree(file)
        return JSONObject().put("deleted", file.path)
    }

    private fun removeTree(file: File) {
        path(file.path, false)
        if (!isLink(file) && file.isDirectory) {
            val children = file.listFiles() ?: throw RemoteError(403, "cannot list directory to delete")
            children.forEach(::removeTree)
        }
        if (!file.delete()) throw RemoteError(403, "cannot delete ${file.path}")
    }

    @Synchronized fun transfer(source: String, destination: String, move: Boolean): JSONObject {
        val src = path(source, false)
        val dst = path(destination, false)
        protectRoot(src); protectRoot(dst)
        if (!exists(src)) throw RemoteError(404, "source not found")
        if (exists(dst)) throw RemoteError(409, "destination exists; choose a new name")
        val srcActual = src.canonicalPath
        val dstActual = dst.canonicalPath
        if (srcActual == dstActual || dstActual.startsWith("$srcActual/")) throw RemoteError(400, "destination is inside the source")
        val parent = path(dst.parent ?: throw RemoteError(400, "missing parent path"), true)
        if (!parent.isDirectory) throw RemoteError(404, "destination parent does not exist")
        if (move && src.renameTo(dst)) return metadata(dst).put("source", src.path).put("moved", true)
        val temporary = File.createTempFile(".remote-copy-", ".tmp", parent)
        if (!temporary.delete()) throw RemoteError(500, "cannot prepare copy")
        try {
            val budget = intArrayOf(20000)
            copyTree(src, temporary, budget)
            if (exists(dst)) throw RemoteError(409, "destination appeared during the copy")
            if (!temporary.renameTo(dst)) throw RemoteError(403, "cannot install copied tree")
            // Only a fully copied and verified destination permits deleting the source.
            if (move) removeTree(src)
            return metadata(dst).put("source", src.path).put("moved", move)
        } finally {
            if (exists(temporary)) try { removeTree(temporary) } catch (_: Exception) { }
        }
    }

    private fun copyTree(src: File, dst: File, budget: IntArray) {
        if (--budget[0] < 0) throw RemoteError(413, "tree exceeds 20000 entries")
        path(src.path, false); path(dst.path, false)
        val stat = Os.lstat(src.path)
        when {
            OsConstants.S_ISLNK(stat.st_mode) -> Os.symlink(Os.readlink(src.path), dst.path)
            OsConstants.S_ISDIR(stat.st_mode) -> {
                if (!dst.mkdir()) throw RemoteError(403, "cannot create copied directory")
                val children = src.listFiles() ?: throw RemoteError(403, "cannot read source directory")
                children.forEach { copyTree(it, File(dst, it.name), budget) }
            }
            OsConstants.S_ISREG(stat.st_mode) -> {
                val digest = MessageDigest.getInstance("SHA-256")
                FileInputStream(src).use { input -> FileOutputStream(dst).use { output ->
                    val buffer = ByteArray(65536)
                    while (true) {
                        val count = input.read(buffer); if (count < 0) break
                        output.write(buffer, 0, count); digest.update(buffer, 0, count)
                    }
                    output.fd.sync()
                } }
                val beforeHash = digest.digest().joinToString("") { "%02x".format(it) }
                if (hash(dst) != beforeHash || hash(src) != beforeHash) throw RemoteError(409, "source changed or copy verification failed")
            }
            else -> throw RemoteError(400, "only regular files, directories and symlinks can be copied")
        }
        if (!OsConstants.S_ISLNK(stat.st_mode) && dst.path.startsWith(PrivatePaths.FILES + "/")) {
            Os.chmod(dst.path, stat.st_mode and 0x1ff)
        }
    }
}