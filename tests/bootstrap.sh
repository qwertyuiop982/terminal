#!/bin/sh
# Verify automatic import, hash rejection and signed publication without network.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
trap 'exit 1' HUP INT TERM
(cd "$ROOT/packages" && sha256sum -c SHA256SUMS)
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
    "$REPO_PACKAGES_URL"/*) ;;
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
REPO_PACKAGES_URL=https://gh.xmly.dev/https://raw.githubusercontent.com/qwertyuiop982/terminal/main-repo/packages
TEST_PACKAGES=$ROOT/packages
export PATH GNUPGHOME REPO_NGINX REPO_BOOTSTRAP REPO_PACKAGES_URL TEST_PACKAGES
gpg --batch --passphrase '' --quick-generate-key 'Bootstrap Test <test@example.invalid>' ed25519 sign 0 >/dev/null 2>&1
REPO_SIGNING_KEY=$(gpg --with-colons --list-secret-keys | awk -F: '$1 == "fpr" { print $10; exit }')
export REPO_SIGNING_KEY
REPO_CLIENT_HOME=$TEST_ROOT/repository
export REPO_CLIENT_HOME
sh "$ROOT/debian/install.sh" 127.0.0.1 18923
(cd "$REPO_CLIENT_HOME/repository/pool/main" && sha256sum -c "$ROOT/packages/SHA256SUMS")
gpg --batch --verify "$REPO_CLIENT_HOME/repository/dists/stable/InRelease" >/dev/null 2>&1
for name in nano tcc; do
    grep -q "^Package: $name\$" "$REPO_CLIENT_HOME/repository/dists/stable/main/binary-arm64/Packages"
done
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
            -o APT::Architecture=arm64 -o APT::Sandbox::User=root download nano tcc
    )
    cmp "$ROOT/packages/nano_9.2-1_arm64.deb" "$TEST_ROOT/download/nano_9.2-1_arm64.deb"
    cmp "$ROOT/packages/tcc_20260922-1_arm64.deb" "$TEST_ROOT/download/tcc_20260922-1_arm64.deb"
fi
REPO_CLIENT_HOME=$TEST_ROOT/tampered
TEST_CORRUPT=nano_9.2-1_arm64.deb
export REPO_CLIENT_HOME TEST_CORRUPT
if sh "$ROOT/debian/install.sh" 127.0.0.1 18923 >/dev/null 2>&1; then
    echo 'bootstrap accepted a corrupted package' >&2
    exit 1
fi
[ ! -e "$REPO_CLIENT_HOME/repository/pool/main/nano_9.2-1_arm64.deb" ] || {
    echo 'bootstrap imported a corrupted package' >&2
    exit 1
}
printf 'test: HTTPS package bootstrap, checksum rejection and signed publication passed\n'