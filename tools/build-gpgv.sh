#!/bin/sh
# Cross-build upstream GnuPG's gpgv verifier and its pinned libraries.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
NDK=${ANDROID_NDK_HOME:-/root/Android/ndk/29.0.14206865}
API=${ANDROID_API:-24}
BIN="$NDK/toolchains/llvm/prebuilt/linux-$(uname -m)/bin"
CC="$BIN/aarch64-linux-android${API}-clang"
SOURCE="$ROOT/build-ext/src/apt-gnupg"
OUT="$ROOT/build-ext/out/arm64-v8a"
DEP="$OUT/apt-deps"
FINAL="$OUT/final"
PREFIX=/data/data/com.terminal/files/usr

[ -s "$DEP/lib/libgcrypt.a" ] && [ -s "$DEP/lib/libgpg-error.a" ] || {
    echo 'build-apt.sh must build libgcrypt and libgpg-error first' >&2; exit 1;
}
sh "$ROOT/tools/prepare-gpgv-source.sh"
sh "$ROOT/tools/build-host-bison.sh"
PATH="$ROOT/build-ext/host/bison/bin:$DEP/bin:$BIN:$PATH"
YACC="$ROOT/build-ext/host/bison/bin/bison -y"
PKG_CONFIG_LIBDIR="$DEP/lib/pkgconfig"
export PATH YACC PKG_CONFIG_LIBDIR

build_library() {
    source=$1
    library=$2
    shift 2
    [ -s "$DEP/lib/$library" ] && return
    build="$OUT/$source-build"
    mkdir -p "$build"
    (
        cd "$build"
        if [ "$source" = npth-1.7 ]; then
            # bionic has pthread_create but no pthread_cancel; nPth never calls cancel.
            ac_cv_search_pthread_cancel='none required'
            export ac_cv_search_pthread_cancel
        fi
        CC="$CC" AR="$BIN/llvm-ar" RANLIB="$BIN/llvm-ranlib" \
            CPPFLAGS="-I$DEP/include" CFLAGS='-O2 -fPIC' \
            LDFLAGS="-L$DEP/lib -Wl,-z,max-page-size=16384" \
            "$SOURCE/$source/configure" --host=aarch64-linux-android \
                --prefix="$DEP" --disable-shared --enable-static --disable-doc "$@"
        make -j"${ANDROID_BUILD_JOBS:-2}"
        make install
    )
    [ -s "$DEP/lib/$library" ] || { printf 'missing %s after building %s\n' "$library" "$source" >&2; exit 1; }
}

build_library libassuan-2.5.7 libassuan.a
build_library npth-1.7 libnpth.a
build_library libksba-1.6.7 libksba.a

BUILD="$OUT/gnupg-build"
mkdir -p "$BUILD"
(
    cd "$BUILD"
    if [ ! -f Makefile ]; then
        CC="$CC" AR="$BIN/llvm-ar" RANLIB="$BIN/llvm-ranlib" \
            CPPFLAGS="-I$DEP/include" CFLAGS='-O2 -fPIC' \
            LDFLAGS="-L$DEP/lib -Wl,-z,max-page-size=16384" \
            "$SOURCE/gnupg-2.4.8/configure" --host=aarch64-linux-android \
                --prefix="$PREFIX" --disable-nls --disable-doc --disable-tests \
                --disable-gpgsm --disable-scdaemon --disable-dirmngr \
                --disable-keyboxd --disable-ccid-driver --disable-libdns \
                --disable-sqlite --disable-ldap \
                --with-libgpg-error-prefix="$DEP" --with-libgcrypt-prefix="$DEP" \
                --with-libassuan-prefix="$DEP" --with-libksba-prefix="$DEP" \
                --with-npth-prefix="$DEP"
    fi
    make -j"${ANDROID_BUILD_JOBS:-2}" -C common libcommonpth.a libgpgrl.a
    make -j"${ANDROID_BUILD_JOBS:-2}" -C regexp libregexp.a
    make -j"${ANDROID_BUILD_JOBS:-2}" -C kbx libkeybox.a
    make -j"${ANDROID_BUILD_JOBS:-2}" -C g10 gpgv
)
[ -s "$BUILD/g10/gpgv" ] || { echo 'gpgv build did not produce a verifier' >&2; exit 1; }
cp -f "$BUILD/g10/gpgv" "$FINAL/bin/gpgv"
"$BIN/llvm-strip" "$FINAL/bin/gpgv"
printf 'GnuPG 2.4.8 gpgv staged at %s/bin/gpgv\n' "$FINAL"