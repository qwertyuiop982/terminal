# Installation and Administration

This branch runs a signed package server for the Terminal Android app. Use a Debian or Termux host with a reachable IPv4 address.

## Prepare the host

Install `curl`, `sha256sum`, `gpg`, `dpkg-deb`, `dpkg-scanpackages`, `gzip`, and nginx using your host's package manager. On Debian these tools are supplied by `curl`, `coreutils`, `gnupg`, `dpkg-dev`, `gzip`, and `nginx`. The installer can install missing nginx through the host's package manager.

Clone the package-server branch:

```sh
git clone --branch main-repo --single-branch https://github.com/qwertyuiop982/terminal.git terminal-packages
cd terminal-packages
```

## Import and publish packages

The installer downloads Nano 9.2-1, TinyCC 20260922-2, and OpenJDK 17.0.20-android4 from the fixed `android-packages-20261002-r1` GitHub Release through `https://gh.xmly.dev/`. If that default mirror fails (for example with HTTP 429), it continues from the original GitHub HTTPS asset URL. It verifies all three downloads against the local `packages/SHA256SUMS.release` before importing any of them. An explicitly supplied `REPO_PACKAGES_URL` is never silently replaced.

Choose a real address and port for your host. Set `REPO_SIGNING_KEY` to the complete fingerprint of your repository signing key, held in a private GnuPG directory on that host:

```sh
REPO_SIGNING_KEY=<full-fingerprint> sh debian/install.sh <IPv4> <port>
# Inside Termux, use termux/install.sh instead.
```

With a signing key, installation imports the packages and publishes a signed snapshot. Without it, packages are imported but no signed snapshot is published. You can publish later:

```sh
REPO_SIGNING_KEY=<full-fingerprint> sh debian/publish.sh
```

Keep the private signing key outside the public repository. Export only its public key for clients, and distribute its fingerprint through a trusted channel.

You can use `gh-proxy.org` as an alternative download mirror with the same pinned package checks:

```sh
REPO_PACKAGES_URL=https://gh-proxy.org/https://github.com/qwertyuiop982/terminal/releases/download/android-packages-20261002-r1 \
  sh debian/install.sh <IPv4> <port>
```

## Start the server

```sh
sh debian/start.sh <IPv4> <port> check
sh debian/start.sh <IPv4> <port> start
sh debian/start.sh <IPv4> <port> reload
sh debian/start.sh status
sh debian/start.sh stop
```

Use the corresponding `termux/` scripts on Termux. Port 443 additionally requires readable `REPO_TLS_CERT` and `REPO_TLS_KEY` files stored outside the served directory.

## Connect Terminal

Import the verified public key into a dedicated keyring in the Terminal app, then create a source with your actual server address:

```text
deb [arch=arm64 signed-by=/data/data/com.terminal/files/usr/etc/apt/keyrings/terminal-repo.gpg] http://<IPv4>:<port>/ stable main
```

Run `apt update`, then install the tools you want. These packages target Terminal's private Android Bionic runtime; ordinary Debian or Termux binary packages are not substitutes.

## Settings

| Variable | Purpose |
| --- | --- |
| `REPO_CLIENT_HOME` | State directory. Debian root defaults to `/var/lib/terminal-repo-client`; Termux defaults to `$PREFIX/var/lib/terminal-repo-client`. |
| `REPO_SUITE` | Suite name; defaults to `stable`. |
| `REPO_ARCH` | APT architecture; automatic package downloads support `arm64`. |
| `REPO_PACKAGES_URL` | Alternative HTTPS asset base URL. Local pinned checksums still apply. |
| `REPO_BOOTSTRAP=no` | Skip automatic package downloads for an offline or manual setup. |
| `REPO_SIGNING_KEY` | Complete repository signing-key fingerprint. |
| `GNUPGHOME` | Private GnuPG directory on the repository host. |
| `REPO_NGINX` | Explicit nginx executable path. |
| `REPO_TLS_CERT`, `REPO_TLS_KEY` | TLS certificate and key when HTTPS is enabled. |

The server exposes package files and signed indexes through GET/HEAD. Publishing writes a new snapshot and switches it atomically; downloads are never trusted merely because they arrived through a proxy.

## Verify changes

```sh
sh tests/run.sh
TEST_PACKAGES=/path/to/verified-release-assets sh tests/bootstrap.sh
sh tests/nginx-smoke.sh /absolute/path/to/nginx
```

`bootstrap.sh` uses local Release assets and a simulated downloader to check the default Release URL, custom mirror, signatures, all three package hashes, and rejection before import. Its APT checks use isolated state directories.

The build-side `build-packages.sh` produces Nano and the historical TinyCC 20260922-1 package from Terminal's native outputs. The corrected TinyCC 20260922-2 and OpenJDK packages are built in their companion source repositories. Existing package versions remain immutable.
