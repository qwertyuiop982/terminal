#!/bin/sh
# Apply the pinned Android file-backup and private-temp fixes without resetting other outputs.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
SRC=${1:-$ROOT/build-ext/src/dpkg-arm64-v8a}
[ -f "$SRC/lib/dpkg/file.c" ] || { echo 'dpkg source is missing' >&2; exit 1; }
if ! grep -Fq 'file_link_or_copy(' "$SRC/lib/dpkg/file.c"; then
    patch --batch --fuzz=0 -d "$SRC" -p1 < "$ROOT/third_party/dpkg/android-private-backup.patch"
fi
if ! grep -Fq 'Android uses the private BusyBox tar' "$SRC/src/deb/extract.c"; then
    patch --batch --fuzz=0 -d "$SRC" -p1 < "$ROOT/third_party/dpkg/android-busybox-tar.patch"
fi
# Disable a glibc-only writeback hint. dpkg still fsyncs before committing.
sed -i -e 's/^#if defined(SYNC_FILE_RANGE_WRITE)$/#if 0/' \
    -e 's/^#if defined(SYNC_FILE_RANGE_WAIT_BEFORE)$/#if 0/' "$SRC/src/main/archives.c"
grep -Fq 'file_link_or_copy(file->name, staged_backup)' "$SRC/lib/dpkg/atomic-file.c"
grep -Fq 'files/usr/tmp' "$SRC/lib/dpkg/path.c"