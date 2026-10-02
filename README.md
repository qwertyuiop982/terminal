# Terminal

A terminal for Android that brings a shell, everyday command-line tools, and an optional C and Java workspace to your phone.

Terminal opens directly into your own working directory. Use it to manage files, run scripts, explore command-line tools, or work on small programming projects without rooting your device.

## What you can do

- **Work at a real shell prompt.** Run commands and scripts, edit command lines, and recall command history.
- **Use touch-friendly terminal controls.** Ctrl, Esc, Tab, and arrow keys sit above the keyboard. Swipe through previous output, or connect a hardware keyboard.
- **Handle everyday files.** List, search, copy, move, compare, and archive files with the included tools.
- **Add tools when you need them.** Install Nano for text editing, TinyCC for C, or OpenJDK 17 for command-line Java from a compatible, signed package source.
- **Keep your workspace together.** The shell, tools, and home directory live in the app's own storage.

## Download

Get the installable APK from [Terminal 1.0.1](https://github.com/qwertyuiop982/terminal/releases/tag/terminal-v1.0.1), or browse [all releases](https://github.com/qwertyuiop982/terminal/releases).

If GitHub downloads are slow, prefix the original asset URL with `https://gh-proxy.org/` or `https://gh.xmly.dev/`:

```text
https://gh-proxy.org/https://github.com/qwertyuiop982/terminal/releases/download/terminal-v1.0.1/terminal-1.0.1.apk
```

Install the APK, open Terminal, tap the terminal area to show your keyboard, and try:

```sh
pwd
ls
echo "Hello from Terminal"
```

## Device support

Android 7.0 or newer is required. ARM64 devices have the full included toolkit and optional development packages. The APK also includes a basic shell for 32-bit ARM devices; the additional toolkit is currently ARM64 only.

Package installation needs a configured Terminal-compatible package source. See [Terminal Packages](https://github.com/qwertyuiop982/terminal/tree/main-repo) for setup. The app starts without a preconfigured public package server.

## C and Java tools

The companion projects provide the sources for the optional programming tools:

- [OpenJDK 17 Bionic](https://github.com/qwertyuiop982/openjdk-17-bionic): a command-line Java runtime, compiler, and tools for Android.
- [TinyCC 0.9 Bionic](https://github.com/qwertyuiop982/tcc-0.9-bionic): a small C compiler for quick builds and experiments on Android.

The APK and optional `.deb` packages are distributed through [Terminal Releases](https://github.com/qwertyuiop982/terminal/releases).

## For contributors

The Android app lives on `main`; the package server lives on `main-repo`. See [Building Terminal](BUILDING.md) for the build instructions and [the development roadmap](docs/ROADMAP.md) for current work. Third-party licenses are included with their sources and packaged tools.
