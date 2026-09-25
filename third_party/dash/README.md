# dash 0.5.13.5

Upstream: Herbert Xu, http://gondor.apana.org.au/~herbert/dash/files/dash-0.5.13.5.tar.gz
License: BSD-3-Clause and additional notices in `COPYING`.

This tree vendors the upstream tarball. `tools/build-dash.sh` cross-compiles it
with the Android NDK (API 24) and applies two bionic compatibility fixes:

- `ac_cv_func_sigsetmask=no`, because bionic does not provide `sigsetmask(3)`.
- `android-bionic.patch.py`, because bionic `waitpid(3)` takes three arguments
  and dash's fallback incorrectly passes a fourth.

The resulting PIE executables are stored as:

- `app/src/main/assets/bin/dash-arm64-v8a`
- `app/src/main/assets/bin/dash-armeabi-v7a`

The same bytes are also packaged as `libdash.so` so Android can extract them
into the executable native-library directory on API 29 and newer.
