package com.terminal

import android.os.Bundle
import android.text.Editable
import android.text.TextWatcher
import android.view.KeyEvent
import android.view.inputmethod.EditorInfo
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import com.terminal.databinding.ActivityMainBinding
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class MainActivity : AppCompatActivity() {
    private lateinit var binding: ActivityMainBinding
    private val io: ExecutorService = Executors.newSingleThreadExecutor()
    private var session: TerminalSession? = null
    private val screen = StringBuilder()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)
        binding.input.setOnEditorActionListener { _, actionId, event ->
            val enter = actionId == EditorInfo.IME_ACTION_SEND ||
                (event?.keyCode == KeyEvent.KEYCODE_ENTER && event.action == KeyEvent.ACTION_DOWN)
            if (!enter) return@setOnEditorActionListener false
            submitInput()
            true
        }
        binding.send.setOnClickListener { submitInput() }
        binding.input.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) = Unit
            override fun afterTextChanged(s: Editable?) {
                if (s != null && s.endsWith("\n")) submitInput()
            }
        })
        startShell()
    }

    private fun startShell() {
        io.execute {
            try {
                val layout = Rootfs.ensure(this)
                val pty = Pty.open(
                    shell = layout.shell.absolutePath,
                    cwd = layout.home.absolutePath,
                    environment = Rootfs.environment(layout),
                    rows = 40,
                    cols = 100,
                )
                val created = TerminalSession(
                    pty = pty,
                    onOutput = { text -> runOnUiThread { append(text) } },
                    onExit = { code ->
                        runOnUiThread { append("\n[dash exited: $code]\n") }
                    },
                )
                session = created
                created.start()
                runOnUiThread {
                    append("terminal 1.0\n")
                    append("dash 0.5.13.5\n")
                    append("HOME=${layout.home.absolutePath}\n")
                    append("USR=${layout.usr.absolutePath}\n")
                }
            } catch (error: Exception) {
                runOnUiThread {
                    append("failed to start dash: ${error.message}\n")
                    Toast.makeText(this, error.message, Toast.LENGTH_LONG).show()
                }
            }
        }
    }

    private fun submitInput() {
        val text = binding.input.text?.toString().orEmpty()
        if (text.isEmpty()) return
        binding.input.text = null
        val line = if (text.endsWith("\n")) text else text + "\n"
        io.execute { session?.write(line) }
    }

    private fun append(text: String) {
        screen.append(text)
        if (screen.length > 80_000) screen.delete(0, screen.length - 60_000)
        binding.transcript.text = screen
        binding.scroll.post { binding.scroll.fullScroll(android.view.View.FOCUS_DOWN) }
    }

    override fun onDestroy() {
        session?.close()
        io.shutdownNow()
        super.onDestroy()
    }
}