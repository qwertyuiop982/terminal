#!/bin/sh
# Real local HTTP and signed APT check. Pass an existing nginx binary; never install it here.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
NGINX=${1:?usage: sh tests/nginx-smoke.sh /absolute/path/to/nginx [port]}
PORT=${2:-18923}
case "$NGINX" in /*) ;; *) printf 'nginx path must be absolute\n' >&2; exit 1 ;; esac
[ -x "$NGINX" ] || { printf 'nginx binary is missing\n' >&2; exit 1; }
TEST_ROOT=$(mktemp -d)
REPO_BOOTSTRAP=no
REPO_CLIENT_HOME=$TEST_ROOT/client
REPO_NGINX=$NGINX
GNUPGHOME=$TEST_ROOT/keys
export REPO_CLIENT_HOME REPO_NGINX GNUPGHOME REPO_BOOTSTRAP
cleanup() {
    if [ -f "$REPO_CLIENT_HOME/run/nginx.pid" ]; then
        sh "$ROOT/debian/start.sh" stop >/dev/null 2>&1 || true
    fi
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
mkdir -p "$GNUPGHOME" "$TEST_ROOT/pkg/DEBIAN" "$TEST_ROOT/pkg/usr/share/repo-test"
chmod 755 "$TEST_ROOT" "$TEST_ROOT/pkg/DEBIAN"
chmod 700 "$GNUPGHOME"
printf 'Package: repo-test\nVersion: 1.0\nArchitecture: all\nMaintainer: Test <test@example.invalid>\nDescription: verify signed APT over nginx\n' > "$TEST_ROOT/pkg/DEBIAN/control"
printf 'test content\n' > "$TEST_ROOT/pkg/usr/share/repo-test/data.txt"
printf 'X-Android-Bionic: yes\nX-Android-Min-API: 24\nX-Terminal-Prefix: /data/data/com.terminal/files/usr\n' >> "$TEST_ROOT/pkg/DEBIAN/control"
dpkg-deb --build "$TEST_ROOT/pkg" "$TEST_ROOT/repo-test_1.0_all.deb" >/dev/null
gpg --batch --passphrase '' --quick-generate-key 'Repository Test <test@example.invalid>' ed25519 sign 0 >/dev/null 2>&1
REPO_SIGNING_KEY=$(gpg --with-colons --list-secret-keys | awk -F: '$1 == "fpr" { print $10; exit }')
export REPO_SIGNING_KEY
sh "$ROOT/debian/install.sh" 127.0.0.1 "$PORT"
sh "$ROOT/debian/publish.sh" "$TEST_ROOT/repo-test_1.0_all.deb"
sh "$ROOT/debian/start.sh" 127.0.0.1 "$PORT" check
sh "$ROOT/debian/start.sh" 127.0.0.1 "$PORT"
URL=http://127.0.0.1:$PORT
for resource in dists/stable/InRelease dists/stable/Release dists/stable/main/binary-arm64/Packages.gz pool/main/repo-test_1.0_all.deb; do
    curl --silent --show-error --fail --head "$URL/$resource" >/dev/null || exit 1
done
[ "$(curl --silent --output /dev/null --write-out '%{http_code}' "$URL/conf/nginx.conf")" = 404 ]
[ "$(curl --silent --output /dev/null --write-out '%{http_code}' "$URL/dists/stable/../../releases/stable-initial/Release" --path-as-is)" = 404 ]
[ "$(curl --silent --output /dev/null --write-out '%{http_code}' -X POST "$URL/dists/stable/Release")" = 403 ]
if command -v apt-get >/dev/null 2>&1; then
    mkdir -p "$TEST_ROOT/apt/lists/partial" "$TEST_ROOT/apt/archives/partial" "$TEST_ROOT/download"
    touch "$TEST_ROOT/apt/status"
    gpg --batch --export "$REPO_SIGNING_KEY" > "$TEST_ROOT/keyring.gpg"
    printf 'deb [arch=arm64 signed-by=%s] %s/ stable main\n' "$TEST_ROOT/keyring.gpg" "$URL" > "$TEST_ROOT/sources.list"
    # An isolated source, lists directory, package cache and status file protect host APT state.
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
            -o APT::Architecture=arm64 -o APT::Sandbox::User=root download repo-test
    )
    cmp "$TEST_ROOT/repo-test_1.0_all.deb" "$TEST_ROOT/download/repo-test_1.0_all.deb"
    printf 'test: nginx HTTP and signed APT update/download passed\n'
else
    printf 'test: nginx HTTP passed (no apt-get on this host)\n'
fi