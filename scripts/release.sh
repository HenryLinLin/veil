#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${DEVELOPER_ID:?Set DEVELOPER_ID to your Developer ID Application certificate}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to a saved notarytool keychain profile}"
./scripts/build.sh
codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" build/Veil.app
codesign --verify --deep --strict build/Veil.app
ditto -c -k --keepParent build/Veil.app build/Veil.zip
xcrun notarytool submit build/Veil.zip --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple build/Veil.app
xcrun stapler validate build/Veil.app
ditto -c -k --keepParent build/Veil.app build/Veil.zip
