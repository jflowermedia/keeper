#!/bin/bash
# Builds Keeper.app from the Swift package.
#
#   ./build_app.sh             build Keeper.app in this folder
#   ./build_app.sh --install   build it and copy it into /Applications
#   ./build_app.sh --notarize  sign with your Developer ID and notarize, so the app opens
#                              cleanly on any Mac instead of being blocked by Gatekeeper
#
# App icon: drop a square icon.png (1024x1024 is ideal) next to this script and it is
# converted into the app's icon automatically. A ready-made AppIcon.icns is used if present.
#
# --notarize needs a paid Apple Developer account and two environment variables:
#   DEVID           the certificate name, e.g. "Developer ID Application: Jane Doe (AB12CD34EF)"
#                   list yours with:  security find-identity -v -p codesigning
#   NOTARY_PROFILE  the keychain profile you stored once with:
#                   xcrun notarytool store-credentials NOTARY --apple-id you@example.com --team-id AB12CD34EF
# e.g.  DEVID="Developer ID Application: Jane Doe (AB12CD34EF)" NOTARY_PROFILE=NOTARY ./build_app.sh --notarize
#
set -euo pipefail
cd "$(dirname "$0")"

INSTALL=0
NOTARIZE=0
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        --notarize) NOTARIZE=1 ;;
    esac
done

if [ "$NOTARIZE" -eq 1 ]; then
    : "${DEVID:?Set DEVID to your Developer ID Application certificate name}"
    : "${NOTARY_PROFILE:?Set NOTARY_PROFILE to your stored notarytool keychain profile}"
fi

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Keeper"

APP="Keeper.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Keeper"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Keeper</string>
    <key>CFBundleDisplayName</key><string>Keeper</string>
    <key>CFBundleIdentifier</key><string>local.keeper</string>
    <key>CFBundleExecutable</key><string>Keeper</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSRemovableVolumesUsageDescription</key><string>Keeper reads clip XML files and videos from your SD card.</string>
</dict>
</plist>
PLIST

# ---- App icon -------------------------------------------------------------
if [ -f AppIcon.icns ]; then
    cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
    echo "Icon: used AppIcon.icns"
elif [ -f icon.png ]; then
    ICONSET="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$ICONSET"
    while read -r px name; do
        [ -z "$px" ] && continue
        sips -z "$px" "$px" icon.png --out "$ICONSET/$name.png" >/dev/null 2>&1
    done <<'SIZES'
16 icon_16x16
32 icon_16x16@2x
32 icon_32x32
64 icon_32x32@2x
128 icon_128x128
256 icon_128x128@2x
256 icon_256x256
512 icon_256x256@2x
512 icon_512x512
1024 icon_512x512@2x
SIZES
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
    rm -rf "$(dirname "$ICONSET")"
    echo "Icon: built from icon.png"
else
    echo "Icon: no icon.png found, using the system default"
fi

# ---- Signing --------------------------------------------------------------
# Sign last, so the icon and plist are inside the seal.
if [ "$NOTARIZE" -eq 1 ]; then
    # Hardened runtime and a secure timestamp are both required for notarization.
    codesign --force --options runtime --timestamp --sign "$DEVID" "$APP"
    echo "Signed with: $DEVID"

    ZIP="Keeper-notarize.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"     # ditto, not zip: preserves the bundle

    echo "Submitting to Apple, this usually takes a few minutes…"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    rm -f "$ZIP"

    # Staples the ticket into the bundle so it opens even offline.
    xcrun stapler staple "$APP"
    echo "--- Gatekeeper check ---"
    spctl -a -vvv -t install "$APP" || true
else
    codesign --force --deep --sign - "$APP"
fi

echo "Built $APP"

if [ "$INSTALL" -eq 1 ]; then
    rm -rf "/Applications/$APP"
    cp -R "$APP" /Applications/
    touch "/Applications/$APP"          # nudges Finder to pick up a changed icon
    echo "Installed to /Applications/$APP"
fi
