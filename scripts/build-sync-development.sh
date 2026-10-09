#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
derived_data="${WN_SYNC_DERIVED_DATA:-$repo_root/../build/MacSyncSidecar}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

source "$repo_root/scripts/local-device-sync-settings.sh"

# App-specific variables leave SwiftPM privacy resource targets unchanged.
xcodebuild build \
  -project "$repo_root/whitenoise-mac.xcodeproj" \
  -scheme whitenoise-mac -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$derived_data" \
  WN_APP_BUNDLE_IDENTIFIER=dev.ipf.whitenoise.mac.syncdev \
  'WN_APP_PRODUCT_NAME=White Noise Sync Development' \
  'WN_APP_DISPLAY_NAME=White Noise Sync Development' \
  WN_APP_URL_SCHEME=marmot-syncdev \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual \
  CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES DEVELOPMENT_TEAM='' \
  ${device_sync_settings[@]+"${device_sync_settings[@]}"}

codesign --verify --deep --strict \
  "$derived_data/Build/Products/Debug/White Noise Sync Development.app"
