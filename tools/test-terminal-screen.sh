#!/bin/sh
# Exercise the pure Kotlin grid using its compiled JVM classes; no JUnit or device needed.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
VERSION=2.1.0
STDLIB_ROOT=${GRADLE_USER_HOME:-$HOME/.gradle}/caches/modules-2/files-2.1/org.jetbrains.kotlin/kotlin-stdlib/$VERSION
STDLIB=$(find "$STDLIB_ROOT" -name "kotlin-stdlib-$VERSION.jar" -print -quit 2>/dev/null)
CLASSES="$ROOT/app/build/tmp/kotlin-classes/debug"
[ -f "$STDLIB" ] && [ -f "$CLASSES/com/terminal/TerminalScreen.class" ] || {
    echo 'compileDebugKotlin and the pinned Kotlin stdlib must be available' >&2
    exit 1
}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/terminal-screen-test.XXXXXXXX")
trap 'rm -rf "$WORK"' EXIT
javac -cp "$CLASSES:$STDLIB" -d "$WORK" "$ROOT/tools/TerminalScreenRegression.java"
java -cp "$WORK:$CLASSES:$STDLIB" com.terminal.TerminalScreenRegression