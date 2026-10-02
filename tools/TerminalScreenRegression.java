package com.terminal;

import java.nio.charset.StandardCharsets;
import java.util.Arrays;

/** Pure JVM checks for the terminal grid; no device data is touched. */
public final class TerminalScreenRegression {
    private static String row(TerminalScreen.Cell[] cells) {
        StringBuilder text = new StringBuilder();
        for (TerminalScreen.Cell cell : cells) text.append(cell.getText());
        return text.toString().stripTrailing();
    }

    private static void expect(TerminalScreen screen, String... lines) {
        TerminalScreen.Cell[][] actual = screen.visibleCells();
        if (actual.length != lines.length) {
            throw new AssertionError("rows: " + actual.length + " != " + lines.length);
        }
        for (int i = 0; i < lines.length; i++) {
            if (!row(actual[i]).equals(lines[i])) {
                throw new AssertionError("row " + i + ": " + row(actual[i]) + " != " + lines[i]
                    + "; expected=" + Arrays.toString(lines));
            }
        }
    }

    public static void main(String[] args) {
        TerminalScreen startup = new TerminalScreen(4, 2);
        startup.resize(4, 5);
        startup.writeLocal("start");
        expect(startup, "star", "t", "", "", "");

        TerminalScreen wrap = new TerminalScreen(4, 2);
        wrap.writeLocal("abcd\r\nX");
        expect(wrap, "abcd", "X");
        TerminalScreen exact = new TerminalScreen(4, 2);
        exact.writeLocal("abcde");
        expect(exact, "abcd", "e");

        TerminalScreen history = new TerminalScreen(4, 3);
        history.writeLocal("abcd\r\n1234\r\nwxyz\r\n");
        expect(history, "1234", "wxyz", "");
        history.scrollBy(1);
        expect(history, "abcd", "1234", "wxyz");
        history.resize(4, 2);
        expect(history, "abcd", "1234");
        history.returnToLive();
        expect(history, "wxyz", "");
        history.resize(4, 3);
        expect(history, "1234", "wxyz", "");
        history.scrollBy(1);
        expect(history, "abcd", "1234", "wxyz");
        history.resize(3, 3);
        expect(history, "abc", "123", "wxy");

        TerminalScreen alternate = new TerminalScreen(4, 2);
        alternate.writeLocal("aaaa\r\nbbbb\r\ncccc\r\n");
        alternate.writeLocal("\u001b[?1049hXXXX\r\nYYYY\r\nZZZZ\r\n\u001b[?1049l");
        alternate.scrollBy(2);
        expect(alternate, "aaaa", "bbbb");

        TerminalScreen utf8 = new TerminalScreen(4, 2);
        byte[] accented = "é".getBytes(StandardCharsets.UTF_8);
        utf8.append(new byte[]{accented[0]});
        utf8.append(new byte[]{accented[1]});
        expect(utf8, "é", "");
        System.out.println("terminal screen: resize, wrapping, scrollback, alternate and UTF-8 passed");
    }
}
