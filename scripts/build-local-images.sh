#!/bin/bash
# Reuse verified 0.3.7 Python/llama resources; replace backend, Swift and add image runtime.
set -euo pipefail
cd "$(dirname "$0")/.."
base=/Users/viktor/Desktop/Inij-0.3.7-arm64.dmg
[[ "$(shasum -a 256 "$base" | cut -d ' ' -f 1)" == 4e145c2ebd48ae2937b411c87d550a556985fe36cc92f6817a0cdd08ff885eec ]]
[[ ! -e build/Inij.app ]]
mkdir -p build dist
mount_dir="$(mktemp -d /tmp/inij-base-038.XXXXXX)"
hdiutil attach -readonly -nobrowse -mountpoint "$mount_dir" "$base"
trap 'hdiutil detach "$mount_dir" >/dev/null 2>&1 || true' EXIT
codesign --verify --deep --strict "$mount_dir/Inij.app"
ditto "$mount_dir/Inij.app" build/Inij.app
hdiutil detach "$mount_dir"
trap - EXIT
app="$PWD/build/Inij.app"
python_bin="$app/Contents/Resources/python/bin/python3"
cp backend/*.py "$app/Contents/Resources/backend/"
bash scripts/install-image-runtime.sh "$app" "$PWD/build/cache"
"$python_bin" -I -B -m unittest discover -s tests -v
cp macos/Info.plist "$app/Contents/Info.plist"
xcrun --sdk macosx swiftc -swift-version 5 -parse-as-library -O -target arm64-apple-macosx13.0 \
 macos/Assistant.swift macos/SmokeTest.swift -o "$app/Contents/MacOS/PersonalAssistant" \
 -framework SwiftUI -framework AppKit -framework WebKit -framework Security -framework PDFKit -framework Vision
for binary in sd-cli libstable-diffusion.dylib; do codesign --force --sign - "$app/Contents/Resources/stable-diffusion/$binary"; done
codesign --force --sign - "$app"
codesign --verify --deep --strict --verbose=2 "$app"
"$python_bin" -I -B scripts/verify_bundle.py "$app"
"$python_bin" -I -B scripts/verify_native.py "$app" "$PWD/build/native-smoke.json" --skip-keychain
"$python_bin" -I -B scripts/verify_local_images.py "$app" /Users/viktor/Inij-local-images-038/test-models/hyper-sd-v1_5-1step-q8_0.gguf "$PWD/build/local-image-smoke.json"
codesign --verify --deep --strict --verbose=2 "$app"
mkdir -p build/dmg-stage
ditto "$app" build/dmg-stage/Inij.app
ln -s /Applications build/dmg-stage/Applications
hdiutil create -volname Inij -srcfolder build/dmg-stage -format UDZO "$PWD/dist/Inij-0.3.8-arm64.dmg"
"$python_bin" -I -B scripts/verify_installer.py "$PWD/dist/Inij-0.3.8-arm64.dmg" "$PWD/build/installed-smoke.json"
shasum -a 256 "$PWD/dist/Inij-0.3.8-arm64.dmg"
echo 'PASS: local image inference, backend/native/installer/signatures verified.'
