#!/bin/sh
# Build arm64 dash with NDK-built libedit/ncurses line editing; keep the basic 32-bit shell.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
NDK=${ANDROID_NDK_HOME:-/root/Android/ndk/29.0.14206865}
API=${ANDROID_API:-24}
BIN="$NDK/toolchains/llvm/prebuilt/linux-$(uname -m)/bin"
CC="$BIN/aarch64-linux-android${API}-clang"
PREFIX=/data/data/com.terminal/files/usr
OUT="$ROOT/build-ext/out/arm64-v8a"
NCROOT="$OUT/userland-stage$PREFIX"
LIBEDIT_SRC="$ROOT/build-ext/src/dash-libedit"
LIBEDIT_BUILD="$OUT/dash-libedit-build"
DASH_SRC="$ROOT/build-ext/src/dash-edit"
DASH_BUILD="$OUT/dash-edit-build"
LIBEDIT_ARCHIVE="$ROOT/third_party/dash/libedit/libedit-cabe0cf6.tar.gz"
DASH_ARCHIVE="$ROOT/third_party/dash/dash-0.5.13.5.tar.gz"
ASSETS="$ROOT/app/src/main/assets/bin"

[ -x "$CC" ] && [ -s "$NCROOT/lib/libncursesw.a" ] &&
    [ -s "$NCROOT/share/terminfo/x/xterm-256color" ] || {
    echo 'build-userland.sh must finish the pinned ncurses arm64 stage first' >&2
    exit 1
}
(cd "$ROOT/third_party/dash" && sha256sum -c SHA256SUMS)
(cd "$ROOT/third_party/dash/libedit" && sha256sum -c SHA256SUMS)
printf '#include <wchar.h>\n_Static_assert(sizeof(wchar_t) == 4, "Android wchar_t must be UTF-32");\n' |
    "$CC" -x c -c -o "$OUT/dash-edit-wchar.o" -
if [ ! -f "$LIBEDIT_SRC/configure" ]; then
    mkdir -p "$LIBEDIT_SRC"
    tar -xzf "$LIBEDIT_ARCHIVE" -C "$LIBEDIT_SRC" --strip-components=1
fi
if ! grep -Fq 'Bionic does not enumerate users' "$LIBEDIT_SRC/src/readline.c"; then
    patch --batch --fuzz=0 -d "$LIBEDIT_SRC" -p1 < "$ROOT/third_party/dash/libedit/android-api24.patch"
fi
# libedit's older configure checks -ltinfo; the build-only alias uses our
# NDK-built ncurses static archive and never enters the APK.
mkdir -p "$LIBEDIT_BUILD/compat"
ln -sf "$NCROOT/lib/libncursesw.a" "$LIBEDIT_BUILD/compat/libtinfo.a"
LIBEDIT_CPPFLAGS="-D__STDC_ISO_10646__=201103L -I$NCROOT/include/ncursesw -I$NCROOT/include"
if [ ! -f "$LIBEDIT_BUILD/Makefile" ]; then
    (cd "$LIBEDIT_BUILD" &&
        CC="$CC" AR="$BIN/llvm-ar" RANLIB="$BIN/llvm-ranlib" \
        CPPFLAGS="$LIBEDIT_CPPFLAGS" CFLAGS='-O2 -fPIC' \
        LDFLAGS="-L$LIBEDIT_BUILD/compat -L$NCROOT/lib -Wl,-z,max-page-size=16384" \
        LIBS='-lncursesw -lm' \
        "$LIBEDIT_SRC/configure" --host=aarch64-linux-android \
            --prefix="$PREFIX" --disable-shared --enable-static \
            --disable-examples --enable-widec)
fi
make -j"${ANDROID_BUILD_JOBS:-2}" -C "$LIBEDIT_BUILD/src" CPPFLAGS="$LIBEDIT_CPPFLAGS"
[ -s "$LIBEDIT_BUILD/src/.libs/libedit.a" ] || {
    echo 'libedit static library was not built' >&2
    exit 1
}

if [ ! -f "$DASH_SRC/configure" ]; then
    mkdir -p "$DASH_SRC"
    tar -xzf "$DASH_ARCHIVE" -C "$DASH_SRC" --strip-components=1
fi
if grep -Fq 'waitpid((pid_t)-1, status, flags, NULL)' "$DASH_SRC/src/jobs.c"; then
    python3 "$ROOT/third_party/dash/android-bionic.patch.py" "$DASH_SRC"
fi
if grep -Fq 'char *const path_bshell = _PATH_BSHELL;' "$DASH_SRC/src/exec.c"; then
    patch --batch --fuzz=0 -d "$DASH_SRC" -p1 < "$ROOT/third_party/dash/android-private-path.patch"
fi
if grep -Fq 'return !faccessat(AT_FDCWD, path, mode, AT_EACCESS);' "$DASH_SRC/src/bltin/test.c" &&
    ! grep -Fq "the app's real and effective UIDs match" "$DASH_SRC/src/bltin/test.c"; then
    patch --batch --fuzz=0 -d "$DASH_SRC" -p1 < "$ROOT/third_party/dash/android-access.patch"
fi
if grep -Fq '_PATH_TMP' "$DASH_SRC/src/histedit.c"; then
    patch --batch --fuzz=0 -d "$DASH_SRC" -p1 < "$ROOT/third_party/dash/android-private-edit-tmp.patch"
fi
if grep -Fq 'read_profile("/etc/profile");' "$DASH_SRC/src/main.c"; then
    patch --batch --fuzz=0 -d "$DASH_SRC" -p1 < "$ROOT/third_party/dash/android-private-profile.patch"
fi
mkdir -p "$DASH_BUILD"
DASH_LIBS="-ledit $NCROOT/lib/libncursesw.a -lm"
if [ ! -f "$DASH_BUILD/Makefile" ] ||
    ! grep -Fq "LIBS = $DASH_LIBS -ledit" "$DASH_BUILD/src/Makefile"; then
    (cd "$DASH_BUILD" &&
        PATH="$BIN:$PATH" ac_cv_func_sigsetmask=no \
        CC="$CC" AR="$BIN/llvm-ar" RANLIB="$BIN/llvm-ranlib" \
        CPPFLAGS="-I$LIBEDIT_SRC/src" CFLAGS='-O2 -fPIE' \
        LDFLAGS="-pie -Wl,-z,max-page-size=16384 -L$LIBEDIT_BUILD/src/.libs -L$LIBEDIT_BUILD/compat -L$NCROOT/lib" \
        LIBS="$DASH_LIBS" \
        "$DASH_SRC/configure" --host=aarch64-linux-android \
            --prefix="$PREFIX" --with-libedit)
    rm -f "$DASH_BUILD/src/dash" # Regenerate the binary after changing its link inputs.
fi
make -j"${ANDROID_BUILD_JOBS:-2}" -C "$DASH_BUILD"
[ -s "$DASH_BUILD/src/dash" ] || { echo 'editable dash was not built' >&2; exit 1; }
"$BIN/llvm-strip" -s "$DASH_BUILD/src/dash"
cp -f "$DASH_BUILD/src/dash" "$ASSETS/dash-arm64-v8a"
chmod 755 "$ASSETS/dash-arm64-v8a"
(cd "$ASSETS" && sha256sum dash-arm64-v8a dash-armeabi-v7a > SHA256SUMS)

# Keep terminfo separate from optional nano's package-owned files.
TERMINFO="$OUT/final/share/terminal/terminfo"
for name in x/xterm-256color x/xterm a/ansi; do
    mkdir -p "$TERMINFO/${name%/*}"
    cp -f "$NCROOT/share/terminfo/$name" "$TERMINFO/$name"
done
printf 'arm64 dash with line editing and private terminfo staged\n'
