# Building Terminal

## Android app

Use JDK 17, Android SDK Platform 35, Android Build Tools 35.0.0, and Android NDK 29.0.14206865. The Gradle wrapper is included. Set `ANDROID_HOME` to your SDK directory, or put `sdk.dir=/absolute/path/to/sdk` in an untracked `local.properties` file.

```sh
./gradlew --no-daemon :app:assembleDebug :app:assembleRelease :app:lintDebug :app:lintRelease
```

The debug APK is written to `app/build/outputs/apk/debug/app-debug.apk`. Release assembly produces `app/build/outputs/apk/release/app-release-unsigned.apk`; sign it with your own keystore before distribution. Keep keystores and their passwords outside Git.

The release variant excludes the Debug HTTP API, its listener, and its service declaration. Debug builds include the optional development interface documented in [DEBUG_REMOTE.md](docs/DEBUG_REMOTE.md).

A source checkout includes the basic dash shell and PTY libraries for ARM64 and 32-bit ARM, so Gradle can build the base app without a staged extension toolkit. The published ARM64 APK additionally packages the tools built in the next section.

## Included ARM64 toolkit

Set `ANDROID_NDK_HOME` to your NDK directory. Native build scripts require Linux build tools, Python 3, Perl, Autoconf/Automake, CMake/Ninja, and the source archives and patches under `third_party/`. The pinned archives and checksum files are checked into the repository.

Clone the self-contained TinyCC source project beside Terminal before building the optional compiler:

```sh
git clone https://github.com/qwertyuiop982/tcc-0.9-bionic.git ../tcc-0.9-bionic
```

Run the stages in this order from the project root:

```sh
./tools/build-dash.sh
./tools/build-ext.sh arm64
./tools/build-userland.sh
./tools/build-dpkg.sh
./tools/build-busybox.sh
./tools/build-dash-edit.sh
./tools/build-file.sh
./tools/build-openssl.sh
./tools/build-apt.sh
./tools/build-gpgv.sh
./tools/check-private-runtime.sh
./gradlew --no-daemon :app:assembleDebug :app:assembleRelease :app:lintDebug :app:lintRelease
./tools/test-terminal-screen.sh
```

`build-ext.sh arm64` recreates its output tree, so rerun the following stages whenever you run it. Gradle packages `build-ext/out/arm64-v8a/final/` into assets while optional Nano/TinyCC packages remain separate. Build output is ignored by Git.

On ARM Linux hosts, Gradle's downloaded AAPT2 executable may target x86-64. Supply a working host-native AAPT2 explicitly when needed:

```sh
./gradlew -Pandroid.aapt2FromMavenOverride=/absolute/path/to/aapt2 :app:assembleDebug
```

The repository does not impose a machine-specific AAPT2 path. See [Sources and Build Details](docs/SOURCES_AND_BUILD.md) for native dependencies, archive provenance, private runtime paths, and ABI checks.

## Optional packages

Sources and build tooling for OpenJDK 17 and TinyCC are maintained in [openjdk-17-bionic](https://github.com/qwertyuiop982/openjdk-17-bionic) and [tcc-0.9-bionic](https://github.com/qwertyuiop982/tcc-0.9-bionic). Their Android `.deb` packages are Release assets, not Gradle dependencies.
