#!/bin/bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1
cd "$(dirname "$0")/.."
mkdir -p build dist
app="$PWD/build/Inij.app"
if [[ ! -d "$app" ]]; then ditto /Applications/Inij.app "$app"; fi
cp backend/*.py "$app/Contents/Resources/backend/"
cp macos/Info.plist "$app/Contents/Info.plist"
python_bin="$app/Contents/Resources/python/bin/python3"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' macos/Info.plist)"
dmg="Inij-${version}-arm64.dmg"
"$python_bin" -I -B -m unittest discover -s tests -v
if [[ "${PACKAGE_ONLY:-0}" != 1 ]]; then
xcrun --sdk macosx swiftc -swift-version 5 -parse-as-library -O -target arm64-apple-macosx13.0 macos/Assistant.swift macos/SmokeTest.swift -o "$app/Contents/MacOS/PersonalAssistant" -framework SwiftUI -framework AppKit -framework WebKit -framework Security -framework PDFKit -framework Vision
fi
"$python_bin" -I -B -c 'import pathlib,shutil,sys; p=pathlib.Path(sys.argv[1])/"Contents/Resources/backend/__pycache__"; shutil.rmtree(p) if p.exists() else None' "$app"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
"$python_bin" -I -B scripts/verify_bundle.py "$app"
if [[ "${PACKAGE_ONLY:-0}" != 1 ]]; then
"$python_bin" -I -B scripts/verify_documents_native.py "$app" "$PWD/build/documents-native.json"
"$python_bin" -I -B scripts/verify_native.py "$app" "$PWD/build/native-final.json" --skip-keychain
"$python_bin" -I -B scripts/verify_local_images.py "$app" /Users/viktor/Inij-local-images-038/test-models/hyper-sd-v1_5-1step-q8_0.gguf "$PWD/build/local-image-final.json"
fi
stage="$(mktemp -d "$PWD/build/dmg-stage.XXXXXX")"
ditto "$app" "$stage/Inij.app"
ln -s /Applications "$stage/Applications"
hdiutil create -ov -volname Inij -srcfolder "$stage" -format UDZO "$PWD/dist/${dmg}"
"$python_bin" -I -B scripts/verify_installer.py "$PWD/dist/${dmg}" "$PWD/build/installed-final.json"
codesign --verify --deep --strict "$app"
cp "$PWD/dist/${dmg}" /Users/viktor/Desktop/${dmg}
shasum -a 256 "$PWD/dist/${dmg}" /Users/viktor/Desktop/${dmg}
stat -f '%z %N' /Users/viktor/Desktop/${dmg}
