#!/bin/sh
# Verify pinned upstream apt sources and apply the Android-private shell path.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
SRC="$ROOT/build-ext/src/apt-2.8.1"
DEPS="$ROOT/third_party/apt"
(cd "$DEPS" && sha256sum -c SHA256SUMS)
if [ ! -f "$SRC/CMakeLists.txt" ]; then
    mkdir -p "$ROOT/build-ext/src"
    tar -xjf "$DEPS/apt-2.8.1.tar.bz2" -C "$ROOT/build-ext/src"
fi
if grep -Fq 'Args[0] = "/bin/sh";' "$SRC/apt-pkg/deb/dpkgpm.cc"; then
    patch --batch --fuzz=0 -d "$SRC" -p1 < "$DEPS/android-private-shell.patch"
fi
if grep -Fq 'PRIVATE -lutil' "$SRC/apt-pkg/CMakeLists.txt"; then
    patch --batch --fuzz=0 -d "$SRC" -p1 < "$DEPS/android-openssl-cmake.patch"
fi
if grep -Fq '#ifdef HAVE_GNUTLS' "$SRC/methods/http.cc"; then
    sed -i 's/^#ifdef HAVE_GNUTLS$/#if defined(HAVE_GNUTLS) || defined(HAVE_OPENSSL)/' "$SRC/methods/http.cc"
fi
if grep -Fq 'inline char* setlocale' "$SRC/CMake/apti18n.h.in"; then
    patch --batch --fuzz=0 -d "$SRC" -p1 < "$DEPS/android-bionic-i18n.patch"
fi
if ! grep -Fq 'if (ANDROID_GNULIB_GLOB)' "$SRC/apt-pkg/CMakeLists.txt"; then
    patch --batch --fuzz=0 -d "$SRC" -p1 < "$DEPS/android-bionic-glob.patch"
fi
if ! grep -Fq 'pkgcachegen.h includes xxhash.h' "$SRC/apt-pkg/CMakeLists.txt"; then
    patch --batch --fuzz=0 -d "$SRC" -p1 < "$DEPS/android-xxhash-include.patch"
fi
if ! grep -Fq "Only the application's own temp directory" "$SRC/apt-pkg/contrib/fileutl.cc"; then
    if grep -Fq 'if (chdir(GetTempDir().c_str()) != 0)' "$SRC/apt-pkg/contrib/fileutl.cc"; then
        echo 'APT source has a partial private-temp patch; keep the source and apply its missing hunk before rebuilding' >&2
        exit 1
    fi
    patch --batch --fuzz=0 -d "$SRC" -p1 < "$DEPS/android-private-tmp.patch"
fi
if ! grep -Fq 'private prefix is not a chroot' "$SRC/apt-pkg/aptconfiguration.cc"; then
    patch --batch --fuzz=0 -d "$SRC" -p1 < "$DEPS/android-private-bin.patch"
fi
if grep -Fq 'getservbyport_r(' "$SRC/apt-pkg/contrib/srvrec.cc"; then
    patch --batch --fuzz=0 -d "$SRC" -p1 < "$DEPS/android-bionic-srvrec.patch"
fi
if grep -Fxq 'if(HAVE_LIBC_RESOLV)' "$SRC/CMakeLists.txt"; then
    patch --batch --fuzz=0 -d "$SRC" -p1 < "$DEPS/android-bionic-resolv.patch"
fi
if ! grep -Fq 'defined(__ANDROID__) && __ANDROID_API__ < 26' "$SRC/apt-pkg/deb/debrecords.cc"; then
    patch --batch --fuzz=0 -d "$SRC" -p1 < "$DEPS/android-bionic-locale.patch"
fi
if grep -Fq 'inline iterator_type operator+(typename container_iterator::difference_type const &n) {' "$SRC/apt-pkg/cacheset.h"; then
    patch --batch --fuzz=0 -d "$SRC" -p1 < "$DEPS/android-libcxx-iterator.patch"
fi
if grep -Fq 'uint32_t const RAMFS_MAGIC' "$SRC/apt-private/private-download.cc"; then
    patch --batch --fuzz=0 -d "$SRC" -p1 < "$DEPS/android-bionic-ramfs.patch"
fi
if grep -Fq 'Res = regcomp(&Pattern, nl_langinfo(YESEXPR),' "$SRC/apt-private/private-output.cc" &&
    ! grep -Fq 'No nl_langinfo on API 24' "$SRC/apt-private/private-output.cc"; then
    patch --batch --fuzz=0 -d "$SRC" -p1 < "$DEPS/android-bionic-yesexpr.patch"
fi
for source in apt-pkg/deb/dpkgpm.cc apt-pkg/contrib/fileutl.cc \
    apt-private/private-json-hooks.cc methods/rsh.cc cmdline/apt-key.in; do
    if grep -Fq '"/bin/sh"' "$SRC/$source" ||
        grep -Fq '#!/bin/sh' "$SRC/$source"; then
        printf 'apt source still refers to the system shell: %s\n' "$source" >&2
        exit 1
    fi
done
printf 'apt source prepared at %s\n' "$SRC"