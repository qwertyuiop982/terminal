#!/bin/sh
# Delegate optional TCC to its independent Git/source/build projects.
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd) || exit $?
case "${1:-arm64-v8a}" in arm64|arm64-v8a) ;; *) echo '32-bit optional extension builds remain paused' >&2; exit 1 ;; esac
PROJECT=${TCC_ANDROID_PROJECT:-$ROOT/../tcc-0.9-bionic}
if [ -f "$PROJECT/source_snapshot.py" ]; then
  SOURCE=${TCC_SOURCE_DIR:-$PROJECT/upstream}
else
  SOURCE=${TCC_SOURCE_DIR:-$ROOT/../tinycc}
fi
[ -f "$PROJECT/build.py" ] && [ -d "$SOURCE" ] || {
  printf 'TinyCC project or source missing: %s and %s (see BUILDING.md)\n' "$PROJECT" "$SOURCE" >&2
  exit 1
}
python3 "$PROJECT/build.py" --source "$SOURCE" --jobs "${TCC_JOBS:-2}" || exit $?
python3 - "$PROJECT/out/arm64-v8a" "$ROOT/build-ext/out/arm64-v8a/optional/tcc" <<'PY'
import json,os,shutil,sys
from pathlib import Path
source=Path(sys.argv[1]);destination=Path(sys.argv[2]);destination.parent.mkdir(parents=True,exist_ok=True)
manifest=json.loads((source/'share/doc/tcc/BUILD.json').read_text())
assert manifest['prefix']=='/data/data/com.terminal/files/usr' and manifest['targetos']=='Android'
new=destination.with_name('.tcc-new-'+str(os.getpid()));backup=destination.with_name('.tcc-old-'+str(os.getpid()))
assert not new.exists() and not backup.exists()
shutil.copytree(source,new,symlinks=True)
if destination.exists():destination.rename(backup)
try:new.rename(destination)
except BaseException:
    if backup.exists():backup.rename(destination)
    raise
if backup.exists():shutil.rmtree(backup)
print('optional TCC staged without deleting APT/gpgv/BusyBox/nano:',destination)
PY