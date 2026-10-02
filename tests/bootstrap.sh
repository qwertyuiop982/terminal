#!/bin/sh
# Verify automatic import, hash rejection and signed publication without network.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
trap 'exit 1' HUP INT TERM
TEST_PACKAGES=${TEST_PACKAGES:-$ROOT/packages}
(cd "$TEST_PACKAGES" && sha256sum -c "$ROOT/packages/SHA256SUMS.release")
mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/keys"
chmod 700 "$TEST_ROOT/keys"
cat > "$TEST_ROOT/bin/curl" <<'EOF'
#!/bin/sh
output=
url=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --output) output=$2; shift 2 ;;
        https://*) url=$1; shift ;;
        *) shift ;;
    esac
done
[ -n "$output" ] && [ -n "$url" ] || exit 1
case "$url" in
    "$TEST_EXPECTED_BASE"/*) ;;
    *) exit 1 ;;
esac
if [ "${TEST_CORRUPT:-}" = "${url##*/}" ]; then
    printf corrupted > "$output"
else
    cp "$TEST_PACKAGES/${url##*/}" "$output"
fi
EOF
chmod 755 "$TEST_ROOT/bin/curl"
PATH=$TEST_ROOT/bin:$PATH
GNUPGHOME=$TEST_ROOT/keys
REPO_NGINX=/bin/true
REPO_BOOTSTRAP=yes
unset REPO_PACKAGES_URL
TEST_EXPECTED_BASE=https://gh.xmly.dev/https://github.com/qwertyuiop982/terminal/releases/download/android-packages-20261002
export PATH GNUPGHOME REPO_NGINX REPO_BOOTSTRAP TEST_EXPECTED_BASE TEST_PACKAGES
gpg --batch --passphrase '' --quick-generate-key 'Bootstrap Test <test@example.invalid>' ed25519 sign 0 >/dev/null 2>&1
REPO_SIGNING_KEY=$(gpg --with-colons --list-secret-keys | awk -F: '$1 == "fpr" { print $10; exit }')
export REPO_SIGNING_KEY
REPO_CLIENT_HOME=$TEST_ROOT/repository
export REPO_CLIENT_HOME
sh "$ROOT/debian/install.sh" 127.0.0.1 18923
(cd "$REPO_CLIENT_HOME/repository/pool/main" && sha256sum -c "$ROOT/packages/SHA256SUMS.release")
gpg --batch --verify "$REPO_CLIENT_HOME/repository/dists/stable/InRelease" >/dev/null 2>&1
for name in nano tcc openjdk-17; do
    grep -q "^Package: $name\$" "$REPO_CLIENT_HOME/repository/dists/stable/main/binary-arm64/Packages"
done
REPO_PACKAGES_URL=https://mirror.example.invalid/pinned-assets/
TEST_EXPECTED_BASE=${REPO_PACKAGES_URL%/}
export REPO_PACKAGES_URL TEST_EXPECTED_BASE
sh "$ROOT/debian/install.sh" 127.0.0.1 18923
if command -v apt-get >/dev/null 2>&1; then
    mkdir -p "$TEST_ROOT/apt/lists/partial" "$TEST_ROOT/apt/archives/partial" "$TEST_ROOT/download"
    touch "$TEST_ROOT/apt/status"
    gpg --batch --export "$REPO_SIGNING_KEY" > "$TEST_ROOT/keyring.gpg"
    printf 'deb [arch=arm64 signed-by=%s] file://%s/repository stable main\n' \
        "$TEST_ROOT/keyring.gpg" "$REPO_CLIENT_HOME" > "$TEST_ROOT/sources.list"
    apt-get -o Dir::Etc::sourcelist="$TEST_ROOT/sources.list" \
        -o Dir::Etc::sourceparts=- -o Dir::State::lists="$TEST_ROOT/apt/lists" \
        -o Dir::State::status="$TEST_ROOT/apt/status" \
        -o Dir::Cache::archives="$TEST_ROOT/apt/archives" \
        -o APT::Architecture=arm64 -o APT::Sandbox::User=root update
    (
        cd "$TEST_ROOT/download"
        apt-get -o Dir::Etc::sourcelist="$TEST_ROOT/sources.list" \
            -o Dir::Etc::sourceparts=- -o Dir::State::lists="$TEST_ROOT/apt/lists" \
            -o Dir::State::status="$TEST_ROOT/apt/status" \
            -o Dir::Cache::archives="$TEST_ROOT/apt/archives" \
            -o APT::Architecture=arm64 -o APT::Sandbox::User=root download nano tcc openjdk-17
    )
    cmp "$TEST_PACKAGES/nano_9.2-1_arm64.deb" "$TEST_ROOT/download/nano_9.2-1_arm64.deb"
    cmp "$TEST_PACKAGES/tcc_20260922-2_arm64.deb" "$TEST_ROOT/download/tcc_20260922-2_arm64.deb"
    (cd "$TEST_ROOT/download" && sha256sum -c "$ROOT/packages/SHA256SUMS.release")
fi
REPO_CLIENT_HOME=$TEST_ROOT/tampered
TEST_CORRUPT=openjdk-17_17.0.20-android2_arm64.deb
export REPO_CLIENT_HOME TEST_CORRUPT
if sh "$ROOT/debian/install.sh" 127.0.0.1 18923 >/dev/null 2>&1; then
    echo 'bootstrap accepted a corrupted package' >&2
    exit 1
fi
[ ! -e "$REPO_CLIENT_HOME/repository/pool/main/nano_9.2-1_arm64.deb" ] || {
    echo 'bootstrap imported a corrupted package' >&2
    exit 1
}
unset TEST_CORRUPT REPO_PACKAGES_URL
TEST_EXPECTED_BASE=https://gh.xmly.dev/https://github.com/qwertyuiop982/terminal/releases/download/android-packages-20261002
PREFIX=$TEST_ROOT/termux/usr
REPO_CLIENT_HOME=$TEST_ROOT/termux/client
export TEST_EXPECTED_BASE PREFIX REPO_CLIENT_HOME
sh "$ROOT/termux/install.sh" 127.0.0.1 18923
(cd "$REPO_CLIENT_HOME/repository/pool/main" && sha256sum -c "$ROOT/packages/SHA256SUMS.release")
gpg --batch --verify "$REPO_CLIENT_HOME/repository/dists/stable/InRelease" >/dev/null 2>&1
printf 'test: pinned Release bootstrap, mirror override, three packages, corruption rejection and signed publication passed\n'
