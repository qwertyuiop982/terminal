# dash 0.5.13.5

Upstream: Herbert Xu, http://gondor.apana.org.au/~herbert/dash/files/dash-0.5.13.5.tar.gz
License: BSD-3-Clause and additional notices in `COPYING`.

This tree vendors the upstream tarball. `tools/build-dash.sh` verifies its
checksum and cross-compiles it with the Android NDK (API 24). The Android
adaptations are:

- `ac_cv_func_sigsetmask=no`, because bionic does not provide `sigsetmask(3)`.
- `android-bionic.patch.py`, because bionic `waitpid(3)` takes three arguments
  and dash's fallback incorrectly passes a fourth.
- `android-private-path.patch` points the default PATH and the ENOEXEC shell
  fallback at the app-owned prefix, not Android's system commands.
- `android-access.patch` uses `access()` for app-owned 0700 executables;
  `faccessat(..., AT_EACCESS)` rejects them on the tested Android device.

The resulting PIE executables are stored as:

- `app/src/main/assets/bin/dash-arm64-v8a`
- `app/src/main/assets/bin/dash-armeabi-v7a`

The app targets SDK 28 and installs the matching binary directly as
`files/usr/bin/dash` and `files/usr/bin/sh`.
