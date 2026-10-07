#!/usr/bin/env bash
# Build the Mac app (Mac Catalyst) for download outside the App Store:
# archive unsigned → sign with Developer ID + the Developer ID profile →
# verify → notarize + staple → DMG → sign, notarize + staple the DMG.
#
# Shared by .github/workflows/release-mac.yml and scripts/release-mac-local.sh.
# Everything comes in through the environment:
#
#   VERSION          marketing version, e.g. 0.1.0                      (required)
#   BUILD_NUMBER     CFBundleVersion (default: commit count of HEAD)
#   SIGN_IDENTITY    Developer ID Application identity: SHA-1 or name   (required)
#   PROFILE          path to the Developer ID .provisionprofile         (required)
#   KEYCHAIN         keychain holding the identity (default: search list)
#   NOTARY_KEY_PATH  App Store Connect API key (.p8) for notarytool
#   NOTARY_KEY_ID    its key ID
#   NOTARY_ISSUER    its issuer ID      (all three unset → skip notarization)
#   OUT              output directory (default: build/release)
#
# Produces $OUT/PaloAlly.dmg, $OUT/PaloAlly-$VERSION.dmg and $OUT/SHA256SUMS.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${VERSION:?set VERSION, e.g. 0.1.0}"
: "${SIGN_IDENTITY:?set SIGN_IDENTITY (Developer ID Application)}"
: "${PROFILE:?set PROFILE to the Developer ID .provisionprofile}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git -C "$ROOT" rev-list --count HEAD)}"
OUT="${OUT:-$ROOT/build/release}"
KC_ARGS=()
[ -n "${KEYCHAIN:-}" ] && KC_ARGS=(--keychain "$KEYCHAIN")

say() { printf '\033[1;35m▸\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

notarize() { # file to submit
  if [ -z "${NOTARY_KEY_PATH:-}" ] || [ -z "${NOTARY_KEY_ID:-}" ] || [ -z "${NOTARY_ISSUER:-}" ]; then
    say "no notary key: skipping notarization of $(basename "$1")"
    return 1
  fi
  local auth=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
  local log="$OUT/notary-$(basename "$1").json"
  # Submit without --wait and poll: Apple's queue sometimes takes hours, and
  # a fixed --wait timeout threw away an otherwise good build.
  if ! xcrun notarytool submit "$1" "${auth[@]}" --output-format json >"$log"; then
    cat "$log" >&2
    die "notarytool submit failed"
  fi
  local id status
  id=$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id",""))' "$log")
  [ -n "$id" ] || { cat "$log" >&2; die "notarytool gave no submission id"; }
  say "notarizing $(basename "$1"): submission $id (polling up to ${NOTARY_MAX_MINUTES:-240} min)"
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] && echo "Notarization submission: \`$id\`" >>"$GITHUB_STEP_SUMMARY"
  local deadline=$(( $(date +%s) + ${NOTARY_MAX_MINUTES:-240} * 60 ))
  while :; do
    status=$(xcrun notarytool info "$id" "${auth[@]}" --output-format json 2>/dev/null |
      /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))' 2>/dev/null || true)
    case "$status" in
      Accepted) break ;;
      Invalid|Rejected)
        xcrun notarytool log "$id" "${auth[@]}" >&2 || true
        die "notarization $status ($id)" ;;
    esac
    [ "$(date +%s)" -lt "$deadline" ] || die "notarization still ${status:-pending} after ${NOTARY_MAX_MINUTES:-240} min ($id)"
    sleep 60
  done
  say "notarized: $id"
}

rm -rf "$OUT"
mkdir -p "$OUT"
ARCHIVE="$OUT/PaloAlly.xcarchive"

say "Xcode: $(xcodebuild -version | head -1), macOS SDK $(xcrun --sdk macosx --show-sdk-version)"
say "archiving PaloAlly $VERSION ($BUILD_NUMBER) for Mac Catalyst, unsigned"
xcodebuild archive \
  -project "$ROOT/ios/App/PaloAlly.xcodeproj" -scheme PaloAlly -configuration Release \
  -destination 'generic/platform=macOS,variant=Mac Catalyst' \
  -archivePath "$ARCHIVE" -derivedDataPath "$OUT/DerivedData" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  PALOALLY_COMMIT="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo dev)" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  -quiet
APP="$OUT/PaloAlly.app"
ditto "$ARCHIVE/Products/Applications/PaloAlly.app" "$APP"

# Entitlements: the app's own (sandbox, network, mic, camera) plus what the
# Developer ID profile grants (identifiers, production push). This matches
# what `xcodebuild -exportArchive -method developer-id` writes.
say "signing with Developer ID"
security cms -D -i "$PROFILE" >"$OUT/profile.plist"
/usr/bin/python3 - "$ROOT/ios/App/PaloAlly.entitlements" "$OUT/profile.plist" "$OUT/PaloAlly.entitlements" <<'PY'
import plistlib, sys
app = plistlib.load(open(sys.argv[1], "rb"))
prof = plistlib.load(open(sys.argv[2], "rb"))["Entitlements"]
ent = {k: v for k, v in app.items() if k != "aps-environment"}
for k in ("application-identifier", "com.apple.application-identifier", "com.apple.developer.team-identifier"):
    ent[k] = prof[k]
if "aps-environment" in app:
    ent["aps-environment"] = prof["com.apple.developer.aps-environment"]
    ent["com.apple.developer.aps-environment"] = prof["com.apple.developer.aps-environment"]
ent["get-task-allow"] = False
plistlib.dump(ent, open(sys.argv[3], "wb"))
PY
cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
# Nested code first (none today: the packages link statically), then the app.
find "$APP/Contents" \( -name "*.framework" -o -name "*.dylib" -o -name "*.appex" -o -name "*.xpc" \) -prune -print0 2>/dev/null |
  while IFS= read -r -d '' nested; do
    codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" ${KC_ARGS[@]+"${KC_ARGS[@]}"} "$nested"
  done
codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" ${KC_ARGS[@]+"${KC_ARGS[@]}"} \
  --entitlements "$OUT/PaloAlly.entitlements" "$APP"

say "verifying the signature"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dvv "$APP" 2>&1 | grep -E "^(Authority|TeamIdentifier)=" | head -2

# One notarization per release: the signed DMG with the signed app inside.
# Apple's ticket covers the app too (Gatekeeper finds it online on first
# launch), and a single submission halves the time spent in Apple's queue.
say "building the DMG"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/PaloAlly.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "PaloAlly" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 \
  -ov "$OUT/PaloAlly.dmg" -quiet
rm -rf "$STAGE"
codesign --force --timestamp --sign "$SIGN_IDENTITY" ${KC_ARGS[@]+"${KC_ARGS[@]}"} "$OUT/PaloAlly.dmg"
NOTARIZED=0
if notarize "$OUT/PaloAlly.dmg"; then
  xcrun stapler staple "$OUT/PaloAlly.dmg"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$OUT/PaloAlly.dmg"
  NOTARIZED=1
fi

cp "$OUT/PaloAlly.dmg" "$OUT/PaloAlly-$VERSION.dmg"
(cd "$OUT" && shasum -a 256 PaloAlly.dmg "PaloAlly-$VERSION.dmg" >SHA256SUMS)
say "done: $OUT/PaloAlly.dmg ($(du -h "$OUT/PaloAlly.dmg" | cut -f1)), notarized=$NOTARIZED"
