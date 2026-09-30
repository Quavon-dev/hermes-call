# App Review notes

Paste the text below into App Store Connect › App Review Information › Notes (it stays under Apple's
4000-character limit; check after editing). Sign-in is **not required**: leave "Sign-in required" unchecked.

---

Hermes Call is a phone and chat client for the reviewer's own, self-hosted AI agent ("Hermes").
The owner runs three pieces themselves: the agent, a bridge next to it, and a small relay server.
The app pairs with that relay by a one-time code; there are no accounts and no server run by us.

HOW TO TEST WITHOUT A RELAY (demo mode)
1. Launch the app, tap Continue on the three intro pages (the third one explains the microphone and
   notification permissions before iOS asks; both may be skipped).
2. Tap "Try a demo". A demo agent named Atlas starts. It runs only on the device, offline; nothing is
   sent anywhere.
3. The consent screen appears (guideline 5.1.2(i)): it lists what the app would share with the owner's
   agent and says that the agent may pass it to a third-party AI service. Tap "Allow sharing with my
   agent" (or "Not now"; the demo works either way because it stays on the device).
4. Chat tab: type "plan my day" (Markdown answer), "places for dinner" (result cards with a map),
   or "help".
5. Call tab: tap "Call Atlas". A simulated call starts with captions; no microphone audio is recorded
   or sent in the demo. Mute, Speaker, the audio route picker and hang-up work.
6. Settings (gear): the agent list (Atlas marked Demo, "Remove demo agent"), Privacy › "Share with my
   agent" (withdraws consent), Phone access (every capability defaults to No), Diagnostics.

WHY THE APP ASKS FOR THESE CAPABILITIES
- VoIP push + CallKit: the owner's agent can ring the phone like a normal call (for example when a task
  needs a decision). Every VoIP push is reported to CallKit immediately; rings the bridge does not
  confirm end at once. The push payload is only a random call id.
- Background audio: keeps the call's audio running when the screen locks during a call.
- Microphone: calls with the agent and voice notes; only while a call or a recording is active.
- Camera: scanning the pairing QR code, photos the user sends, and "Look" during a call.
- HealthKit (read only): only when the user sets Settings › Phone access › Health summary to Ask or Yes
  and the agent asks, the app reads today's steps and active energy, last night's sleep and resting
  heart rate and sends them end-to-end encrypted to the user's own bridge. Nothing is written to Health.
  Health data is never used for advertising and never leaves for any server of ours.
- HomeKit (read only): only with Phone access › Home set to Ask or Yes, the app reads accessory names,
  rooms and on/off state for the agent. It never controls accessories.
- Location "When In Use": only with Phone access › Location on Ask or Yes (about 1 km unless the agent
  asks for precise and the user allows it).
- Location "Always": only for place reminders the user asks the agent to set ("remind me when I'm at
  the supermarket"). The iPhone monitors the region itself (CLMonitor) and shows a local notification;
  the location is never sent to the agent. "Always" is requested only when the first reminder is added.
- Calendars, Reminders, Contacts, Motion, Music, Focus status: read (and, for calendar and reminders,
  add an item the user sees first) only when the user allows it per capability (No / Ask / Yes, all No
  by default); every request is logged in Settings › Phone access › Recent requests.
- Local network: the call can go directly to the user's bridge when it is on the same network.

PRIVACY
All content (audio, messages, files, phone data) is end-to-end encrypted between the phone and the
user's own bridge. The developer runs no server that sees content, collects nothing, and the app has no
analytics, crash reporting or advertising SDKs. The optional push gateway run by the developer only
forwards push requests (a device token and a random call id).

Export compliance: standard encryption only (TLS, libsodium); ITSAppUsesNonExemptEncryption = NO.

Contact: <the support e-mail set in App Store Connect>
