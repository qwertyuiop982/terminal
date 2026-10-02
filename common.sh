#!/bin/sh
# Shared Debian/Termux entry points. RC_PLATFORM and REPO_NGINX are set by callers.
set -eu

rc_die() { printf 'repo-client: %s\n' "$*" >&2; exit 1; }

rc_path() {
    case "$1" in
        /*) ;;
        *) rc_die "expected an absolute path: $1" ;;
    esac
    case "$1" in
        /|*/..|*/.|*/../*|*/./*|*[!a-zA-Z0-9_./+-]*)
            rc_die "unsafe path for nginx configuration: $1" ;;
    esac
}

rc_token() {
    case "$1" in
        ''|-*|*[!a-z0-9-]*) rc_die "invalid suite or architecture: $1" ;;
    esac
}

rc_setup() {
    : "${REPO_CLIENT_HOME:?REPO_CLIENT_HOME is required}"
    RC_HOME=${REPO_CLIENT_HOME%/}
    rc_path "$RC_HOME"
    RC_SUITE=${REPO_SUITE:-stable}
    RC_ARCH=${REPO_ARCH:-arm64}
    rc_token "$RC_SUITE"
    rc_token "$RC_ARCH"
    RC_REPO=$RC_HOME/repository
    RC_RELEASES=$RC_HOME/releases
    RC_DIST=$RC_REPO/dists/$RC_SUITE
}

rc_address() {
    [ "$#" -eq 2 ] || rc_die "usage: $0 <IPv4> <port>"
    rc_ip=$1
    rc_port=$2
    case "$rc_ip" in
        ''|.*|*..*|*.|*[!0-9.]*) rc_die "invalid IPv4 address: $rc_ip" ;;
    esac
    rc_saved_ifs=$IFS
    IFS=.
    set -- $rc_ip
    IFS=$rc_saved_ifs
    [ "$#" -eq 4 ] || rc_die "invalid IPv4 address: $rc_ip"
    for rc_octet do
        case "$rc_octet" in
            0|[1-9]|[1-9][0-9]|[1-9][0-9][0-9]) ;;
            *) rc_die "invalid IPv4 address: $rc_ip" ;;
        esac
        [ "$rc_octet" -le 255 ] || rc_die "invalid IPv4 address: $rc_ip"
    done
    case "$rc_port" in
        ''|0|0*|*[!0-9]*|??????*) rc_die "invalid port: $rc_port" ;;
    esac
    [ "$rc_port" -le 65535 ] || rc_die "invalid port: $rc_port"
    RC_IP=$rc_ip
    RC_PORT=$rc_port
}

rc_nginx() {
    [ -x "$REPO_NGINX" ] || rc_die "nginx is not executable: $REPO_NGINX"
}

rc_install_nginx() {
    if [ "${REPO_NGINX_EXPLICIT:-}" = yes ]; then
        rc_die "nginx is not executable: $REPO_NGINX"
    fi
    if [ "$RC_PLATFORM" = debian ]; then
        [ "$(id -u)" -eq 0 ] || rc_die 'nginx missing: install it as root, then rerun'
        command -v apt-get >/dev/null 2>&1 || rc_die 'apt-get is required to install nginx on Debian'
        apt-get install -y nginx
    else
        command -v apt >/dev/null 2>&1 || rc_die 'apt is required to install nginx in Termux'
        apt install -y nginx
    fi
    rc_nginx
}

rc_require_publish_tools() {
    rc_missing=
    for rc_tool in dpkg-deb dpkg-scanpackages gzip sha256sum gpg; do
        if ! command -v "$rc_tool" >/dev/null 2>&1; then
            rc_missing="$rc_missing $rc_tool"
        fi
    done
    [ -z "$rc_missing" ] || rc_die "publishing requires:$rc_missing (Debian: dpkg-dev, gnupg, gzip, coreutils; check Termux packages separately)"
}

rc_bootstrap_packages() (
    [ "${REPO_BOOTSTRAP:-yes}" != no ] || exit 0
    [ "$RC_ARCH" = arm64 ] || rc_die 'the pinned Android packages are only available for arm64'
    rc_require_publish_tools
    command -v curl >/dev/null 2>&1 || rc_die 'curl is required for verified HTTPS downloads'
    rc_manifest=$SCRIPT_DIR/../packages/SHA256SUMS.release
    [ -s "$rc_manifest" ] || rc_die "release package hashes are missing: $rc_manifest"
    rc_base=${REPO_PACKAGES_URL:-https://gh.xmly.dev/https://github.com/qwertyuiop982/terminal/releases/download/android-packages-20261002-r1}
    rc_base=${rc_base%/}
    case "$rc_base" in https://*/*) ;; *) rc_die 'package URL must use HTTPS' ;; esac
    rc_download=$(mktemp -d "$RC_HOME/run/bootstrap.XXXXXXXX")
    trap 'rm -rf "$rc_download"' EXIT
    trap 'exit 1' HUP INT TERM
    for rc_filename in nano_9.2-1_arm64.deb tcc_20260922-2_arm64.deb openjdk-17_17.0.20-android4_arm64.deb; do
        curl --fail --silent --show-error --location --retry 2 --max-time 300 \
            --proto '=https' --proto-redir '=https' \
            --output "$rc_download/$rc_filename" "$rc_base/$rc_filename" ||
            rc_die "could not download $rc_filename"
    done
    (cd "$rc_download" && sha256sum -c "$rc_manifest") || rc_die 'downloaded package checksum mismatch'
    for rc_filename in nano_9.2-1_arm64.deb tcc_20260922-2_arm64.deb openjdk-17_17.0.20-android4_arm64.deb; do
        rc_import_package "$rc_download/$rc_filename"
    done
    if [ -n "${REPO_SIGNING_KEY:-}" ]; then
        (rc_publish)
    else
        printf 'repo-client: packages imported; set REPO_SIGNING_KEY and run publish.sh before starting nginx\n'
    fi
)

rc_install() {
    rc_address "$@"
    rc_setup
    if [ ! -x "$REPO_NGINX" ]; then rc_install_nginx; fi
    umask 077
    mkdir -p "$RC_HOME/conf" "$RC_HOME/logs" \
        "$RC_RELEASES/$RC_SUITE-initial/main/binary-$RC_ARCH" \
        "$RC_REPO/pool/main" "$RC_REPO/dists"
    for rc_temp in body proxy fastcgi uwsgi scgi; do
        mkdir -p "$RC_HOME/run/$rc_temp"
        chmod 700 "$RC_HOME/run/$rc_temp"
    done
    chmod 700 "$RC_HOME/conf" "$RC_HOME/logs"
    chmod 755 "$RC_RELEASES" "$RC_RELEASES/$RC_SUITE-initial" \
        "$RC_RELEASES/$RC_SUITE-initial/main" \
        "$RC_RELEASES/$RC_SUITE-initial/main/binary-$RC_ARCH" \
        "$RC_REPO" "$RC_REPO/pool" "$RC_REPO/pool/main" "$RC_REPO/dists"
    if [ "$RC_PLATFORM" = debian ] && [ "$(id -u)" -eq 0 ]; then
        id -u www-data >/dev/null 2>&1 || rc_die 'Debian nginx user www-data is missing'
        chmod 711 "$RC_HOME" "$RC_HOME/run"
        for rc_temp in body proxy fastcgi uwsgi scgi; do
            chown www-data "$RC_HOME/run/$rc_temp"
        done
    else
        chmod 700 "$RC_HOME" "$RC_HOME/run"
    fi
    if [ -L "$RC_DIST" ]; then
        case "$(readlink "$RC_DIST")" in
            ../../releases/$RC_SUITE-*) ;;
            *) rc_die "unexpected repository link: $RC_DIST" ;;
        esac
        [ -d "$RC_DIST/main/binary-$RC_ARCH" ] || rc_die "invalid repository link: $RC_DIST"
    elif [ -e "$RC_DIST" ]; then
        rc_die "expected a published-release link at $RC_DIST; existing directory was preserved"
    else
        ln -s "../../releases/$RC_SUITE-initial" "$RC_DIST"
    fi
    rc_missing=
    for rc_tool in dpkg-deb dpkg-scanpackages gzip sha256sum gpg; do
        command -v "$rc_tool" >/dev/null 2>&1 || rc_missing="$rc_missing $rc_tool"
    done
    if [ -n "$rc_missing" ]; then
        printf 'repo-client: publishing still needs:%s\n' "$rc_missing" >&2
    fi
    rc_bootstrap_packages
    printf 'repo-client: repository prepared at %s (listen %s:%s)\n' "$RC_REPO" "$RC_IP" "$RC_PORT"
}

rc_pid_running() {
    [ -f "$RC_HOME/run/nginx.pid" ] || return 1
    read -r rc_pid < "$RC_HOME/run/nginx.pid" || return 1
    case "$rc_pid" in ''|*[!0-9]*) return 1 ;; esac
    kill -0 "$rc_pid" 2>/dev/null
}

rc_tls() {
    REPO_TLS_CERT=${REPO_TLS_CERT:-}
    REPO_TLS_KEY=${REPO_TLS_KEY:-}
    if [ "$RC_PORT" = 443 ] && { [ -z "$REPO_TLS_CERT" ] || [ -z "$REPO_TLS_KEY" ]; }; then
        rc_die 'port 443 requires REPO_TLS_CERT and REPO_TLS_KEY for HTTPS'
    fi
    if [ -z "$REPO_TLS_CERT" ] && [ -z "$REPO_TLS_KEY" ]; then
        RC_LISTEN="listen $RC_IP:$RC_PORT;"
        RC_SSL=
        return
    fi
    [ -n "$REPO_TLS_CERT" ] && [ -n "$REPO_TLS_KEY" ] || rc_die 'supply both TLS certificate and key'
    rc_path "$REPO_TLS_CERT"
    rc_path "$REPO_TLS_KEY"
    [ -r "$REPO_TLS_CERT" ] && [ -r "$REPO_TLS_KEY" ] || rc_die 'TLS certificate or key is not readable'
    for rc_secret in "$REPO_TLS_CERT" "$REPO_TLS_KEY"; do
        case "$(readlink -f "$rc_secret")" in
            "$(readlink -f "$RC_REPO")"/*) rc_die 'TLS files must remain outside the public repository' ;;
        esac
    done
    RC_LISTEN="listen $RC_IP:$RC_PORT ssl;"
    RC_SSL="ssl_certificate $REPO_TLS_CERT;
        ssl_certificate_key $REPO_TLS_KEY;
        ssl_protocols TLSv1.2 TLSv1.3;"
}

rc_render() {
    # Values expanded here have been validated; nginx variables and regex anchors are escaped.
    cat <<EOF
worker_processes 1;
$(if [ "$RC_PLATFORM" = debian ] && [ "$(id -u)" -eq 0 ]; then printf 'user www-data;'; fi)
pid $RC_HOME/run/nginx.pid;
error_log $RC_HOME/logs/error.log warn;
events { worker_connections 256; }
http {
    access_log $RC_HOME/logs/access.log;
    server_tokens off;
    client_body_temp_path $RC_HOME/run/body;
    proxy_temp_path $RC_HOME/run/proxy;
    fastcgi_temp_path $RC_HOME/run/fastcgi;
    uwsgi_temp_path $RC_HOME/run/uwsgi;
    scgi_temp_path $RC_HOME/run/scgi;
    default_type application/octet-stream;
    server {
        $RC_LISTEN
        $RC_SSL
        server_name _;
        root $RC_REPO;
        autoindex off;
        location / { return 404; }
        location ~ "^/pool/main/[a-zA-Z0-9_+.-]+(/[a-zA-Z0-9_+.-]+)*\.deb\$" {
            limit_except GET HEAD { deny all; }
            disable_symlinks on from=\$document_root;
            try_files \$uri =404;
        }
        location ~ "^/dists/$RC_SUITE/(InRelease|Release(\.gpg)?|main/binary-$RC_ARCH/(Packages(\.gz)?|by-hash/SHA256/[a-f0-9]{64}))\$" {
            limit_except GET HEAD { deny all; }
            try_files \$uri =404;
        }
    }
}
EOF
}

rc_control() {
    rc_setup
    case "$#" in
        1)
            case "$1" in
                status|stop) rc_action=$1 ;;
                *) rc_die "usage: $0 <IPv4> <port> [start|check|reload] | status | stop" ;;
            esac ;;
        2|3)
            rc_address "$1" "$2"
            rc_action=${3:-start}
            case "$rc_action" in start|check|reload) ;; *) rc_die "invalid action: $rc_action" ;; esac ;;
        *) rc_die "usage: $0 <IPv4> <port> [start|check|reload] | status | stop" ;;
    esac
    rc_nginx
    if [ "$rc_action" = status ]; then
        rc_pid_running || rc_die 'nginx is not running'
        printf 'repo-client: nginx running (pid %s)\n' "$rc_pid"
        return
    fi
    if [ "$rc_action" = stop ]; then
        rc_pid_running || rc_die 'nginx is not running'
        "$REPO_NGINX" -p "$RC_HOME/" -c "$RC_HOME/conf/nginx.conf" -s quit
        return
    fi
    [ -d "$RC_DIST/main/binary-$RC_ARCH" ] || rc_die 'run the install script first'
    if [ "$rc_action" != check ]; then
        for rc_metadata in Release InRelease Release.gpg; do
            [ -s "$RC_DIST/$rc_metadata" ] || rc_die "publish a signed release before starting: missing $rc_metadata"
        done
    fi
    if [ "$rc_action" = start ] && rc_pid_running; then rc_die 'nginx is already running; use reload'; fi
    if [ "$rc_action" = reload ] && ! rc_pid_running; then rc_die 'nginx is not running'; fi
    rc_tls
    umask 077
    rc_tmp=$(mktemp "$RC_HOME/conf/nginx.conf.XXXXXXXX")
    trap 'rm -f "$rc_tmp"' EXIT
    trap 'exit 1' HUP INT TERM
    rc_render > "$rc_tmp"
    "$REPO_NGINX" -p "$RC_HOME/" -c "$rc_tmp" -t
    if [ "$rc_action" = check ]; then
        printf 'repo-client: nginx configuration valid\n'
        return
    fi
    rc_previous=
    if [ -f "$RC_HOME/conf/nginx.conf" ]; then
        rc_previous=$(mktemp "$RC_HOME/conf/nginx.previous.XXXXXXXX")
        cp -p "$RC_HOME/conf/nginx.conf" "$rc_previous"
    fi
    mv -f "$rc_tmp" "$RC_HOME/conf/nginx.conf"
    if [ "$rc_action" = reload ]; then
        rc_result=0
        "$REPO_NGINX" -p "$RC_HOME/" -c "$RC_HOME/conf/nginx.conf" -s reload || rc_result=$?
    else
        rc_result=0
        "$REPO_NGINX" -p "$RC_HOME/" -c "$RC_HOME/conf/nginx.conf" || rc_result=$?
    fi
    if [ "$rc_result" -ne 0 ]; then
        if [ -n "$rc_previous" ]; then mv -f "$rc_previous" "$RC_HOME/conf/nginx.conf"; else rm -f "$RC_HOME/conf/nginx.conf"; fi
        rc_die "nginx $rc_action failed; previous configuration restored"
    fi
    if [ -n "$rc_previous" ]; then rm -f "$rc_previous"; fi
    printf 'repo-client: nginx %s at %s:%s\n' "$rc_action" "$RC_IP" "$RC_PORT"
}
