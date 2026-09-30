# Chat — design (M6, implemented; wire format in docs/protocol.md)

Goal: text your agent from the Hermes Call app, and let it write to you when a
call is not possible — replacing Telegram, with the same privacy model as calls
(end-to-end encrypted through your own relay, nothing readable by the relay or
Apple).

## How Hermes supports this (researched 2026-09-29, Hermes docs)

- **Platform adapter plugin** (`kind: platform`, `ctx.register_platform`): a
  plugin can add a messaging platform exactly like Telegram — inbound messages
  become gateway sessions with memory and tools; the adapter implements
  `connect/disconnect/send/send_typing`. Handled for free: user allow-lists,
  message chunking, platform hint in the system prompt, `/sethome` home chat,
  cron delivery (`deliver=hermes_call`), background-task notices, the delivery
  ledger (redelivery after crashes).
- **Proactive messages**: Hermes' built-in `send_message` tool, cron
  `deliver=hermes_call` and `hermes send --to hermes_call` all reach the phone
  (live adapter, or `standalone_sender_fn` when no gateway runs in-process).
- **Approvals** (checked in the v0.15 source, 2026-09-29): there is no
  `register_approval_transport`; the adapter implements `send_exec_approval`
  and answers with `tools.approval.resolve_gateway_approval`. Failures are
  denied in the adapter (never the typed `/approve` fallback), and typed
  `/approve` is refused on this platform.

## Proposed architecture

```
iPhone app ⇄ relay (E2E ciphertext, mailbox, APNs) ⇄ bridge ⇄ 127.0.0.1 ⇄ Hermes gateway (platform adapter "hermes_call")
```

1. **Hermes side**: the existing `hermes-call` plugin also registers the
   platform `hermes_call`. The adapter keeps one loopback WebSocket to the
   bridge (ring-only token extended by a chat scope); `send()` → bridge →
   E2E to the phone. One chat per paired phone (`chat_id` = device id).
2. **Bridge**: new E2E types `chat` (text, id, reply_to), `chat_ack`,
   `typing`, `voice_note` (audio → Whisper → text), `image` (encrypted blob
   reference). Voice notes and images reuse the call pipeline pieces.
3. **Relay mailbox** for phones that are offline: stores E2E ciphertext only,
   per device (bounded: e.g. 500 messages / 7 days / 20 MB), delivered on
   connect, deleted on ack. Encrypted blobs (images) with the same limits.
4. **Push**: a normal APNs *alert* push (not VoIP — Apple forbids VoIP pushes
   for messages). Payload: generic text plus the E2E ciphertext if it fits
   (< ~3 KB). A **Notification Service Extension** decrypts it on the phone
   (keys shared via Keychain access group) and shows the real text on the
   lock screen; Apple only ever sees ciphertext. Setting to show only
   "New message" instead.
5. **App**: chat screen (Markdown rendering, typing indicator, delivered/read
   state, voice-note button, photo picker), history stored only on the phone
   (encrypted at rest, wiped by "Delete all data"). Approvals from chat use
   the same Face ID sheet. HUD appearance applies.
6. **"Write me when I can't call"**: when a `call_owner` ring ends
   `no_answer`/`declined`, the bridge posts the call's opening sentence and
   reason into the chat ("Missed call — …") and tells the agent it did; the
   agent's follow-ups arrive through the normal chat session. This stays
   within Hermes' rule (no agent-initiated send tool): it is the outcome of a
   call the agent was already allowed to make.

## Decisions (user, 2026-09-29)

- Lock-screen previews: **decrypted on the phone** (Notification Service Extension).
- v1 scope: **text both ways, voice notes, photos to the agent, files/images from the agent**.
- Face ID approvals via the phone for **calls and chat from this app** only.
- Built as milestone **M6**.
- Requires the Hermes gateway process (`hermes gateway`) next to the bridge.
