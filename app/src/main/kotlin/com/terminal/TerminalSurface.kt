package com.terminal

import android.content.Context
import android.util.AttributeSet
import android.util.TypedValue
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Typeface
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.inputmethod.BaseInputConnection
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.view.inputmethod.InputMethodManager
import kotlin.math.floor

/** Owns the on-screen grid; the IME writes directly to the PTY through [onInput]. */
class TerminalSurface(context: Context, attrs: AttributeSet? = null) : View(context, attrs) {
    private val screen = TerminalScreen()
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        typeface = Typeface.MONOSPACE
        textSize = TypedValue.applyDimension(
            TypedValue.COMPLEX_UNIT_SP,
            14f,
            resources.displayMetrics,
        )
    }
    private val left = 10f * resources.displayMetrics.density
    private val top = 8f * resources.displayMetrics.density
    private var cellWidth = paint.measureText("M")
    private var cellHeight = paint.fontSpacing
    private var baseline = -paint.fontMetrics.ascent
    var onInput: ((String) -> Unit)? = null
    var onResize: ((Int, Int) -> Unit)? = null
    var control = false
        set(value) {
            field = value
            onControlChanged?.invoke(value)
        }
    var onControlChanged: ((Boolean) -> Unit)? = null
    val columns get() = screen.columns
    val rows get() = screen.rows

    init {
        isFocusable = true
        isFocusableInTouchMode = true
        screen.onReply = { onInput?.invoke(it) }
        setBackgroundColor(0xff111418.toInt())
    }

    fun append(bytes: ByteArray) {
        screen.append(bytes)
        invalidate()
    }

    fun showMessage(message: String) {
        screen.writeLocal(message)
        invalidate()
    }

    fun send(text: String) {
        if (control) {
            control = false
            val letter = text.singleOrNull()?.uppercaseChar()
            if (letter != null && letter in '@'..'_') {
                onInput?.invoke((letter.code - 64).toChar().toString())
                return
            }
        }
        onInput?.invoke(text)
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        if (w <= 0 || h <= 0) return
        val cols = floor((w - 2 * left) / cellWidth).toInt().coerceAtLeast(2)
        val lines = floor((h - 2 * top) / cellHeight).toInt().coerceAtLeast(2)
        screen.resize(cols, lines)
        onResize?.invoke(cols, lines)
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val cells = screen.cells
        for (row in 0 until screen.rows) {
            for (col in 0 until screen.columns) {
                val cell = cells[row][col]
                val x = left + col * cellWidth
                val y = top + row * cellHeight
                if (cell.background != 0xff111418.toInt()) {
                    paint.color = cell.background
                    canvas.drawRect(x, y, x + cellWidth, y + cellHeight, paint)
                }
                if (cell.text != " ") {
                    paint.color = cell.foreground
                    paint.isFakeBoldText = cell.bold
                    canvas.drawText(cell.text, x, y + baseline, paint)
                }
            }
        }
        paint.isFakeBoldText = false
        if (screen.cursorVisible) {
            paint.color = 0xff9bcbb4.toInt()
            val x = left + screen.cursorColumn * cellWidth
            val y = top + screen.cursorRow * cellHeight
            canvas.drawRect(x, y + cellHeight - 3f, x + cellWidth, y + cellHeight, paint)
        }
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (event.action == MotionEvent.ACTION_UP) {
            requestFocus()
            (context.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager)
                .showSoftInput(this, InputMethodManager.SHOW_IMPLICIT)
            performClick()
        }
        return true
    }

    override fun performClick(): Boolean {
        super.performClick()
        return true
    }

    override fun onCheckIsTextEditor() = true

    override fun onCreateInputConnection(outAttrs: EditorInfo): InputConnection {
        outAttrs.inputType = android.text.InputType.TYPE_CLASS_TEXT or
            android.text.InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD or
            android.text.InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
        outAttrs.imeOptions = EditorInfo.IME_ACTION_GO or EditorInfo.IME_FLAG_NO_FULLSCREEN
        return object : BaseInputConnection(this, false) {
            override fun commitText(text: CharSequence?, newCursorPosition: Int): Boolean {
                if (!text.isNullOrEmpty()) send(text.toString())
                return true
            }

            override fun setComposingText(text: CharSequence?, newCursorPosition: Int): Boolean = true

            override fun deleteSurroundingText(beforeLength: Int, afterLength: Int): Boolean {
                repeat(beforeLength.coerceAtMost(100)) { send("\u007f") }
                return true
            }

            override fun performEditorAction(actionCode: Int): Boolean {
                send("\r")
                return true
            }

            override fun sendKeyEvent(event: KeyEvent): Boolean =
                if (event.action == KeyEvent.ACTION_DOWN) onKeyDown(event.keyCode, event) else true
        }
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean {
        val sequence = when (keyCode) {
            KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_NUMPAD_ENTER -> "\r"
            KeyEvent.KEYCODE_DEL -> "\u007f"
            KeyEvent.KEYCODE_FORWARD_DEL -> "\u001b[3~"
            KeyEvent.KEYCODE_TAB -> "\t"
            KeyEvent.KEYCODE_ESCAPE -> "\u001b"
            KeyEvent.KEYCODE_DPAD_UP -> "\u001b[A"
            KeyEvent.KEYCODE_DPAD_DOWN -> "\u001b[B"
            KeyEvent.KEYCODE_DPAD_RIGHT -> "\u001b[C"
            KeyEvent.KEYCODE_DPAD_LEFT -> "\u001b[D"
            else -> null
        }
        if (sequence != null) { send(sequence); return true }
        val code = event.unicodeChar
        if (code > 0) {
            if (event.isCtrlPressed) control = true
            send(String(Character.toChars(code)))
            return true
        }
        return super.onKeyDown(keyCode, event)
    }
}