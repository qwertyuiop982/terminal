#!/bin/sh
# Refuse unsafe absolute command/config/temp paths in newly built Android packages.
set -eu
PREFIX=/data/data/com.terminal/files/usr
[ "$#" -eq 1 ] && [ -d "$1" ] || { echo 'usage: check-package-paths.sh <package-staging-root>' >&2; exit 1; }
root=$1
fail() { printf 'package paths: %s\n' "$*" >&2; exit 1; }
command -v strings >/dev/null 2>&1 || fail 'host strings tool is required'

find "$root" -type f -print | while IFS= read -r file; do
    case "$file" in
        "$root"/bin/*|"$root"/lib/*|"$root"/libexec/*)
            # Do not scan headers or documentation; executable and link inputs are audited.
            : ;;
        "$root"/DEBIAN/preinst|"$root"/DEBIAN/postinst|"$root"/DEBIAN/prerm|\
"$root"/DEBIAN/postrm|"$root"/DEBIAN/config)
            : ;;
        *) continue ;;
    esac
    if [ "$(head -c 2 "$file")" = '#!' ]; then
        IFS= read -r first < "$file" || :
        case "$first" in
            "#!$PREFIX/bin/sh"|"#!$PREFIX/bin/dash") ;;
            *) fail "non-private script interpreter in $file: $first" ;;
        esac
    fi
    unsafe=$(strings -a "$file" |
        grep -E '^(/tmp(/|$)|/usr(/|$)|/etc(/|$)|/bin/(sh|bash|dash)(/|$)|/system/bin/)' |
        grep -Fxv /system/bin/linker64 | grep -Fxv /system/bin/linker || :)
    [ -z "$unsafe" ] || fail "external target path in $file: $unsafe"
done

# Package paths must be relative to the private root or private absolute links.
root_absolute=$(CDPATH= cd -- "$root" && pwd -P)
find "$root" -type l -print | while IFS= read -r link; do
    target=$(readlink "$link")
    case "$target" in
        /*) case "$target" in "$PREFIX"/*) ;; *) fail "external symlink: $link -> $target" ;; esac ;;
        *)
            resolved=$(readlink -f "$link") || fail "dangling symlink: $link -> $target"
            [ -e "$resolved" ] || fail "dangling symlink: $link -> $target"
            case "$resolved" in
                "$root_absolute"/*) ;; *) fail "external symlink: $link -> $target" ;;
            esac ;;
    esac
done
printf 'package paths: private command, config, temp and symlink paths verified\n'