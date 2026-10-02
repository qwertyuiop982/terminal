package com.terminal

import android.content.Context
import android.system.ErrnoException
import android.util.Base64
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.URI
import java.net.URLDecoder
import java.security.MessageDigest
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

/** Small HTTP/1.1 server built from platform APIs; no downloaded server dependency. */
internal class DebugRemoteServer(
    private val context: Context,
    private val layout: Rootfs.Layout,
    private val token: String,
) : AutoCloseable {
    private val listener = ServerSocket()
    private val files = DebugRemoteFiles()
    private val jobs = DebugRemoteJobs(layout, files)
    private val sockets = ConcurrentHashMap.newKeySet<Socket>()
    private val clients = ThreadPoolExecutor(8, 8, 0, TimeUnit.SECONDS, ArrayBlockingQueue(16))
    @Volatile private var closed = false

    fun start() {
        listener.reuseAddress = true
        listener.bind(InetSocketAddress("0.0.0.0", DebugFeatures.PORT), 16)
        Thread({
            while (!closed) {
                val socket = try { listener.accept() } catch (_: Exception) { break }
                socket.soTimeout = 15000
                sockets.add(socket)
                try { clients.execute { handle(socket) } }
                catch (_: java.util.concurrent.RejectedExecutionException) { sockets.remove(socket); socket.close() }
            }
        }, "debug-http-listener").also { it.isDaemon = true; it.start() }
    }

    private fun line(input: InputStream, max: Int): String {
        val bytes = java.io.ByteArrayOutputStream()
        while (true) {
            val next = input.read()
            if (next < 0) throw RemoteError(400, "incomplete HTTP headers")
            if (next == 10) break
            if (bytes.size() >= max) throw RemoteError(431, "HTTP headers exceed limit")
            bytes.write(next)
        }
        return bytes.toString("ISO-8859-1").removeSuffix("\r")
    }

    private fun handle(socket: Socket) {
        socket.use {
            val output = socket.getOutputStream()
            try {
                val input = BufferedInputStream(socket.getInputStream())
                val start = line(input, 4096).split(' ')
                if (start.size != 3 || !start[1].startsWith('/') || start[2] != "HTTP/1.1") throw RemoteError(400, "expected HTTP/1.1 request")
                val method = start[0]
                val uri = URI(start[1])
                val path = uri.path
                val headers = mutableMapOf<String, String>()
                var total = 0
                while (true) {
                    val header = line(input, 8192); if (header.isEmpty()) break
                    total += header.length
                    if (total > 16384) throw RemoteError(431, "HTTP headers exceed limit")
                    val key = header.substringBefore(':').lowercase()
                    if (!header.contains(':') || headers.containsKey(key)) throw RemoteError(400, "duplicate or invalid header")
                    headers[key] = header.substringAfter(':').trim()
                }
                if (path.startsWith("/api/")) {
                    val supplied = headers["authorization"]?.takeIf { it.startsWith("Bearer ") }?.removePrefix("Bearer ") ?: ""
                    if (!MessageDigest.isEqual(token.toByteArray(), supplied.toByteArray())) throw RemoteError(401, "valid Bearer token is required")
                    val origin = headers["origin"]
                    if (origin != null && origin != "http://${headers["host"]}") throw RemoteError(403, "cross-origin requests are disabled")
                }
                if (headers.containsKey("transfer-encoding")) throw RemoteError(400, "chunked requests are not supported; send Content-Length")
                val length = if (headers.containsKey("content-length")) {
                    headers["content-length"]?.toLongOrNull() ?: throw RemoteError(400, "invalid Content-Length")
                } else 0L
                if (length !in 0..(16 * 1024 * 1024).toLong()) throw RemoteError(413, "request body exceeds 16 MiB")
                val body = ByteArray(length.toInt())
                var count = 0
                while (count < body.size) {
                    val read = input.read(body, count, body.size - count)
                    if (read < 0) throw RemoteError(400, "incomplete request body")
                    count += read
                }
                val query = mutableMapOf<String, String>()
                uri.rawQuery?.split('&')?.forEach { pair ->
                    query[URLDecoder.decode(pair.substringBefore('='), "UTF-8")] = URLDecoder.decode(pair.substringAfter('=', ""), "UTF-8")
                }
                if (method == "GET" && path in listOf("/", "/remote.js")) {
                    val asset = if (path == "/") "index.html" else "remote.js"
                    val type = if (path == "/") "text/html; charset=utf-8" else "text/javascript; charset=utf-8"
                    bytes(output, 200, type, context.assets.open("debug-remote/$asset").use { it.readBytes() })
                } else if (method == "GET" && path == "/api/file") {
                    val file = files.read(query["path"] ?: "")
                    file.inputStream().use { fileInput ->
                        head(output, 200, "application/octet-stream", file.length())
                        fileInput.copyTo(output)
                    }
                } else if (method == "POST" && path == "/api/upload") {
                    json(output, 200, files.write(query["path"] ?: "", body, query["overwrite"] == "true", query["sha256"]))
                } else {
                    val data = if (body.isEmpty()) JSONObject() else JSONObject(String(body, Charsets.UTF_8))
                    val (status, result) = route(method, path, query, data)
                    json(output, status, result)
                }
            } catch (error: RemoteError) {
                try { json(output, error.status, JSONObject().put("error", error.message)) } catch (_: Exception) { }
            } catch (error: JSONException) {
                try { json(output, 400, JSONObject().put("error", "invalid JSON or missing field: ${error.message}")) } catch (_: Exception) { }
            } catch (error: Exception) {
                val status = if (error is SecurityException || error is ErrnoException || error is java.io.IOException) 403 else 400
                try { json(output, status, JSONObject().put("error", error.message ?: "request failed")) } catch (_: Exception) { }
            } finally { sockets.remove(socket) }
        }
    }

    private fun route(method: String, path: String, query: Map<String, String>, data: JSONObject): Pair<Int, JSONObject> {
        if (method == "GET" && path == "/api/status") return 200 to JSONObject()
            .put("uid", android.os.Process.myUid()).put("prefix", layout.usr.path).put("home", layout.home.path)
            .put("roots", JSONArray(files.roots)).put("addresses", JSONArray(DebugFeatures.addresses()))
            .put("externalReadable", java.io.File("/storage/emulated/0").canRead())
            .put("externalWritable", java.io.File("/storage/emulated/0").canWrite())
        if (method == "GET" && path == "/api/files") return 200 to files.list(
            query["path"] ?: layout.home.path, query["offset"]?.toIntOrNull() ?: 0, query["limit"]?.toIntOrNull() ?: 500,
        )
        if (method == "GET" && path == "/api/files/read") {
            val file = files.read(query["path"] ?: "")
            if (file.length() > 8 * 1024 * 1024) throw RemoteError(413, "editor read exceeds 8 MiB; use /api/file to download")
            val content = file.readBytes()
            return 200 to files.metadata(file).put("text", String(content, Charsets.UTF_8))
                .put("base64", Base64.encodeToString(content, Base64.NO_WRAP)).put("sha256", files.hash(file))
        }
        if (method == "GET" && path == "/api/permissions" || method == "POST" && path == "/api/permissions/repair") {
            val report = PrivatePermissions.audit(listOf(java.io.File(PrivatePaths.FILES).parentFile!!), repair = method == "POST")
            return 200 to JSONObject().put("directories", report.directories).put("repaired", JSONArray(report.repaired)).put("issues", JSONArray(report.issues))
        }
        if (method == "POST" && path == "/api/exec") return 202 to jobs.submit(data)
        if (path.startsWith("/api/jobs/")) {
            val id = path.removePrefix("/api/jobs/").substringBefore('/')
            if (!id.matches(Regex("[a-f0-9-]{36}"))) throw RemoteError(400, "invalid job id")
            if (method == "GET" && path == "/api/jobs/$id") return 200 to jobs.get(id)
            if (method == "POST" && path == "/api/jobs/$id/cancel") return 200 to jobs.cancel(id)
        }
        if (method == "POST") when (path) {
            "/api/files/write" -> {
                val content = if (data.has("base64")) Base64.decode(data.getString("base64"), Base64.DEFAULT)
                    else data.getString("text").toByteArray(Charsets.UTF_8)
                return 200 to files.write(data.getString("path"), content, data.optBoolean("overwrite", false), data.optString("sha256").takeIf { it.isNotEmpty() })
            }
            "/api/files/mkdir" -> return 200 to files.mkdir(data.getString("path"))
            "/api/files/delete" -> return 200 to files.delete(data.getString("path"), data.optBoolean("recursive", false))
            "/api/files/copy", "/api/files/move" -> return 200 to files.transfer(data.getString("source"), data.getString("destination"), path.endsWith("/move"))
        }
        throw RemoteError(404, "endpoint not found")
    }

    private fun head(output: OutputStream, status: Int, type: String, length: Long) {
        val reason = when (status) { 200 -> "OK"; 202 -> "Accepted"; 401 -> "Unauthorized"; 403 -> "Forbidden"; 404 -> "Not Found"; 409 -> "Conflict"; 413 -> "Content Too Large"; 429 -> "Too Many Requests"; else -> "Bad Request" }
        output.write(("HTTP/1.1 $status $reason\r\nContent-Type: $type\r\nContent-Length: $length\r\n" +
            "Connection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n" +
            "Content-Security-Policy: default-src 'self'; style-src 'unsafe-inline'; frame-ancestors 'none'\r\n\r\n").toByteArray(Charsets.US_ASCII))
    }
    private fun bytes(output: OutputStream, status: Int, type: String, body: ByteArray) { head(output, status, type, body.size.toLong()); output.write(body) }
    private fun json(output: OutputStream, status: Int, value: JSONObject) = bytes(output, status, "application/json; charset=utf-8", value.toString().toByteArray(Charsets.UTF_8))
    override fun close() {
        closed = true
        try { listener.close() } catch (_: Exception) { }
        sockets.forEach { try { it.close() } catch (_: Exception) { } }
        clients.shutdownNow(); jobs.close()
    }
}