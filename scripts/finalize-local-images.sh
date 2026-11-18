#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="$PWD/build/Inij.app"
python_bin="$app/Contents/Resources/python/bin/python3"
cp backend/*.py "$app/Contents/Resources/backend/"
cp macos/Info.plist "$app/Contents/Info.plist"
"$python_bin" -I -B -m unittest discover -s tests -v
xcrun --sdk macosx swiftc -swift-version 5 -parse-as-library -O -target arm64-apple-macosx13.0 \
 macos/Assistant.swift macos/SmokeTest.swift -o "$app/Contents/MacOS/PersonalAssistant" \
 -framework SwiftUI -framework AppKit -framework WebKit -framework Security -framework PDFKit -framework Vision
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
"$python_bin" -I -B scripts/verify_bundle.py "$app"
"$python_bin" -I -B scripts/verify_native.py "$app" "$PWD/build/native-final.json" --skip-keychain
"$python_bin" -I -B scripts/verify_local_images.py "$app" /Users/viktor/Inij-local-images-038/test-models/hyper-sd-v1_5-1step-q8_0.gguf "$PWD/build/local-image-final.json"
"$python_bin" -I -B scripts/verify_local_model.py "$app" /Users/viktor/Inij-local-images-038/test-models/hyper-sd-v1_5-1step-q8_0.gguf > "$PWD/build/model-swap-final.json"
codesign --verify --deep --strict "$app"
mv build/dmg-stage build/dmg-stage-first-pass
mv dist/Inij-0.3.8-arm64.dmg dist/first-pass-038.dmg
mkdir build/dmg-stage
ditto "$app" build/dmg-stage/Inij.app
ln -s /Applications build/dmg-stage/Applications
hdiutil create -volname Inij -srcfolder build/dmg-stage -format UDZO "$PWD/dist/Inij-0.3.8-arm64.dmg"
"$python_bin" -I -B scripts/verify_installer.py "$PWD/dist/Inij-0.3.8-arm64.dmg" "$PWD/build/installed-final.json"
shasum -a 256 "$PWD/dist/Inij-0.3.8-arm64.dmg"
echo 'PASS: final source, image/native/model-swap/installer/signatures verified'
