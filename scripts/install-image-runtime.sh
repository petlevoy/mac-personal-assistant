#!/bin/bash
# Pinned upstream arm64 CPU/Metal runtime; models are never part of the app.
set -euo pipefail
app="$1"
cache="$2"
mkdir -p "$cache" "$app/Contents/Resources/stable-diffusion"
archive="$cache/sd-macos-532d2c1.zip"
expected=8146d6ffc75f8ff8f64b62a80fffee8fb714ab65e368e202084135fa07cc6f36
if [[ ! -f "$archive" ]] || [[ "$(shasum -a 256 "$archive" | cut -d ' ' -f 1)" != "$expected" ]]; then
 curl --fail --location --connect-timeout 20 --max-time 600 --speed-time 30 --speed-limit 1024 \
  https://github.com/leejet/stable-diffusion.cpp/releases/download/master-1106-532d2c1/sd-master-532d2c1-bin-Darwin-macOS-26.7.2-arm64.zip -o "$archive.download"
 [[ "$(shasum -a 256 "$archive.download" | cut -d ' ' -f 1)" == "$expected" ]]
 mv "$archive.download" "$archive"
fi
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
unzip -q "$archive" -d "$stage"
for binary in sd-cli libstable-diffusion.dylib; do
 lipo "$stage/$binary" -thin arm64 -output "$app/Contents/Resources/stable-diffusion/$binary"
done
chmod +x "$app/Contents/Resources/stable-diffusion/sd-cli"
cp "$stage/ggml.txt" "$stage/stable-diffusion.cpp.txt" "$app/Contents/Resources/stable-diffusion/"
# This pinned engine requires macOS 26; app explicitly checks before invocation.
