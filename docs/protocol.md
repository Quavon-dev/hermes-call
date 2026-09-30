# Wire protocol v1

All relay traffic is JSON text frames over WebSocket-over-TLS (max 64 KiB).
Binary fields are unpadded base64url. Every message has a type field `t`.
Requests may carry `rid` (string or int); the relay echoes it in its reply.

Reference implementations: `common/hermescall_common/` (Python). The iOS app
must match these byte-for-byte; `common/tests/` hold the interoperability tests.

## Identities

| Party | Keys | Registered at relay |
|---|---|---|
| Bridge | Ed25519 (relay auth), X25519 (E2E) | Ed25519 public key → `bridge_id` |
| Device | Ed25519 (relay auth), X25519 (E2E) | Ed25519 public key → `device_id` (authorized by its bridge) |

IDs are 16 random bytes, base64url (22 chars), assigned by the relay.
The relay never learns X25519 keys.

## Pairing codes

`slot` (3 chars) + `secret` (5 chars typed, 26 chars in QR), Crockford base32
`0123456789ABCDEFGHJKMNPQRSTVWXYZ`. Input is normalized (upper-case; `O→0`,
`I/L→1`; `-` and spaces removed). Only the slot is sent to the relay; the secret
is the CPace password. Codes: single use, 10 min, 3 attempts; 10 failures from
one IP (IPv6: /64) lock it out for 15 min.

QR / link: `hermescall://pair?v=1&k=<relay|device>&r=<host[:port]>&c=<slot+secret>[&pin=<spki>]`
`pin` = base64url(SHA-256(DER SubjectPublicKeyInfo)) of the relay TLS key
(self-signed relays only).

## CPace handshake (`GET /v1/pair`)

CPace = jedisct1/cpace (ristretto255, SHA-512), vendored in `third_party/cpace`.

- identities: relay pairing `id_a="bridge"`, `id_b="relay"`; device pairing `id_a="device"`, `id_b="bridge"`
- associated data: `hermescall/v1/<kind>-pair|<authority>|<pin>` where authority is
  `host` or `host:port` (port omitted when 443) and pin is empty for WebPKI relays.
  A client using a self-signed relay puts the pin **it observed** in the AD, so a
  TLS man-in-the-middle makes the key exchange fail.
- confirmation: `XChaCha20-Poly1305-IETF(key, json, ad)`, output `nonce(24) || ciphertext`;
  initiator uses `client_sk` with AD `hermescall/v1/pair/initiator`,
  responder uses `server_sk` with AD `hermescall/v1/pair/responder`.

### Bridge ↔ relay (relay is responder)

```
bridge → relay  {"t":"join","slot":S,"msg":cpace_step1(48 bytes)}
relay  → bridge {"t":"cpace","msg":cpace_response(32 bytes)}
bridge → relay  {"t":"confirm","data":seal_initiator({"sign_pk":ed25519_pk})}
relay  → bridge {"t":"paired","data":seal_responder({"bridge_id":…, "authority":…})}
```

### Device ↔ bridge (relay only forwards; bridge is responder)

```
bridge → relay  {"t":"open_slot"}                         → {"t":"slot_opened","slot":S,"ttl":600}
device → relay  {"t":"join","slot":S,"msg":step1}         relay → bridge {"t":"pair_join","slot":S,"conn":C,"msg":step1}
bridge → relay  {"t":"pair_msg","conn":C,"data":response} relay → device {"t":"pair_msg","data":response}
device → relay  {"t":"pair_msg","data":seal_initiator({"sign_pk":…,"box_pk":…,"name":…})}
                                                          relay → bridge {"t":"pair_msg","conn":C,"data":…}
bridge → relay  {"t":"pair_done","conn":C,"ok":true,"sign_pk":device_ed25519}
relay  → bridge {"t":"pair_registered","conn":C,"device_id":D}
bridge → relay  {"t":"pair_final","conn":C,"data":seal_responder({"device_id":D,"bridge_box_pk":…,…})}
relay  → device {"t":"pair_final","device_id":D,"data":…}
```

`pair_done` with `"ok":false` rejects the attempt (counts as a failure). The
relay registers the device **only** under the bridge that owns the slot.
Payload fields beyond `sign_pk` are defined by the bridge/app (M2/M3).

## Authenticated session (`GET /v1/ws`)

```
relay  → client {"t":"challenge","nonce":32 bytes,"v":1[,"time":ms since epoch]}
client → relay  {"t":"auth","role":"bridge"|"device","id":ID,"sig":Ed25519(msg)[,"v":N,"caps":[…]]}
relay  → client {"t":"ready","v":1,"relay":"0.6.2","caps":["unsupported","mail","blobs","live_activity","turns"]}
msg = "hermescall/v1/auth" | authority | role | id | nonce     (joined with "|")
```

The optional `time` lets a client notice clock skew early: the bridge logs a warning when its
clock is more than 30 s off the relay's (E2E live messages fail beyond ±120 s). Relays do not
send it yet; without `time` nothing changes.

A new session for the same identity closes the old one. Revoked identities are
disconnected within 15 s. On shutdown the relay closes sessions with WebSocket code 1001
(going away); clients reconnect with their usual backoff.

### Versions and capabilities

`v` and `caps` in `auth` are optional (clients up to 0.6.2 send neither): `v` is the client's
protocol version, `caps` up to 32 names (`[a-z0-9_]{1,32}`) of features it supports. The relay
records them, ignores names it does not know and never requires them; they are not covered by the
signature and grant nothing. `ready` carries the relay's protocol version, its software version
(`relay`) and its own caps. Older relays send a bare `{"t":"ready"}`: a client treats missing caps
as "none of the optional features".

Relay caps: `unsupported` (unknown request types are answered, see below), `mail`, `blobs`,
`live_activity`, `turns` (the TURN reply may contain `turns:` URLs).

A request type the relay does not know is answered with
`{"t":"error","code":"unsupported","type":<t>[,"rid":…]}` (`type` only when it matches
`[a-z0-9_]{1,32}`) and the session stays open. Relays up to 0.6.2 closed the connection instead
(`protocol_error`), so a client should send new request types only when the relay listed the
matching cap.

### Bridge requests

| `t` | Fields | Reply |
|---|---|---|
| `open_slot` / `close_slot` | `slot` | `slot_opened` / `slot_closed` (max 5 open), or `error: too_many_slots/too_many_devices` (20 devices per bridge by default) |
| `list_devices` | – | `devices: [{device_id, push, online, created}]` |
| `revoke_device` | `device_id` | `revoked` |
| `e2e` | `to`, `data` (≤ 48 KiB) | none, or `error: offline/unknown_device` |
| `ring` | `call_id` (16 bytes), `devices`: `"all"` or `[ids]` | `rang: {call_id, pushed:[ids]}` (10/min) |
| `turn` | – | `turn: {urls, username, credential, ttl}`; `urls` holds `turn:` (UDP and TCP) and, when the relay offers TURN over TLS, `turns:host:5349?transport=tcp`; `ttl` is 5400 s by default (longer than the longest call) |
| `live_update` | `to` (device id), `event`: `start`/`update`/`end`, `content_state` (see "Live Activity push") | `live_updated`, or `error: no_token/unknown_device/rate_limited/invalid_content_state/push_disabled/push_failed` |

### Device requests

| `t` | Fields | Reply |
|---|---|---|
| `register_push` | `token` (hex), `env`: `sandbox`/`production`, `kind`: `voip` (default) / `alert` / `liveactivity` / `liveactivity_start` | `push_registered {kind}` |
| `e2e` | `data` | none, or `error: offline` |
| `turn` | – | `turn` |

Relay → bridge events: `presence {device_id, online}`, `e2e {from, data}`.
Relay → device events: `e2e {data}`.

## VoIP push

Sent by the relay directly (own APNs key) or through the [push gateway](push-gateway.md), which
takes the same fields and builds the identical APNs request.

`POST /3/device/<token>` to `api.push.apple.com` or `api.sandbox.push.apple.com`,
`apns-push-type: voip`, topic `<bundle>.voip`, priority 10, expiry 30 s.
Payload is always exactly `{"c":"<call_id>"}` — no names, no text.

## Live Activity push (M9)

Task progress for a phone that is offline (the app cannot update its Live Activity itself).
`register_push kind: "liveactivity"` stores the running activity's push token
(`activity.pushTokenUpdates`), `kind: "liveactivity_start"` the push-to-start token
(`Activity<HermesTaskAttributes>.pushToStartTokenUpdates`, iOS 17.2+); one of each per device.

`live_update` → `POST /3/device/<token>`, `apns-push-type: liveactivity`, topic
`<bundle>.push-type.liveactivity`, `apns-priority` 10 for `start`/`end` and 5 for `update`:

```json
{"aps": {"timestamp": 1790000000, "event": "update",
         "content-state": {"step": 2, "total": null, "label": "Working…", "state": "running", "startedAt": 1789999950.5}}}
```

- `start` uses the push-to-start token and adds `"attributes-type": "HermesTaskAttributes"`,
  `"attributes": {}`, `"alert": {"title": "Working…", "body": ""}`.
- `end` adds `"dismissal-date": now + 900`.
- `update`/`end` use the activity token. APNs 410 or `BadDeviceToken` drops that token (`error: no_token`).

The relay accepts exactly these `content_state` keys (the payload is **plaintext to Apple**):
`step` (int 0–999), `total` (int 0–999 or null), `label` (string ≤ 60), `state`
(`running`/`done`/`failed`), `startedAt` (unix seconds). Per device the relay allows one `update` per 3 s, one `start` per 30 s
and 20 per hour, and 30 `end` per hour (`error: rate_limited`). The bridge sends `start` on a turn's first tool (if it
sent nothing to that phone for the turn yet, and the phone did not see the turn live, else
`update`), `update` at most every 5 s, and `end` on done/failed. Only a new turn at most every 2 s and 30 per
hour may push at all; more turns are shown in the app only. The label is the generic
`Working…` unless the phone's `task_prefs.details` is on; tool arguments never go into a push.

## E2E call signaling (inside relay `e2e.data`)

`data` = base64url(`nonce(24) || crypto_box_easy(json, recipient_x25519, sender_x25519_sk)`).
Every plaintext carries `"from"`, `"to"` (relay ids) and `"ts"` (ms since epoch,
strictly increasing per sender, ±120 s of the receiver's clock); receivers
reject anything else, so the relay cannot reflect, redirect or replay.

The **device always sends the SDP offer** (non-trickle: wait for ICE gathering
to finish), with `iceTransportPolicy = relay` and only the relay's TURN server.

| Direction | `type` | Fields | Meaning |
|---|---|---|---|
| device → bridge | `offer` | `call_id`, `sdp`, optional `stt: "device"` | start a call (new `call_id`) or answer a ring (its `call_id`); `stt: "device"` = the phone transcribes on-device |
| device → bridge | `transcript` | `call_id`, `text` (≤ 2000), optional `stt_ms` | one finished utterance (only with `stt: "device"`); the bridge then uses call audio only for barge-in |
| device → bridge | `invite_query` | `call_id` | after a VoIP push `{"c": call_id}`: is this ring real? (sent to every paired bridge; the push does not say which one rang) |
| device → bridge | `decline` | `call_id` | user declined the ring |
| device → bridge | `hangup` | `call_id` | end the call |
| device → bridge | `ptt` | `call_id`, `down` (bool) | push-to-talk: switches the bridge from VAD endpointing to PTT |
| device → bridge | `interrupt` | `call_id` | the owner tapped to cut the agent off: the bridge stops the current speech at once (like barge-in: output flushed, rest of the turn cancelled) and listens again; idempotent, no-op when the agent is not speaking; only from the device in the call |
| device → bridge | `unpair` | – | the user removed this relay profile in the app: bridge revokes the device |
| device → bridge | `approval` | `call_id`, `request_id`, `choice`: `once`\|`session`\|`deny` | answer to `approval_request`; `session` = allow this command for the rest of the Hermes session (Hermes ≥ 0.15; only when the request's `choices` lists it); anything else counts as `deny` |
| device → bridge | `call_image` | `call_id`, `blob_id`, `key`, `mime`: `image/jpeg`\|`image/png`\|`image/heic` | "look at this": a still for the agent, uploaded as an encrypted blob (see Chat); only from the device in the call, at most 1 per second and 30 per call (extras are rejected; beyond 40 `call_image` messages per minute per device they are ignored
without an ack); the bridge downloads and deletes it, re-encodes it (JPEG ≤ 1280 px, no metadata) and sends it with the owner's **next** utterance as an `image_url` data-URL part (at most the newest 3 wait) |
| bridge → device | `invite` | `call_id`, `reason` | ringing; also the positive answer to `invite_query` |
| bridge → device | `cancel` | `call_id`, `why` | ring over (`timeout`, `answered_elsewhere`, `unknown_call` → end CallKit call at once) |
| bridge → device | `answer` | `call_id`, `sdp` | call accepted |
| bridge → device | `busy` | `call_id` | another call is active |
| bridge → device | `hangup` | `call_id` | bridge ended the call |
| bridge → device | `caption` | `call_id`, `role`: `agent`\|`owner`, `text` (≤ 500, trimmed) | live caption, best-effort: an agent sentence when its audio starts playing; an owner utterance transcribed by the bridge (never with `stt: "device"`) |
| bridge → device | `approval_request` | `call_id`, `request_id`, `command`, `description`, `choices` (e.g. `["once","session","deny"]`; absent from older bridges = once/deny) | Hermes wants to run a gated command; show it, never approve by voice |
| bridge → device | `call_image_ack` | `call_id` (`""` if the message's was invalid), `blob_id`, `ok` (bool) | `ok: true` once the image was downloaded and queued for the agent; `false` when it was rejected (not in this call, rate limit, unsupported or unreadable image). HEIC needs a HEIF-capable Pillow on the bridge; send JPEG |

`call_id` = 16 random bytes, base64url; the app uses the same 16 bytes as the
CallKit call UUID, so a push and an `invite` for one ring are one call.
The device reports every VoIP push to CallKit before it knows whether the ring
is real, and ends it at once when no bridge confirms it within 15 s. Pairing payloads: device → bridge
`{"sign_pk","box_pk","name"}`; bridge → device `{"device_id","bridge_id",
"bridge_sign_pk","bridge_box_pk","bridge_name","relay":{"host","port","pin"}}`.

## Chat (M6)

### Mailbox (relay)

Chat messages to phones go through a per-device ciphertext mailbox (500 messages,
20 MiB, 7 days per device by default, configurable on the relay; duplicates by id are ignored,
also when the mailbox is full). `mailbox_full` is also returned when the relay's total storage
budget or free-disk floor is reached.

| From | `t` | Fields | Reply |
|---|---|---|---|
| bridge | `mail` | `to`, `id` (16 bytes = the E2E `mid`), `data` (≤ 48 KiB), `alert` (bool) | `mailed {id}` or `error: mailbox_full/unknown_device/rate_limited` |
| device | `mail_fetch` | – | pending mail as `mail {id, data}` frames, then `mail_done {more}` |
| device | `mail_ack` | `ids` (≤ 100) | `mail_acked` (deleted) |

An online device also gets `mail {id, data}` at once. With `alert: true` the relay
sends an APNs **alert** push (topic = bundle id, never VoIP) when the mail is not
acked within 3 s: `{"aps":{"alert":{"title":"New message","body":"Open Hermes Call to read it."},"mutable-content":1,...},"e":<data>}`
(`e` only when ≤ 3600 chars). The Notification Service Extension decrypts `e` on the phone.
`register_push` takes `kind: "voip"|"alert"` (default `voip`).

### Encrypted attachments (relay)

`blob_put {size, to?}` → `blob_ticket {blob_id, token, ttl: 300}`; then
`PUT /v1/blobs/<blob_id>` with `Authorization: Bearer <token>` (single use, exact size,
≤ 10 MiB + 64, whole upload within 300 s). A relay that is busy with other transfers answers
`503` without using up the ticket: retry the same PUT after a short pause. The recipient asks
`blob_get {blob_id}` for a download ticket and uses `GET /v1/blobs/<blob_id>`; a download ticket
works three times within its ttl (a retry after a dropped connection), `503` again means busy;
`blob_delete` by sender or recipient. `quota_exceeded` also covers the relay's total storage
budget. Blob bytes are
`XChaCha20-Poly1305(key, file, ad="hermescall/v1/blob")` with a random key that only
travels inside the E2E message. Quota: 20 blobs / 50 MiB per recipient, 7 days.
Clients reuse the relay's pinned certificate (checked on the WebSocket) for these requests.

### Mailbox envelope (E2E)

Chat messages carry `mid` (16 random bytes) in the E2E plaintext. For them the
timestamp rule is replaced by: `ts` within the last 8 days (+120 s skew) and `mid`
never seen before (ids kept 8 days, persisted). The phone marks a `mid` as seen only
after it has stored the message (`mail_ack`), so a crash cannot lose it.

| Direction | `type` | Fields |
|---|---|---|
| device → bridge | `chat` (mailbox envelope) | `id`, `text` (≤ 12 000), `reply_to?`, `attachments: [{kind: photo/voice/file, blob_id, key, name, mime}]` (≤ 4), `voice_replies?` (bool, M9: only meaningful with a `voice` attachment) |
| bridge → device | `chat_ack` | `id`, `state: delivered/transcribed`, `transcript?` (voice notes) |
| bridge → device | `chat` (mail) | `id`, `role: agent/owner` (owner = mirrored from another phone), `kind: text/missed_call/declined_call`, `text`, `attachments?` (with `size`) |
| bridge → device | `typing` | – |
| bridge → device | `approval_request` (mail) | `request_id`, `command`, `description`, `chat: true`, `choices` (e.g. `["once","session","deny"]`; absent from older bridges = once/deny) |
| device → bridge | `approval` (mailbox envelope, no `call_id`) | `request_id`, `choice: once/session/deny` |
| bridge → device | `approval_done` | `request_id` (answered on another phone) |

A resent chat message (same `id`, new `mid`) is acked again but delivered once. The bridge stores
an owner message durably before it sends `delivered` (so `delivered` survives a bridge restart);
agent messages wait in a persistent outbox on the bridge until the relay's mailbox took them
(retried with backoff and after every reconnect, for up to 7 days, with the same `mid`).

**Spoken replies (M9).** An owner voice note with `voice_replies: true` asks for a spoken answer.
The bridge remembers it for 10 minutes (a text message or a voice note without the flag clears it).
The agent's reply **to that note** — `POST /v1/chat/messages` with `answers` (or `reply_to`) = the
note's `id`; the plugin sets `answers` on a turn's final response only, so interim, cron and
missed-call messages do not count — is then synthesized with the bridge's TTS
(markdown, code blocks, URLs and emoji stripped; at most ≈ 1800 characters ≈ 2 minutes, longer
replies speak the first paragraphs and end with "More in the chat.") and sent as **one** chat
message: `text` = the reply, `attachments: [{kind: "voice", name: "reply.m4a", mime: "audio/mp4",
blob_id, key, size}]` (AAC-LC mono ≈ 32 kbit/s in MP4). Only that first reply is spoken. If TTS
fails or takes over 20 s, encoding or the upload fails, or the message would exceed the mail
limit, the text arrives alone.

## Tasks (M9)

The agent's tool progress, for the presence's tasks ring and the Live Activity.

`POST /v1/chat/progress` (ring/chat token allowed; the Hermes plugin's tool hooks):
`{turn_id?: str 1–64 (default "chat"), tool: str 1–64 ([A-Za-z0-9_.:-]; optional for done/failed),
index: int ≥ 0 (optional for done/failed), state: started|finished|done|failed, ok?: bool,
duration?: number ≥ 0, preview?: str ≤ 200, total?: int 1–999 (tools the turn will run, when
known), toolset?: str ([a-z0-9_-] 1–64, Hermes' toolset of the tool: labels unknown tools)}`.
Unknown keys → 400; success → 204 (503 when the
bridge runs without task support). `done`/`failed`
end the turn (the plugin sends them when the reply for the owner's message was sent). Only the
newest turn counts: a new `turn_id` replaces a running one, and later events of the replaced turn
are ignored. A turn that never started a tool shows nothing. A turn without any event for 10 minutes ends as
`done` (a lost end). Calls feed the same path from the
chat-completions stream (`event: hermes.tool.progress`; turn ids `call-…`).

| Direction | `type` | Fields |
|---|---|---|
| bridge → device | `task` (live; the final state also by mail, `alert: false`) | `turn_id`, `step` (tools started so far, 1-based), `total` (null: unknown), `tool` (raw name), `label` ("Searching the web", "Running a command", "Working on files", "Browsing", "Looking at an image", else "Using <tool>"; ≤ 60), `preview?` (argument preview, E2E only), `state`: `running`/`done`/`failed`, `started_at` (ms since epoch of the turn's first event) |
| device → bridge | `task_prefs` (live or mailbox envelope) | `details` (bool, default false): real tool labels may appear in this phone's Live Activity pushes (kept per device on the bridge) |

`task` updates are coalesced to about 2 per second per turn; the final `done`/`failed` always goes
at once. Online phones update their Live Activity locally from `task`; offline phones get the
pushes described in "Live Activity push".

## Phone context (M7)

The agent can ask the owner's phone for information. Every capability is set on the
phone to **No / Ask / Yes** (Settings → Phone access; all **No** by default). The phone
decides; the bridge only relays and validates. Nothing is stored on the bridge.

### Capabilities

| `capability` | Allowed settings | `params` | `data` in an `ok` answer |
|---|---|---|---|
| `location` | No/Ask/Yes | `accuracy`: `approximate` (default, rounded to ≈ 1 km) \| `precise` | `lat`, `lon`, `accuracy_m`, `time` (ISO 8601), `place?` {`name?`, `locality?`, `area?`, `country?`} |
| `battery` | No/Ask/Yes | – | `level` (0…1), `state`: `charging`/`full`/`unplugged`/`unknown`, `low_power` |
| `device` | No/Ask/Yes | – | `model`, `system`, `network`: `wifi`/`cellular`/`wired`/`none`, `expensive`, `storage_free_gb`, `thermal`, `timezone`, `locale` |
| `calendar` | No/Ask/Yes | `days` 1–14 (default 1), `limit` 1–25 (default 10) | `events`: [{`title`, `start`, `end`, `all_day`, `location?`, `calendar`}] |
| `reminders` | No/Ask/Yes | `limit` 1–30 (default 15) | `reminders`: [{`title`, `due?`, `list`, `priority`}] |
| `contacts` | No/Ask/Yes | `name` (required, 1–100 chars) | `contacts` (≤ 5): [{`name`, `organization?`, `phones`: [{`label`, `number`}], `emails`: [{`label`, `address`}]}] |
| `motion` | No/Ask/Yes | – | `activity`: `stationary`/`walking`/`running`/`cycling`/`automotive`/`unknown`, `confidence`: `low`/`medium`/`high`, `steps_today?`, `distance_today_m?` |
| `focus` | No/Ask/Yes | – | `focused` (whether a Focus is on; never which one) |
| `now_playing` | No/Ask/Yes | – | `playing`, `title?`, `artist?`, `album?` (Apple Music app only) |
| `health` | No/Ask/Yes | – | `steps_today?`, `active_energy_kcal_today?`, `sleep_hours_last_night?`, `resting_heart_rate?` |
| `home` | No/Ask/Yes | – | `homes`: [{`name`, `accessories` (≤ 100): [{`name`, `room?`, `category`, `reachable`, `on?`}]}] |
| `clipboard` | No/Ask | – | `text?` (≤ 8000), `has_text` |
| `photos` | No/Ask | `max` 1–4 (default 1) | `files`: [{`blob_id`, `key`, `name`, `mime`}] — the owner picks them |
| `files` | No/Ask | `max` 1–4 (default 1) | same as `photos` |
| `geofence` | No/Ask/Yes | `action`: `add`\|`remove`\|`list`; add: `title` (1–120, required), `note?` (≤ 500), `place` (required): `{lat, lon, radius_m?}` (radius 100–2000 m, default 200) or `{query}` (1–120, resolved on the phone near the owner), `trigger`: `enter` (default) \| `exit`, `repeat` (bool, default false), `id?` (≤ 64); remove: `id` (required, ≤ 64); list: – | add: `id`, `resolved_name?`; remove: `removed`; list: `reminders` (≤ 20): [{`id`, `title`, `place_name?`, `trigger`, `repeat`}] — never the phone's location |

| `reminder_create` | No/Ask | `title` (1–200, required), `due?` (ISO 8601 with offset), `notes?` (≤ 1000) | `ok` (true), `id` (≤ 200) |
| `calendar_create` | No/Ask | `title` (1–200, required), `start`, `end` (ISO 8601 with offset, required; end after start, ≤ 14 days later), `location?` (≤ 200), `notes?` (≤ 1000) | `ok` (true), `id` (≤ 200) |

Times are ISO 8601 with offset. Answers carry only what the table lists (no ids, except
geofence reminder ids and the ids of created reminders/events). Place reminders live on the phone:
it monitors the region itself and fires a local notification; the bridge validates params before
asking (400 on bad input). The write capabilities (`reminder_create`, `calendar_create`) go to one
phone only, the most recently active one, so nothing is created twice.

### Local API (Hermes plugin, ring/chat token allowed)

`POST /v1/phone/queries` `{capability, reason (1–300 chars), params?}` waits for the
outcome and returns `{status, data?, files?}`:
`ok` / `denied` / `unavailable` (iOS permission off, feature missing) / `timeout` /
`no_devices` / `rate_limited` (20 per 10 min, 100 per day) / `busy` (≥ 2 queries open).
For `photos`/`files` the bridge downloads and deletes the blobs and returns
`files: [{name, mime, data (base64url)}]`; the plugin writes them to a private temp
directory and gives the agent only paths.

### E2E

| Direction | `type` | Fields |
|---|---|---|
| bridge → device | `phone_query` (mail, alert) | `query_id` (16 bytes), `capability`, `params`, `reason`, `expires` (ms since epoch: 60 s, pickers 120 s) |
| device → bridge | `phone_answer` (mailbox envelope) | `query_id`, `status`: `ok`/`denied`/`unavailable`/`timeout`, `data?` (≤ 16 KiB JSON) |
| bridge → device | `query_done` | `query_id` (answered elsewhere or expired: close the prompt) |

The query goes to every paired phone (writes: see above). An `ok` answer from the most recently
active phone (the one that last sent the bridge anything) wins at once; an `ok` from another phone
waits up to 3 s for that phone (it is probably in the owner's hand) and wins if that phone declines
or stays silent; pickers take the first `ok`. Otherwise the bridge
waits until every phone answered or `expires` + 10 s passed and reports, in this order,
`denied`, `unavailable`, `timeout`. The bridge validates `data` per capability (only the
listed top-level keys, ≤ 16 KiB) and rejects anything else as `unavailable`.
Phones drop queries past `expires`. Every query and its outcome is logged on the phone
only (last 200, Settings → Phone access → Recent requests; wiped by "Delete all data").

## Presentations (M7)

Structured results the agent shows to the owner (places, links, lists): a card deck
that unfolds from the presence and is stored in the chat.

`POST /v1/present` (ring/chat token allowed):

```json
{"title": "Restaurants near you", "kind": "places", "text": "Three open now.",
 "items": [{"title": "Trattoria", "subtitle": "Italian · 4.6 ★ · 350 m", "detail": "…",
            "url": "https://…", "image_url": "https://…", "lat": 48.1, "lon": 11.5,
            "actions": [{"label": "Call", "tel": "+49 89 123"}, {"label": "Route", "maps": true},
                        {"label": "Menu", "url": "https://…"}]}]}
```

Limits: `title` 1–120, `kind` `places`/`links`/`list` (default `list`), `text` ≤ 2000,
1–10 items; item `title` 1–120, `subtitle` ≤ 200, `detail` ≤ 600, `url`/`image_url`
`https://` ≤ 1000, `lat`/`lon` both or neither, ≤ 3 actions with `label` 1–30 and exactly
one of `url` (https), `tel` (`+`, digits, spaces, `-()/`, 3–30 chars) or `maps: true`
(needs `lat`/`lon`). No HTML; strings are shown as plain text. Reply
`{message_id, images}` (images loaded) or 400 `{error}`.

**Images**: the phone never contacts third parties. The bridge fetches each `image_url`
(https only, public IP addresses only — checked on every resolved address, so no DNS
rebinding; no redirects; ≤ 5 MiB; 8 s), re-encodes it as JPEG ≤ 512 px without metadata
and sends it as an encrypted blob. Failed images are dropped silently.

E2E: bridge → device `chat` (mail, alert) with `kind: "presentation"`, `text` = `text` or
`title` (preview), and `presentation`: `{title, kind, items: [{title, subtitle?, detail?, url?,
lat?, lon?, actions?, image?: {blob_id, key, mime, size}}]}`. Older apps show the text.
