#!/bin/sh
# Cross-build upstream file 5.48 and its magic database for arm64 Android.
# Run after build-ext.sh arm64; this appends to the final prefix.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
NDK=${ANDROID_NDK_HOME:-/root/Android/ndk/29.0.14206865}
API=${ANDROID_API:-24}
BIN="$NDK/toolchains/llvm/prebuilt/linux-$(uname -m)/bin"
CC="$BIN/aarch64-linux-android${API}-clang"
SRC="$ROOT/build-ext/src/file-5.48"
ARCHIVE="$ROOT/third_party/file/file-5.48.tar.gz"
OUT="$ROOT/build-ext/out/arm64-v8a"
HOST_BUILD="$OUT/file-host"
TARGET_BUILD="$OUT/file-target"
STAGE="$OUT/file-stage"
FINAL="$OUT/final"
DEV_PREFIX=/data/data/com.terminal/files/usr

[ -x "$CC" ] || { echo "Android NDK compiler missing: $CC" >&2; exit 1; }
[ -d "$FINAL/bin" ] || { echo 'build the arm64 extension first' >&2; exit 1; }
(cd "$ROOT/third_party/file" && sha256sum -c SHA256SUMS)
if [ ! -f "$SRC/configure" ]; then
    mkdir -p "$ROOT/build-ext/src"
    tar -xzf "$ARCHIVE" -C "$ROOT/build-ext/src"
fi
mkdir -p "$HOST_BUILD" "$TARGET_BUILD" "$STAGE"

if [ ! -f "$HOST_BUILD/Makefile" ]; then
    (cd "$HOST_BUILD" && "$SRC/configure" --disable-static --disable-landlock)
fi
make -C "$HOST_BUILD" -j4
HOST_FILE="$HOST_BUILD/src/file"
[ -x "$HOST_FILE" ] || { echo 'host magic compiler was not built' >&2; exit 1; }

if [ ! -f "$TARGET_BUILD/Makefile" ]; then
    (cd "$TARGET_BUILD" && \
        CC="$CC" AR="$BIN/llvm-ar" RANLIB="$BIN/llvm-ranlib" STRIP="$BIN/llvm-strip" \
        PKG_CONFIG=/bin/false \
        CPPFLAGS="-I$OUT/stage/include" \
        CFLAGS='-O2 -fPIC' \
        LDFLAGS="-L$OUT/stage/lib -Wl,-z,max-page-size=16384" \
        "$SRC/configure" --build="$(gcc -dumpmachine)" --host=aarch64-linux-android \
        --prefix="$DEV_PREFIX" --disable-static --disable-libseccomp \
        --disable-landlock --disable-bzlib --disable-xzlib \
        --disable-zstdlib --disable-lzlib --disable-lrziplib)
fi
make -C "$TARGET_BUILD" -j4 FILE_COMPILE="$HOST_FILE"
make -C "$TARGET_BUILD" FILE_COMPILE="$HOST_FILE" DESTDIR="$STAGE" install

INSTALLED="$STAGE$DEV_PREFIX"
[ -s "$INSTALLED/bin/file" ] && [ -s "$INSTALLED/share/misc/magic.mgc" ] || {
    echo 'file executable or magic database missing from stage' >&2
    exit 1
}
mkdir -p "$FINAL/bin" "$FINAL/lib" "$FINAL/share/misc"
cp -f "$INSTALLED/bin/file" "$FINAL/bin/file"
cp -a "$INSTALLED/lib/libmagic.so"* "$FINAL/lib/"
cp -f "$INSTALLED/share/misc/magic.mgc" "$FINAL/share/misc/magic.mgc"
chmod 755 "$FINAL/bin/file"
printf 'file and magic database staged under %s\n' "$FINAL"
