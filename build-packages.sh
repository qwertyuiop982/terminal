#!/bin/sh
# Package NDK-built Android bionic tools; never package host or Termux binaries.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
STAGE=${TERMINAL_STAGE:-$ROOT/../terminal/build-ext/out/arm64-v8a/optional}
OUT=$ROOT/packages
mkdir -p "$OUT"
WORK=$(mktemp -d "$OUT/.build.XXXXXXXX")
trap 'rm -rf "$WORK"' EXIT
trap 'exit 1' HUP INT TERM

make_package() {
    name=$1
    version=$2
    summary=$3
    input=$STAGE/$name
    package=$WORK/$name
    deb=$OUT/${name}_${version}_arm64.deb
    [ -d "$input" ] || { printf 'missing NDK output: %s\n' "$input" >&2; exit 1; }
    mkdir -p "$package/DEBIAN"
    cp -a "$input/." "$package/"
    for binary in "$package/bin/"*; do
        [ -f "$binary" ] || continue
        case "$(readelf -h "$binary" | sed -n 's/.*Machine: *//p')" in
            AArch64) ;;
            *) printf 'not an Android arm64 ELF: %s\n' "$binary" >&2; exit 1 ;;
        esac
        readelf -l "$binary" | grep -Fq '/system/bin/linker64' || {
            printf 'not a bionic PIE: %s\n' "$binary" >&2; exit 1;
        }
    done
    printf 'Package: %s\nVersion: %s\nArchitecture: arm64\nMaintainer: Terminal Project <terminal@example.invalid>\nX-Android-Bionic: yes\nX-Android-Min-API: 24\nX-Terminal-Prefix: /data/data/com.terminal/files/usr\nDescription: %s (Android bionic, com.terminal private prefix)\n' \
        "$name" "$version" "$summary" > "$package/DEBIAN/control"
    chmod 755 "$package/DEBIAN" "$package/bin"/*
    SOURCE_DATE_EPOCH=1767225600 dpkg-deb --root-owner-group --build "$package" "$WORK/${name}_${version}_arm64.deb" >/dev/null
    if [ -e "$deb" ] && ! cmp -s "$WORK/${name}_${version}_arm64.deb" "$deb"; then
        printf 'immutable package differs: %s (choose a new version)\n' "$deb" >&2
        exit 1
    fi
    if [ ! -e "$deb" ]; then mv "$WORK/${name}_${version}_arm64.deb" "$deb"; fi
    dpkg-deb -f "$deb" Package Version Architecture
}

[ -f "$STAGE/nano/lib/libncursesw.so.6.4" ] || { echo 'nano runtime library missing' >&2; exit 1; }
[ -f "$STAGE/tcc/lib/tcc/libtcc1.a" ] || { echo 'tcc runtime library missing' >&2; exit 1; }
[ -f "$STAGE/tcc/include/stdio.h" ] || { echo 'tcc bionic headers missing' >&2; exit 1; }
make_package nano 9.2-1 'text editor with ncurses and terminfo'
make_package tcc 20260922-1 'Tiny C compiler with NDK bionic headers and CRT'
(cd "$OUT" && sha256sum nano_9.2-1_arm64.deb tcc_20260922-1_arm64.deb > SHA256SUMS)
printf 'Pinned Android packages built in %s\n' "$OUT"