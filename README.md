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

The iPhone / Mac app isn't on the App Store yet. Build it from `ios/` with your own Apple developer team (set `DEVELOPMENT_TEAM` and a bundle ID you own); see [`ios/README.md`](ios/README.md).

Host and app talk through a relay, end-to-end encrypted. By default that is the shared public bento relay at `relay.bentoai.dev`; it needs no account. Voice input in the app is transcribed through the same relay, with per-install and global limits; heavy use may be throttled. You can run your own relay from [bento](https://github.com/NovaShang/bento)'s `relay/`.

## Everyday use

```sh
paloally chat                 # talk in the terminal (/tasks /approvals /y id /n id /stop)
paloally status | tasks | approvals | watch | artifacts | memory | audit
paloally stop                 # stop what it's doing (the harness' interrupt)
paloally restart              # restart once it's idle (--now to force)
paloally doctor               # health check
```

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

## License

MIT. See [`LICENSE`](LICENSE).
