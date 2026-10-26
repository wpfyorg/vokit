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
app="${VOKIT_MACOS_APP_PATH:-$root/build/VOkit.app}"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$root/macos/Info.plist" "$app/Contents/Info.plist"
(
  cd "$root"
  CGO_ENABLED=0 go build -trimpath -o "$app/Contents/Resources/vivolinux" ./cmd/vivolinux
)
swiftc -target "$(uname -m)-apple-macos13.0" -parse-as-library -O \
  -framework AppKit -framework SwiftUI -framework Network \
  -framework AVFoundation -framework VideoToolbox -framework CoreMedia \
  -o "$app/Contents/MacOS/VOkit" "$root"/macos/*.swift
helper="$app/Contents/Resources/VOkitHelper.app"
mkdir -p "$helper/Contents/MacOS"
cp "$root/macos/helper/Info.plist" "$helper/Contents/Info.plist"
swiftc -target "$(uname -m)-apple-macos13.0" -parse-as-library -O \
  -framework AppKit -framework UserNotifications \
  -o "$helper/Contents/MacOS/VOkitHelper" \
  "$root/macos/helper/PhoneDesktopHelper.swift"
printf 'Built: %s\n' "$app"
printf '%s\n' 'Install qrencode to use QR pairing: brew install qrencode'
