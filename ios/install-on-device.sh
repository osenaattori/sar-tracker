#!/bin/zsh
# Build, sign and install SAR Tracker on a USB-connected iPhone using an
# existing Xcode-managed provisioning profile (no Xcode account sign-in needed).
#
# Usage: [FEED_URL=http://<mac-ip>:8080/feed.json] ios/install-on-device.sh <bundle-id-of-existing-profile> [device-udid]
#   e.g. ios/install-on-device.sh org.codex.PDFDeviceProbe
#
# Note: free "Personal Team" profiles expire after 7 days. After that, sign in
# to Xcode (Settings → Accounts) and just press Run instead.
set -euo pipefail

BUNDLE_ID=${1:?bundle id of an existing provisioning profile}
DEVICE=${2:-$(xcrun devicectl list devices 2>/dev/null | awk '/physical/ && /available/ {for(i=1;i<=NF;i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) print $i}' | head -1)}
[[ -n "$DEVICE" ]] || { echo "No connected iPhone found"; exit 1; }

HERE=${0:A:h}
WORK=$(mktemp -d)
PROFILES="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"

PROF=""
for f in "$PROFILES"/*.mobileprovision; do
  if security cms -D -i "$f" 2>/dev/null | grep -q "\.${BUNDLE_ID}</string>"; then PROF=$f; break; fi
done
[[ -n "$PROF" ]] || { echo "No provisioning profile for $BUNDLE_ID"; exit 1; }

security cms -D -i "$PROF" > "$WORK/prof.plist"
/usr/libexec/PlistBuddy -x -c 'Print :Entitlements' "$WORK/prof.plist" > "$WORK/ent.plist"
TEAM=$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$WORK/prof.plist")
IDENTITY=$(security find-identity -v -p codesigning | grep "Apple Development" | grep -o '"[^"]*"' | head -1 | tr -d '"')
echo "Profile: $(basename "$PROF")  team: $TEAM  device: $DEVICE"

xcodebuild -project "$HERE/SARTracker/SARTracker.xcodeproj" -scheme SARTracker \
  -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath "$WORK/dd" \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" CODE_SIGNING_ALLOWED=NO \
  SAR_DEFAULT_FEED_URL="${FEED_URL:-}" \
  ENABLE_DEBUG_DYLIB=NO ENABLE_PREVIEWS=NO -quiet build

APP="$WORK/dd/Build/Products/Debug-iphoneos/SAR Tracker.app"
cp "$PROF" "$APP/embedded.mobileprovision"
# iOS kills the app at launch if ANY embedded code is unsigned: sign nested code first.
find "$APP" -mindepth 1 \( -name "*.dylib" -o -name "*.framework" -o -name "*.appex" \) -prune -print0 |
  xargs -0 -I{} codesign --force --sign "$IDENTITY" --timestamp=none {}
codesign --force --sign "$IDENTITY" --entitlements "$WORK/ent.plist" --timestamp=none --generate-entitlement-der "$APP"
codesign --verify --deep --strict "$APP"

xcrun devicectl device install app --device "$DEVICE" "$APP"
xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE_ID"
echo "Installed and launched SAR Tracker."
