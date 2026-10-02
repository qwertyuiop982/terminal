#!/bin/sh
# Audit the app's shell assets and staged arm64 runtime (not host build tools).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
PREFIX=/data/data/com.terminal/files/usr
FINAL="$ROOT/build-ext/out/arm64-v8a/final"
fail() { printf 'private runtime: %s\n' "$*" >&2; exit 1; }

for abi in arm64-v8a armeabi-v7a; do
    dash="$ROOT/app/src/main/assets/bin/dash-$abi"
    [ -s "$dash" ] || fail "dash for $abi is missing"
    strings "$dash" | grep -Fxq "$PREFIX/bin/sh" || fail "dash for $abi uses an external shell"
    strings "$dash" | grep -Fq "PATH=$PREFIX/bin:$PREFIX/sbin:$PREFIX/libexec" ||
        fail "dash for $abi lacks a private fallback PATH"
    system_paths=$(strings "$dash" | grep -F '/system/bin/' |
        grep -Fxv '/system/bin/linker64' | grep -Fxv '/system/bin/linker' || true)
    [ -z "$system_paths" ] || fail "dash for $abi uses a system command: $system_paths"
done

[ -s "$FINAL/bin/busybox" ] && [ -s "$FINAL/bin/openssl" ] &&
    [ -s "$FINAL/bin/dpkg" ] && [ -s "$FINAL/bin/file" ] || fail 'runtime tools are missing'
[ ! -e "$FINAL/bin/nano" ] && [ ! -e "$FINAL/bin/tcc" ] &&
    [ ! -e "$FINAL/include/stdio.h" ] || fail 'optional tools leaked into APK assets'
(cd "$ROOT/third_party/ca" && sha256sum -c SHA256SUMS) || fail 'CA bundle source mismatch'
cmp -s "$ROOT/third_party/ca/ca-bundle.crt" "$FINAL/etc/ssl/cert.pem" ||
    fail 'app CA bundle is missing or outdated'
[ -s "$FINAL/share/dpkg/sh/dpkg-error.sh" ] || fail 'dpkg-realpath support is missing'
for name in grep sed awk tar gzip nslookup nc ls cat cp mv rm mkdir touch echo \
    sleep env date uname whoami wget find ps kill killall diff cmp; do
    grep -Fxq "$name" "$FINAL/share/busybox/applets" || fail "BusyBox applet is missing: $name"
done
[ -s "$ROOT/build-ext/out/arm64-v8a/optional/nano/bin/nano" ] || fail 'optional nano is missing'
[ -s "$ROOT/build-ext/out/arm64-v8a/optional/tcc/bin/tcc" ] || fail 'optional tcc is missing'
for name in dpkg-maintscript-helper dpkg-realpath; do
    [ -f "$FINAL/bin/$name" ] || fail "$name is missing"
    read -r interpreter < "$FINAL/bin/$name"
    [ "$interpreter" = "#!$PREFIX/bin/sh" ] || fail "$name uses an external shell"
    sh -n "$FINAL/bin/$name" || fail "$name has invalid shell syntax"
done
strings "$FINAL/bin/busybox" | grep -Fq "PATH=$PREFIX/bin:$PREFIX/sbin:$PREFIX/libexec" ||
    fail 'BusyBox lacks a private fallback PATH'
for binary in "$FINAL/bin/"* "$FINAL/lib/"*.so*; do
    [ -f "$binary" ] || continue
    system_paths=$(strings "$binary" | grep -F '/system/bin/' |
        grep -Fxv '/system/bin/linker64' | grep -Fxv '/system/bin/linker' || true)
    [ -z "$system_paths" ] || fail "$binary uses a system command: $system_paths"
done
nano="$ROOT/build-ext/out/arm64-v8a/optional/nano/bin/nano"
strings "$nano" | grep -Fxq "$PREFIX/bin/sh" ||
    fail 'nano lacks a private fallback shell'
if strings "$nano" | grep -Fxq /bin/sh; then
    fail 'nano contains a host shell fallback'
fi
strings "$FINAL/bin/busybox" | grep -Fq "$PREFIX/etc/resolv.conf" ||
    fail 'nslookup is not using the private resolver config'
printf 'private runtime: dash (both ABIs) and arm64 command paths verified\n'