# hermes-call-bridge (runs inside the Hermes container, LXC 121)

The bridge connects **out** to your relay, answers and places calls, and runs
the voice pipeline next to Hermes:

```
phone ⇄ (DTLS-SRTP via TURN) ⇄ aiortc → Silero VAD → faster-whisper → Hermes API (stream)
                                  ↑                                      ↓ sentences
                         barge-in / push-to-talk             Kokoro TTS (clause-first) → aiortc → phone
```

- **Speech recognition** runs on the bridge (faster-whisper) by default. If
  the phone is set to *On iPhone*, it sends finished utterances as text
  (`transcript`) and the bridge skips Whisper; the audio is then used only to
  notice when you interrupt the agent.
- **No inbound ports.** Media uses TURN *relay* candidates only (enforced in
  code), so the phone never learns your home IP and nothing connects in. The
  control API listens on `127.0.0.1:8765` and needs a bearer token.
- **Hermes stays in charge.** The bridge talks to the official Hermes API
  server (`/v1/chat/completions`, streaming) with `X-Hermes-Session-Id:
  hermes-call-phone-<phone>-<date>`: one Hermes session per phone and day (a new one
  also after 200 turns), so sessions do not grow forever; the recent chat and the last
  call's transcript carry over between calls and chat (kept in the state directory, so
  also across restarts). Tool approvals are **never granted by voice**: the exact
  command is shown on the phone (Approve once / Approve for this session / Deny); no
  answer within 60 s = deny.
- **If Hermes or Kokoro fails mid-call** the agent says "Sorry, I couldn't reach
  <agent> just now." (or, if speech synthesis itself is down, two short tones), never
  silence; the log says which one failed and how (HTTP status or error class).
- **No audio stored, no transcripts logged.** Audio lives only in memory for
  the current utterance. Logs contain timings and 6-character ids only. (Hermes
  itself keeps the conversation text in its session store, as with any chat.)

## Install (as root in LXC 121)

Explained before you run it:

- `pct push` copies the repository archive from the Proxmox host into the container.
- `install.sh` runs as root inside the container. It:
  - installs `python3-venv`, `libsodium23` and `qrencode`
  - creates the unprivileged user `hermes-call-bridge`
  - installs hash-pinned Python packages into `/opt/hermes-call-bridge/venv`
  - downloads the Whisper model at a pinned revision
  - writes `/etc/hermes-call-bridge` (secrets 0600) and a sandboxed systemd unit
- `--configure-hermes` appends `API_SERVER_ENABLED=true`, `API_SERVER_HOST=127.0.0.1`
  and a random `API_SERVER_KEY` to `~hermes/.hermes/.env` (after a backup; the
  file stays mode 600). It does not touch anything else in Hermes.

```bash
pct exec 121 -- bash -c "curl -fsSL https://raw.githubusercontent.com/Quavon-dev/hermes-call/main/bridge/get.sh | bash"
```

`bridge/get.sh` downloads the latest release, checks its signature against the pinned release key
before anything runs, finds the Hermes user (the one who called `sudo`, or the only user with a
`~/.hermes`; else set `HERMES_USER=`) and runs `bridge/install.sh install --configure-hermes`.
Inside the container, or on any other Hermes host: `curl -fsSL …/bridge/get.sh | sudo bash`.
Settings go in front of `bash`, e.g. `| sudo AGENT_NAME=Atlas STT_MODEL=small.en bash`.

Update later the same way (keeps keys, pairings, voice, model and agent name, and refreshes the
Hermes plugin; restart Hermes and its gateway afterwards when the plugin changed).

Restart Hermes so its API server starts (as the `hermes` user, the way you
normally run `hermes gateway`), then pair with the relay using the link that
`hermescall-relay pair` printed on the relay:

```bash
pct exec 121 -- bash -c "systemctl stop hermes-call-bridge; hermes-call-bridge relay add 'hermescall://pair?v=1&k=relay&r=relay.example.com&c=...' && systemctl start hermes-call-bridge"
```

Pair a phone (the app shows a code field and a QR scanner):

```bash
pct exec 121 -- hermes-call-bridge device add --name iPhone
```

Other commands:

```bash
pct exec 121 -- hermes-call-bridge doctor
pct exec 121 -- hermes-call-bridge device list
pct exec 121 -- hermes-call-bridge device revoke <device-id>
pct exec 121 -- hermes-call-bridge call --first-message "Hello, this is Hermes." --reason "test"
pct exec 121 -- hermes-call-bridge status
pct exec 121 -- journalctl -u hermes-call-bridge -f
```

`--agent-name NAME` sets the name your phone shows for the agent (default
"Hermes", e.g. `--agent-name Atlas`); you can also rename it per relay in the
app (*Relays → relay → Assistant*).

`base.en` is the default (≈0.45 s per utterance on 2 cores). `--stt-model small.en` is more
accurate but ≈1.7 s per utterance on 2 cores — too slow for the 2.5 s target on LXC 121.

## Test client (M2): call the agent without the app

`testclient/` is a command-line stand-in for the iPhone: it pairs like the
app, then talks through your Mac's microphone and speakers (**use headphones** —
it has no echo cancellation) or plays a WAV and records the reply.

```bash
uv sync && uv run hermescall-testclient pair relay.example.com ABC-DE123
```

```bash
uv run hermescall-testclient call
```

```bash
uv run hermescall-testclient listen
```

`listen` waits for the agent to ring (`hermes-call-bridge call` or the Hermes
`call_owner` tool).

## Hermes plugin: the agent calls you (`call_owner`)

`install.sh install --configure-hermes` also:

- copies `hermes-integration/hermes-call` to `~hermes/.hermes/plugins/hermes-call`
  (owned by the Hermes user),
- writes `HERMES_CALL_TOKEN=<ring-only token>` into `~hermes/.hermes/.env`
  (file stays 0600). That token (`/etc/hermes-call-bridge/call_token`) can only
  `POST /v1/calls`; pairing, revoking and status need the admin `api_token`,
  which Hermes never gets,
- runs `hermes plugins enable hermes-call` as the Hermes user (plugins are
  opt-in in Hermes; if the `hermes` command is not found, run it yourself).

Restart Hermes afterwards. The agent then has one tool:

`call_owner(reason, first_message, device="all")` — rings your phone(s) and
waits up to 45 s. If you answer, the bridge speaks `first_message` and the
conversation continues on the call (that phone's call session, which
is told the `reason`). If the owner stops the agent while a tool waits, the tool returns at
once (`interrupted`). The plugin needs Hermes ≥ 0.15 (`min_hermes`); on startup it checks the
Hermes internals it uses and disables only what is missing (with a warning in Hermes' log).
The tool returns `answered`, `declined`, `no_answer`,
`busy`, `no_devices` or `rate_limited` (at most 3 rings per 10 minutes and
20 per day, whoever asks). The plugin only talks to `127.0.0.1` (a non-loopback
`HERMES_CALL_URL` is refused); the relay limits rings to 10 per minute.

Ask your agent to call you, e.g. "call me when the backup is done", or test it
without Hermes:

```bash
pct exec 121 -- hermes-call-bridge call --first-message "Hello, this is Hermes." --reason "test"
``` `--wav question.wav --record reply.wav` prints the measured
end-of-speech → first-audio latency.

## Local API (127.0.0.1:8765, `Authorization: Bearer $(cat /etc/hermes-call-bridge/api_token)`)

| Method | Path | Body / result |
|---|---|---|
| POST | `/v1/calls` | `{"first_message", "reason", "device": "all"\|id}` → `{"status": "answered"\|"declined"\|"no_answer"\|"busy"\|"no_devices"\|"rate_limited", "call_id"}` (waits up to 45 s) |
| GET | `/v1/devices` | paired devices |
| POST | `/v1/devices/pairing` | `{"name"}` → one-time code + link |
| DELETE | `/v1/devices/{id}` | revoke (bridge + relay) |
| GET | `/v1/status` | relay connection, device count, call state |
| GET | `/v1/chat/events?cursor=&wait=&epoch=&files=1` | chat adapter long-poll → `{cursor, events, epoch}` (Hermes token); `epoch` names the bridge's event store, a cursor with another epoch acks nothing; with `files=1` attachments carry `file_id` and `size` instead of base64 `data` (older adapters get `data`) |
| GET | `/v1/chat/files/{file_id}` | the bytes of an owner attachment (Hermes token), until the adapter's cursor passed its event and the message left the history; 404 after |
| POST | `/v1/chat/messages` | `{text, reply_to?, answers?}` → `{message_id, queued}` (`queued`: the relay has not taken it yet; it is retried) |
| GET | `/healthz` | **no token**: `{ok, relay, hermes, kokoro}`, 503 when something is down |
| GET | `/metrics` | **no token**: Prometheus text — call latency (end of speech → first audio), STT real-time factor, turn errors by cause, calls, relay connection, chat event/inbox/outbox depth. Counts and timings only |

`hermes-call-bridge doctor` checks the config, secrets, relay pairing and reachability,
Hermes and Kokoro (`/health`), the speech model, free disk space and whether the service
answers `/healthz`; it exits 1 when a check failed.

## Reliability

- **Chat never loses a message on a restart.** An owner message is stored (SQLite,
  `/var/lib/hermes-call-bridge/chat.db`, 0600) before the phone sees *delivered*, and stays
  there until the Hermes adapter took it. Agent messages wait (end-to-end encrypted) in an
  outbox until the relay's mailbox took them: retried with backoff and after every relay
  reconnect for up to 7 days; if one is given up, the adapter logs it. Owner message text sits
  in that file only until Hermes has it (Hermes keeps the conversation in its own session store).
- **Attachments are spooled on disk, not held in memory**: an owner attachment is streamed from the
  relay into `/var/lib/hermes-call-bridge/files/` (0700, files 0600) still sealed with its blob key,
  and the key is kept in chat.db; the Hermes adapter fetches it with `GET /v1/chat/files/<id>`. An
  agent file is sealed once. Both go to the other phones as the same sealed bytes (one relay upload
  per phone, as the relay keeps blobs per recipient), so other phones see the photo itself instead of
  a `[photo: name]` line. A file is deleted once Hermes has its event and the message left the
  history (below); at most one attachment (≤ 10 MiB) is in memory at a time.
- **Replay protection** marks are appended to a small log per message and compacted in the
  background (no file rewrite per message).
- **Calls survive a network change** (phones that list `call_resume`): when the phone moves from
  Wi-Fi to cellular it offers a new connection for the same call; the bridge swaps the WebRTC
  connection and keeps the conversation (session, transcript, what the agent was saying). Without a
  new offer within 20 s the call ends and the phone shows "Connection lost".
- **Revoking a phone works offline**: it is forgotten locally at once and the relay is told when
  it is reachable again.
- **Stopping** (`systemctl stop`, SIGTERM) hangs up an active call, gives queued chat messages a
  last try and saves the replay marks. The unit uses systemd's watchdog (`WatchdogSec=60`).
- **Live-call speech recognition goes first**: a long voice note is transcribed in pieces behind
  any live utterance.
- Hermes' tool approvals that cannot be delivered are retried and otherwise denied, so a Hermes
  run never waits on a lost answer.

## Settings (`/etc/hermes-call-bridge/bridge.toml`, all optional)

```toml
[calls]
ring_timeout = 45        # seconds
approval_timeout = 60
max_call_seconds = 3600  # "We have about a minute left on this call." warning_seconds before
warning_seconds = 60
media_timeout = 20       # a call whose audio never arrives ends
[voice]
end_silence_ms = 550     # silence that ends your utterance (200–3000)
[turn]
transport = "auto"       # TURN transport the bridge uses: auto/udp, tcp or tls (turns:)
[log]
level = "INFO"
format = "text"          # or "json" (one object per line)
```

The bridge gets all TURN URLs from the relay and uses the preferred one (aiortc uses one TURN
server per call; the phone uses all of them). Set `transport = "tcp"` or `"tls"` when the bridge's
network blocks outbound UDP. Restart the service after changing the file.

## Several agents on one host

Each agent gets its own bridge with its own relay pairing, phones and port:

```bash
/root/hermes-call/bridge/install.sh install --instance atlas --api-port 8766 --hermes-port 8643 \
  --hermes-user atlas --agent-name Atlas --configure-hermes
hermes-call-bridge-atlas relay add '<pairing link>' && systemctl start hermes-call-bridge@atlas
```

It uses `/etc/hermes-call-bridge-atlas`, `/var/lib/hermes-call-bridge-atlas`, the unit
`hermes-call-bridge@atlas` and the wrapper `hermes-call-bridge-atlas`, and sets
`HERMES_CALL_URL` for that Hermes user. The default bridge is unchanged. One Hermes user per
bridge. `install.sh uninstall --instance atlas [--purge]` removes only that one.

## Resources

| Component | RAM (measured) |
|---|---|
| bridge incl. Whisper small.en int8 | see M2 report |
| Kokoro-FastAPI (existing) | ~1.5–2 GB |
| Hermes (existing) | ~0.5 GB+ |

With 6 GB for LXC 121 there is comfortable headroom.

## Phone context and result cards (M7)

The plugin adds two tools next to `call_owner` (same ring/chat token):

- `phone_context(capability, reason, params)` — the agent asks the owner's iPhone for
  location, battery, device status, calendar, reminders, a contact by name, motion/steps,
  Focus, now playing, a health summary, Home accessories, clipboard text, or photos/files the
  owner picks. The phone decides by its rules (Settings › Phone access, **No / Ask / Yes**,
  everything No by default); the tool waits up to ~2 minutes and returns
  `ok` / `denied` / `unavailable` / `timeout` / `rate_limited` / `busy` / `no_devices`.
  Picked photos and files are written to a private temp directory
  (`hermes-call-*`, mode 0700) and returned as paths — images can be analyzed with
  `vision_analyze`.
- `present_to_owner(title, kind, text, items)` — structured results (places, links, lists)
  that unfold as cards from the presence in the app and stay in the chat. The bridge
  fetches `image_url`s itself (public https hosts only) and re-encodes them; the phone never
  contacts third parties.

**Web search is Hermes' job.** For "find restaurants nearby" the agent gets the location
with `phone_context`, searches with Hermes' own web tools and shows the result with
`present_to_owner`. Hermes' web tools support Firecrawl, also self-hosted: set
`FIRECRAWL_API_URL=http://<your-firecrawl>:3002` (and `FIRECRAWL_API_KEY` if your instance
needs one) in Hermes' `.env` yourself — the bridge installer never changes it.

Limitation: iOS gives an app data only while it runs. With the app suspended a query shows a
notification ("Atlas asks for: Location") and succeeds once you open the app within the
time limit; during a call or with the app open, *Yes* rules answer at once.
