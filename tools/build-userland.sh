#!/bin/sh
# Build arm64 BusyBox for the APK and nano as an optional package from source.
# Run after ./tools/build-ext.sh arm64.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
NDK=${ANDROID_NDK_HOME:-/root/Android/ndk/29.0.14206865}
API=${ANDROID_API:-24}
BIN="$NDK/toolchains/llvm/prebuilt/linux-$(uname -m)/bin"
CC="$BIN/aarch64-linux-android${API}-clang"
DEV_PREFIX=/data/data/com.terminal/files/usr
WORK="$ROOT/build-ext/src/userland-arm64"
STAGE="$ROOT/build-ext/out/arm64-v8a/userland-stage"
FINAL="$ROOT/build-ext/out/arm64-v8a/final"
NANO_PACKAGE="$ROOT/build-ext/out/arm64-v8a/optional/nano"

[ -x "$CC" ] || { echo "Android NDK arm64 compiler missing: $CC" >&2; exit 1; }
[ -d "$FINAL/bin" ] || { echo "build the arm64 extension first" >&2; exit 1; }
(cd "$ROOT/third_party" && sha256sum -c userland-SHA256SUMS)
mkdir -p "$WORK" "$STAGE" "$FINAL/bin" "$NANO_PACKAGE/bin" \
    "$NANO_PACKAGE/lib" "$NANO_PACKAGE/share/terminfo"

sh "$ROOT/tools/build-busybox.sh"

if [ ! -d "$WORK/ncurses" ]; then
    mkdir -p "$WORK/ncurses"
    tar -xf "$ROOT/third_party/ncurses/ncurses-6.4.tar.gz" -C "$WORK/ncurses" --strip-components=1
fi
(
    mkdir -p "$WORK/ncurses/build"
    cd "$WORK/ncurses/build"
    CC="$CC" AR="$BIN/llvm-ar" RANLIB="$BIN/llvm-ranlib" \
    CFLAGS='-O2 -fPIC' LDFLAGS='-Wl,-z,max-page-size=16384' \
    ../configure --host=aarch64-linux-android --prefix="$DEV_PREFIX" \
        --with-shared --enable-widec --without-debug --without-ada \
        --without-manpages --without-tests --without-progs --without-cxx \
        --with-default-terminfo-dir="$DEV_PREFIX/share/terminfo"
    make -j4
    make DESTDIR="$STAGE" install.libs install.includes install.data
)
NCROOT="$STAGE$DEV_PREFIX"
cp "$NCROOT/lib/libncursesw.so.6.4" "$NANO_PACKAGE/lib/"
ln -sf libncursesw.so.6.4 "$NANO_PACKAGE/lib/libncursesw.so.6"
for term in x/xterm-256color x/xterm a/ansi; do
    mkdir -p "$NANO_PACKAGE/share/terminfo/${term%/*}"
    cp "$NCROOT/share/terminfo/$term" "$NANO_PACKAGE/share/terminfo/$term"
done

if [ ! -d "$WORK/nano" ]; then
    mkdir -p "$WORK/nano" "$WORK/gnulib"
    tar -xf "$ROOT/third_party/nano/nano-git-88ae189.tar.gz" -C "$WORK/nano" --strip-components=1
    tar -xf "$ROOT/third_party/nano/gnulib-snapshot.tar.gz" -C "$WORK/gnulib" --strip-components=1
    ln -s ../gnulib "$WORK/nano/gnulib"
    (
        cd "$WORK/nano"
        ./gnulib/gnulib-tool --import canonicalize-lgpl futimens getdelim \
            getline getopt-gnu glob isblank iswblank lstat mkstemps \
            nl_langinfo regex rewinddir sigaction snprintf-posix stdarg-h \
            strcase strcasestr-simple strnlen sys_wait vsnprintf-posix \
            wchar-h wctype-h wcwidth windows-stat-timespec
        autoreconf --install --force
    )
fi
if grep -Fq 'theshell = (char *)"/bin/sh";' "$WORK/nano/src/files.c"; then
    patch --batch --fuzz=0 -d "$WORK/nano" -p1 < "$ROOT/third_party/nano/android-private-shell.patch"
fi
grep -Fq "theshell = (char *)\"$DEV_PREFIX/bin/sh\";" "$WORK/nano/src/files.c"
(
    mkdir -p "$WORK/nano/build"
    cd "$WORK/nano/build"
    CC="$CC" CFLAGS="-O2 -fPIC -I$NCROOT/include/ncursesw -I$NCROOT/include" \
        LDFLAGS="-L$NCROOT/lib -Wl,-z,max-page-size=16384" \
        LIBS=-lncursesw PKG_CONFIG=/bin/false \
        ../configure --host=aarch64-linux-android --prefix="$DEV_PREFIX" \
        --disable-nls --disable-libmagic --disable-speller \
        --disable-browser --enable-utf8 \
        ac_cv_header_glob_h=no ac_cv_header_pwd_h=no \
        gl_cv_func_strcasecmp_works=yes
    make -j4 -C lib
    make -j4 -C src
)
cp "$WORK/nano/build/src/nano" "$NANO_PACKAGE/bin/nano"
"$BIN/llvm-strip" "$NANO_PACKAGE/bin/nano"
echo "arm64 BusyBox staged under $FINAL; nano under $NANO_PACKAGE"
