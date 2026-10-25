#!/usr/bin/env bash
# Build build/JustSpeak.app: release binary + sherpa-onnx dylibs, signed with a stable local identity
# so macOS keeps the Microphone / Input Monitoring / Accessibility grants across rebuilds.
#
#   scripts/build-app.sh            build and sign
#   scripts/build-app.sh --install  also copy to /Applications and link /usr/local/bin/just-speak
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/JustSpeak.app"
IDENTITY="just-speak local signing"
BUNDLE_ID="dev.just-speak.app"
VERSION="0.1.0"

[ -f "$ROOT/vendor/sherpa-onnx/lib/libsherpa-onnx-c-api.dylib" ] || "$ROOT/scripts/fetch-deps.sh"

echo "==> swift build -c release"
swift build -c release --package-path "$ROOT" >/dev/null
BIN="$(swift build -c release --package-path "$ROOT" --show-bin-path)/just-speak"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$ROOT/LICENSE" "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"   # regenerate: swift scripts/make-icon.swift Resources
cp "$BIN" "$APP/Contents/MacOS/just-speak"
cp "$ROOT/vendor/sherpa-onnx/lib/libsherpa-onnx-c-api.dylib" "$ROOT/vendor/sherpa-onnx/lib/libonnxruntime.dylib" \
  "$APP/Contents/Frameworks/"
# the dev rpath into vendor/ has no business in the shipped bundle
install_name_tool -delete_rpath "$ROOT/vendor/sherpa-onnx/lib" "$APP/Contents/MacOS/just-speak" 2>/dev/null || true

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>just-speak</string>
  <key>CFBundleDisplayName</key><string>just-speak</string>
  <key>CFBundleExecutable</key><string>just-speak</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>just-speak records your voice while you hold the dictation hotkey and transcribes it on this Mac.</string>
</dict>
</plist>
EOF

# --- signing identity -------------------------------------------------------------------------
if ! security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
  echo "==> creating self-signed code signing identity \"$IDENTITY\" in the login keychain"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  cat > "$tmp/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $IDENTITY
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$tmp/cert.cnf" \
    -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
  pass="just-speak-$RANDOM$RANDOM"
  /usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -name "$IDENTITY" \
    -out "$tmp/id.p12" -passout "pass:$pass" 2>/dev/null
  security import "$tmp/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$pass" -T /usr/bin/codesign >/dev/null
fi

echo "==> codesign"
for lib in "$APP/Contents/Frameworks/"*.dylib; do
  codesign --force --sign "$IDENTITY" --timestamp=none "$lib"
done
codesign --force --sign "$IDENTITY" --timestamp=none --identifier "$BUNDLE_ID" "$APP"
codesign --verify --strict "$APP"
echo "==> built $APP"

if [ "${1:-}" = "--install" ]; then
  rm -rf "/Applications/JustSpeak.app"
  cp -R "$APP" /Applications/
  mkdir -p /usr/local/bin 2>/dev/null || true
  ln -sf "/Applications/JustSpeak.app/Contents/MacOS/just-speak" /usr/local/bin/just-speak 2>/dev/null \
    || echo "   (could not link /usr/local/bin/just-speak; add an alias instead)"
  echo "==> installed /Applications/JustSpeak.app"
fi
