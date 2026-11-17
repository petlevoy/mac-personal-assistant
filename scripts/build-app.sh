#!/bin/bash
# Developer/release build. End users receive the DMG, never run this script.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "$(uname -s)" == Darwin ]] || { echo 'ERROR: release build requires macOS and Xcode Command Line Tools'; exit 1; }
[[ "$(uname -m)" == arm64 ]] || { echo 'ERROR: this release targets Apple Silicon'; exit 1; }
xcrun --find swiftc >/dev/null
app="$PWD/build/Inij.app"
# Never merge a previous signed bundle/staging tree into a new release.
if [[ -e "$app" || -e "$PWD/build/dmg-stage" ]]; then
  echo "ERROR: use a clean build directory for release"; exit 1
fi
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/backend" "$PWD/build/cache" "$PWD/dist"
archive="$PWD/build/cache/python-3.12.16-arm64.tar.gz"
expected=e956e60bc9465d577ef8062059aa05cd3a2665b4b8678a2ed24e432368330b8f
if [[ ! -f "$archive" ]] || [[ "$(shasum -a 256 "$archive" | cut -d ' ' -f 1)" != "$expected" ]]; then
  curl --fail --location --connect-timeout 20 --max-time 600 --speed-time 30 --speed-limit 1024 \
    'https://github.com/astral-sh/python-build-standalone/releases/download/20261110/cpython-3.12.16%2B20261110-aarch64-apple-darwin-install_only.tar.gz' -o "$archive.download"
  [[ "$(shasum -a 256 "$archive.download" | cut -d ' ' -f 1)" == "$expected" ]] || { echo 'ERROR: Python checksum mismatch'; exit 1; }
  mv "$archive.download" "$archive"
fi
tar -xzf "$archive" -C "$app/Contents/Resources"
python_bin="$app/Contents/Resources/python/bin/python3"
"$python_bin" -I -B -m pip install --no-compile -r requirements-office.txt
rm -f "$app/Contents/Resources/python/bin/vba_extract.py"
"$python_bin" -I -B -m unittest discover -s tests -v
# Pin a verified upstream llama.cpp Metal build. Everything is bundled in .app.
llama_archive="$PWD/build/cache/llama-b12475-macos-arm64.tar.gz"
curl --fail --location --connect-timeout 20 --max-time 300 --speed-time 30 --speed-limit 1024 \
  'https://github.com/ggml-org/llama.cpp/releases/download/b12475/llama-b12475-bin-macos-arm64.tar.gz' -o "$llama_archive"
[[ "$(shasum -a 256 "$llama_archive" | cut -d ' ' -f 1)" == fdb6f35a513b200ae457b72796f8b543566f2a15c2e3e0347dca4d6cc110a086 ]] || { echo 'ERROR: llama checksum mismatch'; exit 1; }
mkdir -p "$app/Contents/Resources/llama"
tar -xzf "$llama_archive" --strip-components=1 -C "$app/Contents/Resources/llama"
# Remove upstream developer/sample utilities, not runtime dependencies.
"$python_bin" -I -B - "$app/Contents/Resources" <<'PYSLIM'
import pathlib,shutil,sys
res=pathlib.Path(sys.argv[1])
for name in ('test','idlelib','tkinter','turtledemo','ensurepip'):
    folder=res/'python/lib/python3.12'/name
    if folder.is_dir(): shutil.rmtree(folder)
for f in (res/'llama').iterdir():
    if f.is_file() and not f.is_symlink() and f.name not in ('llama-server','LICENSE') and not f.name.endswith('.dylib'):
        f.unlink()
PYSLIM
cp backend/*.py "$app/Contents/Resources/backend/"
cp macos/Info.plist "$app/Contents/Info.plist"
xcrun swift macos/MakeIcon.swift "$PWD/build/AppIcon.iconset"
iconutil -c icns "$PWD/build/AppIcon.iconset" -o "$app/Contents/Resources/AppIcon.icns"
xcrun --sdk macosx swiftc -swift-version 5 -parse-as-library -O \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" -target arm64-apple-macosx13.0 \
  macos/Assistant.swift macos/SmokeTest.swift -o "$app/Contents/MacOS/PersonalAssistant" \
  -framework SwiftUI -framework AppKit -framework WebKit -framework Security -framework PDFKit -framework Vision
# Runtime dylibs/extensions must be signed before their containing app.
while IFS= read -r -d '' item; do
  if file -b "$item" | grep -q 'Mach-O'; then codesign --force --sign "${SIGNING_IDENTITY:--}" "$item"; fi
done < <(find "$app/Contents/Resources/python" "$app/Contents/Resources/llama" -type f -print0)
if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --entitlements macos/Entitlements.plist --sign "$SIGNING_IDENTITY" "$app"
else
  codesign --force --sign - "$app"
fi
codesign --verify --deep --strict --verbose=2 "$app"
"$python_bin" -I -B scripts/verify_bundle.py "$app"
"$python_bin" -I -B scripts/verify_local_model.py "$app" | tee "$PWD/build/local-model-smoke.json"
codesign --verify --deep --strict --verbose=2 "$app"
"$python_bin" -I -B scripts/verify_native.py "$app" "$PWD/build/native-smoke.json"
codesign --verify --deep --strict --verbose=2 "$app"
# Package with Applications shortcut. Keep the runtime inside .app when dragged.
stage="$PWD/build/dmg-stage"
mkdir -p "$stage"
ditto "$app" "$stage/Inij.app"
[[ -L "$stage/Applications" ]] || ln -s /Applications "$stage/Applications"
hdiutil create -volname 'Inij' -srcfolder "$stage" -ov -format UDZO "$PWD/dist/Inij-0.3.3-arm64.dmg"
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$PWD/dist/Inij-0.3.3-arm64.dmg" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$PWD/dist/Inij-0.3.3-arm64.dmg"
fi
"$python_bin" -I -B scripts/verify_installer.py "$PWD/dist/Inij-0.3.3-arm64.dmg" "$PWD/build/installed-smoke.json"
shasum -a 256 "$PWD/dist/Inij-0.3.3-arm64.dmg"
echo 'Release built; packaged/installed LaunchServices smoke and post-launch signatures passed. Ad-hoc build is not notarized.'
