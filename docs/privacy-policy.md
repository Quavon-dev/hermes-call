# Privacy Policy — Hermes Call

_Last updated: 1 October 2026._

## Who is responsible

Quavon UG (haftungsbeschränkt), Langbehnstraße 39, 83022 Rosenheim, Germany, e-mail:
[contact@quavon.de](mailto:contact@quavon.de)
("we"). This policy covers the Hermes Call iOS app, the open-source relay and bridge software, and
the push gateway `hermes-push.quavon.de` that we operate.

## The short version

Hermes Call connects your iPhone to an AI agent **you** run. Audio, messages, files and the phone
data you allow are end-to-end encrypted between your iPhone and your own bridge. We have no accounts,
no analytics, no advertising and no tracking, and we cannot read your content.

## What the app processes, and where it goes

- **Calls, messages, voice notes, photos, files** and the **phone data** you allow (location,
  calendar, reminders, contacts, health summary, Home, motion, music, Focus status, clipboard,
  photos, files): sent end-to-end encrypted to the bridge **you** paired, through a relay **you**
  (or someone you chose) run. We do not receive them. Your agent may pass what it receives to the AI
  service it is configured with; that is under your control and that provider's terms. The app asks
  for your consent before anything is shared and you can withdraw it in Settings › Privacy.
- **On your iPhone**: chat history, the request log and settings stay on the device (protected by
  iOS data protection) and are deleted with "Delete all data" or by removing the app.
- **Relay you use**: sees only encrypted data, which device talks to which bridge, when, and how
  much.

## Push notifications and the push gateway

To ring your iPhone or show a message while the app is closed, iOS needs a push via Apple (APNs).
Relays without their own Apple key send these pushes through our push gateway. The gateway
receives the device push token, the environment, a random call id or an encrypted message body, and
the relay's public key and IP address. It forwards the push to Apple and keeps, only for abuse
protection: hashes of request signatures for 2 minutes, and for 30 days the hash of a push token
together with the ids of at most 5 relays that used it and whether a delivery succeeded. It keeps no
access logs and no content. Legal basis: Art. 6(1)(b) GDPR (providing the service you requested) and
Art. 6(1)(f) GDPR (security of the service). Apple's processing is governed by Apple's privacy policy.
Relays with their own Apple key do not use our gateway at all.

## What we do not do

No user accounts, no analytics or crash-reporting SDKs, no advertising, no tracking across apps or
websites, no sale or sharing of personal data. The app never contacts third parties directly: images
in result cards are fetched by your bridge.

## Your rights

You have the rights of access, rectification, erasure, restriction, data portability and objection
(Art. 15–21 GDPR), and the right to lodge a complaint with a supervisory authority. Because we hold
no content and no data that identifies you beyond the hashed push token described above, contact us
at [contact@quavon.de](mailto:contact@quavon.de) for any request.

## Changes

We will update this page when the app or the gateway changes how data is processed; the date above
shows the latest version.
