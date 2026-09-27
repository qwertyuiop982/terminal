package com.terminal

import android.os.Bundle
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import com.terminal.databinding.ActivityMainBinding
import java.util.concurrent.Executors

class MainActivity : AppCompatActivity() {
    private lateinit var binding: ActivityMainBinding
    private val io = Executors.newSingleThreadExecutor()
    @Volatile private var session: TerminalSession? = null
    @Volatile private var destroyed = false
    private val pendingInput = StringBuilder()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)
        binding.terminal.onInput = { text -> sendInput(text) }
        binding.terminal.onResize = { cols, rows ->
            session?.let { current -> io.execute { current.resize(rows, cols) } }
        }
        binding.terminal.onControlChanged = { binding.ctrl.isSelected = it }
        binding.ctrl.setOnClickListener { binding.terminal.control = !binding.terminal.control }
        binding.escape.setOnClickListener { binding.terminal.send("\u001b") }
        binding.tab.setOnClickListener { binding.terminal.send("\t") }
        binding.left.setOnClickListener { binding.terminal.send("\u001b[D") }
        binding.down.setOnClickListener { binding.terminal.send("\u001b[B") }
        binding.up.setOnClickListener { binding.terminal.send("\u001b[A") }
        binding.right.setOnClickListener { binding.terminal.send("\u001b[C") }
        binding.terminal.post { startShell() }
    }

    private fun startShell() {
        if (destroyed) return
        val cols = binding.terminal.columns
        val rows = binding.terminal.rows
        io.execute {
            if (destroyed || session?.isRunning == true) return@execute
            session?.close()
            try {
                val layout = Rootfs.ensure(this)
                if (destroyed) return@execute
                val pty = Pty.open(
                    shell = layout.shell.absolutePath,
                    cwd = layout.home.absolutePath,
                    environment = Rootfs.environment(layout),
                    rows = rows,
                    cols = cols,
                )
                val created = TerminalSession(
                    pty = pty,
                    onOutput = { bytes -> runOnUiThread { if (!destroyed) binding.terminal.append(bytes) } },
                    onExit = { code ->
                        runOnUiThread { if (!destroyed) binding.terminal.showMessage("\r\n[dash exited: $code]\r\n") }
                    },
                )
                session = created
                created.start()
                runOnUiThread {
                    if (!destroyed) {
                        binding.terminal.showMessage("terminal 1.0\r\n")
                        val input = pendingInput.toString()
                        pendingInput.clear()
                        if (input.isNotEmpty()) io.execute { created.write(input) }
                    }
                }
            } catch (error: Exception) {
                runOnUiThread {
                    if (!destroyed) {
                        binding.terminal.showMessage("failed to start dash: ${error.message}\r\n")
                        Toast.makeText(this, error.message, Toast.LENGTH_LONG).show()
                    }
                }
            }
        }
    }

    private fun sendInput(text: String) {
        val current = session
        if (current == null || !current.isRunning) {
            pendingInput.append(text)
            startShell()
        } else {
            io.execute { current.write(text) }
        }
    }

    override fun onDestroy() {
        destroyed = true
        session?.close()
        io.shutdown()
        super.onDestroy()
    }
}