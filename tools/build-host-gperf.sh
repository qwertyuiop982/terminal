#!/bin/sh
# Generate the host-only gperf tool from pinned upstream GitHub source.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
SRC="$ROOT/build-ext/src/host-gperf"
OUT="$ROOT/build-ext/host/gperf"
ARCHIVE="$ROOT/third_party/apt/host/gperf-1a8e476.tar.gz"
(cd "$ROOT/third_party/apt/host" && sha256sum -c SHA256SUMS)
if [ ! -f "$SRC/configure.ac" ]; then
    mkdir -p "$SRC"
    tar -xzf "$ARCHIVE" -C "$SRC" --strip-components=1
fi
[ -d "$ROOT/build-ext/src/userland-arm64/gnulib/build-aux" ] || {
    echo 'build-userland.sh must prepare the pinned gnulib host scripts first' >&2; exit 1;
}
for name in config.guess config.sub; do
    cp -f "$ROOT/build-ext/src/userland-arm64/gnulib/build-aux/$name" "$SRC/build-aux/"
done
if [ ! -f "$SRC/lib/filename.h" ]; then
    (cd "$SRC" && GNULIB_TOOL="$ROOT/build-ext/src/userland-arm64/gnulib/gnulib-tool" sh ./autopull.sh)
fi
if [ ! -f "$SRC/configure" ]; then
    (cd "$SRC" && sh ./autogen.sh)
fi
if [ ! -x "$OUT/bin/gperf" ]; then
    mkdir -p "$OUT/build"
    if [ ! -f "$OUT/build/Makefile" ]; then
        (cd "$OUT/build" && "$SRC/configure" --prefix="$OUT")
    fi
    make -j3 -C "$OUT/build/lib"
    make -j3 -C "$OUT/build/src"
    mkdir -p "$OUT/bin"
    cp -f "$OUT/build/src/gperf" "$OUT/bin/gperf"
fi
"$OUT/bin/gperf" --version | head -1