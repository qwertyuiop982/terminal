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
. "$SCRIPT_DIR/../common.sh"
. "$SCRIPT_DIR/../publisher.sh"
rc_publish "$@"
