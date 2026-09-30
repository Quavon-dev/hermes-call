# App Privacy answers (App Store Connect › App Privacy)

These answers match `ios/Config/PrivacyInfo.xcprivacy` (no tracking, no tracking domains, an empty
`NSPrivacyCollectedDataTypes`).

**Do you or your third-party partners collect data from this app?** → **No, we do not collect data
from this app.** The label then reads "Data Not Collected".

Why that is accurate under Apple's definition ("collect" = transmit data off the device in a way that
lets the developer or its partners access it longer than needed to service the request in real time):

| What leaves the phone | Goes to | Can the developer read it? |
|---|---|---|
| Call audio / transcripts, messages, photos, files, voice notes, phone data the user allows | The user's **own** bridge, end-to-end encrypted, through the user's **own** relay | No (the developer runs neither; relays only see ciphertext) |
| VoIP / alert / Live Activity push tokens | The user's relay, which sends pushes itself or through the developer's push gateway | The gateway needs a token and a random call id only to forward a push to Apple; confirm it keeps no log of them before answering "No" |
| Pairing code handshake | The user's relay | No (CPace; the code never leaves in the clear) |

Things to keep true, or the answers must change:

- No analytics, crash reporting, advertising or attribution SDKs (CONTRIBUTING.md forbids them).
- The push gateway must not store tokens beyond forwarding, or "Device ID" (push token) becomes
  collected data linked to the user.
- The owner's agent may pass what the user shares to an AI service the **owner** chose; that is the
  owner's own processing, disclosed in the consent screen (guideline 5.1.2(i)), not collection by the
  developer.
- Health data is read only on request of the user's own agent and never used for advertising
  (guideline 5.1.3); nothing is written to Health.

Required-reason APIs declared in the manifest: UserDefaults (CA92.1, 1C8F.1), file timestamps
(C617.1), system boot time (35F9.1), disk space (85F4.1). The Diagnostics log export reads the app's
own unified log in-process (OSLogStore, current process), which is not a required-reason API.
