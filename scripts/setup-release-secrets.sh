#!/usr/bin/env bash
# Upload the Mac release signing secrets to GitHub (run it yourself, on the Mac
# that holds the Developer ID certificate).
#
#   scripts/setup-release-secrets.sh <notary-key.p8> <notary-key-id> <notary-issuer-id> [profile] [--repo owner/name] [--yes]
#
#   notary-key.p8     an App Store Connect API key used ONLY for notarization
#                     (App Store Connect → Users and Access → Integrations →
#                     App Store Connect API → Team Keys → +, access: Developer)
#   notary-key-id     that key's Key ID
#   notary-issuer-id  the Issuer ID shown above the key list
#   profile           the "PaloAlly Mac Developer ID" .provisionprofile
#                     (default: the installed one with that name)
#
# It exports just the "Developer ID Application" identity from your login
# keychain into a temporary .p12 with a random password (macOS asks you to
# allow the export), then sets these repo secrets with `gh secret set`:
#   MAC_DEVID_P12_BASE64, MAC_DEVID_P12_PASSWORD, MAC_DEVID_PROFILE_BASE64,
#   ASC_NOTARY_KEY_ID, ASC_NOTARY_ISSUER_ID, ASC_NOTARY_KEY_P8_BASE64
# Values go through files and stdin only; nothing is printed. Temp files are
# deleted on exit.
set -euo pipefail

usage() { sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
REPO=""
YES=""
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --yes) YES=1; shift ;;
    -h|--help) usage ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
[ ${#ARGS[@]} -ge 3 ] || usage
P8="${ARGS[0]}"; KEY_ID="${ARGS[1]}"; ISSUER="${ARGS[2]}"; PROFILE="${ARGS[3]:-}"

command -v gh >/dev/null || { echo "需要 GitHub CLI (gh)，并已 gh auth login" >&2; exit 1; }
[ -f "$P8" ] || { echo "找不到 $P8" >&2; exit 1; }
[ -n "$REPO" ] || REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"

if [ -z "$PROFILE" ]; then
  for dir in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" "$HOME/Library/MobileDevice/Provisioning Profiles"; do
    [ -d "$dir" ] || continue
    for p in "$dir"/*.provisionprofile; do
      [ -f "$p" ] || continue
      [ "$(security cms -D -i "$p" 2>/dev/null | plutil -extract Name raw - 2>/dev/null)" = "PaloAlly Mac Developer ID" ] && PROFILE="$p"
    done
  done
fi
[ -n "$PROFILE" ] && [ -f "$PROFILE" ] || { echo "找不到 Developer ID 描述文件，把路径作为第 4 个参数传进来" >&2; exit 1; }

TMP="$(mktemp -d)"
chmod 700 "$TMP"
trap 'rm -rf "$TMP"' EXIT

# Export exactly one identity (not the whole keychain) with the Security framework.
cat >"$TMP/export.swift" <<'SWIFT'
import Foundation
import Security

let out = CommandLine.arguments[1]
let pass = ProcessInfo.processInfo.environment["P12_PASS"] ?? ""
let query: [String: Any] = [kSecClass as String: kSecClassIdentity,
                            kSecMatchLimit as String: kSecMatchLimitAll,
                            kSecReturnRef as String: true]
var result: CFTypeRef?
guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let identities = result as? [SecIdentity] else { fputs("no identities in the keychain\n", stderr); exit(1) }
var best: (SecIdentity, Date)?
for identity in identities {
  var cert: SecCertificate?
  guard SecIdentityCopyCertificate(identity, &cert) == errSecSuccess, let cert,
        let name = SecCertificateCopySubjectSummary(cert) as String?,
        name.hasPrefix("Developer ID Application") else { continue }
  let values = SecCertificateCopyValues(cert, [kSecOIDX509V1ValidityNotAfter] as CFArray, nil) as? [String: Any]
  let entry = values?[kSecOIDX509V1ValidityNotAfter as String] as? [String: Any]
  let notAfter = (entry?[kSecPropertyKeyValue as String] as? NSNumber).map { Date(timeIntervalSinceReferenceDate: $0.doubleValue) } ?? .distantPast
  if best == nil || notAfter > best!.1 { best = (identity, notAfter) }
}
guard let identity = best?.0 else { fputs("no 'Developer ID Application' identity in the keychain\n", stderr); exit(1) }
var params = SecItemImportExportKeyParameters()
params.version = UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION)
params.passphrase = Unmanaged.passRetained(pass as AnyObject)
var data: CFData?
let status = SecItemExport(identity, .formatPKCS12, [], &params, &data)
guard status == errSecSuccess, let data else { fputs("export failed: \(status)\n", stderr); exit(1) }
try (data as Data).write(to: URL(fileURLWithPath: out))
SWIFT

P12_PASS="$(openssl rand -base64 30 | tr -d '\n')"
echo "▸ 导出 Developer ID 证书（系统会弹窗请你允许导出）…"
P12_PASS="$P12_PASS" xcrun swift "$TMP/export.swift" "$TMP/devid.p12"

echo "▸ 即将在 $REPO 上设置 6 个 secret："
echo "  MAC_DEVID_P12_BASE64, MAC_DEVID_P12_PASSWORD, MAC_DEVID_PROFILE_BASE64,"
echo "  ASC_NOTARY_KEY_ID, ASC_NOTARY_ISSUER_ID, ASC_NOTARY_KEY_P8_BASE64"
if [ -z "$YES" ]; then
  printf "继续？[y/N] "
  read -r yes || yes=""
  [ "$yes" = "y" ] || [ "$yes" = "Y" ] || { echo "已取消，什么都没上传（不能交互时加 --yes）。"; exit 1; }
fi

base64 -i "$TMP/devid.p12" | gh secret set MAC_DEVID_P12_BASE64 --repo "$REPO"
printf '%s' "$P12_PASS" | gh secret set MAC_DEVID_P12_PASSWORD --repo "$REPO"
base64 -i "$PROFILE" | gh secret set MAC_DEVID_PROFILE_BASE64 --repo "$REPO"
base64 -i "$P8" | gh secret set ASC_NOTARY_KEY_P8_BASE64 --repo "$REPO"
printf '%s' "$KEY_ID" | gh secret set ASC_NOTARY_KEY_ID --repo "$REPO"
printf '%s' "$ISSUER" | gh secret set ASC_NOTARY_ISSUER_ID --repo "$REPO"
echo "✓ 好了。打 tag（git tag v0.1.0 && git push origin v0.1.0）就会自动出 Mac 版。"
