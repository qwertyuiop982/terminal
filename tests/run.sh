#!/bin/sh
# Offline functional checks; no software is installed and no ports are opened.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d)
REPO_BOOTSTRAP=no
export REPO_BOOTSTRAP
trap 'rm -rf "$TEST_ROOT"' EXIT
trap 'exit 1' HUP INT TERM

fail() { printf 'test: %s\n' "$*" >&2; exit 1; }
must_fail() { if "$@" >/dev/null 2>&1; then fail "unexpected success: $*"; fi; }

mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/pkg/DEBIAN" "$TEST_ROOT/pkg/usr/share/doc/repo-test" "$TEST_ROOT/keys"
chmod 700 "$TEST_ROOT/keys"
chmod 755 "$TEST_ROOT/pkg/DEBIAN"
cat > "$TEST_ROOT/bin/nginx" <<'EOF'
#!/bin/sh
prefix=
config=
check=no
action=start
while [ "$#" -gt 0 ]; do
    case "$1" in
        -p) prefix=$2; shift 2 ;;
        -c) config=$2; shift 2 ;;
        -t) check=yes; shift ;;
        -s) action=$2; shift 2 ;;
        *) exit 1 ;;
    esac
done
[ -s "$config" ] || exit 1
if [ "$check" = yes ]; then
    [ "${FAKE_NGINX_FAIL_T:-}" != 1 ] || exit 1
    grep -q 'root .*repository;' "$config"
    ! grep -q 'proxy_pass' "$config"
    exit
fi
[ "${FAKE_NGINX_FAIL_RUN:-}" != 1 ] || exit 1
case "$action" in
    start) printf '%s\n' "$TEST_PID" > "$prefix/run/nginx.pid" ;;
    reload) [ -f "$prefix/run/nginx.pid" ] || exit 1 ;;
    quit) rm -f "$prefix/run/nginx.pid" ;;
    *) exit 1 ;;
esac
EOF
chmod 755 "$TEST_ROOT/bin/nginx"
REPO_NGINX=$TEST_ROOT/bin/nginx
TEST_PID=$$
GNUPGHOME=$TEST_ROOT/keys
export REPO_NGINX TEST_PID GNUPGHOME
printf 'Package: repo-test\nVersion: 1.0\nArchitecture: all\nMaintainer: Test <test@example.invalid>\nDescription: signed repository smoke test\n' > "$TEST_ROOT/pkg/DEBIAN/control"
printf 'sample\n' > "$TEST_ROOT/pkg/usr/share/doc/repo-test/README"
printf 'X-Android-Bionic: yes\nX-Android-Min-API: 24\nX-Terminal-Prefix: /data/data/com.terminal/files/usr\n' >> "$TEST_ROOT/pkg/DEBIAN/control"
dpkg-deb --build "$TEST_ROOT/pkg" "$TEST_ROOT/repo-test_1.0_all.deb" >/dev/null
gpg --batch --passphrase '' --quick-generate-key 'Repository Test <test@example.invalid>' ed25519 sign 0 >/dev/null 2>&1
REPO_SIGNING_KEY=$(gpg --with-colons --list-secret-keys | awk -F: '$1 == "fpr" { print $10; exit }')
[ "${#REPO_SIGNING_KEY}" -eq 40 ] || fail 'failed to generate a signing key'
export REPO_SIGNING_KEY

for platform in debian termux; do
    (
        PREFIX=$TEST_ROOT/$platform/usr
        REPO_CLIENT_HOME=$TEST_ROOT/$platform/client
        export PREFIX REPO_CLIENT_HOME
        mkdir -p "$PREFIX"
        install="$ROOT/$platform/install.sh"
        start="$ROOT/$platform/start.sh"
        publish="$ROOT/$platform/publish.sh"
        must_fail sh "$install"
        must_fail sh "$install" 127.0.0.1
        must_fail sh "$install" 127.0.0.1 18080 extra
        for address in '127.0.0' '256.1.1.1' '127.0.0.01' '1..1.1' '1.2.3.4;include'; do
            must_fail sh "$install" "$address" 18080
        done
        for port in 0 65536 00080 '8080;return'; do must_fail sh "$install" 127.0.0.1 "$port"; done
        must_fail sh "$start" 127.0.0.1 18080 check
        sh "$install" 127.0.0.1 18080
        printf 'keep\n' > "$REPO_CLIENT_HOME/repository/pool/main/keep.txt"
        sh "$install" 127.0.0.1 18080
        [ "$(cat "$REPO_CLIENT_HOME/repository/pool/main/keep.txt")" = keep ] || fail 'install erased packages'
        [ "$(stat -c %a "$REPO_CLIENT_HOME/conf")" = 700 ] || fail 'config permissions'
        [ -d "$REPO_CLIENT_HOME/repository/dists/stable/main/binary-arm64" ] || fail 'missing directory layout'
        must_fail sh "$start" 127.0.0.1 443 check
        must_fail sh "$start" 127.0.0.1 18080
        sh "$start" 127.0.0.1 18080 check
        [ ! -e "$REPO_CLIENT_HOME/conf/nginx.conf" ] || fail 'check saved a config'
        must_fail env REPO_SIGNING_KEY= sh "$publish"
        must_fail sh "$publish"
        sh "$publish" "$TEST_ROOT/repo-test_1.0_all.deb"
        dist=$REPO_CLIENT_HOME/repository/dists/stable
        package=$REPO_CLIENT_HOME/repository/pool/main/repo-test_1.0_all.deb
        [ -s "$dist/InRelease" ] && [ -s "$dist/Release.gpg" ] || fail 'missing signatures'
        gpg --batch --verify "$dist/InRelease" >/dev/null 2>&1 || fail 'invalid InRelease'
        gpg --batch --verify "$dist/Release.gpg" "$dist/Release" >/dev/null 2>&1 || fail 'invalid Release.gpg'
        grep -q '^Filename: pool/main/repo-test_1.0_all.deb$' "$dist/main/binary-arm64/Packages" || fail 'wrong package path'
        grep -q "^SHA256: $(sha256sum "$package" | cut -d' ' -f1)$" "$dist/main/binary-arm64/Packages" || fail 'wrong package checksum'
        grep -q '^Acquire-By-Hash: yes$' "$dist/Release" || fail 'by-hash is disabled'
        old=$(readlink "$dist")
        old_index=$(sha256sum "$dist/main/binary-arm64/Packages.gz" | cut -d' ' -f1)
        sh "$publish"
        [ "$old" != "$(readlink "$dist")" ] || fail 'release link not replaced'
        [ -s "$dist/main/binary-arm64/by-hash/SHA256/$old_index" ] || fail 'old index lost after publication'
        wrong=$TEST_ROOT/wrong/DEBIAN
        mkdir -p "$wrong"
        chmod 755 "$wrong"
        printf 'Package: wrong\nVersion: 1\nArchitecture: amd64\nMaintainer: Test <test@example.invalid>\nDescription: wrong architecture\n' > "$wrong/control"
        dpkg-deb --build "$TEST_ROOT/wrong" "$TEST_ROOT/wrong_1_amd64.deb" >/dev/null
        must_fail sh "$publish" "$TEST_ROOT/wrong_1_amd64.deb"
        sed 's/Architecture: amd64/Architecture: arm64/' "$wrong/control" > "$wrong/control.tmp"
        mv "$wrong/control.tmp" "$wrong/control"
        dpkg-deb --build "$TEST_ROOT/wrong" "$TEST_ROOT/wrong_1_arm64.deb" >/dev/null
        must_fail sh "$publish" "$TEST_ROOT/wrong_1_arm64.deb"
        [ -s "$dist/InRelease" ] || fail 'failed publish damaged release'
        sh "$start" 127.0.0.1 18080
        config=$REPO_CLIENT_HOME/conf/nginx.conf
        grep -Fq 'listen 127.0.0.1:18080;' "$config" || fail 'wrong listen address'
        grep -Fq 'limit_except GET HEAD' "$config" || fail 'missing method restriction'
        grep -Fq 'by-hash/SHA256/' "$config" || fail 'missing by-hash path'
        must_fail sh "$start" 127.0.0.1 18080
        sh "$start" status
        initial_hash=$(sha256sum "$config" | cut -d' ' -f1)
        must_fail env FAKE_NGINX_FAIL_T=1 sh "$start" 127.0.0.1 18081 reload
        [ "$initial_hash" = "$(sha256sum "$config" | cut -d' ' -f1)" ] || fail 'failed check replaced config'
        must_fail env FAKE_NGINX_FAIL_RUN=1 sh "$start" 127.0.0.1 18081 reload
        [ "$initial_hash" = "$(sha256sum "$config" | cut -d' ' -f1)" ] || fail 'failed reload replaced config'
        sh "$start" 127.0.0.1 18081 reload
        grep -Fq 'listen 127.0.0.1:18081;' "$config" || fail 'reload not applied'
        sh "$start" stop
        must_fail sh "$start" status
        printf 'test: %s install, signed publication and nginx control passed\n' "$platform"
    )
done