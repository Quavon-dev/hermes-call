import Foundation
import HermesCallCore

/// "Try a demo": an agent that runs only on this iPhone, for people (and App Review) without a relay
/// and bridge yet. It is never stored with the real agents: its profile lives in memory (keys made at
/// launch, a relay address that cannot resolve), nothing it gets leaves the phone, and removing it
/// deletes its chat.
enum DemoAgent {
    /// Fixed, so the demo chat survives a relaunch until the demo is removed.
    static let id = UUID(uuidString: "D3A0D3A0-0000-4000-8000-00000000DE70") ?? UUID()
    static let name = "Atlas"
    static let label = "Demo"

    /// A profile for the demo agent; its keys never leave memory.
    static func makeProfile() -> RelayProfile? {
        guard let keys = try? DeviceKeys.generate() else { return nil }
        return RelayProfile(id: id, label: label, relay: RelayAddress(host: "demo.invalid", port: 443), pin: "",
                            deviceID: "demo", bridgeID: "demo", bridgeName: name,
                            bridgeBoxKey: Base64URL.encode(Sodium.randomBytes(32)),
                            bridgeSignKey: Base64URL.encode(Sodium.randomBytes(32)), keys: keys, created: Date(), palette: .ice)
    }

    // MARK: replies

    enum Topic: Equatable { case greeting, places, plan, call, attachment, help, echo }

    /// What the owner asked about (a few keywords; this is not an AI).
    static func topic(of text: String, attachments: Int = 0) -> Topic {
        let words = text.lowercased()
        func has(_ keys: String...) -> Bool { keys.contains { words.contains($0) } }
        if has("place", "restaurant", "dinner", "lunch", "coffee", "café", "cafe", "eat out") { return .places }
        if has("plan", "today", "calendar", "schedule", "agenda", "tomorrow") { return .plan }
        if has("call me", "call", "phone") { return .call }
        if has("help", "what can you", "markdown", "demo") { return .help }
        if has("hello", "hi ", "hey", "good morning", "good evening") || ["hi", "hello", "hey"].contains(words) { return .greeting }
        if attachments > 0, words.isEmpty { return .attachment }
        return attachments > 0 ? .attachment : .echo
    }

    /// The agent's `chat` body answering `text` (docs/protocol.md, "Chat"), as the bridge would send it.
    static func reply(to text: String, attachments: Int = 0, id: String = E2EChannel.newMessageID()) -> [String: JSON] {
        switch topic(of: text, attachments: attachments) {
        case .places:
            return ["type": "chat", "id": .string(id), "role": "agent", "kind": "presentation",
                    "text": "Three quiet places near you that are open now:", "presentation": places]
        case .plan: return message(plan, id: id)
        case .call: return message(callHint, id: id)
        case .help: return message(help, id: id)
        case .greeting: return message(greeting, id: id)
        case .attachment: return message(attachmentReply, id: id)
        case .echo:
            let quoted = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
            return message("You said: “\(quoted)”.\n\nThis is the offline demo, so I only know a few things. Try **places**, "
                             + "**plan my day** or **help**.", id: id)
        }
    }

    private static func message(_ text: String, id: String) -> [String: JSON] {
        ["type": "chat", "id": .string(id), "role": "agent", "text": .string(text)]
    }

    static let greeting = "Hi! I'm **Atlas**, a demo agent that runs only on this iPhone. Nothing you write here leaves it.\n\n"
        + "With Hermes Call your own agent answers here, calls you when something needs you, and you can call it back. "
        + "Try **places**, **plan my day** or **help**."

    static let plan = """
        ## Your day
        1. **09:30** Stand-up with the team
        2. **12:00** Lunch with Sam
        3. **15:00** Dentist, 2nd floor

        > Leave at **14:35** to be on time for the dentist.

        - [x] Pay the electricity bill
        - [ ] Book train tickets for Friday
        """

    static let callHint = "Tap **Call** (or tap the presence in the HUD appearance) to try a demo call. "
        + "It is simulated on this iPhone: no microphone audio is recorded or sent."

    static let help = """
        In this demo I can show you:

        | Ask for | You get |
        |---|---|
        | places | result cards with a map |
        | plan my day | a formatted plan |
        | call me | how calls work |

        With your own agent, Hermes Call connects through **your relay** to **your bridge**, end-to-end encrypted. \
        Set them up with the guide at github.com/Quavon-dev/hermes-call.
        """

    static let attachmentReply = "Got it. In the demo your file stays on this iPhone; your own agent could look at it and answer."

    static let places: JSON = [
        "title": "Quiet places nearby",
        "kind": "places",
        "items": .array([
            place("Linden Reading Café", "Café · 4 min walk", "Open until 20:00. Window seats, no music.", 52.5208, 13.4095),
            place("Harbour Noodle Bar", "Noodles · 7 min walk", "Table for two free at 19:30.", 52.5163, 13.4011),
            place("The Green Courtyard", "Vegetarian · 9 min walk", "Garden seating, quiet on weekdays.", 52.5241, 13.4032),
        ]),
    ]

    private static func place(_ title: String, _ subtitle: String, _ detail: String, _ lat: Double, _ lon: Double) -> JSON {
        ["title": .string(title), "subtitle": .string(subtitle), "detail": .string(detail), "lat": .double(lat), "lon": .double(lon),
         "actions": .array([["label": "Directions", "maps": true]])]
    }

    /// The calendar card and captions the demo call shows.
    static let callLines: [(fromAgent: Bool, text: String)] = [
        (false, "What's next on my calendar?"),
        (true, "Lunch with Sam at twelve. Should I send a reminder at half past eleven?"),
        (false, "Yes, please."),
        (true, "Done. Anything else?"),
    ]
}
