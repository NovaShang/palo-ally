# PaloAlly · Apple client

This is the native client for iOS and Mac Catalyst. It talks to the desktop host over the bento relay, end-to-end encrypted, using the wire protocol in `docs/design.md` §5.

```
ios/
  PaloAllyKit/                Swift package (iOS 26 / macOS 26): no UI
    Sources/PaloAllyKit/
      Models/                 §5.3 models (tolerant decoding), RPC params/results, JSONValue
      Crypto/                 device Ed25519 identity + Keychain store, SSH-wire pubkey,
                              base64url, E2E handshake + ChaCha20-Poly1305 channel (§5.2)
      Relay/                  pairing link parser, POST /v1/pair, RelayTransport (WSS tunnel,
                              handshake, keepalive, reconnect with backoff)
      Transport/              HostTransport protocol + InMemoryTransport
      RPC/                    RPCClient: numeric ids, pending continuations, timeouts, FIFO outbox
      Store/                  AppStore (@Observable): state, events, sync/gap handling, optimistic chat
      Demo/                   DemoHost: an in-memory host for demo mode, previews and tests
    Tests/PaloAllyKitTests/   Swift Testing suites (+ Fixtures/e2e-vectors.json from the host)
  App/                        SwiftUI app (xcodegen project.yml → PaloAlly.xcodeproj)
    Sources/App               entry point, AppModel (unpaired / paired / demo), push, RootView
    Sources/Chat              main chat, markdown, composer + dictation, approval cards
    Sources/Library           artifact library + preview (markdown / offline WKWebView / QuickLook)
    Sources/Assistant         assistant page: 任务 / 审批 / 定时 / 记忆, kill switch
    Sources/Settings          quiet hours, proactive limit, pairing management
    Sources/Pairing           QR scan (VisionKit) / paste link / manual code
  screenshots/                demo-mode screenshots from the simulator
```

## Build and test

```sh
# Package tests (macOS host)
cd ios/PaloAllyKit && swift test

# App (regenerate the project after adding or removing files)
cd ios/App && xcodegen generate
xcodebuild -project ios/App/PaloAlly.xcodeproj -scheme PaloAlly \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project ios/App/PaloAlly.xcodeproj -scheme PaloAlly \
  -destination 'platform=macOS,variant=Mac Catalyst' CODE_SIGNING_ALLOWED=NO build
```

### Live test against a real host

`LiveHostTests` is opt-in. It pairs, connects through the real relay, syncs, chats, and reconnects:

```sh
# relay: cd ~/code/bento/relay && npx wrangler dev --port 8789
# host:  any host with relay.url = http://127.0.0.1:8789, then `paloally pair`
PALOALLY_LIVE_LINK='paloally://pair?...'   swift test --filter LiveHost   # or a path to a file holding the link
```

Each pairing code works only once, so every run needs a fresh link.

## Demo mode and screenshots

Launch arguments (also read from UserDefaults):

| arg | effect |
|---|---|
| `-demo YES` | use the in-memory `DemoHost` (seeded Chinese sample data, streamed replies) |
| `-demoScreen chat\|library\|artifact\|assistant\|settings\|pairing` | open that screen |
| `-demoTab tasks\|approvals\|watches\|memory` | open the assistant page on that tab |

```sh
xcrun simctl install booted <DerivedData>/Build/Products/Debug-iphonesimulator/PaloAlly.app
xcrun simctl launch booted com.novashang.paloally -demo YES -demoTab approvals
xcrun simctl io booted screenshot ios/screenshots/x.png
```

SwiftUI previews use `AppModel.demo()`. On first launch an unpaired app also offers 「先看看演示」.

## Protocol notes (how the client reads §5)

- **Tunnel.** `GET wss://<relay>/v1/tunnel?daemon_id&device_id&ts&pubkey&sig`. The signature covers `bento-device-attach:<daemon>:<device>:<ts>`, and `pubkey`/`sig` are base64url without padding. Each WebSocket binary message carries exactly one unit, with no extra framing on the phone's side of the relay.
- **Handshake.** The `hello`/`welcome` fields `eph` and `sig` are standard base64. The client accepts both padded and unpadded input, and base64url too. A `0x01 {"t":"error"}` unit appears as `DisconnectReason.rejected`, and the UI then asks the user to pair again.
- **Counters.** The send and receive counters start at 0 for every new tunnel or handshake and advance only on `0x02` units. If a unit fails to decrypt, the tunnel is closed and the client reconnects.
- **Reconnect.** Backoff runs 0.5 s, 1 s, 2 s, … up to 30 s, with ±20 % jitter. `reconnectNow()` runs when the app comes back to the foreground. A WebSocket ping goes out every 20 s, and a ping with no reply in 10 s drops the link.
- **After each (re)connect:** `hello{client:"ios"|"mac"}` → `sync{sinceSeq:lastSeq}`. The very first `sync` sends no `sinceSeq`. Then `push.register` if a token exists.
- **Sync result.** `seq` is read as the host's latest seq. If a `sync{sinceSeq}` page returns 500 messages, the client asks again from the highest seq it received, and keeps going until it holds `seq`. A `sync` with no `sinceSeq` replaces the message list, but keeps any echoes that were not sent yet. The `tasks`, `approvals`, `watches` and `artifacts` lists in a sync replace the stored ones wholesale.
- **Gaps.** `lastSeq` is the highest seq the client holds with nothing missing before it. A `chat.message` whose seq is more than `lastSeq + 1` is shown right away and triggers `sync{sinceSeq:lastSeq}`. Requests made while a sync is already running are merged into one extra round.
- **Echo.** `chat.send{text, clientMsgId}` puts an echo on screen immediately. That echo is merged with the server's copy in one of three ways:
  - by `clientMsgId`, if the broadcast `chat.message` includes it;
  - otherwise by matching the oldest pending app echo with the same text;
  - otherwise by the `{id}` in the response.

  In every case only one copy stays.
- **Streaming.** A `chat.delta{id,text}` appends `text` to the message with that id, creating it if needed (seq 0, still streaming). The `chat.message` with the same id replaces the text and finishes the message. Deltas that arrive after that are ignored.
- **Event payloads.** `settings.updated` and `status` are accepted either as the bare object or wrapped as `{settings}` / `{status}`. `artifact.updated` is accepted bare or wrapped as `{artifact}`. `watch.updated` is accepted as `{watch}`, `{removed}`, or a bare watch.
- **Approvals.** The client sends `remember:true` only when the user allows the action and `irreversible == false`; otherwise the field is left out. If an approval arrives without `irreversible`, the client treats it as irreversible.
