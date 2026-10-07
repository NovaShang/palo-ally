#!/usr/bin/env bash
# Upload the iOS (TestFlight) signing secrets to GitHub. Run it yourself.
#
#   scripts/setup-ios-release-secrets.sh [--p12 file] [--password-file file] [--profile file] [--repo owner/name] [--yes]
#
# Defaults: the Apple Distribution identity and App Store profile created for
# PaloAlly through the App Store Connect API, kept with the other signing files:
#   ~/Documents/个人项目/开发者证书/PaloAlly-AppleDistribution.p12
#   ~/Documents/个人项目/开发者证书/PaloAlly-AppleDistribution.p12.password
#   ~/Documents/个人项目/开发者证书/PaloAlly_App_Store.mobileprovision
# Sets IOS_DIST_P12_BASE64, IOS_DIST_P12_PASSWORD, IOS_PROFILE_BASE64. The
# upload reuses the ASC_NOTARY_* secrets that setup-release-secrets.sh set.
# Values go through files and stdin only; nothing is printed.
set -euo pipefail

DIR="$HOME/Documents/个人项目/开发者证书"
P12="$DIR/PaloAlly-AppleDistribution.p12"
PASSFILE="$DIR/PaloAlly-AppleDistribution.p12.password"
PROFILE="$DIR/PaloAlly_App_Store.mobileprovision"
REPO=""
YES=""
while [ $# -gt 0 ]; do
  case "$1" in
    --p12) P12="$2"; shift 2 ;;
    --password-file) PASSFILE="$2"; shift 2 ;;
    --profile) PROFILE="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --yes) YES=1; shift ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "不认识的参数：$1" >&2; exit 1 ;;
  esac
done

command -v gh >/dev/null || { echo "需要 GitHub CLI (gh)，并已 gh auth login" >&2; exit 1; }
for f in "$P12" "$PASSFILE" "$PROFILE"; do [ -f "$f" ] || { echo "找不到 $f" >&2; exit 1; }; done
[ -n "$REPO" ] || REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"

# Check the pieces belong together before uploading anything.
/usr/bin/openssl pkcs12 -in "$P12" -passin "file:$PASSFILE" -nokeys >/dev/null 2>&1 ||
  { echo "p12 打不开：密码文件不对？" >&2; exit 1; }
NAME="$(security cms -D -i "$PROFILE" 2>/dev/null | plutil -extract Name raw - 2>/dev/null || true)"
echo "▸ 描述文件：${NAME:-?}"

echo "▸ 即将在 $REPO 上设置 3 个 secret：IOS_DIST_P12_BASE64, IOS_DIST_P12_PASSWORD, IOS_PROFILE_BASE64"
if [ -z "$YES" ]; then
  printf "继续？[y/N] "
  read -r yes || yes=""
  [ "$yes" = "y" ] || [ "$yes" = "Y" ] || { echo "已取消，什么都没上传（不能交互时加 --yes）。"; exit 1; }
fi

base64 -i "$P12" | gh secret set IOS_DIST_P12_BASE64 --repo "$REPO"
gh secret set IOS_DIST_P12_PASSWORD --repo "$REPO" <"$PASSFILE"
base64 -i "$PROFILE" | gh secret set IOS_PROFILE_BASE64 --repo "$REPO"
echo "✓ 好了。下次打 v* tag，iOS 版会自动上传到 TestFlight。"
