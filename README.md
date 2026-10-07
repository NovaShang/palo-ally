# PaloAlly

PaloAlly turns the coding agent you already run (V1: Claude Code) into an always-on personal assistant: it stays running on your machine, finds you on your phone or WeChat when something matters, and remembers you. Your data and models stay on your own machine.

- Product: [`docs/paloally-prd-v2.md`](docs/paloally-prd-v2.md)
- Implementation design and wire protocol: [`docs/design.md`](docs/design.md)

## Pieces

| Directory | What it is |
|---|---|
| `host/` | The desktop host: one CLI program (Bun + TypeScript). It is both the daemon and the onboarding. |
| `ios/` | The Apple client: SwiftUI for iOS, reused on Mac via Mac Catalyst. See [`ios/README.md`](ios/README.md). |
| relay | Not in this repo. It reuses the [bento](https://github.com/NovaShang/bento) relay (`relay/` there, deployed at `relay.bentoai.dev`) unchanged. |

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/NovaShang/palo-ally/main/install.sh | bash   # or ./install.sh from a checkout
paloally service install
paloally pair           # scan the QR code with the app
paloally wechat login   # optional
```

The installer installs Bun if it's missing, puts the code in `~/.paloally/app`, links `paloally` into `~/.local/bin`, and runs `paloally setup`. You need your own Claude access: a claude.ai login in Claude Code, or an API key.

`paloally setup` handles first-run setup. It creates the home directory, writes the config, checks the model connection, and can configure a third-party Anthropic-compatible model (GLM / Kimi / DeepSeek, …) through `ANTHROPIC_BASE_URL` and `ANTHROPIC_AUTH_TOKEN`. If you are logged in to Claude Code with a claude.ai subscription, or have `ANTHROPIC_API_KEY` set, that works with no extra configuration.

### The app and the relay

**Mac app:** download [PaloAlly.dmg](https://github.com/NovaShang/palo-ally/releases/latest/download/PaloAlly.dmg) from the latest release (macOS 26 or later; signed with Developer ID and notarized). The iPhone app isn't on the App Store yet. Build it from `ios/` with your own Apple developer team (set `DEVELOPMENT_TEAM` and a bundle ID you own); see [`ios/README.md`](ios/README.md).

Host and app talk through a relay, end-to-end encrypted. By default that is the shared public bento relay at `relay.bentoai.dev`; it needs no account. Voice input in the app is transcribed through the same relay, with per-install and global limits; heavy use may be throttled. You can run your own relay from [bento](https://github.com/NovaShang/bento)'s `relay/`.

## Everyday use

```sh
paloally chat                 # talk in the terminal (/tasks /approvals /y id /n id /stop)
paloally status | tasks | approvals | watch | artifacts | memory | audit
paloally stop                 # stop what it's doing (the harness' interrupt)
paloally restart              # restart once it's idle (--now to force)
paloally update               # update to the latest release now (--check to just look)
paloally doctor               # health check
```

### Updates

The host follows official releases (`v*` tags) by itself. Every few hours it looks for a newer one, downloads it next to the running code, installs its dependencies and smoke-runs it. It switches over only at a clean break: no turn running, nothing handed off or waiting on you, and you quiet for a few minutes. Then the service restarts it. If the new version can't start, the next start rolls back to the previous one and says why in the conversation. A line in the conversation says when it has updated. `paloally status` shows the version and when it last checked.

This applies to installs made by the installer (`~/.paloally/app`). A dev checkout or a copy is managed by hand; set `"update": { "auto": true }` in `~/.paloally/config.json` to opt in, or `false` to turn it off. Installs from before this feature need one manual update first: `git -C ~/.paloally/app pull && paloally restart`, or run the installer again.

## Where things live (`~/.paloally`)

```
home/            the assistant's working directory: CLAUDE.md, user.md, soul.md, artifacts/
state/           chat log, tasks, approvals, watches, usage, metrics
audit/           daily JSONL audit log
identity.json    host Ed25519 key + remote ID
config.json      config (models, budgets, quiet hours, relay / WeChat / APNs / browser)
```

## Tests

```sh
cd host && bun test                      # unit + integration; relay tests need the local relay below
cd host && bun run fixtures              # regenerate the protocol/crypto fixtures the iOS tests decode (commit them)
(cd bento/relay && npx wrangler dev --port 8789)          # the real relay, run locally from a checkout of github.com/NovaShang/bento
PALOALLY_LIVE=1 bun test test/live.test.ts               # against the real Claude Code harness (uses tokens)
cd ios/PaloAllyKit && swift test
```

## Releasing

Pushing a tag `vX.Y.Z` runs [`.github/workflows/release-mac.yml`](.github/workflows/release-mac.yml). It archives the Mac app, signs it with Developer ID, notarizes and staples it, wraps it in a DMG, and attaches `PaloAlly.dmg`, `PaloAlly-X.Y.Z.dmg` and `SHA256SUMS` to the GitHub Release. You can also start it by hand (Actions → Release Mac app → Run workflow).

```sh
git tag v0.1.0 && git push origin v0.1.0
```

The steps live in [`scripts/release-mac.sh`](scripts/release-mac.sh); `scripts/release-mac-local.sh` runs the same thing on your Mac as a dry run. The workflow needs these repo secrets, which `scripts/setup-release-secrets.sh` sets for you:

| Secret | What |
|---|---|
| `MAC_DEVID_P12_BASE64`, `MAC_DEVID_P12_PASSWORD` | the Developer ID Application certificate and key |
| `MAC_DEVID_PROFILE_BASE64` | the Mac Catalyst Developer ID provisioning profile |
| `ASC_NOTARY_KEY_ID`, `ASC_NOTARY_ISSUER_ID`, `ASC_NOTARY_KEY_P8_BASE64` | an App Store Connect API key used only for notarization |

## License

MIT. See [`LICENSE`](LICENSE).
