#!/bin/zsh
# Opt-in Developer ID distribution. Never changes local trust, TCC or credentials.
set -euo pipefail
cd "${0:A:h}"
identity="${SPY_DEVELOPER_ID:-}"
profile="${SPY_NOTARY_PROFILE:-}"
identities=$(/usr/bin/security find-identity -v -p codesigning)
if [[ -z "$identity" || -z "$profile" ]]; then
    print -u2 "Developer ID distribution is not configured."
    print -u2 "Set SPY_DEVELOPER_ID to an installed Developer ID Application identity and SPY_NOTARY_PROFILE to an existing notarytool keychain profile."
    print -u2 "Local development certificates cannot be notarized. See DISTRIBUTION.md."
    exit 2
fi
if ! print -r -- "$identities" | /usr/bin/awk -v requested="$identity" 'index($0, requested) && index($0, "Developer ID Application:") { found=1 } END { exit !found }'; then
    print -u2 "The requested Developer ID Application identity is not installed."
    exit 2
fi
if [[ "${1:-}" == "--check" ]]; then
    print "Developer ID identity is available. Keychain profile will be validated by notarytool during submission."
    exit 0
fi
[[ $# == 2 && -f "$1/Contents/MacOS/Spy" ]] || { print -u2 "Usage: distribute-macos.sh INPUT/Spy.app OUTPUT_DIRECTORY"; exit 2; }
input_app="${1:A}"
mkdir -p "$2"
output_dir="${2:A}"
stage=$(mktemp -d "$output_dir/.Spy-distribution.XXXXXX")
trap 'rm -rf "$stage"' EXIT INT TERM
app="$stage/Spy.app"
ditto "$input_app" "$app"
mkdir -p "$app/Contents/Helpers"
cp "$app/Contents/MacOS/Spy" "$app/Contents/Helpers/SpyInstaller"
codesign --force --sign "$identity" --identifier local.spy.updater --options runtime --timestamp "$app/Contents/Helpers/SpyInstaller"
codesign --force --sign "$identity" --identifier local.spy.mac --options runtime --timestamp --entitlements Distribution.entitlements "$app"
codesign --verify --deep --strict "$app"
ditto -c -k --keepParent "$app" "$stage/Submission.zip"
xcrun notarytool submit "$stage/Submission.zip" --keychain-profile "$profile" --wait --output-format json > "$output_dir/notary-app-result.json"
python3 - "$output_dir/notary-app-result.json" <<'PY'
import json,sys
report=json.load(open(sys.argv[1]))
if report.get('status')!='Accepted':
    raise SystemExit('Apple did not accept the app. Review notary-app-result.json and request the submission log before distributing it.')
PY
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"
zsh package-release.sh "$app" "$output_dir"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")
dmg="$output_dir/Spy-$version-macOS-arm64.dmg"
codesign --force --sign "$identity" --timestamp "$dmg"
xcrun notarytool submit "$dmg" --keychain-profile "$profile" --wait --output-format json > "$output_dir/notary-dmg-result.json"
python3 - "$output_dir/notary-dmg-result.json" <<'PY'
import json,sys
if json.load(open(sys.argv[1])).get('status')!='Accepted':
    raise SystemExit('Apple did not accept the disk image. Do not publish these artifacts.')
PY
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
(
    cd "$output_dir"
    shasum -a 256 "Spy-$version-macOS-arm64.zip" "Spy-$version-macOS-arm64.dmg" > SHA256SUMS.txt
)
print "Notarized release artifacts: $output_dir"
