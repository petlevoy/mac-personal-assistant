#!/bin/bash
# UI-only build: reuse the exact verified 0.3.6 runtime, rebuild Swift, verify and package.
set -euo pipefail
cd "$(dirname "$0")/.."
base=/Users/viktor/Desktop/Inij-0.3.6-arm64.dmg
expected=a316c1dca2567ecffb6f0254272c4e926e519a99283dbf7a887a4371486cf84f
[[ "$(shasum -a 256 "$base" | cut -d ' ' -f 1)" == "$expected" ]]
[[ ! -e build/Inij.app ]]
mkdir -p build dist
mount_dir="$(mktemp -d /tmp/inij-base-037.XXXXXX)"
hdiutil attach -readonly -nobrowse -mountpoint "$mount_dir" "$base"
trap 'hdiutil detach "$mount_dir" >/dev/null 2>&1 || true' EXIT
codesign --verify --deep --strict "$mount_dir/Inij.app"
ditto "$mount_dir/Inij.app" build/Inij.app
hdiutil detach "$mount_dir"
trap - EXIT
app="$PWD/build/Inij.app"
python_bin="$app/Contents/Resources/python/bin/python3"
# Enforce that no runtime/backend change is being bypassed by reusing 0.3.6.
for path in backend/*.py; do cmp "$path" "$app/Contents/Resources/$path"; done
"$python_bin" -I -B -m unittest discover -s tests -v
cp macos/Info.plist "$app/Contents/Info.plist"
xcrun --sdk macosx swiftc -swift-version 5 -parse-as-library -O -target arm64-apple-macosx13.0 \
 macos/Assistant.swift macos/SmokeTest.swift -o "$app/Contents/MacOS/PersonalAssistant" \
 -framework SwiftUI -framework AppKit -framework WebKit -framework Security -framework PDFKit -framework Vision
codesign --force --sign - "$app"
codesign --verify --deep --strict --verbose=2 "$app"
"$python_bin" -I -B scripts/verify_bundle.py "$app"
"$python_bin" -I -B scripts/verify_native.py "$app" "$PWD/build/native-smoke.json" --skip-keychain
codesign --verify --deep --strict --verbose=2 "$app"
mkdir -p build/dmg-stage
ditto "$app" build/dmg-stage/Inij.app
ln -s /Applications build/dmg-stage/Applications
hdiutil create -volname Inij -srcfolder build/dmg-stage -format UDZO "$PWD/dist/Inij-0.3.7-arm64.dmg"
"$python_bin" -I -B scripts/verify_installer.py "$PWD/dist/Inij-0.3.7-arm64.dmg" "$PWD/build/installed-smoke.json"
shasum -a 256 "$PWD/dist/Inij-0.3.7-arm64.dmg"
echo 'PASS: UI rebuilt; exact baseline runtime; bundle/native mouse/streaming/installed-launch/signatures verified.'
