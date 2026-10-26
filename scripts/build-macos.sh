#!/bin/sh
set -eu

if [ "$(uname -s)" != Darwin ]; then
  printf '%s\n' 'macOS is required to build the native VOkit app.' >&2
  exit 1
fi

for tool in go swiftc; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf '%s\n' "Missing build tool: $tool" >&2
    exit 1
  fi
done

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
app="$root/build/VOkit.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$root/macos/Info.plist" "$app/Contents/Info.plist"
(
  cd "$root"
  CGO_ENABLED=0 go build -trimpath -o "$app/Contents/Resources/vivolinux" ./cmd/vivolinux
)
swiftc -target "$(uname -m)-apple-macos13.0" -parse-as-library -O \
  -framework AppKit -framework SwiftUI \
  -o "$app/Contents/MacOS/VOkit" "$root/macos/VOkitMac.swift"
printf 'Built: %s\n' "$app"
printf '%s\n' 'Install qrencode to use QR pairing: brew install qrencode'
