#!/bin/sh
# Prepare pinned GnuPG/gpgv and library sources from their GitHub mirrors.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
ARCHIVES="$ROOT/third_party/apt/gnupg"
WORK="$ROOT/build-ext/src/apt-gnupg"
(cd "$ARCHIVES" && sha256sum -c SHA256SUMS)
mkdir -p "$WORK"

prepare() {
    archive=$1
    name=$2
    source="$WORK/$name"
    if [ ! -f "$source/configure.ac" ]; then
        mkdir -p "$source"
        tar -xzf "$ARCHIVES/$archive" -C "$source" --strip-components=1
    fi
    if [ ! -f "$source/configure" ]; then
        (cd "$source" && sh ./autogen.sh --force)
    fi
    [ -f "$source/configure" ] || { printf 'configure was not generated for %s\n' "$name" >&2; exit 1; }
}

prepare libassuan-2.5.7.tar.gz libassuan-2.5.7
prepare libksba-1.6.7.tar.gz libksba-1.6.7
prepare npth-1.7.tar.gz npth-1.7
prepare gnupg-2.4.8.tar.gz gnupg-2.4.8
if grep -Fq 'try_set_envvar ("PATH", "/usr/local/bin:/usr/bin:/bin", silent);' \
    "$WORK/gnupg-2.4.8/common/sysutils.c" &&
    ! grep -Fq '"/data/data/com.terminal/files/usr/libexec", silent);' \
        "$WORK/gnupg-2.4.8/common/sysutils.c"; then
    patch --batch --fuzz=0 -d "$WORK/gnupg-2.4.8" -p1 < "$ARCHIVES/android-private-path.patch"
fi
# GitHub archives omit the generated headers shipped in release tarballs.
# Generate them with GnuPG's own AWK scripts before building individual targets.
common="$WORK/gnupg-2.4.8/common"
if [ ! -s "$common/status-codes.h" ]; then
    awk -f "$common/exstatus.awk" "$common/status.h" |
        awk -f "$common/mkstrtable.awk" -v textidx=3 -v nogettext=1 \
            -v pkg_namespace=statusstr_ > "$common/status-codes.h"
fi
if [ ! -s "$common/audit-events.h" ]; then
    awk -f "$common/exaudit.awk" "$common/audit.h" |
        awk -f "$common/mkstrtable.awk" -v textidx=3 -v nogettext=1 \
            -v pkg_namespace=eventstr_ > "$common/audit-events.h"
fi
regexp="$WORK/gnupg-2.4.8/regexp"
if [ ! -s "$regexp/_unicode_mapping.c" ]; then
    awk -f "$regexp/parse-unidata.awk" "$regexp/UnicodeData.txt" > "$regexp/_unicode_mapping.c"
fi
if grep -Fq '#if @INSERT_EXPOSE_RWLOCK_API@' "$WORK/npth-1.7/src/npth.h.in"; then
    patch --batch --fuzz=0 -d "$WORK/npth-1.7" -p1 < "$ARCHIVES/android-npth-rwlock.patch"
fi
printf 'GnuPG source and dependencies prepared under %s\n' "$WORK"