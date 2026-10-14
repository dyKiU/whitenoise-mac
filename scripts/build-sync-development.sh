#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
derived_data="${WN_SYNC_DERIVED_DATA:-$repo_root/../build/MacSyncSidecar}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
build_jobs="${WN_BUILD_JOBS:-1}"
if [[ ! "$build_jobs" =~ ^[1-9][0-9]*$ ]]; then
  echo 'WN_BUILD_JOBS must be a positive integer' >&2
  exit 2
fi

source "$repo_root/scripts/local-device-sync-settings.sh"

# App-specific variables leave SwiftPM privacy resource targets unchanged.
xcodebuild build \
  -project "$repo_root/whitenoise-mac.xcodeproj" \
  -scheme whitenoise-mac -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$derived_data" \
  -jobs "$build_jobs" \
  WN_APP_BUNDLE_IDENTIFIER=dev.ipf.whitenoise.mac.syncdev \
  'WN_APP_PRODUCT_NAME=White Noise Sync Development' \
  'WN_APP_DISPLAY_NAME=White Noise Sync Development' \
  WN_APP_URL_SCHEME=marmot-syncdev \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual \
  CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES DEVELOPMENT_TEAM='' \
  ${device_sync_settings[@]+"${device_sync_settings[@]}"}

# The experimental camera belongs only to this isolated development product.
# Keep production signing and SwiftPM resource target settings unchanged.
if [[ "${WN_EXPERIMENTAL_DEVICE_SYNC:-0}" == 1 ]]; then
  development_app="$derived_data/Build/Products/Debug/White Noise Sync Development.app"
  python3 - "$development_app/Contents/Info.plist" <<'CAMERA_PLIST'
import plistlib,sys
from pathlib import Path
path=Path(sys.argv[1]);info=plistlib.loads(path.read_bytes())
info['NSCameraUsageDescription']='Scan a pairing QR code from your other device.'
path.write_bytes(plistlib.dumps(info,fmt=plistlib.FMT_BINARY))
CAMERA_PLIST
  codesign --force --sign - --timestamp=none \
    --entitlements "$repo_root/whitenoise-mac/whitenoise-mac.syncdev.entitlements" "$development_app"
fi

codesign --verify --deep --strict \
  "$derived_data/Build/Products/Debug/White Noise Sync Development.app"
