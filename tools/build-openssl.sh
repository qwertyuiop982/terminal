#!/bin/sh
# Build the OpenSSL CLI from its pinned GitHub source for BusyBox wget HTTPS.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
NDK=${ANDROID_NDK_HOME:-/root/Android/ndk/29.0.14206865}
API=${ANDROID_API:-24}
BIN="$NDK/toolchains/llvm/prebuilt/linux-$(uname -m)/bin"
SOURCE="$ROOT/build-ext/src/openssl-3.5.4"
FINAL="$ROOT/build-ext/out/arm64-v8a/final"
PREFIX=/data/data/com.terminal/files/usr

[ -x "$BIN/aarch64-linux-android${API}-clang" ] || { echo 'NDK arm64 compiler is missing' >&2; exit 1; }
[ -d "$FINAL/bin" ] || { echo 'build the arm64 extension first' >&2; exit 1; }
(cd "$ROOT/third_party" && sha256sum -c userland-SHA256SUMS)
if [ ! -f "$SOURCE/Configure" ]; then
    tar -xzf "$ROOT/third_party/openssl/openssl-3.5.4.tar.gz" -C "$ROOT/build-ext/src"
    mv "$ROOT/build-ext/src/openssl-openssl-3.5.4" "$SOURCE"
fi
(
    cd "$SOURCE"
    if [ ! -f Makefile ] || ! grep -Fq "aarch64-linux-android${API}-clang" Makefile; then
        if [ -f Makefile ]; then PATH="$BIN:$PATH" make clean; fi
        PATH="$BIN:$PATH" ANDROID_NDK_ROOT="$NDK" \
            CFLAGS='-O2 -fPIC' LDFLAGS='-Wl,-z,max-page-size=16384' \
            ./Configure android-arm64 -D__ANDROID_API__="$API" \
                --prefix="$PREFIX" --openssldir="$PREFIX/etc/ssl" \
                no-shared no-tests no-docs no-legacy no-engine no-module
    fi
    PATH="$BIN:$PATH" make -j4 build_generated
    PATH="$BIN:$PATH" make -j4 apps/openssl
)
cp -f "$SOURCE/apps/openssl" "$FINAL/bin/openssl"
"$BIN/llvm-strip" "$FINAL/bin/openssl"
[ -s "$FINAL/bin/openssl" ] || { echo 'OpenSSL CLI was not built' >&2; exit 1; }
(cd "$ROOT/third_party/ca" && sha256sum -c SHA256SUMS)
mkdir -p "$FINAL/etc/ssl"
cp -f "$ROOT/third_party/ca/ca-bundle.crt" "$FINAL/etc/ssl/cert.pem"
printf 'OpenSSL 3.5.4 and pinned Mozilla CAs staged under %s\n' "$FINAL"
