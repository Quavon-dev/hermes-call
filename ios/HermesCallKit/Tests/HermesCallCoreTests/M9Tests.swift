import Foundation
import Testing
@testable import HermesCallCore

@Suite struct GeofenceTests {
    @Test func parsesAddWithCoordinates() {
        let request = GeofenceRequest.parse([
            "action": "add", "title": " Buy milk ", "note": "2 litres",
            "place": ["lat": .double(48.16), "lon": .double(11.58), "radius_m": 200], "trigger": "exit", "repeat": true,
        ])
        #expect(request == .add(title: "Buy milk", note: "2 litres", place: .coordinate(latitude: 48.16, longitude: 11.58, radius: 200),
                                trigger: .exit, repeats: true))
    }

    @Test func parsesAddWithQueryAndDefaults() {
        let request = GeofenceRequest.parse(["action": "add", "title": "Milk", "place": ["query": "Rewe Schwabing"]])
        #expect(request == .add(title: "Milk", note: nil, place: .query("Rewe Schwabing"), trigger: .enter, repeats: false))
    }

    @Test func parsesListAndRemove() {
        #expect(GeofenceRequest.parse(["action": "list"]) == .list)
        #expect(GeofenceRequest.parse(["action": "remove", "id": "abc"]) == .remove(id: "abc"))
    }

    @Test(arguments: [
        ["action": "add", "place": ["query": "x"]],                                                   // no title
        ["action": "add", "title": "x"],                                                               // no place
        ["action": "add", "title": "x", "place": ["lat": 91, "lon": 0]],                               // bad latitude
        ["action": "add", "title": "x", "place": ["lat": 1, "lon": 2, "radius_m": 50]],                // radius too small
        ["action": "add", "title": "x", "place": ["lat": 1, "lon": 2, "radius_m": 5000]],              // radius too big
        ["action": "add", "title": "x", "place": ["query": "x"], "trigger": "dwell"],                  // bad trigger
        ["action": "add", "title": .string(String(repeating: "a", count: 121)), "place": ["query": "x"]],
        ["action": "add", "title": "x", "note": .string(String(repeating: "a", count: 501)), "place": ["query": "x"]],
        ["action": "remove"],
        ["action": "nuke"],
    ] as [[String: JSON]])
    func rejectsBadParams(_ params: [String: JSON]) {
        #expect(GeofenceRequest.parse(params) == nil)
    }

    @Test func storeKeepsAtMostTwenty() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("reminders-\(UUID()).json")
        let store = PlaceReminderStore(url: url)
        defer { try? FileManager.default.removeItem(at: url) }
        for index in 0..<PlaceReminderStore.maxReminders {
            try await store.add(PlaceReminder(title: "R\(index)", placeName: "P", latitude: 1, longitude: 2, radius: 150,
                                              trigger: .enter, repeats: false))
        }
        await #expect(throws: PlaceReminderStore.StoreError.full) {
            try await store.add(PlaceReminder(title: "extra", placeName: "P", latitude: 1, longitude: 2, radius: 150,
                                              trigger: .enter, repeats: false))
        }
        let first = await store.all()[0]
        #expect(await store.remove(first.id))
        #expect(await !store.remove(first.id))
        #expect(await store.all().count == PlaceReminderStore.maxReminders - 1)
        #expect(first.summary["place_name"] == "P" && first.summary["lat"] == nil)
    }
}

@Suite struct TaskProgressTests {
    private let body: [String: JSON] = [
        "type": "task", "turn_id": "t1", "step": 3, "total": 5, "tool": "web_search", "label": "Searching the web",
        "preview": "flights to Rome", "state": "running", "started_at": 1_790_000_000_000,
    ]

    @Test func parsesATaskUpdate() throws {
        let update = try #require(TaskUpdate.parse(body))
        #expect(update.turnID == "t1" && update.step == 3 && update.total == 5 && update.state == .running)
        #expect(update.contentState().fraction == 0.6)
        #expect(update.contentState().label == "Searching the web")
        #expect(update.contentState(details: false).label == "Working…")
        #expect(update.contentState().startedAt == 1_790_000_000)
    }

    @Test func rejectsBadUpdates() {
        var bad = body
        bad["state"] = "exploded"
        #expect(TaskUpdate.parse(bad) == nil)
        bad = body
        bad["step"] = 5000
        #expect(TaskUpdate.parse(bad) == nil)
        bad = body
        bad["turn_id"] = nil
        #expect(TaskUpdate.parse(bad) == nil)
    }

    /// The relay pushes the same JSON to ActivityKit, so the coding must match docs/protocol.md exactly.
    @Test func contentStateCodingMatchesThePushFormat() throws {
        let state = TaskContentState(step: 2, total: nil, label: "Working…", state: .running, startedAt: 1_790_000_000.5)
        let json = try JSON.decode(JSONEncoder().encode(state))
        #expect(json["step"] == 2 && json["label"] == "Working…" && json["state"] == "running")
        #expect(json["startedAt"]?.number == 1_790_000_000.5)
        let pushed = #"{"step":4,"total":6,"label":"Working…","state":"done","startedAt":1790000000}"#
        let decoded = try JSONDecoder().decode(TaskContentState.self, from: Data(pushed.utf8))
        #expect(decoded == TaskContentState(step: 4, total: 6, label: "Working…", state: .done, startedAt: 1_790_000_000))
    }
}

@Suite struct PaletteTests {
    @Test func oldProfilesDecodeAsGold() throws {
        let keys = DeviceKeys(signPublic: "a", signSecret: "b", boxPublic: "c", boxSecret: "d")
        let profile = RelayProfile(id: UUID(), label: "Home", relay: RelayAddress(host: "r.example", port: 443), pin: "",
                                   deviceID: "d", bridgeID: "b", bridgeName: "Atlas", bridgeBoxKey: "k", bridgeSignKey: "s",
                                   keys: keys, created: Date(timeIntervalSince1970: 0))
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
        object["palette"] = nil
        let old = try JSONDecoder().decode(RelayProfile.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.palette == nil && old.agentPalette == .gold)
        var colored = profile
        colored.palette = .ice
        let roundTrip = try JSONDecoder().decode(RelayProfile.self, from: JSONEncoder().encode(colored))
        #expect(roundTrip.agentPalette == .ice)
    }

    @Test func newAgentsGetAFreeColour() {
        #expect(AgentPalette.next(after: []) == .gold)
        #expect(AgentPalette.next(after: [.gold]) == .ice)
        #expect(AgentPalette.next(after: AgentPalette.allCases) == .gold)
    }
}

@Suite struct VoiceReplyTests {
    @Test func voiceNotesCarryTheVoiceReplyFlag() {
        let voice = ChatAttachment(kind: .voice, name: "Voice note.m4a", mime: "audio/mp4", size: 10)
        let note = ChatMessage(id: "AAAAAAAAAAAAAAAAAAAAAA", role: .owner, text: "", attachments: [voice], status: .pending)
        let upload = (attachment: voice, blobID: "b", key: Data(repeating: 1, count: 32))
        #expect(ChatWire.body(for: note, uploads: [upload], voiceReplies: true)["voice_replies"] == true)
        #expect(ChatWire.body(for: note, uploads: [upload], voiceReplies: false)["voice_replies"] == nil)
        let text = ChatMessage(id: "AAAAAAAAAAAAAAAAAAAAAA", role: .owner, text: "hi", status: .pending)
        #expect(ChatWire.body(for: text, uploads: [], voiceReplies: true)["voice_replies"] == nil)
    }
}
