#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_directory="$(python3 Scripts/build_config.py --value build_directory)"
test -x "$build_directory/Persisted.app/Contents/MacOS/Persisted" || { echo 'Run Scripts/build-app.sh first.' >&2; exit 1; }
report_path="$build_directory/native-integration-$(date +%s).json"
# Only the supplied Harness bundle is an eligible mutation target. The checker
# never prompts for permission, writes layouts, or operates on other applications.
open "$build_directory/PersistedHarness.app"
open -n "$build_directory/Persisted.app" --args --integration-check "$report_path"
for ((attempt=0; attempt<60; attempt++)); do
  if [[ -f "$report_path" ]]; then
    python3 - "$report_path" <<'PY'
import json, sys
with open(sys.argv[1]) as source: report = json.load(source)
print(json.dumps(report, indent=2))
print('Report: '+sys.argv[1])
sys.exit(0 if report['succeeded'] else 1)
PY
    exit $?
  fi
  sleep 1
done
echo "Timed out waiting for the integration report: $report_path" >&2
exit 1
