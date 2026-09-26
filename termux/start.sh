#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
: "${PREFIX:?run this script inside Termux (PREFIX is required)}"
RC_PLATFORM=termux
REPO_CLIENT_HOME=${REPO_CLIENT_HOME:-$PREFIX/var/lib/terminal-repo-client}
REPO_NGINX=${REPO_NGINX:-$PREFIX/bin/nginx}
. "$SCRIPT_DIR/../common.sh"
rc_control "$@"