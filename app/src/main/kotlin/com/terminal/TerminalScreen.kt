package com.terminal

import java.nio.ByteBuffer
import java.nio.CharBuffer
import java.nio.charset.CodingErrorAction
import java.util.ArrayDeque

/** A small VT-style screen with bounded scrollback and an alternate buffer for full-screen programs. */
internal class TerminalScreen(initialColumns: Int = 80, initialRows: Int = 24) {
    data class Cell(var text: String = " ", var foreground: Int = 0xffd7e0ea.toInt(),
                    var background: Int = 0xff111418.toInt(), var bold: Boolean = false)

    var columns = initialColumns.coerceAtLeast(2)
        private set
    var rows = initialRows.coerceAtLeast(2)
        private set
    var cursorRow = 0
        private set
    var cursorColumn = 0
        private set
    var cursorVisible = true
        private set
    private var screen = emptyGrid()
    private val scrollback = ArrayDeque<Array<Cell>>()
    private var scrollOffset = 0
    private var hasWritten = false
    private var wrapPending = false
    private val maxScrollbackRows = 2000
    private var mainScreen: Array<Array<Cell>>? = null
    private var mainCursor = 0 to 0
    private var scrollTop = 0
    private var scrollBottom = rows - 1
    private var foreground = normalForeground
    private var background = normalBackground
    private var bold = false
    private var state = 0 // 0 text, 1 escape, 2 CSI, 3 OSC, 4 OSC escape, 5 charset
    private val sequence = StringBuilder()
    private var savedRow = 0
    private var savedColumn = 0
    private var pendingBytes = byteArrayOf()
    private val decoder = Charsets.UTF_8.newDecoder()
        .onMalformedInput(CodingErrorAction.REPLACE)
        .onUnmappableCharacter(CodingErrorAction.REPLACE)

    val cells: Array<Array<Cell>> get() = screen

    fun visibleCells(): Array<Array<Cell>> {
        if (scrollOffset == 0 || mainScreen != null || scrollback.isEmpty()) return screen
        val combined = ArrayList<Array<Cell>>(scrollback.size + screen.size)
        combined.addAll(scrollback)
        combined.addAll(screen.asList())
        val start = (combined.size - rows - scrollOffset).coerceAtLeast(0)
        return Array(rows) { index ->
            combined.getOrNull(start + index) ?: Array(columns) { Cell() }
        }
    }

    val displayCursorRow: Int
        get() = if (scrollOffset == 0 || mainScreen != null) cursorRow else -1

    fun scrollBy(lines: Int) {
        if (mainScreen != null || lines == 0) return
        scrollOffset = (scrollOffset + lines).coerceIn(0, scrollback.size)
    }

    fun returnToLive() {
        scrollOffset = 0
    }
    var onReply: ((String) -> Unit)? = null

    fun resize(newColumns: Int, newRows: Int) {
        val width = newColumns.coerceAtLeast(2)
        val height = newRows.coerceAtLeast(2)
        if (width == columns && height == rows) return
        val emptyBeforeFirstOutput = !hasWritten
        val dropped = (rows - height).coerceAtLeast(0)
        val added = (height - rows).coerceAtLeast(0)
        val saved = mainScreen
        val historySource = saved ?: screen
        repeat(dropped) { remember(historySource[it]) }
        val restored = ArrayList<Array<Cell>>()
        repeat(minOf(added, scrollback.size)) { restored.add(0, scrollback.removeLast()) }
        scrollOffset = (scrollOffset - restored.size).coerceIn(0, scrollback.size)
        if (width != columns) {
            val resizedHistory = scrollback.map { copyRow(it, width) }
            scrollback.clear()
            scrollback.addAll(resizedHistory)
        }
        if (saved != null) {
            mainScreen = resizeGrid(saved, width, height, restored)
            mainCursor = (mainCursor.first - dropped + added).coerceIn(0, height - 1) to
                mainCursor.second.coerceIn(0, width - 1)
            screen = resizeGrid(screen, width, height, emptyList())
        } else {
            screen = resizeGrid(screen, width, height, restored)
        }
        cursorRow = if (emptyBeforeFirstOutput) 0 else (cursorRow - dropped + added).coerceIn(0, height - 1)
        cursorColumn = cursorColumn.coerceIn(0, width - 1)
        savedRow = (savedRow - dropped + added).coerceIn(0, height - 1)
        savedColumn = savedColumn.coerceIn(0, width - 1)
        columns = width
        rows = height
        scrollTop = 0
        scrollBottom = height - 1
        wrapPending = false
    }

    private fun resizeGrid(old: Array<Array<Cell>>, width: Int, height: Int,
                           restored: List<Array<Cell>>): Array<Array<Cell>> {
        val next = Array(height) { Array(width) { Cell() } }
        val drop = (rows - height).coerceAtLeast(0)
        val add = (height - rows).coerceAtLeast(0)
        restored.forEachIndexed { index, line ->
            next[add - restored.size + index] = copyRow(line, width)
        }
        for (row in drop until rows) next[add + row - drop] = copyRow(old[row], width)
        return next
    }

    private fun copyRow(row: Array<Cell>, width: Int): Array<Cell> =
        Array(width) { column -> row.getOrNull(column)?.copy() ?: Cell() }

    private fun remember(row: Array<Cell>) {
        if (scrollOffset > 0) scrollOffset++
        scrollback.addLast(copyRow(row, columns))
        if (scrollback.size > maxScrollbackRows) scrollback.removeFirst()
        scrollOffset = scrollOffset.coerceAtMost(scrollback.size)
    }

    fun append(bytes: ByteArray) {
        if (bytes.isNotEmpty()) hasWritten = true
        val data = pendingBytes + bytes
        val input = ByteBuffer.wrap(data)
        val output = CharBuffer.allocate(data.size + 1)
        decoder.reset()
        decoder.decode(input, output, false)
        pendingBytes = ByteArray(input.remaining()).also { input.get(it) }
        output.flip()
        while (output.hasRemaining()) accept(output.get())
    }

    fun writeLocal(message: String) {
        if (message.isNotEmpty()) hasWritten = true
        message.forEach(::accept)
    }

    private fun emptyGrid() = Array(rows) { Array(columns) { Cell() } }

    private fun accept(char: Char) {
        when (state) {
            1 -> {
                state = 0
                when (char) {
                    '[' -> { sequence.clear(); state = 2 }
                    ']' -> { sequence.clear(); state = 3 }
                    '(', ')' -> state = 5
                    '7' -> { savedRow = cursorRow; savedColumn = cursorColumn }
                    '8' -> { cursorRow = savedRow.coerceIn(0, rows - 1); cursorColumn = savedColumn.coerceIn(0, columns - 1) }
                    'D' -> { wrapPending = false; lineFeed() }
                    'E' -> { wrapPending = false; cursorColumn = 0; lineFeed() }
                    'M' -> { wrapPending = false; reverseLineFeed() }
                    'c' -> {
                        screen = emptyGrid(); cursorRow = 0; cursorColumn = 0
                        wrapPending = false; scrollback.clear(); scrollOffset = 0
                    }
                }
            }
            2 -> {
                if (char in '@'..'~') {
                    csi(char, sequence.toString())
                    sequence.clear()
                    state = 0
                } else if (sequence.length < 128) sequence.append(char) else state = 0
            }
            3 -> when (char) {
                '\u0007' -> state = 0
                '\u001b' -> state = 4
                else -> if (sequence.length < 512) sequence.append(char)
            }
            4 -> state = if (char == '\\') 0 else 3
            5 -> state = 0
            else -> when (char) {
                '\u001b' -> state = 1
                '\r' -> { wrapPending = false; cursorColumn = 0 }
                '\n', '\u000b', '\u000c' -> { wrapPending = false; lineFeed() }
                '\b' -> { wrapPending = false; cursorColumn = (cursorColumn - 1).coerceAtLeast(0) }
                '\t' -> {
                    wrapPending = false
                    cursorColumn = ((cursorColumn / 8 + 1) * 8).coerceAtMost(columns - 1)
                }
                else -> if (char >= ' ') put(char)
            }
        }
    }

    private fun put(char: Char) {
        if (wrapPending) {
            cursorColumn = 0
            lineFeed()
            wrapPending = false
        }
        screen[cursorRow][cursorColumn] = Cell(char.toString(), foreground, background, bold)
        if (cursorColumn == columns - 1) wrapPending = true else cursorColumn++
    }

    private fun lineFeed() {
        if (cursorRow == scrollBottom) {
            if (scrollTop == 0 && scrollBottom == rows - 1 && mainScreen == null) {
                remember(screen[0])
            }
            for (row in scrollTop until scrollBottom) screen[row] = screen[row + 1]
            screen[scrollBottom] = Array(columns) { Cell() }
        } else cursorRow = (cursorRow + 1).coerceAtMost(rows - 1)
    }

    private fun insertLines(count: Int) {
        if (cursorRow !in scrollTop..scrollBottom) return
        repeat(count.coerceAtLeast(0).coerceAtMost(scrollBottom - cursorRow + 1)) {
            for (row in scrollBottom downTo cursorRow + 1) screen[row] = screen[row - 1]
            screen[cursorRow] = Array(columns) { Cell() }
        }
    }

    private fun deleteLines(count: Int) {
        if (cursorRow !in scrollTop..scrollBottom) return
        repeat(count.coerceAtLeast(0).coerceAtMost(scrollBottom - cursorRow + 1)) {
            for (row in cursorRow until scrollBottom) screen[row] = screen[row + 1]
            screen[scrollBottom] = Array(columns) { Cell() }
        }
    }

    private fun reverseLineFeed() {
        if (cursorRow == scrollTop) {
            for (row in scrollBottom downTo scrollTop + 1) screen[row] = screen[row - 1]
            screen[scrollTop] = Array(columns) { Cell() }
        } else cursorRow = (cursorRow - 1).coerceAtLeast(0)
    }

    private fun csi(command: Char, value: String) {
        if (command != 'm') wrapPending = false
        val privateMode = value.startsWith('?')
        val args = value.trimStart('?').split(';').map { it.toIntOrNull() ?: 0 }
        fun arg(index: Int, fallback: Int = 1) = (args.getOrNull(index) ?: 0).takeIf { it > 0 } ?: fallback
        when (command) {
            'A' -> cursorRow = (cursorRow - arg(0)).coerceAtLeast(0)
            'B' -> cursorRow = (cursorRow + arg(0)).coerceAtMost(rows - 1)
            'C' -> cursorColumn = (cursorColumn + arg(0)).coerceAtMost(columns - 1)
            'D' -> cursorColumn = (cursorColumn - arg(0)).coerceAtLeast(0)
            'E' -> { cursorRow = (cursorRow + arg(0)).coerceAtMost(rows - 1); cursorColumn = 0 }
            'F' -> { cursorRow = (cursorRow - arg(0)).coerceAtLeast(0); cursorColumn = 0 }
            'G' -> cursorColumn = (arg(0) - 1).coerceIn(0, columns - 1)
            'd' -> cursorRow = (arg(0) - 1).coerceIn(0, rows - 1)
            'H', 'f' -> {
                cursorRow = (arg(0) - 1).coerceIn(0, rows - 1)
                cursorColumn = (arg(1) - 1).coerceIn(0, columns - 1)
            }
            'J' -> {
                for (row in 0 until rows) {
                    val start = if (args[0] == 0 && row == cursorRow) cursorColumn else 0
                    val end = if (args[0] == 1 && row == cursorRow) cursorColumn else columns - 1
                    if ((args[0] == 0 && row < cursorRow) || (args[0] == 1 && row > cursorRow)) continue
                    for (col in start..end) screen[row][col] = Cell()
                }
            }
            'K' -> {
                val start = if (args[0] == 0) cursorColumn else 0
                val end = if (args[0] == 1) cursorColumn else columns - 1
                for (col in start..end) screen[cursorRow][col] = Cell()
            }
            '@' -> repeat(arg(0).coerceAtMost(columns)) {
                for (col in columns - 1 downTo cursorColumn + 1) screen[cursorRow][col] = screen[cursorRow][col - 1]
                screen[cursorRow][cursorColumn] = Cell()
            }
            'P' -> repeat(arg(0).coerceAtMost(columns)) {
                for (col in cursorColumn until columns - 1) screen[cursorRow][col] = screen[cursorRow][col + 1]
                screen[cursorRow][columns - 1] = Cell()
            }
            'L' -> insertLines(arg(0).coerceAtMost(rows))
            'M' -> deleteLines(arg(0).coerceAtMost(rows))
            'r' -> {
                val top = (arg(0) - 1).coerceIn(0, rows - 1)
                val bottom = (arg(1, rows) - 1).coerceIn(0, rows - 1)
                if (bottom > top) { scrollTop = top; scrollBottom = bottom; cursorRow = 0; cursorColumn = 0 }
            }
            's' -> { savedRow = cursorRow; savedColumn = cursorColumn }
            'u' -> { cursorRow = savedRow.coerceIn(0, rows - 1); cursorColumn = savedColumn.coerceIn(0, columns - 1) }
            'm' -> style(args)
            'n' -> if (args[0] == 6) onReply?.invoke("\u001b[${cursorRow + 1};${cursorColumn + 1}R")
            'h', 'l' -> if (privateMode) {
                args.filter { it > 0 }.forEach { mode ->
                    if (mode == 25) cursorVisible = command == 'h'
                    if (mode == 1049 || mode == 47) alternate(command == 'h')
                }
            }
        }
    }

    private fun alternate(enabled: Boolean) {
        if (enabled && mainScreen == null) {
            returnToLive()
            mainScreen = screen
            mainCursor = cursorRow to cursorColumn
            screen = emptyGrid()
            cursorRow = 0
            cursorColumn = 0
        } else if (!enabled && mainScreen != null) {
            screen = mainScreen!!
            mainScreen = null
            cursorRow = mainCursor.first
            cursorColumn = mainCursor.second
        }
    }

    private fun style(args: List<Int>) {
        var index = 0
        while (index < args.size) {
            val code = args[index]
            when (code) {
                0 -> { foreground = normalForeground; background = normalBackground; bold = false }
                1 -> bold = true
                22 -> bold = false
                7 -> { val old = foreground; foreground = background; background = old }
                39 -> foreground = normalForeground
                49 -> background = normalBackground
                in 30..37 -> foreground = palette[code - 30]
                in 40..47 -> background = palette[code - 40]
                in 90..97 -> foreground = palette[code - 90 + 8]
                in 100..107 -> background = palette[code - 100 + 8]
                38, 48 -> {
                    val color = if (args.getOrNull(index + 1) == 5 && index + 2 < args.size) {
                        index += 2
                        val slot = args[index].coerceIn(0, 255)
                        if (slot < 16) palette[slot] else if (slot < 232) {
                            val n = slot - 16
                            rgb((n / 36) * 51, (n / 6 % 6) * 51, (n % 6) * 51)
                        } else rgb((slot - 232) * 10 + 8, (slot - 232) * 10 + 8, (slot - 232) * 10 + 8)
                    } else if (args.getOrNull(index + 1) == 2 && index + 4 < args.size) {
                        index += 4
                        rgb(args[index - 2], args[index - 1], args[index])
                    } else null
                    if (color != null) {
                        if (code == 38) foreground = color else background = color
                    }
                }
            }
            index++
        }
    }

    companion object {
        private val normalForeground = 0xffd7e0ea.toInt()
        private val normalBackground = 0xff111418.toInt()
        private fun rgb(r: Int, g: Int, b: Int) = 0xff000000.toInt() or
            (r.coerceIn(0, 255) shl 16) or (g.coerceIn(0, 255) shl 8) or b.coerceIn(0, 255)
        private val palette = intArrayOf(
            rgb(17, 20, 24), rgb(204, 93, 88), rgb(119, 185, 131), rgb(224, 182, 92),
            rgb(104, 157, 224), rgb(182, 133, 207), rgb(104, 187, 192), rgb(215, 224, 234),
            rgb(112, 128, 144), rgb(238, 120, 109), rgb(147, 212, 153), rgb(243, 211, 127),
            rgb(132, 183, 245), rgb(213, 162, 233), rgb(139, 214, 215), rgb(248, 250, 252),
        )
    }
}