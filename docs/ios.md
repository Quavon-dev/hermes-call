# iOS app (Hermes Call)

SwiftUI, iOS 26+, Swift 6 strict concurrency, warnings are errors. Two
dependencies only: **stasel/WebRTC** (unmodified Google libwebrtc builds —
Google ships no official iOS binaries; the LiveKit fork carries its own patches)
and **swift-sodium's Clibsodium** (libsodium, the same crypto the bridge uses;
CPace is compiled from `third_party/cpace`). No analytics, no crash reporting.

| Piece | Where |
|---|---|
| Protocol core (pairing, CPace, E2E, TLS pinning, relay session) | `ios/HermesCallKit` (Swift package, also builds on macOS) |
| App (CallKit, WebRTC, UI, Keychain) | `ios/HermesCall` |
| Project spec | `ios/project.yml` (XcodeGen) |

Features: onboarding, add relay by code or QR (the app always shows which
relay it is about to pair with, and asks before trusting a self-signed
certificate), several relay profiles (switch = swipe right in *Relays*),
**Call <agent>** through CallKit with a ringback tone (shows in the Phone app's
Recents unless disabled), hands-free and push-to-talk, mute, speaker, approval
requests (Face ID/passcode to approve, never voice; over-long commands are
denied, never shown cut off), paired device info, unpair, delete all data.

Settings:

- **Speech recognition**: *On bridge (Whisper)* (default) or *On iPhone*
  (Apple's on-device English model, downloaded once): the phone recognizes your
  words and sends only the text; call audio still reaches the bridge so you can
  interrupt the agent. Falls back to the bridge if it cannot start.
- **Appearance**: *Standard* or *HUD* (dark visor, audio-reactive core, live
  link gauges, voice waveform).
- **Assistant name** per relay (*Relays → relay → Assistant*); the default comes
  from the bridge (`--agent-name`, "Hermes").

**Incoming calls**: the agent rings the phone like a normal call, also when the
app is closed or the phone is locked.

1. The app registers its VoIP push token with every paired relay
   (`sandbox` for Xcode builds, `production` for TestFlight/App Store — read
   from the embedded provisioning profile).
2. The relay's push carries only a random call id. The app shows the CallKit
   ring **at once** (iOS requires it), then asks its bridge(s) over the E2E
   channel whether that ring is real (`invite_query`). Unknown, cancelled or
   unconfirmed (15 s) rings end immediately, so a relay cannot make the phone
   ring with a fake call.
3. The confirmed ring shows the bridge's name; the reason is shown in the app.
   Answer → the phone sends its WebRTC offer for that call id; Decline → the
   bridge learns it at once. Answered on another phone / timed out → the ring
   stops.
4. While the app is open and connected, the bridge's E2E `invite` rings
   directly, so incoming calls also work with a relay that sends no pushes
   (`--no-push-gateway`; then only while the app is in the foreground).

Pushes for the published app go through the Hermes Call [push gateway](push-gateway.md)
(`hermes-push.quavon.de`) unless the relay has its own APNs key; nobody needs an Apple developer
account to get incoming calls.

## App Store readiness (0.7)

- **Consent** (guideline 5.1.2(i)): right after the first agent (or the demo) is added, one screen says
  what is shared (voice, messages, files and camera pictures, phone data the owner allows), that it goes
  end-to-end encrypted to the owner's bridge, and that the owner's agent may pass it to a third-party AI
  service. Without it calls, chat sends, the outbox (also the share sheet's) and phone-context answers stay
  off (`SharedContainer.aiConsentKey`, versioned). Settings › Privacy › *Share with my agent* withdraws it.
- **Try a demo**: an offline agent (*Atlas*, `ios/HermesCall/Demo/`) for people without a relay and for App
  Review. Its profile exists only in memory (fresh keys each launch, relay `demo.invalid`), is never written
  to the Keychain or connected; its chat answers a few keywords (Markdown plan, place cards, help) and its
  calls are simulated by `PresenceDemo` (no CallKit, no audio). Labelled Demo everywhere; *Remove demo agent*
  deletes it and its chat. `hermescall://demo` (QR `ios/appstore/demo-qr.png`, for reviewers who look for a
  code) starts it from the pairing scanner, or from outside the app while no real agent is paired. Review
  notes and privacy answers: `ios/appstore/`; `beta-review-notes.txt` is written into TestFlight's Beta App
  Review notes by `tools/asc.py beta-add`.
- **Onboarding**: four pages (what agent, bridge and relay are; microphone and notification priming before
  iOS asks; pair or try the demo; setup guide link). `hermescall://pair?…` links opened on the phone open the
  pairing sheet, which still shows the relay and asks before pairing.
- **Pairing errors**: unreachable, TLS key mismatch, rate limited (relay HTTP 429), relay busy (503), wrong
  or expired code, invalid input (`PairingFailure`); a denied camera shows an explanation and Open Settings.
- **Approvals**: one panel for call and chat approvals; a cancelled Face ID keeps the request open (*Try
  again* / *Deny*) instead of denying it; without a passcode only *Deny* remains. When the request's
  `choices` list `session` (bridges with Hermes ≥ 0.15), a third button *Allow for this session* sends
  `choice: "session"`, also only after Face ID / passcode; older bridges keep *Approve once* / *Deny*.
  Screenshot: `-UITestReset YES -UITestConsent YES -ChatDemo YES -ChatDemoApproval YES`.
- **Chat history for a new phone** (`ChatHistorySync`, `ChatModel+History`): when a bridge lists
  `history` and this phone's chat with that agent is empty (a fresh pairing), the app asks once for
  the recent chat, page by page, downloads the attachments the bridge sends and stores only messages it
  does not have (`ChatStore.insertNew`); imported messages are not counted as unread. An import cut short
  (app quit, a page lost: 120 s per page) resumes at its cursor on the next connect. Agents paired before
  the first launch of a version with history sync are never filled in (their chat may be empty because
  the owner deleted it). Deleting a
  message stays local to this phone (the history is never asked again for that agent).
- **Call resume** (`CallReconnect`, `CallCoordinator+Reconnect`): with a bridge listing `call_resume`,
  a broken connection (also one found 2 s after a network change: not connected, or no audio arriving;
  a call that still works is left alone) shows *Reconnecting…* (Standard: under the name; HUD:
  RECONNECTING in the header) while CallKit's call stays up; the app replaces the call's relay connection,
  re-offers for the same call id with a new peer connection (an offer unanswered after 5 s is repeated
  after 1 s) and gives up after 20 s ("Connection lost. The call could not be resumed.").
  Older bridges end the call on a failed connection as before. Screenshot: `-PresenceDemo YES
  -PresenceDemoAuto YES -PresenceDemoReconnect YES` (both appearances).
- **Calls**: interruptions and route changes are followed (`CallAudioRoute`), *Speaker* shows the real
  route, the call screen has iOS' audio route picker and captions, CallKit shows a template icon, and push
  rings with several agents show "Atlas or Nova" until the bridge confirms which one rang.
- **Chat details**: code blocks scroll sideways with a fade and a chevron where more is hidden, or wrap
  (toggle), and copy; the owner's bubble is the agent's colour darkened until white text, the transcript and
  the waveform pass WCAG AA (`AgentPalette.ownerBubble`); search hits say *Today* / *Yesterday* and mark
  matches in file names and cards too (`SearchSnippet`); a jumped-to hit keeps its ring for 4 s or until you
  scroll. Every sheet and cover takes the active agent's colour (`agentTheme()`), not system blue.
- **Chats** (several agents): the chat tab lists every agent's conversation, newest first, with its colour,
  connection dot, last message and its own unread count; the badge is the sum (`UnreadCounts`, app group).
  Opening a chat makes that agent active. While the app is open every agent (up to five, the active one
  first) keeps its relay connection (`AppModel.standby`), so switching agents (also the presence swipe)
  tears nothing down and other agents' messages and rings arrive at once; in the background only pushes and
  borrowed connections remain. A notification tap opens the chat of the agent that wrote. With one agent the
  tab shows its chat directly. UI tests: `-UITestAgents YES` seeds two agents on `relay.invalid`.
- **Settings**: agents first (each with its own page), then calls, appearance, chat and tasks, privacy;
  **Diagnostics** shows network, push tokens and registrations per agent, relay connection and round trip
  (WebSocket ping), and exports the last hour of this app's log with tokens (also standard base64 with
  `+`/`/`), pairing codes, ids, addresses and e-mail addresses replaced.
- **Network**: an offline banner (*No internet connection* / *Can't reach your relay*); a returning or
  changed network reconnects at once (`RelaySession.reconnectNow`, also borrowed connections such as a
  ring of another agent) instead of after the backoff.
- **Relay protocol**: `auth` carries `v: 1` and the app's caps; the relay's `ready` (version, caps) is kept per
  agent and its version shown in Diagnostics (a bare `ready` = relay 0.6.2 or older, no caps). Requests that
  need a cap are not sent without it (`request(_:requires:)`); an `unsupported` answer fails only that request.
  A relay shutting down (WebSocket 1001) is reconnected after 0.5–2.5 s instead of the current backoff; 1001s
  in a row (without 30 s of connection between them) back off as usual. Blob
  transfers retry HTTP 503 (busy) on the same ticket with 1, 2, 4… s pauses (a download ticket works three
  times, then one more ticket), within the 300 s deadline. Calls pass every TURN URL on the relay's host to
  ICE, including `turns:<host>:5349?transport=tcp`. `too_many_devices` while pairing has its own message.
- **Bridge protocol**: after every relay connect the app sends an E2E `hello` (protocol version, app
  version, caps; `AppHello`); the bridge's answer (`BridgeInfo`: version, caps) is kept per agent and its
  version shown in Diagnostics ("0.6.2 or older" when a connected bridge does not answer). Optional
  features (call resume, history sync) are used only when the bridge lists their cap.
  E2E types nobody in the app handles are answered with `unsupported`; an unknown mailbox message is
  acked so it is not fetched forever. The share and notification extensions send no `hello`.
- **Presence**: paused under full-screen sheets and in the background; 30 fps in Low Power Mode, with Reduce
  Motion or a serious thermal state, 20 fps when critical; voice levels are read per frame instead of
  polling. HUD labels follow Dynamic Type (up to twice their size), hairlines get stronger with Increase
  Contrast, surfaces opaque with Reduce Transparency.
- **Stop** (emergency stop, `AgentStop`, docs/protocol.md "Stop"): a red **Stop** button next to the chat's
  call button while the agent types or a task of it runs, and always *Stop agent* in the call button's menu;
  in the HUD *Stop agent* in the long-press menu (idle and in a call), and a tap on the running tasks ring
  asks "Stop <agent>?". It sends `/stop` through the durable chat path (outbox when offline, consent like
  every send), with a light haptic; the chat shows "Stop requested", the presence "stop requested" for a
  few seconds. The demo agent drops its pending reply and a demo call ends. *Stop Agent*
  (`StopAgentIntent`, a `LiveActivityIntent` so it runs in the app's process without its UI) works from
  Siri ("Stop Hermes Call"), Shortcuts, the Action button and the *Stop Agent* Control Center control.
  UI test: `-DemoThinkingSeconds <s>` makes the demo agent type longer.
- **App Intents**: *Call Agent*, *Ask Agent*, *Open Chat*, *Stop Agent* take an agent ("Call Atlas with Hermes Call");
  Focus › Hermes Call chooses which agents may notify (notifications carry the agent id as
  `filterCriteria`).
- **Phone access**: *Add reminders* (`reminder_create`: `title`, `due?`, `notes?`) and *Add calendar events*
  (`calendar_create`: `title`, `start`, `end`, `location?`, `notes?`), No by default; with Ask the item is shown
  exactly before it is created; the answer's `data` is `{ok: true, id}`.
- Errors are typed (`AppError`) with a recovery action (Open Settings, Review consent, Relays).

UI tests (`HermesCallUITests`, part of the scheme's tests) run on the demo agent: onboarding → demo →
consent → chat → call → hang up, the presence tap-to-call, Settings and Diagnostics. Debug launch arguments:
`-UITestReset YES` (fresh install state), `-UITestConsent YES`, `-appearance hud|standard`.
App Store screenshots (6.9", iPhone 17 Pro Max simulator), each with a one-line caption above the screen on
the app's near-black backdrop (drawn by the test at 1320 × 2868): presence, call, chat, a place card with its
map, and a phone-access *Ask* prompt (`-PhoneDemoPrompt YES`):

```bash
cd ios && TEST_RUNNER_APPSTORE_SHOTS=$PWD/appstore/screenshots xcodebuild test -project HermesCall.xcodeproj \
  -scheme HermesCall -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:HermesCallUITests/AppStoreScreenshots CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=
```

## Build and run on your iPhone (Xcode)

1. Generate the project (only needed after changing `project.yml`):

   ```bash
   cd ios && xcodegen generate
   ```

2. Open it:

   ```bash
   open ios/HermesCall.xcodeproj
   ```

3. Xcode → *Settings → Accounts*: sign in with the Apple ID of **Quavon UG
   (CFV35FGSHF)**. The project uses that team and `de.quavon.hermescall` with automatic
   signing (`ios/Config/Identity.xcconfig`); Xcode creates the App IDs and capabilities on the
   first device build. Not in the Quavon team? See [Build your own copy](#build-your-own-copy).
4. Connect the iPhone by cable, trust the Mac, and enable
   *Settings → Privacy & Security → Developer Mode* on the phone (restart).
5. Select your iPhone as run destination and press **Run** (⌘R).
6. On the bridge: `hermes-call-bridge device add --name "iPhone"`; in the app:
   *Add your relay* → scan the QR or type relay address + code.

Command-line alternative (same signing):

```bash
cd ios && xcodebuild -project HermesCall.xcodeproj -scheme HermesCall -destination 'generic/platform=iOS' -allowProvisioningUpdates build
```

## Build your own copy

The project's Apple identity lives in `ios/Config/Identity.xcconfig`: Quavon UG (`CFV35FGSHF`),
`de.quavon.hermescall`, `group.de.quavon.hermescall`. To build under your own developer account, copy
`ios/Config/Identity.local.xcconfig.example` to `ios/Config/Identity.local.xcconfig` (git-ignored)
and set:

| Setting | Example | Used for |
|---|---|---|
| `HC_TEAM` | `ABCDE12345` | signing (your team ID, Membership page of the developer account) |
| `HC_BUNDLE_ID` | `com.example.hermescall` | the app; extensions and the watch app append `.notifications`, `.share`, `.widget`, `.watchkitapp`, … |
| `HC_APP_GROUP` | `group.com.example.hermescall` | data shared with the extensions and the watch complication |

Then `cd ios && xcodegen generate` and build with `-allowProvisioningUpdates` (or Run in Xcode).
Automatic signing registers the App IDs with the capabilities the project asks for: Push
Notifications, App Groups, Keychain Sharing, HealthKit, HomeKit, Communication Notifications and
Time Sensitive notifications. The [push gateway](push-gateway.md) can only push to the published
app, so give your relay your own team's APNs key and bundle ID (`install.sh --apns-key …
--bundle-id … --team-id …`, see below); otherwise incoming calls reach your build only while it is
open.
The Metal shaders need Xcode's Metal toolchain: `xcodebuild -downloadComponent MetalToolchain`.

CarPlay needs an entitlement from Apple (see [CarPlay](#carplay)); everything else works with a
standard (paid) developer account.

## TestFlight (optional, for installing without the cable)

1. App Store Connect → *Apps* → **+** → New App: iOS, name "Hermes Call",
   bundle ID `de.quavon.hermescall` (your own `HC_BUNDLE_ID` for your own copy), SKU e.g.
   `hermescall`.
2. Xcode → *Product → Archive* (destination "Any iOS Device") → *Distribute
   App* → *App Store Connect* → Upload.
3. Export compliance question: the app uses standard encryption (TLS,
   libsodium) for its own communication; answer according to your
   distribution (for internal TestFlight testing the standard exemption for
   standard algorithms usually applies — check Apple's current guidance).
4. App Store Connect → TestFlight → add yourself as internal tester → install
   the TestFlight app on the iPhone.

TestFlight/App Store builds receive **production** VoIP pushes; builds run from
Xcode receive **sandbox** pushes. The app tells the relay which one; the relay
and the push gateway support both.

## Automatic releases

`.github/workflows/ios-release.yml` runs on every push to `main` that changes the app (`ios/`,
not its tests or docs), or by hand (*Actions → iOS release → Run workflow*). Same model as
Quavon's jackpoll:

1. **Version**: `MARKETING_VERSION` in `ios/project.yml`, or, once Apple has approved that
   version, the next minor one (0.6.0 → 0.7.0), because an approved version takes no more builds.
   Raise `MARKETING_VERSION` by hand for 1.0.0. **Build number**: the highest one App Store Connect
   has for that version + 1, so manual and CI uploads share one sequence (`tools/asc.py`).
2. **ios** (macOS): archive, upload, signed build provenance (`gh attestation verify
   HermesCall-….ipa --repo Quavon-dev/hermes-call`), GitHub release `ios-v<version>-<build>` with
   the IPA (never "latest": relay releases `v*` are).
3. **beta** (Linux, waits for Apple's processing): TestFlight group `Internal` (skipped if it gets
   every build anyway); with the repository variable `ASC_EXTERNAL_BETA=true` also the group
   `Beta` and Beta App Review ("What to test" = the app's commit subjects). Apple reviews one
   build per version at a time; later builds wait in the group.
4. **app-store** (Linux), with the repository variable `ASC_APP_STORE=true`: the build is attached
   to the open App Store version and submitted for App Review, released automatically after
   approval. While a version is with Apple (waiting, in review, approved) this skips; the next push
   after that goes out as the next version. "What's New" comes from
   `ios/appstore/notes/<version>/<locale>.txt`.

Both review switches stay off until Apple's reviewers can test the app (review demo) and the store
listing exists; internal testing works from the first build.

Export compliance is answered in the project (`ITSAppUsesNonExemptEncryption = NO`, Quavon UG's
decision: standard encryption, treated as exempt), so no build waits for the question. The IPA in
the GitHub release is signed for App Store distribution and installs only through TestFlight or
the App Store.

One-time setup (repository *Settings → Secrets and variables → Actions*):

| Secret | What |
|---|---|
| `ASC_KEY_ID`, `ASC_ISSUER_ID` | App Store Connect → *Users and Access → Integrations → App Store Connect API* → **+**, role **Admin** (needed for cloud-managed distribution signing); Key ID and Issuer ID from that page |
| `ASC_KEY_P8` | the downloaded `AuthKey_XXXXXXXXXX.p8`, base64: `base64 -i AuthKey_XXXXXXXXXX.p8 \| pbcopy` |
| `BUILD_CERT_P12` | an **Apple Development** certificate with its private key for team `CFV35FGSHF`: Keychain Access → *My Certificates* → right-click → Export → `.p12` with a password; then `base64 -i cert.p12 \| pbcopy` |
| `BUILD_CERT_PASSWORD` | the `.p12` password |

The job runs in the `app-store` environment: add required reviewers there if every upload should
wait for approval. Distribution signing happens in Apple's cloud during export, so no
distribution certificate leaves Apple. Once in App Store Connect: create the TestFlight groups
`Internal` and `Beta`, fill in *TestFlight → Test Information* (Beta App Review) and the App
Store listing (description, screenshots, privacy policy, App Privacy, age rating, review notes
with the demo pairing) — without them the external and App Store channels only warn.



For the published app this key belongs on the [push gateway](push-gateway.md#running-the-gateway-publisher)
(Quavon, team `CFV35FGSHF`); relays then need no key. For your own build of the app it goes on
your relay.

1. <https://developer.apple.com/account> → *Certificates, Identifiers &
   Profiles* → **Keys** → **+**.
2. Name "Hermes Call relay", tick **Apple Push Notifications service (APNs)**,
   *Configure* → environment **Sandbox & Production**, key restriction **Team
   Scoped (All Topics)** → Save → Continue → Register.
3. **Download** the `AuthKey_XXXXXXXXXX.p8` — Apple lets you download it
   only once. Note the **Key ID** (10 characters) shown on the page. Team ID:
   `CFV35FGSHF` for the published app, otherwise your `HC_TEAM`.
4. Published app: install the push gateway with it (see [push gateway](push-gateway.md#running-the-gateway-publisher)).
   Your own build: give it to your relay (never to the app or the bridge):

   ```bash
   /opt/hermescall-relay/relay/install.sh install --apns-key /root/AuthKey_XXXXXXXXXX.p8 --apns-key-id XXXXXXXXXX --team-id <HC_TEAM> --bundle-id <HC_BUNDLE_ID>
   ```

   The relay stores it as `/etc/hermescall-relay/apns_key` (0600,
   `hermescall-relay` user). Delete your other copies or keep one offline.

## Try it locally (Simulator or phone on the same Wi-Fi)

`tools/dev_stack.py` runs a relay (self-signed TLS), a bridge with real
Whisper/Kokoro and a fake Hermes that repeats your question (or your real
Hermes with `--hermes-url/--hermes-key`). Needs Docker for Kokoro and coturn;
the exact commands are in the script's header. Then paste the printed
`hermescall://` link into the app's address field (or scan the QR).

Simulator limitations (verified): the Simulator's CallKit never activates the
audio session (a Simulator-only workaround starts audio), and its microphone
delivers silence here, so speech can only be tested on a real iPhone. The
Simulator also has no in-call screen: CallKit logs "there wont be a UI to host
the call" and ends every call (outgoing or incoming) right after it starts, and
the app correctly follows CallKit. It never receives VoIP pushes either
(`xcrun simctl push` goes to user notifications, not PushKit). With a local,
uncommitted patch that ignores that system end, both directions were verified
in the Simulator (pairing, ring → answer → offer for the ring's call id,
relay-only WebRTC, reason shown, hang-up); ringing, answering and audio need a
real iPhone.

## Tests

```bash
cd ios/HermesCallKit && swift test
```

```bash
cd ios && xcodebuild test -project HermesCall.xcodeproj -scheme HermesCall -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=
```

`swift test` starts the real Python relay and bridge (needs `uv sync` at the
repo root) and pairs, authenticates and exchanges E2E messages with them.

## M9 additions

### App icons

The icons are Icon Composer documents (`.icon`: `icon.json` + SVG layers), so iOS 26/27 render
them with Liquid Glass and generate the dark, clear and tinted looks themselves.
`tools/make_icons.py` builds them from code (original artwork, no external assets):
`ios/HermesCall/Resources/AppIcon.icon` (Standard: glass handset in an orbit on amber),
`AppIconPresence.icon` (the gold orrery with a glass heart) and the watch icon, plus the
Settings tile previews. `python3 tools/make_icons.py --preview` also renders every appearance
with Xcode's `ictool` (design generation 27) into `/tmp/icon-previews`.

Settings › App icon: *Standard*, *Presence* or *Match appearance*; iOS confirms each switch.
The alternate `.icon` works on iOS 27; the iOS 26.2 simulator answers "Resource temporarily
unavailable" (the app retries and re-applies at launch).

Settings › *<agent>'s colour* sets the active agent's colour (also per relay in Relays). The HUD
uses it for the presence; the Standard appearance uses its deeper tone as the tint.

### Audio and the voice spectrum

Every call now runs WebRTC audio through `EngineAudioDevice` (AVAudioEngine with
voice processing). Its playout and microphone paths feed `SpectrumAnalyzer`
(HermesCallCore: 1024-point FFT at 48 kHz, 8 log bands 80 Hz–8 kHz), which the
presence reads every frame. Fallback to WebRTC's own audio unit for one launch:
launch argument `-legacyAudioDevice YES` (then the bands are shaped from the level
as before). Voice replies in the chat play through an engine too, so the presence
speaks them.

### Live Activity

`HermesTaskAttributes` (ios/Shared) + `TaskLiveActivity` (widget extension). While the
app runs it starts/updates the activity itself, with the agent's id, name and colour in the
attributes (a push-to-start carries `{}`, then the widget shows the active agent); it registers the activity push token
(`register_push kind: liveactivity`) and the push-to-start token (`liveactivity_start`)
with every relay. Debug: `-TaskDemo YES` plays a fake five-step task.

### Place reminders

`PlaceMonitor` (CLMonitor, max 20 regions). Needs "Always" location for reminders
while the app is closed; asked when the first reminder is added. Settings › Phone
access › Place reminders lists them (swipe to delete).

### Chat history, share sheet and notifications

- **History** lives in one SQLite database in the app group (`Chats/chat.sqlite`, system SQLite, WAL,
  iOS data protection "until first unlock" like the attachments next to it; "Delete all data" removes
  the folder). Every operation opens a short connection and writes in `BEGIN IMMEDIATE`
  transactions, so the app and the extensions can write at the same time and no process holds a
  lock while suspended. The JSON files of older versions are moved in once (call entries from
  "Outgoing call · 2:31" text into structured entries). There is no message limit any more.
- The chat screen loads the newest 50 messages and older pages while scrolling up; **search**
  (magnifier) queries the database (text, transcripts, file names, card titles; case and accents
  ignored) and jumps to a hit; long-press → **Delete on This iPhone**. Agent messages render
  headings, lists (nested, numbered, task lists), code blocks, quotes, tables and rules. The
  composer takes up to 4 photos or files at once and photos from the camera; voice notes show a
  waveform, can be scrubbed and played at 1×/1.5×/2×; a denied microphone offers Settings.
- **Live activity in the chat**: while the agent works, a card at the end of the chat shows the
  current tool (`task` messages: label, step, elapsed time, a progress bar when the total is known)
  and its argument preview, commands with a `$` prompt in a terminal look; tap it for the turn's
  earlier steps. Live drafts stream in as an agent bubble with a caret, the typing dots bounce, and the
  title says what happens ("Running a command…", "writing…"). The chat follows along only while it is
  scrolled to the end. New messages spring in from their side; Reduce Motion turns the motion off.
  Messages of one sender within three minutes are grouped (joined corners, one time stamp); an arrow
  button returns to the newest message; an empty chat offers starter questions.
- **Commands**: typing `/` lists Hermes' gateway commands (`/new`, `/retry`, `/undo`, `/compress`,
  `/usage`, `/model`, `/help`, `/stop`); a tap sends it (`/model` waits for an argument). New session,
  retry and undo are also in the composer's **+** menu, new session and retry in the call button's
  menu. Commands that change the session come back as an approval (Face ID).
- **Outbox**: owner messages not yet confirmed by the bridge (also those the share sheet wrote).
  A sender *claims* a message in the database while sending it, so the app and the share
  extension never send the same one twice.
- **Share sheet**: the relay keeps one connection per device and drops the older one, so the
  extension must not connect while the app has a connection (for example during a call). It
  stores the message in the outbox and pings the app (Darwin notification); a running app answers
  within a second and sends it itself. Darwin notifications are visible to every app, so the answer
  counts only if the app also wrote it into the app group for the extension's random nonce: a pong
  posted by another app is ignored. Only without an answer (app suspended or not running) does
  the extension connect, holding the claim. It defaults to the agent active in the app and names
  items it leaves out (more than 4 files, over 10 MB).
- **Notifications**: agent messages are communication notifications (`INSendMessageIntent`: the
  agent's name and presence as the sender, so Focus can let them through; needs the
  communication-notifications entitlement and `NSUserActivityTypes`), count on the app badge, and
  show a photo when message text is shown and the app is not running (the extension then fetches
  the blob itself; the relay copy stays for the app). Phone-context "Ask" notifications have
  **Answer…** (opens the app at the question) and **Deny** (answers without opening).
- **Widget**: pick the agent in the widget's settings (default: the active one); the Call and chat
  buttons run their intent in the app. The widget's `hermescall://chat?agent=<id>` and
  `…/call?agent=<id>` links carry a per-install secret from the app group (`s=`), so a tap calls at
  once and switches to that agent. The same links from any other app or web page cannot: a call link
  shows "Call <agent>?" first (the agent becomes active only after **Call**), and a chat link opens the
  active agent's chat. The app writes agent names and colours (no keys) to the app group for this.
- Debug builds: `-ChatDemo YES` seeds a demo agent and history for screenshots
  (`-ChatDemoQuery <text>`, `-ChatDemoPlay YES`, `-ChatDemoReveal <text>`). `-TaskDemo YES` runs a
  five-step task with command previews; the on-device demo agent streams its replies as drafts.

### Apple Watch

Targets `HermesCallWatch` (`<HC_BUNDLE_ID>.watchkitapp`) and
`HermesCallWatchWidget` (complications). There is no WebRTC for watchOS, so the
watch is a remote: tap the presence to start the call **on the iPhone** (audio on the
iPhone or AirPods), dictate a message or record a voice note, read the latest messages. It holds
no keys; everything goes through WatchConnectivity to the iPhone (`WatchBridge`). Message
text reaches the watch only when "Show message text in notifications" is on.

- Messages and denials wait in WatchConnectivity's queue (`transferUserInfo`) while the iPhone is
  out of reach; voice notes travel as file transfers. Every request has an id, so one that arrives
  live and queued runs once.
- A pending approval shows on the watch with **Deny** only: approving needs Face ID or the passcode
  on the iPhone, which the watch cannot give.
- The iPhone updates the watch whenever the chat history changes (also in the background), and on
  approvals and call state; the watch taps the wrist when a call rings, starts and ends.

### CarPlay

- Without anything extra: CallKit shows incoming and active Hermes calls in the car,
  and Siri ("Call Hermes", the App Intent) works there.
- A CarPlay app ("Call Atlas" + latest messages read aloud) is in
  `ios/HermesCall/CarPlay/CarPlaySceneDelegate.swift`, compiled only with the
  `CARPLAY_APP` condition, because it needs a CarPlay entitlement from Apple
  (request it at developer.apple.com/carplay; pick the communication or
  voice-based conversational category the form offers). Once granted:
  1. add the granted entitlement key to `project.yml` (app entitlements),
  2. add `CARPLAY_APP` to `SWIFT_ACTIVE_COMPILATION_CONDITIONS`,
  3. add to the app's Info.plist:
     ```yaml
     UIApplicationSceneManifest:
       UIApplicationSupportsMultipleScenes: true
       UISceneConfigurations:
         CPTemplateApplicationSceneSessionRoleApplication:
           - UISceneConfigurationName: CarPlay
             UISceneDelegateClassName: $(PRODUCT_MODULE_NAME).CarPlaySceneDelegate
     ```
  Check it in Xcode › Open Developer Tool › Simulator › I/O › External Displays › CarPlay.
