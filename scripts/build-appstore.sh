#!/usr/bin/env bash
# Builds the Mac App Store package: sandboxed, signed with Apple Distribution, wrapped in a signed installer.
#   usage: scripts/build-appstore.sh <Mac App Store provisioning profile>
# Pass SANDBOX_TEST=1 to skip the profile and ad-hoc sign a sandboxed copy you can launch locally.
set -euo pipefail
cd "$(dirname "$0")/.."
NAME=LiveCaptions
BUNDLE_ID=com.dunebru.livecaptions
ENT=packaging/LiveCaptions.appstore.entitlements
IDENTITY="${SIGN_IDENTITY:-Apple Distribution}"
INSTALLER="${INSTALLER_IDENTITY:-3rd Party Mac Developer Installer}"

[ -d "dist/$NAME.app" ] || scripts/build-app.sh
OUT=dist/appstore
rm -rf "$OUT" && mkdir -p "$OUT"
cp -R "dist/$NAME.app" "$OUT/"
APP="$OUT/$NAME.app"

if [ "${SANDBOX_TEST:-0}" = "1" ]; then
  # Local smoke test: sandbox on, no profile, ad-hoc identity. The identifier entitlements need a profile, so strip them.
  TMP_ENT="$(mktemp).plist"
  plutil -convert xml1 -o "$TMP_ENT" "$ENT"
  python3 -c 'import plistlib,sys; p=sys.argv[1]; d=plistlib.load(open(p,"rb")); d.pop("com.apple.security.application-identifier",None); d.pop("com.apple.developer.team-identifier",None); plistlib.dump(d,open(p,"wb"))' "$TMP_ENT"
  codesign --force --deep --sign - --identifier "$BUNDLE_ID" --entitlements "$TMP_ENT" "$APP"
  echo "sandboxed test build: $APP"
  exit 0
fi

PROFILE="${1:?path to the Mac App Store provisioning profile}"
cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"

# Nested code first: frameworks, bundles, helper executables, Metal libraries.
find "$APP/Contents" -type f \( -perm -u+x -o -name "*.dylib" -o -name "*.metallib" \) -not -path "*/MacOS/$NAME" | while read -r f; do
  if file "$f" | grep -qE "Mach-O"; then codesign --force --timestamp --sign "$IDENTITY" "$f"; fi
done
find "$APP/Contents" -type d \( -name "*.bundle" -o -name "*.framework" -o -name "*.mlmodelc" \) | while read -r b; do
  codesign --force --timestamp --sign "$IDENTITY" "$b" >/dev/null 2>&1 || true
done
codesign --force --timestamp --sign "$IDENTITY" --identifier "$BUNDLE_ID" --entitlements "$ENT" "$APP"
codesign --verify --deep --strict "$APP"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q app-sandbox || { echo "sandbox entitlement missing"; exit 1; }

productbuild --component "$APP" /Applications --sign "$INSTALLER" "$OUT/$NAME.pkg" >/dev/null
echo "→ $OUT/$NAME.pkg ($(du -h "$OUT/$NAME.pkg" | cut -f1))"
