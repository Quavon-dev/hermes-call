#if DEBUG
import AVFoundation
import Foundation
import HermesCallCore
import UIKit

/// `-ChatDemo YES` (debug builds, simulator screenshots): a paired demo agent on an unreachable relay
/// and a chat history with Markdown, a voice note, a photo and a call entry. `-ChatDemoQuery <text>`
/// opens the search with that text; `-ChatDemoPlay YES` plays the voice note.
enum ChatDemo {
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "ChatDemo") }
    static var query: String? { UserDefaults.standard.string(forKey: "ChatDemoQuery") }
    static var plays: Bool { UserDefaults.standard.bool(forKey: "ChatDemoPlay") }
    /// `-ChatDemoReveal <text>`: jump to the first message containing it, as from a search hit.
    static var reveal: String? { UserDefaults.standard.string(forKey: "ChatDemoReveal") }

    /// `-ChatDemoApproval YES`: an approval request that offers "Allow for this session".
    static func approval(_ profile: UUID) -> ChatApproval? {
        guard enabled, UserDefaults.standard.bool(forKey: "ChatDemoApproval") else { return nil }
        return ChatApproval(id: "demo-approval", profileID: profile, command: "git push origin main",
                            details: "Push the release branch to GitHub", mailID: nil, allowsSession: true)
    }

    /// Before the models load: a demo profile in the Keychain when none is paired.
    static func seedIfRequested() {
        let store = ProfileStore()
        guard enabled, (try? store.load())?.isEmpty ?? true, let keys = try? DeviceKeys.generate() else { return }
        let profile = RelayProfile(id: UUID(), label: "Demo", relay: RelayAddress(host: "relay.invalid", port: 443), pin: "",
                                   deviceID: "demo", bridgeID: "demo-bridge", bridgeName: "Atlas",
                                   bridgeBoxKey: Base64URL.encode(Sodium.randomBytes(32)),
                                   bridgeSignKey: Base64URL.encode(Sodium.randomBytes(32)), keys: keys, created: Date(), palette: .ice)
        try? store.save([profile])
        UserDefaults.standard.set(true, forKey: "onboardingDone")
    }

    /// The demo history, once per profile.
    static func fillIfRequested(_ profile: UUID, store: ChatStore = .shared) async {
        guard enabled, await store.count(profile) == 0 else { return }
        let start = Calendar.current.startOfDay(for: Date()).addingTimeInterval(9 * 3600)
        var messages: [ChatMessage] = [
            message(.owner, "Can you check which invoices are still open this month?", start.addingTimeInterval(-86_400)),
            message(.agent, "Two are open: **Hetzner** (€ 38.20, due Friday) and the *domain renewal* (€ 14.00).",
                    start.addingTimeInterval(-86_300)),
            ChatMessage.callEntry(CallSummary(direction: .outgoing, duration: 151), id: E2EChannel.newMessageID(),
                                  date: start.addingTimeInterval(-80_000)),
            message(.owner, "Plan tomorrow's trip to Hamburg for me", start),
        ]
        messages.append(message(.agent, """
            ## Hamburg, Thursday
            Here is a plan that keeps the morning free:

            1. **ICE 703** Berlin → Hamburg, 10:36–12:20
            2. Lunch near the *Speicherstadt*
               - Fischbrötchen at the harbour
               - or the café in the Elbphilharmonie
            3. Meeting at 14:00, back on the **ICE 1712** at 18:36

            | Train | Departs | Arrives | Price |
            |:------|:-------:|:-------:|------:|
            | ICE 703 | 10:36 | 12:20 | € 29.90 |
            | ICE 1712 | 18:36 | 20:22 | € 34.90 |

            > Seats are reserved in the quiet zone.

            To add both trains to your calendar:
            ```
            hermes calendar add --from 10:36 --to 20:22
            ```
            - [x] tickets booked
            - [ ] hotel not needed
            """, start.addingTimeInterval(60)))
        var note = message(.owner, "", start.addingTimeInterval(300))
        if let voice = voiceNote(), let file = try? await store.saveAttachment(voice, id: "demo-voice", name: "Voice note.wav", in: profile) {
            note.attachments = [ChatAttachment(id: "demo-voice", kind: .voice, name: "Voice note.wav", mime: "audio/wav", size: voice.count,
                                               localFile: file, duration: 6)]
            note.transcript = "And please remind me to buy flowers on the way back."
            note.status = .delivered
            messages.append(note)
        }
        messages.append(message(.agent, "Done: a reminder at **18:00** at Hamburg Hbf. 💐", start.addingTimeInterval(320)))
        for message in messages { _ = try? await store.upsert(message, in: profile) }
    }

    private static func message(_ role: ChatMessage.Role, _ text: String, _ date: Date) -> ChatMessage {
        ChatMessage(id: E2EChannel.newMessageID(), role: role, text: text, date: date, status: role == .owner ? .delivered : .received)
    }

    /// Six seconds of a soft, speech-like hum (a WAV file) so the waveform has something to show.
    private static func voiceNote() -> Data? {
        let rate = 16_000.0, seconds = 6.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * seconds)),
              let samples = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = buffer.frameCapacity
        for index in 0..<Int(buffer.frameLength) {
            let t = Double(index) / rate
            let syllables = max(0, sin(t * 2 * .pi * 1.7)) * (0.5 + 0.5 * sin(t * 0.9))
            samples[index] = Float(syllables * 0.4 * sin(t * 2 * .pi * 180) * sin(t * 2 * .pi * 3))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("demo-voice.wav")
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        } catch {
            return nil
        }
        return try? Data(contentsOf: url)
    }
}
#endif
