#!/bin/sh
# Cross-build upstream apt 2.8.1 and its pinned libraries with the Android NDK.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
NDK=${ANDROID_NDK_HOME:-/root/Android/ndk/29.0.14206865}
API=${ANDROID_API:-24}
BIN="$NDK/toolchains/llvm/prebuilt/linux-$(uname -m)/bin"
CC="$BIN/aarch64-linux-android${API}-clang"
SRC="$ROOT/build-ext/src"
ARCHIVES="$ROOT/third_party/apt/deps"
APT="$SRC/apt-2.8.1"
OUT="$ROOT/build-ext/out/arm64-v8a"
DEP="$OUT/apt-deps"
BASE="$OUT/stage"
FINAL="$OUT/final"
OPENSSL="$SRC/openssl-3.5.4"
PREFIX=/data/data/com.terminal/files/usr

[ -x "$CC" ] && [ -s "$OPENSSL/libssl.a" ] && [ -d "$FINAL/bin" ] || {
    echo 'build-ext.sh arm64 and build-openssl.sh must finish first' >&2; exit 1;
}
(cd "$ROOT/third_party/apt" && sha256sum -c SHA256SUMS)
sh "$ROOT/tools/prepare-apt-source.sh"
mkdir -p "$DEP" "$OUT/apt-build" "$SRC/apt-deps"

extract() {
    name=$1
    archive=$2
    if [ ! -d "$SRC/apt-deps/$name" ]; then
        mkdir -p "$SRC/apt-deps/$name"
        tar -xf "$ARCHIVES/$archive" -C "$SRC/apt-deps/$name" --strip-components=1
    fi
}
extract libgpg-error-1.51 libgpg-error-1.51.tar.bz2
extract libgcrypt-1.11.0 libgcrypt-1.11.0.tar.bz2
extract lz4-1.10.0 lz4-1.10.0.tar.gz
extract xxHash-0.8.3 xxHash-0.8.3.tar.gz
extract libiconv-1.18 libiconv-1.18.tar.gz

# libgpg-error ships a 32-bit Android mutex layout but not bionic's LP64 one.
printf '#include <pthread.h>\n_Static_assert(sizeof(pthread_mutex_t) == 40, "bionic mutex layout changed");\n' |
    "$CC" -x c -c -o "$OUT/apt-build/bionic-lock.o" -
cp "$ROOT/third_party/apt/android-gpgrt-lock-aarch64.h" \
    "$SRC/apt-deps/libgpg-error-1.51/src/syscfg/lock-obj-pub.aarch64-unknown-linux-android.h"

if [ ! -s "$DEP/lib/libgpg-error.a" ]; then
    mkdir -p "$OUT/gpg-error-build"
    (cd "$OUT/gpg-error-build" &&
        CC="$CC" AR="$BIN/llvm-ar" RANLIB="$BIN/llvm-ranlib" \
        CFLAGS='-O2 -fPIC' LDFLAGS='-Wl,-z,max-page-size=16384' \
        "$SRC/apt-deps/libgpg-error-1.51/configure" --host=aarch64-linux-android \
            --prefix="$DEP" --disable-nls --disable-shared --enable-static &&
        make -j4 && make install)
fi
if [ ! -s "$DEP/lib/libgcrypt.a" ]; then
    mkdir -p "$OUT/gcrypt-build"
    (cd "$OUT/gcrypt-build" &&
        CC="$CC" AR="$BIN/llvm-ar" RANLIB="$BIN/llvm-ranlib" \
        PKG_CONFIG_LIBDIR="$DEP/lib/pkgconfig" \
        CFLAGS='-O2 -fPIC' LDFLAGS="-L$DEP/lib -Wl,-z,max-page-size=16384" \
        "$SRC/apt-deps/libgcrypt-1.11.0/configure" --host=aarch64-linux-android \
            --prefix="$DEP" --with-libgpg-error-prefix="$DEP" \
            --disable-doc --disable-shared --enable-static &&
        make -j4 && make install)
fi
if [ ! -s "$DEP/lib/liblz4.a" ]; then
    lz4="$SRC/apt-deps/lz4-1.10.0/lib"
    for name in lz4 lz4frame lz4hc xxhash; do
        "$CC" -O2 -fPIC -c "$lz4/$name.c" -I"$lz4" -o "$OUT/apt-build/$name.o"
    done
    mkdir -p "$DEP/lib" "$DEP/include"
    "$BIN/llvm-ar" rcs "$DEP/lib/liblz4.a" "$OUT/apt-build/lz4.o" \
        "$OUT/apt-build/lz4frame.o" "$OUT/apt-build/lz4hc.o" "$OUT/apt-build/xxhash.o"
    cp "$lz4/lz4.h" "$lz4/lz4frame.h" "$lz4/lz4hc.h" "$DEP/include/"
fi
if [ ! -s "$DEP/lib/libxxhash.a" ]; then
    xxhash="$SRC/apt-deps/xxHash-0.8.3"
    "$CC" -O2 -fPIC -c "$xxhash/xxhash.c" -o "$OUT/apt-build/xxhash.o"
    "$BIN/llvm-ar" rcs "$DEP/lib/libxxhash.a" "$OUT/apt-build/xxhash.o"
    cp "$xxhash/xxhash.h" "$DEP/include/"
fi

if [ ! -f "$SRC/apt-deps/libiconv-1.18/configure" ] ||
    [ ! -f "$SRC/apt-deps/libiconv-1.18/libcharset/configure" ]; then
    sh "$ROOT/tools/build-host-gperf.sh"
    [ -d "$SRC/userland-arm64/gnulib" ] || {
        echo 'build-userland.sh must prepare the pinned gnulib snapshot first' >&2; exit 1;
    }
    (cd "$SRC/apt-deps/libiconv-1.18" &&
        PATH="$ROOT/build-ext/host/gperf/bin:$PATH" \
            MAKEFLAGS='ACLOCAL=aclocal AUTOMAKE=automake MAN2HTML=cat' \
            GNULIB_SRCDIR="$SRC/userland-arm64/gnulib" sh ./autogen.sh)
fi
if [ ! -s "$DEP/lib/libiconv.a" ]; then
    mkdir -p "$OUT/iconv-build"
    (cd "$OUT/iconv-build" &&
        CC="$CC" AR="$BIN/llvm-ar" RANLIB="$BIN/llvm-ranlib" \
        CFLAGS='-O2 -fPIC' LDFLAGS='-Wl,-z,max-page-size=16384' \
        "$SRC/apt-deps/libiconv-1.18/configure" --host=aarch64-linux-android \
            --prefix="$DEP" --disable-nls --disable-shared --enable-static &&
        make -j4 && make install)
fi
GNULIB="$SRC/userland-arm64/nano/build/lib"
GNULIB_HEADERS="$OUT/apt-gnulib-headers"
[ -s "$GNULIB/libgnu.a" ] && [ -s "$GNULIB/glob.h" ] &&
    [ -s "$GNULIB/glob-libc.gl.h" ] || {
    echo 'build-userland.sh must finish the gnulib glob build before apt' >&2; exit 1;
}
mkdir -p "$GNULIB_HEADERS"
cp -f "$GNULIB/glob.h" "$GNULIB/glob-libc.gl.h" "$GNULIB_HEADERS/"

cmake -S "$APT" -B "$OUT/apt-build" \
    -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM="android-$API" -DANDROID_STL=c++_shared \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_INSTALL_LIBEXECDIR=libexec \
    -DCMAKE_INSTALL_SYSCONFDIR=etc -DCMAKE_INSTALL_LOCALSTATEDIR=var \
    -DCMAKE_SHARED_LINKER_FLAGS='-Wl,-z,max-page-size=16384' \
    -DCMAKE_EXE_LINKER_FLAGS='-Wl,-z,max-page-size=16384' \
    -DWITH_DOC=OFF -DWITH_TESTS=OFF -DUSE_NLS=OFF -DREQUIRE_MERGED_USR=OFF \
    -DCOMMON_ARCH=arm64 -DDPKG_DATADIR="$PREFIX/share/dpkg" \
    -DTRIEHASH_EXECUTABLE="$ARCHIVES/triehash.pl" \
    -DCMAKE_DISABLE_FIND_PACKAGE_GnuTLS=ON -DCMAKE_DISABLE_FIND_PACKAGE_Udev=ON \
    -DCMAKE_DISABLE_FIND_PACKAGE_Systemd=ON -DCMAKE_DISABLE_FIND_PACKAGE_SECCOMP=ON \
    -DCMAKE_DISABLE_FIND_PACKAGE_Berkeley=ON \
    -DANDROID_OPENSSL_SOURCE="$ROOT/tools/apt-openssl.cc" \
    -DANDROID_OPENSSL_INCLUDE_DIR="$OPENSSL/include" \
    -DANDROID_OPENSSL_LIBSSL="$OPENSSL/libssl.a" \
    -DANDROID_OPENSSL_LIBCRYPTO="$OPENSSL/libcrypto.a" \
    -DICONV_INCLUDE_DIR="$DEP/include" -DICONV_LIBRARY="$DEP/lib/libiconv.a" \
    -DANDROID_GNULIB_INCLUDE_DIR="$GNULIB_HEADERS" -DANDROID_GNULIB_GLOB="$GNULIB/libgnu.a" \
    -DZLIB_INCLUDE_DIR="$BASE/include" -DZLIB_LIBRARY="$BASE/lib/libz.a" \
    -DBZIP2_INCLUDE_DIR="$BASE/include" -DBZIP2_LIBRARY_RELEASE="$BASE/lib/libbz2.so.1.0" \
    -DLZMA_INCLUDE_DIRS="$BASE/include" -DLZMA_LIBRARIES="$BASE/lib/liblzma.a" \
    -DLZ4_INCLUDE_DIRS="$DEP/include" -DLZ4_LIBRARIES="$DEP/lib/liblz4.a" \
    -DZSTD_INCLUDE_DIRS="$BASE/include" -DZSTD_LIBRARIES="$BASE/lib/libzstd.a" \
    -DXXHASH_INCLUDE_DIRS="$DEP/include" -DXXHASH_LIBRARIES="$DEP/lib/libxxhash.a" \
    -DGCRYPT_INCLUDE_DIRS="$DEP/include" -DGCRYPT_LIBRARIES="$DEP/lib/libgcrypt.a;$DEP/lib/libgpg-error.a"

cmake --build "$OUT/apt-build" --parallel 4 --target apt apt-get apt-cache apt-config vendor-apt-key http gpgv file copy store
for executable in apt apt-get apt-cache apt-config; do
    cp -f "$OUT/apt-build/cmdline/$executable" "$FINAL/bin/"
done
for method in http gpgv file copy store; do
    mkdir -p "$FINAL/libexec/apt/methods"
    cp -f "$OUT/apt-build/methods/$method" "$FINAL/libexec/apt/methods/"
done
ln -sf http "$FINAL/libexec/apt/methods/https"
for library in "$OUT/apt-build/apt-pkg/"libapt-pkg.so* "$OUT/apt-build/apt-private/"libapt-private.so*; do
    [ -f "$library" ] || continue
    cp -f "$library" "$FINAL/lib/"
done
cp -f "$NDK/toolchains/llvm/prebuilt/linux-$(uname -m)/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so" "$FINAL/lib/"
if [ -f "$OUT/apt-build/cmdline/apt-key" ]; then
    cp -f "$OUT/apt-build/cmdline/apt-key" "$FINAL/bin/apt-key"
    chmod 755 "$FINAL/bin/apt-key"
fi
printf 'apt 2.8.1 staged; repository signature verification still requires a built gpgv\n'