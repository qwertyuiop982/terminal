#!/bin/sh
# Cross-compile tcc (mob), dpkg (1.22.6) and their compression libraries
# for Android with the NDK, then stage everything under app/src/main/assets.
#
# Reference: termux-packages packages/tcc/build.sh (two-stage build with the
# host tcc kept for libtcc1.a) and packages/dpkg/build.sh (configure args).
#
# Usage:
#   ./tools/build-ext.sh          # build for both ABIs and stage assets
#   ./tools/build-ext.sh arm64    # build only arm64-v8a
#   ./tools/build-ext.sh arm      # build only armeabi-v7a
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
NDK=${ANDROID_NDK_HOME:-/root/Android/ndk/29.0.14206865}
API=${ANDROID_API:-24}
BIN="$NDK/toolchains/llvm/prebuilt/linux-$(uname -m)/bin"
TARBALL_DIR="$ROOT/third_party"
WORK="$ROOT/build-ext"
SRC="$WORK/src"
OUT="$WORK/out"
ASSETS="$ROOT/app/src/main/assets"
JOBS=$(nproc)

if [ ! -x "$BIN/clang" ]; then
  echo "NDK toolchain not found at $BIN" >&2
  exit 1
fi

mkdir -p "$OUT"

# ---------- ABI selection ----------
build_all=false
case "${1:-all}" in
  all) build_all=true ;;
  arm64) ABIS="arm64-v8a" ;;
  arm)   ABIS="armeabi-v7a" ;;
  *) echo "usage: $0 [all|arm64|arm]" >&2; exit 1 ;;
esac
[ "$build_all" = true ] && ABIS="arm64-v8a armeabi-v7a"

# ---------- per-ABI toolchain variables ----------
abi_triple() {
  case "$1" in
    arm64-v8a)   echo "aarch64-linux-android$API" ;;
    armeabi-v7a) echo "armv7a-linux-androideabi$API" ;;
    *) echo "unsupported ABI: $1" >&2; exit 1 ;;
  esac
}
abi_host_triple() {
  case "$1" in
    arm64-v8a)   echo "aarch64-linux-android" ;;
    armeabi-v7a) echo "arm-linux-androideabi" ;;
  esac
}
abi_cpu() {
  case "$1" in
    arm64-v8a)   echo "aarch64" ;;
    armeabi-v7a) echo "arm" ;;
  esac
}
# Termux tcc: ELF interpreter differs between 32/64-bit Android.
abi_interpreter() {
  case "$1" in
    arm64-v8a)   echo "/system/bin/linker64" ;;
    armeabi-v7a) echo "/system/bin/linker" ;;
  esac
}
abi_libdirs() {
  case "$1" in
    arm64-v8a)   echo "/system/lib64:/system/vendor/lib64" ;;
    armeabi-v7a) echo "/system/lib:/system/vendor/lib" ;;
  esac
}
# dpkg calls this arch triplet; Termux uses the same names.
abi_dpkg_arch() {
  case "$1" in
    arm64-v8a)   echo "linux-arm64" ;;
    armeabi-v7a) echo "linux-armhf" ;;
  esac
}

ABI=$1_TARGET 2>/dev/null || true
for ABI in $ABIS; do
  TRIPLE=$(abi_triple "$ABI")
  HOST=$(abi_host_triple "$ABI")
  CPU=$(abi_cpu "$ABI")
  CC="$BIN/$TRIPLE-clang"
  DEST="$OUT/$ABI"
  # On the device the prefix is always /data/data/com.terminal/files/usr;
  # tcc and dpkg hardcode paths at configure time, so configure against the
  # DEVICE path while keeping build artifacts in the local stage tree.
  DEV_PREFIX="/data/data/com.terminal/files/usr"
  STAGE="$DEST/stage"
  rm -rf "$DEST"
  mkdir -p "$STAGE"
  COMMON_FLAGS="-O2 -D_FILE_OFFSET_BITS=32 -fPIC"
  LDFLAGS_COMMON="-fPIC -Wl,-z,max-page-size=16384"
  echo "===== ABI $ABI (triple $TRIPLE) ====="

  # ---------- bzip2 ----------
  (
    cd "$SRC"
    rm -rf "bz2-$ABI"
    tar -xzf "$TARBALL_DIR/bzip2/bzip2-1.0.8.tar.gz"
    mv bzip2-1.0.8 "bz2-$ABI"
    cd "bz2-$ABI"
    make -j"$JOBS" -f Makefile-libbz2_so \
      CC="$CC" AR="$BIN/llvm-ar" RANLIB="$BIN/llvm-ranlib" \
      "CFLAGS=$COMMON_FLAGS -fpic" LDFLAGS="$LDFLAGS_COMMON -shared -Wl,-soname -Wl,libbz2.so.1.0"
    cp -f libbz2.so.1.0 "$STAGE/"
    make -j"$JOBS" bzip2 \
      CC="$CC" AR="$BIN/llvm-ar" RANLIB="$BIN/llvm-ranlib" \
      "CFLAGS=$COMMON_FLAGS" LDFLAGS="$LDFLAGS_COMMON"
    cp -f bzip2 "$STAGE/"
  )

  # ---------- zlib ----------
  (
    cd "$SRC"
    rm -rf "zlib-$ABI"
    tar -xzf "$TARBALL_DIR/zlib/zlib-1.3.1.tar.gz"
    mv zlib-1.3.1 "zlib-$ABI"
    cd "zlib-$ABI"
    CHOST=$HOST \
    CC="$CC" AR="$BIN/llvm-ar" RANLIB="$BIN/llvm-ranlib" STRIP="$BIN/llvm-strip" \
    CFLAGS="$COMMON_FLAGS" LDFLAGS="$LDFLAGS_COMMON" \
    ./configure --static
    make -j"$JOBS" libz.a
    # Static-only build: skip all program/example targets so no host-side
    # link against the missing shared libz ever happens.
    make -j"$JOBS" -k shared || true
    cp -f libz.a "$STAGE/" 2>/dev/null || true
    if [ -f libz.so.1.3.1 ]; then
      cp -f libz.so.1.3.1 "$STAGE/"
      ln -sf libz.so.1.3.1 "$STAGE/libz.so.1"
      ln -sf libz.so.1.3.1 "$STAGE/libz.so"
    fi
  )

  # ---------- xz (liblzma) ----------
  (
    cd "$SRC"
    rm -rf "xz-$ABI"
    tar -xf "$TARBALL_DIR/xz/xz-5.6.3.tar.gz"
    mv xz-5.6.3 "xz-$ABI"
    cd "xz-$ABI"
    mkdir -p build-"$ABI"
    cd build-"$ABI"
    PKG_CONFIG_PATH= \
    CC="$CC" AR="$BIN/llvm-ar" RANLIB="$BIN/llvm-ranlib" STRIP="$BIN/llvm-strip" \
    CFLAGS="$COMMON_FLAGS" LDFLAGS="$LDFLAGS_COMMON" \
    ../configure \
      --host="$HOST" \
      --disable-silent-rules \
      --disable-xz --disable-xzdec --disable-lzmadec --disable-lzmainfo \
      --disable-lzma-links --disable-scripts --disable-doc \
      --disable-nls \
      --with-pic
        make -j"$JOBS" -C src/liblzma
    cd src/liblzma
    cp -f .libs/liblzma.a "$STAGE/"
    # libtool on Android emits an unversioned liblzma.so (its SONAME is
    # liblzma.so); provide the usual alias names on top of it.
    if [ -f .libs/liblzma.so ]; then
      cp -f .libs/liblzma.so "$STAGE/liblzma.so.5.6.3"
      ln -sf liblzma.so.5.6.3 "$STAGE/liblzma.so.5"
      ln -sf liblzma.so.5.6.3 "$STAGE/liblzma.so"
    fi
    cd ../../..
    # Compression headers are needed later when compiling dpkg against the
    # staged libs, and are useful on-device for tcc; ship them in the tree.
    Z="$SRC/xz-$ABI/src/liblzma/api"
    mkdir -p "$STAGE/include"
    cp -f "$Z/lzma.h" "$STAGE/include/"
    cp -rf "$Z/lzma" "$STAGE/include/"
    cp -f "$SRC/zlib-$ABI/zlib.h" "$SRC/zlib-$ABI/zconf.h" "$STAGE/include/"
    cp -f "$SRC/bz2-$ABI/bzlib.h" "$STAGE/include/"
    cp -f "$SRC/zstd-$ABI/lib/zstd.h" "$STAGE/include/"
  )

  # ---------- zstd ----------
  (
    cd "$SRC"
    rm -rf "zstd-$ABI"
    tar -xzf "$TARBALL_DIR/zstd/zstd-1.5.6.tar.gz"
    mv zstd-1.5.6 "zstd-$ABI"
    cd "zstd-$ABI/lib"
    make -j"$JOBS" libzstd.a \
      CC="$CC" AR="$BIN/llvm-ar" RANLIB="$BIN/llvm-ranlib" \
      CFLAGS="$COMMON_FLAGS" LDFLAGS="$LDFLAGS_COMMON"
    cp -f libzstd.a "$STAGE/"
  )

  # ---------- libmd (md5/sha digests required by dpkg) ----------
  (
    cd "$SRC"
    rm -rf "libmd-$ABI"
    tar -xJf "$TARBALL_DIR/libmd/libmd-1.1.0.tar.xz"
    mv libmd-1.1.0 "libmd-$ABI"
    cd "libmd-$ABI"
    mkdir -p build-"$ABI"
    cd build-"$ABI"
    CC="$CC" AR="$BIN/llvm-ar" RANLIB="$BIN/llvm-ranlib" STRIP="$BIN/llvm-strip" \
    CFLAGS="$COMMON_FLAGS" LDFLAGS="$LDFLAGS_COMMON" \
    ../configure --host="$HOST" --disable-shared --disable-doc
    make -j"$JOBS" -C src
    cp -f src/.libs/libmd.a "$STAGE/"
    if [ -f src/.libs/libmd.so.0.1.0 ] || [ -f src/.libs/libmd.so ]; then
      SOF=$(ls src/.libs/libmd.so* 2>/dev/null | grep -v '\.so\.' | head -1)
      [ -f "$SOF" ] && cp -f "$SOF" "$STAGE/libmd.so.0.1.0" && \
        ln -sf libmd.so.0.1.0 "$STAGE/libmd.so.0" && \
        ln -sf libmd.so.0.1.0 "$STAGE/libmd.so"
    fi
    mkdir -p "$STAGE/include"
    cp -f ../src/*.h "$STAGE/include/" 2>/dev/null || true
  )

  # ---------- tcc (two-stage, per Termux) ----------
  (
    cd "$SRC"
    rm -rf "tcc-$ABI"
    tar -xzf "$TARBALL_DIR/tcc/tinycc-mob-20260922.tar.gz"
    mv tinycc "tcc-$ABI"
    cd "tcc-$ABI"

    # Stage 1: build a host tcc that will assemble libtcc1.a later.
    sysinc=
    otherinc=
    for d in $(echo | "$CC" -E -x c - -v 2>&1 | \
        sed -n '/^#include <...> search/,/^End/p' | \
        grep '^[[:space:]]'); do
      case "$d" in
        */sysroot/usr/*) sysinc="$sysinc$(readlink -f "$d"):" ;;
        *) otherinc="$otherinc$(readlink -f "$d"):" ;;
      esac
    done
    sysinc="${sysinc}${otherinc%:}"

    ./configure --prefix="/tmp/tcc.host.$ABI" --cpu="$CPU" \
      --sysincludepaths="$sysinc"
    make -j"$JOBS" tcc
    mv -f tcc tcc.host
    make distclean >/dev/null

    # Stage 2: cross tcc that runs on Android. Paths are configured against the
    # on-device prefix so tcc finds libtcc1/crt/headers at runtime.
    ./configure \
      --prefix="$DEV_PREFIX" \
      --cross-prefix="$BIN/${TRIPLE}-" \
      --cc=clang \
      --cpu="$CPU" \
      --disable-rpath \
      --elfinterp="$(abi_interpreter "$ABI")" \
      --crtprefix="$DEV_PREFIX/lib/tcc/crt" \
      --sysincludepaths="$DEV_PREFIX/include:$DEV_PREFIX/lib/tcc/include" \
      --libpaths="$DEV_PREFIX/lib:/system/lib64:/system/vendor/lib64:/system/lib:/system/vendor/lib"
    # c2str.exe is a build-time host tool; the cross-configured Makefile would
    # build it with the Android clang (cannot run on this machine). Compile it
    # with the host compiler instead and generate tccdefs_.h up front.
    gcc -DC2STR conftest.c -o c2str.exe
    ./c2str.exe include/tccdefs.h tccdefs_.h
    # tcc's Makefile derives AR/other tools from --cross-prefix but the NDK
    # only ships llvm-ar; override the tool variables explicitly. bionic has
    # pthread/dl built in, so strip -lpthread/-ldl from LIBS.
    make -j"$JOBS" tcc AR="$BIN/llvm-ar" LIBS="-lm"
    mv -f tcc tcc.cross
    cp -f tcc.host tcc
    # Compile libtcc1 objects with the NDK clang (which runs here) and pack
    # the archive with llvm-ar. The plain `make libtcc1.a` flow would need a
    # runnable target tcc, which we do not have while cross-building.
    ( cd lib &&
      # arm64 runtime support: lib-arm64.c plus the generic helpers.
      # armflush.c uses __arm64_clear_cache which only exists when compiled
      # by tcc itself; with clang provide a small inline equivalent instead.
      for c in lib-arm64.c libtcc1.c stdatomic.c builtin.c dsohandle.c; do
        "$CC" -c "$c" -o "${c%.c}.o" -I.. -B.. -O2 -fPIC || exit 1
      done
      cat > armflush-clang.c <<'CEOF'
#include <stdint.h>
#include <sys/mman.h>
#include <unistd.h>
void __clear_cache(void *beg, void *end) {
    const long CACHESIZE = 4096;
    uintptr_t p = (uintptr_t) beg & ~(CACHESIZE - 1);
    uintptr_t e = (uintptr_t) end;
    for (; p < e; p += CACHESIZE) __builtin___clear_cache((char *) p, (char *) (p + CACHESIZE));
    (void) 0;
}
CEOF
      "$CC" -c armflush-clang.c -o armflush.o -O2 -fPIC || exit 1
      for s in atomic.S alloca.S alloca-bt.S; do
        "$CC" -c "$s" -o "${s%.S}.o" -I.. -B.. || exit 1
      done
      "$BIN/llvm-ar" rcs ../libtcc1.a \
        libtcc1.o lib-arm64.o stdatomic.o atomic.o builtin.o \
        alloca.o alloca-bt.o dsohandle.o armflush.o
    )
    rm -f tcc
    mv -f tcc.cross tcc
    # Do not run `make install`; stage files manually so nothing depends on
    # the host layout.
    "$BIN/llvm-strip" -s tcc
    cp -f tcc "$STAGE/tcc"
    mkdir -p "$STAGE/lib/tcc"
    if [ -f libtcc1.a ]; then
      cp -f libtcc1.a "$STAGE/lib/tcc/libtcc1.a"
    fi
    if [ -f include/tcclib.h ]; then
      cp -f include/tcclib.h "$STAGE/include/"
    fi
    # NDK bionic headers + crt objects so tcc can compile real programs on
    # device (mirrors Termux shipping the sysroot pieces tcc needs).
    mkdir -p "$STAGE/lib/tcc/crt"
    SYSROOT="$NDK/toolchains/llvm/prebuilt/linux-$(uname -m)/sysroot"
    cp -f "$SYSROOT/usr/lib/$HOST/$API/"crt*.o "$STAGE/lib/tcc/crt/" 2>/dev/null || true
    cp -f "$SYSROOT/usr/lib/$HOST/$API/"libgcc.a "$STAGE/lib/tcc/" 2>/dev/null || true
    mkdir -p "$STAGE/include/$HOST"
    for d in "$SYSROOT/usr/include"/*; do
      b=$(basename "$d")
      case "$b" in
        aarch64-linux-android|arm-linux-androideabi|i686-linux-android|x86_64-linux-android) ;;
        *) cp -rf "$d" "$STAGE/include/" 2>/dev/null || true ;;
      esac
    done
    cp -rf "$SYSROOT/usr/include/$HOST"/* "$STAGE/include/" 2>/dev/null || true
  )

  # ---------- dpkg ----------
  (
    cd "$SRC"
    rm -rf "dpkg-$ABI"
    tar -xJf "$TARBALL_DIR/dpkg/dpkg-1.22.6.tar.xz"
    mv dpkg-1.22.6 "dpkg-$ABI"
    cd "dpkg-$ABI"
    mkdir -p build-"$ABI"
    cd build-"$ABI"

    ZLIB=$(cd "$STAGE" && pwd)
    export PKG_CONFIG_PATH="$ZLIB/pkgconfig"
    mkdir -p "$ZLIB/pkgconfig"
    cat > "$ZLIB/pkgconfig/zlib.pc" <<EOF
prefix=$ZLIB
libdir=\${prefix}
includedir=\${prefix}

Name: zlib
Description: zlib compression library
Version: 1.3.1
Libs: -L\${libdir} -lz
Cflags: -I\${includedir}
EOF
    cat > "$ZLIB/pkgconfig/liblzma.pc" <<EOF
prefix=$ZLIB
libdir=\${prefix}
includedir=\${prefix}

Name: liblzma
Description: XZ-format compression library
Version: 5.6.3
Libs: -L\${libdir} -llzma
Cflags: -I\${includedir}
EOF
    cat > "$ZLIB/pkgconfig/libzstd.pc" <<EOF
prefix=$ZLIB
libdir=\${prefix}
includedir=\${prefix}

Name: zstd
Description: Zstandard compression library
Version: 1.5.6
Libs: -L\${libdir} -lzstd
Cflags: -I\${includedir}
EOF

    CC="$CC" AR="$BIN/llvm-ar" RANLIB="$BIN/llvm-ranlib" STRIP="$BIN/llvm-strip" \
    CPPFLAGS="-I$STAGE/include" \
    LDFLAGS="-L$STAGE $LDFLAGS_COMMON" \
    LIBS="-lmd" \
    CFLAGS="$COMMON_FLAGS" \
    ../configure \
      --host="$HOST" \
      --prefix="$DEV_PREFIX" \
      --localstatedir="$DEV_PREFIX/var" \
      --sysconfdir="$DEV_PREFIX/etc" \
      --with-mount-point=/system/bin/mount \
      --disable-dselect \
      --disable-largefile \
      --disable-shared \
      --disable-nls \
      --disable-start-stop-daemon \
      --without-selinux \
      ac_cv_lib_selinux_setexecfilecon=no \
      dpkg_cv_c99_snprintf=yes
    make -j"$JOBS"
    # Install into a scratch tree, then copy the runtime bits we need.
    make install DESTDIR="$DEST/dpkg-stage" >/dev/null
  )

  # ---------- collect and package ----------
  (
    cd "$DEST"
    # dpkg binaries live under dpkg-stage/<devprefix>/bin
    mkdir -p final/bin final/lib final/etc final/share
    if [ -d dpkg-stage ]; then
      find dpkg-stage -type f -path '*/bin/*' | while read -r f; do
        cp -f "$f" final/bin/
      done
      find dpkg-stage -type d -path '*share/dpkg' | head -1 | while read -r d; do
        cp -rf "$d/." final/share/dpkg/ 2>/dev/null || true
      done
      find dpkg-stage -type d -path '*etc/dpkg' | head -1 | while read -r d; do
        cp -rf "$d/." final/etc/dpkg/ 2>/dev/null || true
      done
      find dpkg-stage -type d -name alternatives | head -1 | while read -r d; do
        mkdir -p final/etc; cp -rf "$d" final/etc/ 2>/dev/null || true
      done
      find dpkg-stage -type d -name log | head -1 | while read -r d; do
        mkdir -p final/var; cp -rf "$d" final/var/ 2>/dev/null || true
      done
    fi
    # Stage everything the shell needs at runtime.
    for f in "$STAGE"/*; do
      b=$(basename "$f")
      case "$b" in
        lib*.so*|lib*.a) cp -rf "$f" final/lib/ ;;
        include)         cp -rf "$f" final/include ;;
        lib)             ;;
        pkgconfig)       ;;
        *)               cp -f "$f" final/bin/ ;;
      esac
    done
    [ -d "$STAGE/lib" ] && cp -rf "$STAGE/lib/." final/lib/
    # Executable bits for everything in bin.
    for f in final/bin/*; do
      [ -f "$f" ] && chmod 755 "$f"
    done
    # Package as one tar so the APK keeps a single entry per ABI.
    tar -czf "$ABI.tar.gz" -C final .
    echo "staged $ABI: $(du -sh final | cut -f1)"
  )
done

# ---------- stage into assets ----------
STAGE_ASSETS="$ASSETS/prefix"
mkdir -p "$STAGE_ASSETS"
for ABI in $ABIS; do
  cp -f "$OUT/$ABI/$ABI.tar.gz" "$STAGE_ASSETS/prefix-$ABI.tar.gz"
done
( cd "$STAGE_ASSETS" && sha256sum prefix-*.tar.gz > SHA256SUMS )

echo "done. assets at $STAGE_ASSETS:"
ls -la "$STAGE_ASSETS"