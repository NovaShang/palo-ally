#!/bin/sh
# Builds PaloAlly Helper.app (docs/pals-prd.md §7.3) and signs it with a
# Developer ID. The signed app is never committed.
#
#   host/helper/build.sh [out-dir]       default out-dir: host/helper/build
#
# PALOALLY_SIGN_IDENTITY picks the signing identity (a name or a SHA-1 from
# `security find-identity -v -p codesigning`); by default the first
# "Developer ID Application" identity in the keychain. "-" signs ad hoc
# (it runs, but macOS can't keep its permissions across rebuilds).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out=${1:-"$here/build"}
app="$out/PaloAlly Helper.app"
identity=${PALOALLY_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ { print $2; exit }')}
[ -n "$identity" ] || { echo "no Developer ID Application identity; set PALOALLY_SIGN_IDENTITY" >&2; exit 1; }

rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$here/Info.plist" "$app/Contents/Info.plist"
swiftc -O -target arm64-apple-macos14.0 -o "$app/Contents/MacOS/PaloAllyHelper.arm64" "$here/main.swift"
swiftc -O -target x86_64-apple-macos14.0 -o "$app/Contents/MacOS/PaloAllyHelper.x86_64" "$here/main.swift"
lipo -create -output "$app/Contents/MacOS/PaloAllyHelper" "$app/Contents/MacOS/PaloAllyHelper.arm64" "$app/Contents/MacOS/PaloAllyHelper.x86_64"
rm "$app/Contents/MacOS/PaloAllyHelper.arm64" "$app/Contents/MacOS/PaloAllyHelper.x86_64"
codesign --force --options runtime --timestamp --sign "$identity" "$app"
codesign --verify --strict "$app"
echo "$app"
