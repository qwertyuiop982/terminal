package com.terminal

import android.system.Os
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.InputStream
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit

/** Concurrent, bounded jobs: pipe readers always drain stdout/stderr, even after the output cap. */
internal class DebugRemoteJobs(private val layout: Rootfs.Layout, private val files: DebugRemoteFiles) : AutoCloseable {
    private val executor = Executors.newFixedThreadPool(4)
    private val watchdog = Executors.newSingleThreadScheduledExecutor()
    private val slots = Semaphore(4)
    private val jobs = ConcurrentHashMap<String, Job>()
    @Volatile private var closed = false

    private class Output {
        private val buffer = ByteArrayOutputStream()
        @Volatile var truncated = false
        @Synchronized fun append(bytes: ByteArray, count: Int) {
            val available = (2 * 1024 * 1024 - buffer.size()).coerceAtLeast(0)
            buffer.write(bytes, 0, count.coerceAtMost(available))
            if (count > available) truncated = true
        }
        @Synchronized fun text(): String = buffer.toString("UTF-8")
    }
    private class Job(val id: String) {
        val started = System.currentTimeMillis()
        val stdout = Output()
        val stderr = Output()
        @Volatile var process: Process? = null
        @Volatile var exitCode: Int? = null
        @Volatile var timedOut = false
        @Volatile var cancelled = false
        @Volatile var finished: Long? = null
        fun json(): JSONObject = JSONObject().put("id", id).put("started", started)
            .put("finished", finished ?: JSONObject.NULL).put("running", finished == null)
            .put("exitCode", exitCode ?: JSONObject.NULL).put("timedOut", timedOut).put("cancelled", cancelled)
            .put("stdout", stdout.text()).put("stderr", stderr.text())
            .put("truncated", stdout.truncated || stderr.truncated)
    }

    fun submit(body: JSONObject): JSONObject {
        if (closed || !slots.tryAcquire()) throw RemoteError(429, "four commands are already running")
        try {
            val command = body.getString("command")
            if (command.isBlank() || command.length > 65536) throw RemoteError(400, "command must contain 1..65536 characters")
            val directory = files.path(body.optString("cwd", layout.home.path))
            if (!directory.isDirectory) throw RemoteError(400, "cwd must be an accessible directory")
            val timeout = body.optLong("timeoutMs", 30000).coerceIn(100, 300000)
            val input = body.optString("stdin", "").toByteArray(Charsets.UTF_8)
            if (input.size > 1024 * 1024) throw RemoteError(413, "stdin exceeds 1 MiB")
            jobs.values.filter { it.finished != null }.sortedBy { it.finished }.dropLast(12).forEach { jobs.remove(it.id) }
            val job = Job(UUID.randomUUID().toString())
            jobs[job.id] = job
            executor.execute { execute(job, command, directory, input, timeout) }
            return JSONObject().put("id", job.id).put("status", "accepted")
        } catch (error: Exception) { slots.release(); throw error }
    }

    private fun drain(stream: InputStream, output: Output): Thread = Thread({
        try { stream.use { input ->
            val buffer = ByteArray(8192)
            while (true) { val count = input.read(buffer); if (count < 0) break; output.append(buffer, count) }
        } } catch (_: Exception) { }
    }, "debug-command-output").also { it.isDaemon = true; it.start() }

    private fun execute(job: Job, command: String, directory: File, input: ByteArray, timeout: Long) {
        var timer: java.util.concurrent.ScheduledFuture<*>? = null
        try {
            if (job.cancelled || closed) return
            val builder = ProcessBuilder(layout.shell.path, "-c", command).directory(directory)
            builder.environment().clear()
            Rootfs.environment(layout).forEach { entry -> builder.environment()[entry.substringBefore('=')] = entry.substringAfter('=') }
            builder.environment()["PWD"] = directory.path
            val process = builder.start()
            job.process = process
            val out = drain(process.inputStream, job.stdout)
            val err = drain(process.errorStream, job.stderr)
            timer = watchdog.schedule({
                if (job.finished == null) { job.timedOut = true; terminate(process) }
            }, timeout, TimeUnit.MILLISECONDS)
            if (job.cancelled || closed) terminate(process)
            process.outputStream.use { if (input.isNotEmpty()) it.write(input) }
            job.exitCode = process.waitFor()
            out.join(1000); err.join(1000)
            process.inputStream.close(); process.errorStream.close()
        } catch (error: Exception) {
            val message = (error.message ?: error.javaClass.simpleName).toByteArray(Charsets.UTF_8)
            job.stderr.append(message, message.size)
            job.exitCode = -1
            job.process?.let(::terminate)
        } finally {
            timer?.cancel(false)
            job.finished = System.currentTimeMillis()
            slots.release()
        }
    }

    private fun terminate(process: Process) {
        // App-owned descendants only. Android's Process implementation carries its pid;
        // reflect it for API 24, where java.lang.Process.pid() is not public yet.
        val pid = try {
            process.javaClass.getDeclaredField("pid").also { it.isAccessible = true }.getInt(process)
        } catch (_: Exception) { null }
        if (pid != null) {
            val parentMap = mutableMapOf<Int, Int>()
            File("/proc").listFiles()?.forEach { entry ->
                val child = entry.name.toIntOrNull() ?: return@forEach
                try {
                    val stat = File(entry, "stat").readText().substringAfterLast(") ").split(' ')
                    val owner = Os.stat(entry.path).st_uid
                    if (owner == android.os.Process.myUid()) parentMap[child] = stat[1].toInt()
                } catch (_: Exception) { }
            }
            fun stopChildren(parent: Int, depth: Int) {
                if (depth > 32) return
                parentMap.filterValues { it == parent }.keys.forEach { child ->
                    stopChildren(child, depth + 1)
                    try { Os.kill(child, 9) } catch (_: Exception) { }
                }
            }
            stopChildren(pid, 0)
        }
        process.destroy()
    }

    fun get(id: String): JSONObject = jobs[id]?.json() ?: throw RemoteError(404, "job not found")
    fun cancel(id: String): JSONObject {
        val job = jobs[id] ?: throw RemoteError(404, "job not found")
        if (job.finished == null) { job.cancelled = true; job.process?.let(::terminate) }
        return job.json()
    }
    override fun close() {
        closed = true
        jobs.values.filter { it.finished == null }.forEach { it.cancelled = true; it.process?.let(::terminate) }
        watchdog.shutdownNow(); executor.shutdownNow()
    }
}