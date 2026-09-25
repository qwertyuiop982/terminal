package com.terminal

/** JNI bridge to a single POSIX PTY session. */
class Pty private constructor(private var handle: Long) : AutoCloseable {
    val isOpen: Boolean get() = handle != 0L

    fun read(buffer: ByteArray): Int {
        val current = handle
        if (current == 0L) return -1
        return nativeRead(current, buffer)
    }

    fun write(data: ByteArray, length: Int = data.size): Int {
        val current = handle
        if (current == 0L) return -1
        return nativeWrite(current, data, length)
    }

    fun resize(rows: Int, cols: Int) {
        val current = handle
        if (current != 0L) nativeResize(current, rows, cols)
    }

    /** @return process status, -2 while still running, or -1 on error. */
    fun poll(): Int {
        val current = handle
        if (current == 0L) return -1
        return nativeWait(current, 0)
    }

    override fun close() {
        val current = handle
        if (current != 0L) {
            handle = 0L
            nativeClose(current)
        }
    }

    companion object {
        init {
            System.loadLibrary("pty")
        }

        fun open(
            shell: String,
            cwd: String,
            environment: Array<String>,
            rows: Int,
            cols: Int,
        ): Pty {
            val handle = nativeOpen(shell, cwd, environment, rows, cols)
            if (handle == 0L) {
                throw IllegalStateException("failed to open a PTY for $shell")
            }
            return Pty(handle)
        }
    }
}

private external fun nativeOpen(
    shell: String,
    cwd: String,
    environment: Array<String>,
    rows: Int,
    cols: Int,
): Long

private external fun nativeRead(handle: Long, buffer: ByteArray): Int
private external fun nativeWrite(handle: Long, data: ByteArray, length: Int): Int
private external fun nativeResize(handle: Long, rows: Int, cols: Int)
private external fun nativeWait(handle: Long, block: Int): Int
private external fun nativeClose(handle: Long)
