#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
derived_data="${WN_TEST_DERIVED_DATA:-$repo_root/../build/MacIsolatedTests}"
result_bundle="${WN_TEST_RESULT_BUNDLE:-$derived_data/TestResults.xcresult}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
app="$derived_data/Build/Products/Debug/White Noise Unit Host.app"
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# Test execution can register its host app. Remove only this temporary host.
cleanup() {
  if [[ -d "$app" ]]; then
    "$lsregister" -u "$app" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if [[ -e "$result_bundle" ]]; then
  echo "Result bundle already exists; choose a fresh WN_TEST_RESULT_BUNDLE." >&2
  exit 1
fi

settings=(
  -project "$repo_root/whitenoise-mac.xcodeproj"
  -scheme whitenoise-mac -configuration Debug -testPlan PR
  -destination 'platform=macOS,arch=arm64'
  -derivedDataPath "$derived_data"
  WN_APP_BUNDLE_IDENTIFIER=dev.ipf.whitenoise.mac.tests
  'WN_APP_PRODUCT_NAME=White Noise Unit Host'
  'WN_APP_DISPLAY_NAME=White Noise Unit Host'
  WN_APP_URL_SCHEME=marmot-tests
  "TEST_HOST=$app/Contents/MacOS/White Noise Unit Host"
  CODE_SIGNING_ALLOWED=NO
)

xcodebuild build-for-testing "${settings[@]}"
identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")
if [[ "$identifier" != dev.ipf.whitenoise.mac.tests ]]; then
  echo "Refusing test execution with an unexpected host identity." >&2
  exit 1
fi
xcodebuild test-without-building "${settings[@]}" -resultBundlePath "$result_bundle" "$@"
