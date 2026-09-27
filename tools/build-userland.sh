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

if [ ! -d "$WORK/busybox" ]; then
    mkdir -p "$WORK/busybox"
    tar -xf "$ROOT/third_party/busybox/busybox-1.38.0.tar.gz" -C "$WORK/busybox" --strip-components=1
fi
if grep -Fq '# define BB_ADDITIONAL_PATH ":/system/sbin:/system/bin:/system/xbin"' "$WORK/busybox/include/platform.h"; then
    patch --batch --fuzz=0 -d "$WORK/busybox" -p1 < "$ROOT/third_party/busybox/android-private-path.patch"
fi
# BusyBox's full nslookup reads resolv.conf directly; use the app's config.
if grep -Fq 'fopen_for_read("/etc/resolv.conf")' "$WORK/busybox/networking/nslookup.c"; then
    sed -i 's|fopen_for_read("/etc/resolv.conf")|fopen_for_read("/data/data/com.terminal/files/usr/etc/resolv.conf")|' \
        "$WORK/busybox/networking/nslookup.c"
fi
grep -Fq "PATH=$DEV_PREFIX/bin:$DEV_PREFIX/sbin:$DEV_PREFIX/libexec" "$WORK/busybox/include/libbb.h"
grep -Fq '#define bb_default_path (bb_PATH_root_path + sizeof("PATH"))' "$WORK/busybox/include/libbb.h"
grep -Fq '# define BB_ADDITIONAL_PATH ""' "$WORK/busybox/include/platform.h"
(
    cd "$WORK/busybox"
    make allnoconfig </dev/null
    # Start with every optional applet disabled, then enable the pinned list.
    while IFS= read -r setting; do
        key=${setting%%=*}
        sed -i "s/^# ${key} is not set$/${setting}/" .config
    done < "$ROOT/tools/busybox-arm64.config"
    sed -i 's/^CONFIG_SH_IS_ASH=y$/# CONFIG_SH_IS_ASH is not set/' .config
    make silentoldconfig </dev/null
    grep -q '^CONFIG_BUSYBOX=y$' .config
    grep -q '^CONFIG_CAT=y$' .config
    grep -q '^CONFIG_SH_IS_NONE=y$' .config
    for setting in CONFIG_FEATURE_FIND_PRINT0 CONFIG_FEATURE_FIND_TYPE \
        CONFIG_FEATURE_FIND_MAXDEPTH CONFIG_FEATURE_FIND_EXEC \
        CONFIG_FEATURE_FIND_PRUNE CONFIG_PS CONFIG_KILL CONFIG_KILLALL \
        CONFIG_NSLOOKUP CONFIG_NC CONFIG_WGET CONFIG_FEATURE_WGET_OPENSSL; do
        grep -q "^${setting}=y$" .config
    done
    grep -q '^# CONFIG_FEATURE_WGET_HTTPS is not set$' .config
    # The upstream Makefile treats an Android Linux triple as glibc and adds
    # -lresolv, which bionic does not ship as a separate library.
    make -j4 CC="$CC" AR="$BIN/llvm-ar" STRIP="$BIN/llvm-strip" \
        LDLIBS=m CFLAGS='-O2 -fPIC' LDFLAGS='-Wl,-z,max-page-size=16384'
)
cp "$WORK/busybox/busybox" "$FINAL/bin/busybox"
"$BIN/llvm-strip" "$FINAL/bin/busybox"
mkdir -p "$FINAL/share/busybox"
# Keep BusyBox itself in assets once. Rootfs creates the applet symlinks on device.
# Do not shadow dash (sh) or the dedicated dpkg/nano/tcc tools.
: > "$FINAL/share/busybox/applets"
for name in awk basename bunzip2 cat chmod chown clear cp cut date dd df dirname du \
    echo egrep env expr false fgrep find grep gunzip gzip head hexdump hostname \
    id install kill killall ln ls mkdir mktemp more mv nc nslookup od printenv printf ps readlink realpath \
    reset rm sed seq sha256sum sleep sort stat tail tar tee test touch tr true \
    uname unzip unxz wc wget which whoami xargs xz yes; do
    key=$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')
    if grep -q "^CONFIG_${key}=y$" "$WORK/busybox/.config"; then
        printf '%s\n' "$name" >> "$FINAL/share/busybox/applets"
    fi
done

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
