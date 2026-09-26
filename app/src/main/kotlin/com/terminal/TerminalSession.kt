package com.terminal

import java.io.IOException
import java.nio.charset.Charset
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Owns one dash process and pumps its PTY output to the UI thread callback.
 * The reader thread is the only thread that calls [Pty.read].
 */
class TerminalSession(
    private val pty: Pty,
    private val charset: Charset = Charsets.UTF_8,
    private val onOutput: (String) -> Unit,
    private val onExit: (Int) -> Unit,
) : AutoCloseable {
    private val running = AtomicBoolean(true)
    val isRunning: Boolean get() = running.get()

    private val reader = Thread({
        val buffer = ByteArray(8192)
        try {
            while (running.get()) {
                val count = pty.read(buffer)
                when {
                    count > 0 -> onOutput(String(buffer, 0, count, charset))
                    count == 0 -> {
                        // 非阻塞 fd 暂无数据：查一次进程状态再短暂休眠。
                        val status = pty.poll()
                        if (status != -2) {
                            if (running.getAndSet(false)) onExit(status)
                            break
                        }
                        Thread.sleep(16)
                    }
                    else -> {
                        val status = pty.poll().takeIf { it >= 0 } ?: 1
                        if (running.getAndSet(false)) onExit(status)
                        break
                    }
                }
            }
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        } catch (_: IOException) {
            if (running.getAndSet(false)) onExit(1)
        } catch (_: Exception) {
            if (running.getAndSet(false)) onExit(1)
        }
    }, "terminal-pty").also { it.isDaemon = true }

    fun start() {
        reader.start()
    }

    fun write(text: String) {
        if (!running.get()) return
        val bytes = text.toByteArray(charset)
        var offset = 0
        var retries = 0
        while (offset < bytes.size && running.get()) {
            try {
                val wrote = pty.write(bytes.copyOfRange(offset, bytes.size))
                if (wrote < 0) break
                if (wrote == 0) {
                    retries++
                    if (retries > 50) break
                    Thread.sleep(8)
                    continue
                }
                retries = 0
                offset += wrote
            } catch (e: InterruptedException) {
                Thread.currentThread().interrupt()
                break
            } catch (e: Exception) {
                break
            }
        }
    }

    fun resize(rows: Int, cols: Int) {
        if (running.get()) pty.resize(rows, cols)
    }

    override fun close() {
        if (running.getAndSet(false)) {
            pty.close()
            reader.interrupt()
        }
    }
}