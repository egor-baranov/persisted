#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-release}"
case "$configuration" in debug|release) ;; *) echo "Usage: $0 [debug|release]" >&2; exit 2;; esac
build_directory="$(python3 Scripts/build_config.py --value build_directory)"
assert_apps_stopped() {
  # Inspect executable paths, not process names or argument strings. This also
  # catches the integration checker while allowing copies installed elsewhere.
  python3 - "$build_directory" <<'PY'
import ctypes, os, subprocess, sys
from pathlib import Path

root = Path(sys.argv[1])
targets = {os.path.realpath(root / f'{name}.app/Contents/MacOS/{name}'): name
           for name in ('Persisted', 'PersistedHarness')}
libproc = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
libproc.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
libproc.proc_pidpath.restype = ctypes.c_int
running = []
for raw_pid in subprocess.check_output(['/bin/ps', '-axo', 'pid='], text=True).split():
    pid = int(raw_pid)
    buffer = ctypes.create_string_buffer(4096)
    if libproc.proc_pidpath(pid, buffer, len(buffer)) > 0:
        executable = os.path.realpath(os.fsdecode(buffer.value))
        if executable in targets:
            running.append(f'{targets[executable]} (PID {pid})')
if running:
    print('Build stopped: quit ' + ', '.join(running) + ' before replacing the app bundles.', file=sys.stderr)
    print('Reopen the rebuilt app afterward so its running code matches its Accessibility permission.', file=sys.stderr)
    sys.exit(1)
PY
}
assert_apps_stopped
swift build -c "$configuration" --product Persisted
swift build -c "$configuration" --product PersistedHarness
binary_directory="$(swift build -c "$configuration" --show-bin-path)"
mkdir -p "$build_directory"
staging_directory="$(mktemp -d "$build_directory/.app-build.XXXXXX")"
trap 'rm -rf "$staging_directory"' EXIT
mkdir -p "$staging_directory/Persisted.app/Contents/MacOS" "$staging_directory/Persisted.app/Contents/Resources"
mkdir -p "$staging_directory/PersistedHarness.app/Contents/MacOS"
cp "$binary_directory/Persisted" "$staging_directory/Persisted.app/Contents/MacOS/Persisted"
cp "$binary_directory/PersistedHarness" "$staging_directory/PersistedHarness.app/Contents/MacOS/PersistedHarness"
cp Config/Persisted.icns "$staging_directory/Persisted.app/Contents/Resources/Persisted.icns"
python3 Scripts/build_config.py --write-plists "$staging_directory"
codesign --force --sign - --options runtime --timestamp=none "$staging_directory/Persisted.app"
codesign --force --sign - --options runtime --timestamp=none "$staging_directory/PersistedHarness.app"
codesign --verify --deep --strict "$staging_directory/Persisted.app"
codesign --verify --deep --strict "$staging_directory/PersistedHarness.app"
for name in Persisted PersistedHarness; do
  # A user may have launched an existing bundle during compilation. Recheck at
  # publication, after both new bundles have been completely signed and verified.
  assert_apps_stopped
  destination="$build_directory/$name.app"
  previous="$staging_directory/$name.previous.app"
  if [[ -e "$destination" ]]; then mv "$destination" "$previous"; fi
  if ! mv "$staging_directory/$name.app" "$destination"; then
    if [[ -e "$previous" ]]; then mv "$previous" "$destination"; fi
    exit 1
  fi
done
echo "Built $build_directory/Persisted.app"
echo "Built $build_directory/PersistedHarness.app"
