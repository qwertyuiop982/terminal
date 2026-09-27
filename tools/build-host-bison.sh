#!/bin/sh
# Build the host-only parser generator for GnuPG from pinned upstream source.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
SOURCE="$ROOT/build-ext/src/host-bison"
GNULIB="$ROOT/build-ext/src/userland-arm64/gnulib"
OUT="$ROOT/build-ext/host/bison"
ARCHIVE="$ROOT/third_party/apt/host/bison-3.8.2.tar.gz"
(cd "$ROOT/third_party/apt/host" && sha256sum -c SHA256SUMS)
[ -x "$GNULIB/gnulib-tool" ] || { echo 'build-userland.sh must prepare the pinned gnulib snapshot' >&2; exit 1; }
if [ ! -f "$SOURCE/configure.ac" ]; then
    mkdir -p "$SOURCE"
    tar -xzf "$ARCHIVE" -C "$SOURCE" --strip-components=1
fi
if grep -Fq -- '--po-base=gnulib-po' "$SOURCE/bootstrap.conf"; then
    patch --batch --fuzz=0 -d "$SOURCE" -p1 < "$ROOT/third_party/apt/host/bison-no-translations.patch"
fi
if grep -Fq 'AC_PROG_GNU_M4' "$SOURCE/configure.ac"; then
    patch --batch --fuzz=0 -d "$SOURCE" -p1 < "$ROOT/third_party/apt/host/bison-gnulib-m4.patch"
fi
if [ ! -f "$SOURCE/Makefile.in" ]; then
    cp -f "$ROOT/third_party/apt/host/bison-version" "$SOURCE/.tarball-version"
    mkdir -p "$SOURCE/build-aux" "$SOURCE/gnulib-po"
    for name in config.guess config.sub compile install-sh depcomp mkinstalldirs; do
        cp -f "$GNULIB/build-aux/$name" "$SOURCE/build-aux/$name"
    done
    cp -f /usr/share/automake-1.16/missing "$SOURCE/build-aux/missing"
    if [ -s "$SOURCE/lib/gnulib.mk" ]; then
        (cd "$SOURCE" && AUTOPOINT=true LIBTOOLIZE=true \
            autoreconf --verbose --install --force --no-recursive)
    else
        (cd "$SOURCE" && sh ./bootstrap --gen --no-bootstrap-sync --no-git --gnulib-srcdir="$GNULIB")
    fi
    cp -f "$SOURCE/po/Makefile.in.in" "$SOURCE/gnulib-po/Makefile.in.in"
fi
if [ ! -x "$OUT/bin/bison" ]; then
    mkdir -p "$OUT/build"
    if [ ! -f "$OUT/build/Makefile" ]; then
        (cd "$OUT/build" && "$SOURCE/configure" --prefix="$OUT" --disable-nls)
    fi
    make -j3 -C "$OUT/build" all
    make -C "$OUT/build" install
fi
"$OUT/bin/bison" --version | head -1