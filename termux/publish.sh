#!/bin/sh
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
: "${PREFIX:?run this script inside Termux (PREFIX is required)}"
RC_PLATFORM=termux
REPO_CLIENT_HOME=${REPO_CLIENT_HOME:-$PREFIX/var/lib/terminal-repo-client}
. "$SCRIPT_DIR/../common.sh"
. "$SCRIPT_DIR/../publisher.sh"
rc_publish "$@"
