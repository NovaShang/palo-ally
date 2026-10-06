#!/usr/bin/env bash
# Dry run of the Mac release on this Mac, with the same steps CI runs
# (scripts/release-mac.sh), using the Developer ID identity in the login
# keychain instead of a temporary one.
#
#   scripts/release-mac-local.sh [version] [profile] [out-dir]
#
#   version   default: MARKETING_VERSION in ios/App/project.yml
#   profile   the Developer ID .provisionprofile
#             (default: the installed profile named "PaloAlly Mac Developer ID")
#   out-dir   default: build/release
#
# Notarizes when NOTARY_KEY_PATH, NOTARY_KEY_ID and NOTARY_ISSUER are set.
# Nothing is uploaded anywhere.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"/\1/p' "$ROOT/ios/App/project.yml" | head -1)}"
PROFILE="${2:-}"
OUT="${3:-$ROOT/build/release}"

if [ -z "$PROFILE" ]; then
  for dir in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" "$HOME/Library/MobileDevice/Provisioning Profiles"; do
    [ -d "$dir" ] || continue
    for p in "$dir"/*.provisionprofile; do
      [ -f "$p" ] || continue
      if [ "$(security cms -D -i "$p" 2>/dev/null | plutil -extract Name raw - 2>/dev/null)" = "PaloAlly Mac Developer ID" ]; then
        PROFILE="$p"
      fi
    done
  done
fi
[ -n "$PROFILE" ] || { echo "No Developer ID profile found; pass its path as the second argument." >&2; exit 1; }

IDENTITY="$(security find-identity -v -p codesigning | awk '/Developer ID Application/ { print $2; exit }')"
[ -n "$IDENTITY" ] || { echo "No 'Developer ID Application' identity in the keychain." >&2; exit 1; }

VERSION="$VERSION" PROFILE="$PROFILE" SIGN_IDENTITY="$IDENTITY" OUT="$OUT" \
  "$ROOT/scripts/release-mac.sh"
