#!/bin/sh
# Rebuild only APK BusyBox applets from pinned sources; preserve optional packages.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
NDK=${ANDROID_NDK_HOME:-/root/Android/ndk/29.0.14206865}
API=${ANDROID_API:-24}
BIN="$NDK/toolchains/llvm/prebuilt/linux-$(uname -m)/bin"
CC="$BIN/aarch64-linux-android${API}-clang"
DEV_PREFIX=/data/data/com.terminal/files/usr
WORK="$ROOT/build-ext/src/userland-arm64"
FINAL="$ROOT/build-ext/out/arm64-v8a/final"
[ -x "$CC" ] && [ -d "$FINAL/bin" ] || { echo 'NDK/base arm64 prefix missing' >&2; exit 1; }
(cd "$ROOT/third_party" && grep 'busybox/busybox-1.38.0.tar.gz$' userland-SHA256SUMS | sha256sum -c -)
mkdir -p "$WORK"
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
        CONFIG_NSLOOKUP CONFIG_NC CONFIG_WGET CONFIG_FEATURE_WGET_OPENSSL CONFIG_DIFF CONFIG_CMP; do
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
for name in awk basename bunzip2 cat chmod chown clear cmp cp cut date dd df diff dirname du \
    echo egrep env expr false fgrep find grep gunzip gzip head hexdump hostname \
    id install kill killall ln ls mkdir mktemp more mv nc nslookup od printenv printf ps readlink realpath \
    reset rm sed seq sha256sum sleep sort stat tail tar tee test touch tr true \
    uname unzip unxz wc wget which whoami xargs xz yes; do
    key=$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')
    if grep -q "^CONFIG_${key}=y$" "$WORK/busybox/.config"; then
        printf '%s\n' "$name" >> "$FINAL/share/busybox/applets"
    fi
done

printf 'BusyBox applets including diff/cmp staged for arm64\n'
