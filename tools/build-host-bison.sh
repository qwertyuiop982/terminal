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
sh "$ROOT/tools/build-host-gperf.sh"
command -v flex >/dev/null 2>&1 || { echo 'host flex is required to generate Bison scanners' >&2; exit 1; }
PATH="$ROOT/build-ext/host/gperf/bin:$PATH"
export PATH
if [ ! -f "$SOURCE/configure.ac" ]; then
    mkdir -p "$SOURCE"
    tar -xzf "$ARCHIVE" -C "$SOURCE" --strip-components=1
fi
# The GitHub tag archive omits the Autoconf submodule behind these host-only links.
# Use the host's installed Autoconf m4 data, never target Android binaries.
AUTOCONF_M4SUGAR_DIR=${AUTOCONF_M4SUGAR_DIR:-/usr/share/autoconf/m4sugar}
for name in foreach m4sugar; do
    [ -r "$AUTOCONF_M4SUGAR_DIR/$name.m4" ] || {
        echo "missing host Autoconf m4 data: $name.m4" >&2; exit 1;
    }
    mkdir -p "$SOURCE/submodules/autoconf/lib/m4sugar"
    cp "$AUTOCONF_M4SUGAR_DIR/$name.m4" "$SOURCE/submodules/autoconf/lib/m4sugar/$name.m4"
done
mkdir -p "$SOURCE/gnulib/build-aux"
cp "$GNULIB/build-aux/move-if-change" "$SOURCE/gnulib/build-aux/move-if-change"
if grep -Fq -- '--po-base=gnulib-po' "$SOURCE/bootstrap.conf"; then
    patch --batch --fuzz=0 -d "$SOURCE" -p1 < "$ROOT/third_party/apt/host/bison-no-translations.patch"
fi
if grep -Fq 'AC_PROG_GNU_M4' "$SOURCE/configure.ac"; then
    patch --batch --fuzz=0 -d "$SOURCE" -p1 < "$ROOT/third_party/apt/host/bison-gnulib-m4.patch"
fi
if ! grep -Fq '/* dll_dirs */ NULL' "$SOURCE/src/output.c"; then
    patch --batch --fuzz=0 -d "$SOURCE" -p1 < "$ROOT/third_party/apt/host/bison-gnulib-spawn.patch"
fi
if ! grep -Fq '/* dll_dirs */ NULL' "$SOURCE/src/print-xml.c"; then
    patch --batch --fuzz=0 -d "$SOURCE" -p1 < "$ROOT/third_party/apt/host/bison-gnulib-execute.patch"
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
# GitHub's tag archive does not contain generated gettext Makevars files.
# The host parser needs their upstream templates even with NLS disabled.
for po in po runtime-po; do
    [ -f "$SOURCE/$po/Makevars" ] || cp "$SOURCE/$po/Makevars.template" "$SOURCE/$po/Makevars"
done
if [ ! -x "$OUT/bin/bison" ]; then
    mkdir -p "$OUT/build"
    if [ ! -f "$OUT/build/Makefile" ] || grep -Fxq 'LEX = :' "$OUT/build/Makefile"; then
        (cd "$OUT/build" && "$SOURCE/configure" --prefix="$OUT" --disable-nls)
    fi
    (cd "$OUT/build" && ./config.status po/Makefile.in runtime-po/Makefile.in gnulib-po/Makefile.in po-directories)
    make -j"${ANDROID_BUILD_JOBS:-2}" -C "$OUT/build" src/bison
    make -C "$OUT/build" install-binPROGRAMS install-dist_m4sugarDATA \
        install-dist_skeletonsDATA install-dist_pkgdataDATA
fi
"$OUT/bin/bison" --version | head -1