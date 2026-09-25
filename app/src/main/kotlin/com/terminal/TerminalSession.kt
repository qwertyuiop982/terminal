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
    private val reader = Thread({
        val buffer = ByteArray(8192)
        try {
            while (running.get()) {
                val count = pty.read(buffer)
                when {
                    count > 0 -> onOutput(String(buffer, 0, count, charset))
                    count == 0 -> {
                        val status = pty.poll()
                        if (status != -2) {
                            running.set(false)
                            onExit(status)
                            break
                        }
                        Thread.sleep(16)
                    }
                    else -> {
                        running.set(false)
                        onExit(pty.poll().takeIf { it >= 0 } ?: 1)
                        break
                    }
                }
            }
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        } catch (_: IOException) {
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
        while (offset < bytes.size) {
            val wrote = pty.write(bytes.copyOfRange(offset, bytes.size))
            if (wrote < 0) break
            if (wrote == 0) {
                Thread.sleep(8)
                continue
            }
            offset += wrote
        }
    }

    fun resize(rows: Int, cols: Int) {
        pty.resize(rows, cols)
    }

    override fun close() {
        running.set(false)
        pty.close()
        reader.interrupt()
    }
}
