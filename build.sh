#!/usr/bin/env bash
# Build callcap into an .app bundle under /Applications.
#
# It has to be a bundle, not a bare binary: macOS attributes the Screen
# Recording and Microphone grants to the enclosing app, so a loose CLI would
# push those permissions onto Terminal/VS Code instead of onto this tool.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="Call Capture"
BUNDLE_ID="com.callcap.recorder"
# /Applications, not ~/Applications: the Privacy & Security file picker opens
# at /Applications, and an app the user cannot find there looks broken.
APP_DIR="${CALLCAP_APP_DIR:-/Applications}/$APP_NAME.app"
BIN_DIR="${CALLCAP_BIN_DIR:-$HOME/.local/bin}"

echo "==> building $APP_NAME"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

swiftc -O \
  -target arm64-apple-macosx13.0 \
  -framework ScreenCaptureKit -framework AVFoundation -framework CoreMedia \
  -o "$APP_DIR/Contents/MacOS/callcap-rec" \
  "$HERE/src/main.swift"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>callcap-rec</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Records your side of a call so it can be transcribed locally.</string>
  <key>NSAudioCaptureUsageDescription</key>
  <string>Records the other party's audio from the calling app so the call can be transcribed locally.</string>
</dict>
</plist>
PLIST

# TCC keys a permission grant to the app's designated requirement. Under an
# ad-hoc signature that requirement is the cdhash, which changes with every
# rebuild — so each build silently revoked Screen Recording and the toggle had
# to be re-ticked. Signing with a stable local identity instead makes the
# requirement "this bundle id, signed by this certificate", which survives
# rebuilds. setup-signing-identity.sh creates the certificate.
# The hardened runtime denies microphone access outright unless the binary
# carries this entitlement — AVAudioEngine then starts fine and delivers
# nothing but silence, with the permission prompt auto-denied and no error.
ENTITLEMENTS="$(mktemp -t callcap-rec-entitlements).plist"
cat > "$ENTITLEMENTS" <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.device.audio-input</key><true/>
</dict>
</plist>
ENT
trap 'rm -f "$ENTITLEMENTS"' EXIT

SIGN_IDENTITY="${CALLCAP_IDENTITY:-Call Capture Local Signing}"
if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGN_IDENTITY"; then
  codesign --force --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" \
    --options runtime --timestamp=none --entitlements "$ENTITLEMENTS" "$APP_DIR"
  echo "==> signed with '$SIGN_IDENTITY' (grant survives rebuilds)"
else
  codesign --force --sign - --identifier "$BUNDLE_ID" --options runtime \
    --entitlements "$ENTITLEMENTS" "$APP_DIR"
  echo "==> WARNING: signed ad-hoc — '$SIGN_IDENTITY' not in the keychain."
  echo "    Screen Recording permission will need re-granting after every build."
  echo "    Run ./setup-signing-identity.sh once to fix this."
fi

mkdir -p "$BIN_DIR"
cat > "$BIN_DIR/callcap-rec" <<WRAPPER
#!/usr/bin/env bash
exec "$APP_DIR/Contents/MacOS/callcap-rec" "\$@"
WRAPPER
chmod +x "$BIN_DIR/callcap-rec"

ln -sf "$HERE/transcribe.sh" "$BIN_DIR/callcap-transcribe"
ln -sf "$HERE/call.sh" "$BIN_DIR/callcap"
ln -sf "$HERE/verify.sh" "$BIN_DIR/callcap-check"

# Seed a config on first build. Never overwrite: it holds the user's own
# vocabulary and preferences.
CONFIG_DIR="${CALLCAP_CONFIG_DIR:-$HOME/.config/callcap}"
mkdir -p "$CONFIG_DIR"
if [[ ! -f "$CONFIG_DIR/config.env" ]]; then
  cp "$HERE/config.env.example" "$CONFIG_DIR/config.env"
  echo "==> config  : $CONFIG_DIR/config.env (created)"
fi
if [[ ! -f "$CONFIG_DIR/vocabulary.txt" ]]; then
  cp "$HERE/vocabulary.example.txt" "$CONFIG_DIR/vocabulary.txt"
  echo "==> vocab   : $CONFIG_DIR/vocabulary.txt (created — add your jargon)"
fi

echo "==> app     : $APP_DIR"
echo "==> commands: $BIN_DIR/{callcap,callcap-check,callcap-rec,callcap-transcribe}"
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "==> NOTE: add $BIN_DIR to PATH" ;;
esac
