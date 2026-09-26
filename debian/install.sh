#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
RC_PLATFORM=debian
if [ -z "${REPO_CLIENT_HOME:-}" ]; then
    if [ "$(id -u)" -eq 0 ]; then
        REPO_CLIENT_HOME=/var/lib/terminal-repo-client
    else
        REPO_CLIENT_HOME=$HOME/.local/share/terminal-repo-client
    fi
fi
REPO_NGINX_EXPLICIT=${REPO_NGINX+yes}
REPO_NGINX=${REPO_NGINX:-$(command -v nginx 2>/dev/null || printf /usr/sbin/nginx)}
. "$SCRIPT_DIR/../common.sh"
. "$SCRIPT_DIR/../publisher.sh"
rc_install "$@"