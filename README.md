# Terminal Packages

Optional tools for [Terminal on Android](https://github.com/qwertyuiop982/terminal), with a small package server you can run on your own Debian or Termux machine.

Keep the app focused on the essentials, then add an editor, a compiler, or a Java workspace when you need one. Package downloads are hosted in GitHub Releases and can be fetched through `gh.xmly.dev` or `gh-proxy.org`.

## Available tools

| Tool | What it adds |
| --- | --- |
| Nano | A terminal text editor for notes, scripts, and source files. |
| TinyCC | A compact C compiler for quick programs and experiments. |
| OpenJDK 17 | A command-line Java runtime, compiler, and development tools. |

These packages are built for Terminal on ARM64 Android. The package server runs on Debian or Termux; it supplies packages for the Terminal app.

## Get the packages

Download the `.deb` files and checksum list from [Android Packages](https://github.com/qwertyuiop982/terminal/releases/tag/android-packages-20261002).

The installer automatically downloads that fixed Release through:

```text
https://gh.xmly.dev/https://github.com/qwertyuiop982/terminal/releases/download/android-packages-20261002/<asset-name>
```

Every package is checked against the checksum list shipped with this branch before it is imported.

## Run your package server

On a prepared Debian or Termux host, choose the host's listening address and port:

```sh
sh debian/install.sh <IPv4> <port>
# Or, inside Termux:
sh termux/install.sh <IPv4> <port>
```

The installer prepares the package collection. Supply your repository signing key to publish it, then start the server and connect Terminal to it. Follow [Installation and Administration](INSTALLATION.md) for the complete setup, required tools, signing, and client configuration.

After connecting the app to your signed package source, you can install the tools you want:

```sh
apt update
apt install nano tcc openjdk-17
```

## Companion projects

- [Terminal](https://github.com/qwertyuiop982/terminal): the Android app and APK downloads.
- [OpenJDK 17 Bionic](https://github.com/qwertyuiop982/openjdk-17-bionic): Java sources and Android build tools.
- [TinyCC 0.9 Bionic](https://github.com/qwertyuiop982/tcc-0.9-bionic): C compiler sources and Android build tools.

See [Technical Details](TECHNICAL.md) for implementation and [the task list](TASKS.md) for deployment progress.
