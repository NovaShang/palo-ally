#!/usr/bin/env bash
# PaloAlly one-line installer:
#   curl -fsSL https://raw.githubusercontent.com/NovaShang/palo-ally/main/install.sh | bash
# or, from a checkout:  ./install.sh
# Installs bun if missing, installs the host's dependencies, links `paloally`
# into ~/.local/bin, then runs `paloally setup`.
set -euo pipefail

REPO_URL="${PALOALLY_REPO:-https://github.com/NovaShang/palo-ally.git}"
APP_DIR="${PALOALLY_APP_DIR:-$HOME/.paloally/app}"
BIN_DIR="$HOME/.local/bin"

say() { printf '\033[1;35m▸\033[0m %s\n' "$*"; }

# 1. runtime
if ! command -v bun >/dev/null 2>&1; then
  say "安装 bun 运行时…"
  curl -fsSL https://bun.sh/install | bash
  export BUN_INSTALL="$HOME/.bun"
  export PATH="$BUN_INSTALL/bin:$PATH"
fi
say "bun $(bun --version)"

# 2. source: use this checkout if we're inside one, else clone/update.
# Installs follow official releases: the newest v* tag (PALOALLY_REF picks
# another tag or a branch). After that the assistant updates itself to new
# releases (`paloally update` does it by hand).
latest_release() {
  git ls-remote --tags --refs "$REPO_URL" 'v*' 2>/dev/null | sed 's#.*refs/tags/##' \
    | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -t. -k1.2,1n -k2,2n -k3,3n | tail -1
}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/host/package.json" ]; then
  APP_DIR="$SCRIPT_DIR"
else
  command -v git >/dev/null 2>&1 || { echo "需要 git"; exit 1; }
  REF="${PALOALLY_REF:-$(latest_release)}"
  if [ -d "$APP_DIR/.git" ]; then
    say "更新 $APP_DIR${REF:+ 到 $REF}"
    if [ -n "$REF" ] && git ls-remote --exit-code --tags "$REPO_URL" "refs/tags/$REF" >/dev/null 2>&1; then
      git -C "$APP_DIR" fetch --depth 1 origin "refs/tags/$REF:refs/tags/$REF"
      git -C "$APP_DIR" checkout --detach "$REF"
    else
      git -C "$APP_DIR" fetch --depth 1 origin "${REF:-main}"
      git -C "$APP_DIR" checkout --detach FETCH_HEAD
    fi
  else
    say "下载到 $APP_DIR${REF:+（$REF）}"
    git clone --depth 1 ${REF:+--branch "$REF"} "$REPO_URL" "$APP_DIR"
  fi
fi

# 3. dependencies (the Agent SDK bundles Claude Code itself — no separate install needed)
say "安装依赖…"
(cd "$APP_DIR/host" && bun install --production)

# 4. link the CLI
mkdir -p "$BIN_DIR"
ln -sf "$APP_DIR/host/bin/paloally" "$BIN_DIR/paloally"
case ":$PATH:" in *":$BIN_DIR:"*) ;; *)
  say "把 $BIN_DIR 加进 PATH（写入 shell 配置）"
  for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
    [ -f "$rc" ] && ! grep -q 'paloally' "$rc" && printf '\n# paloally\nexport PATH="%s:$PATH"\n' "$BIN_DIR" >> "$rc"
  done
  export PATH="$BIN_DIR:$PATH"
esac

# 5. onboarding
say "开始初始化"
if [ -t 0 ]; then paloally setup; else paloally setup --yes </dev/null; fi
