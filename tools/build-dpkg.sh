#!/bin/sh
# Rebuild only arm64 dpkg using staged NDK dependencies; preserve APT/gpgv/optional trees.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
NDK=${ANDROID_NDK_HOME:-/root/Android/ndk/29.0.14206865}
BIN="$NDK/toolchains/llvm/prebuilt/linux-$(uname -m)/bin"
SRC="$ROOT/build-ext/src/dpkg-arm64-v8a"
BUILD="$SRC/build-arm64-v8a"
STAGE="$ROOT/build-ext/out/arm64-v8a/stage"
FINAL="$ROOT/build-ext/out/arm64-v8a/final"
PREFIX=/data/data/com.terminal/files/usr
JOBS=${ANDROID_BUILD_JOBS:-2}
(cd "$ROOT/third_party" && grep 'dpkg/dpkg-1.22.6.tar.xz$' SHA256SUMS | sha256sum -c -)
[ -f "$BUILD/Makefile" ] && [ -f "$STAGE/lib/libmd.a" ] || {
    echo 'run the arm64 base build first; this command does not reset staged dependencies' >&2
    exit 1
}
sh "$ROOT/tools/prepare-dpkg-source.sh" "$SRC"
make -j"$JOBS" -C "$BUILD/lib"
make -j"$JOBS" -C "$BUILD/src"
make -j"$JOBS" -C "$BUILD/utils" update-alternatives
for program in dpkg dpkg-deb dpkg-divert dpkg-query dpkg-split dpkg-statoverride dpkg-trigger; do
    "$BIN/llvm-strip" -s "$BUILD/src/$program"
    cp "$BUILD/src/$program" "$FINAL/bin/$program"
done
"$BIN/llvm-strip" -s "$BUILD/utils/update-alternatives"
cp "$BUILD/utils/update-alternatives" "$FINAL/bin/update-alternatives"
for script in dpkg-maintscript-helper dpkg-realpath; do
    sed "1s|^#!/bin/sh$|#!$PREFIX/bin/sh|" "$BUILD/src/$script" > "$FINAL/bin/$script"
    chmod 755 "$FINAL/bin/$script"
done
printf 'dpkg arm64 copy backups and private paths staged; other producers preserved\n'