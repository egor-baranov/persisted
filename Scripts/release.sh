#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
package_site=false
case "${1:-}" in
  '') ;;
  --package-site) package_site=true ;;
  *) echo "Usage: $0 [--package-site]" >&2; exit 2 ;;
esac
if [[ $# -gt 1 ]]; then echo "Usage: $0 [--package-site]" >&2; exit 2; fi
: "${SIGNING_IDENTITY:?Set SIGNING_IDENTITY to your Developer ID Application certificate name}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to an existing notarytool keychain profile}"
# Resolve once and pass the same absolute path through every build/release step.
build_directory="$(python3 Scripts/build_config.py --value build_directory)"
export PERSISTED_BUILD_DIRECTORY="$build_directory"
Scripts/build-app.sh release
app="$build_directory/Persisted.app"
# Read the version from the artifact, even if configuration changes after build.
version="$(python3 - "$app/Contents/Info.plist" <<'PY'
import plistlib, re, sys
with open(sys.argv[1], 'rb') as source:
    version = plistlib.load(source)['CFBundleShortVersionString']
if not re.fullmatch(r'[0-9]+(?:\.[0-9]+){0,2}', version):
    raise SystemExit('The built app has an invalid release version.')
print(version)
PY
)"
notarization_archive="$build_directory/Persisted-notarization.zip"
release_archive="$build_directory/Persisted-$version.zip"
codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp "$app"
codesign --verify --deep --strict --verbose=2 "$app"
ditto -c -k --keepParent "$app" "$notarization_archive"
xcrun notarytool submit "$notarization_archive" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"
ditto -c -k --keepParent "$app" "$release_archive"
if "$package_site"; then
  # Keep the existing website URL while publishing this exact release bundle.
  python3 Scripts/package-site.py --app "$app" --require-notarized
fi
echo "Signed and notarized release: $release_archive"
