import Foundation
import HermesCallCore
import Testing
@testable import HermesCall

@MainActor
@Suite(.serialized) struct PhoneAndTaskTests {
    func settings() -> PhoneAccessSettings {
        PhoneAccessSettings(defaults: UserDefaults(suiteName: "de.quavon.hermescall.tests.\(UUID().uuidString)") ?? .standard)
    }

    // MARK: PhoneContextModel

    @Test func askQueriesWaitForTheOwnerOneAtATime() throws {
        let fixture = try ChatFixture()
        let rules = settings()
        rules.set(.ask, for: .battery)
        rules.set(.ask, for: .calendar)
        let phone = PhoneContextModel(app: fixture.app, settings: rules)
        let session = try RelaySession(profile: fixture.home, mailStore: nil)
        let first = ConsentApprovalTests.query(.battery)
        let second = ConsentApprovalTests.query(.calendar)
        phone.receive(first, from: session)
        phone.receive(second, from: session)
        phone.receive(first, from: session)  // the same query again (live and from the mailbox)
        #expect(phone.prompt?.id == first["query_id"]?.string)
        #expect(phone.prompt?.agentName == fixture.home.bridgeName)
        phone.receive(["type": "query_done", "query_id": try #require(first["query_id"])], from: session)
        #expect(phone.prompt?.id == second["query_id"]?.string)
    }

    @Test func writeCapabilitiesShowTheItemAndDefaultToNo() throws {
        let rules = settings()
        #expect(rules.permission(for: .reminderCreate) == .no)
        #expect(rules.permission(for: .calendarCreate) == .no)
        let good = try #require(PhoneQuery.parse(ConsentApprovalTests.query(
            .calendarCreate, params: ["title": "Dentist", "start": "2026-10-02T15:00:00+02:00", "end": "2026-10-02T16:00:00+02:00",
                                      "location": "Main St 1"])))
        #expect(good.newItem?.title == "Dentist" && good.newItem?.location == "Main St 1")
        #expect(PhoneContextModel.decision(consent: true, permission: .ask, for: good) == .ask)
        // An item the phone cannot show exactly is never created.
        let broken = try #require(PhoneQuery.parse(ConsentApprovalTests.query(.calendarCreate, params: ["title": "No times"])))
        #expect(broken.newItem == nil)
        #expect(PhoneContextModel.decision(consent: true, permission: .yes, for: broken) == .deny)
    }

    // MARK: TaskActivityModel

    func task(_ turn: String, step: Int, state: String = "running", started: Int64) -> [String: JSON] {
        ["type": "task", "turn_id": .string(turn), "step": .int(Int64(step)), "total": 5, "tool": "web_search",
         "label": "Searching the web", "state": .string(state), "started_at": .int(started)]
    }

    @Test func tasksShowOnlyTheNewestTurnOfTheActiveAgent() throws {
        let fixture = try ChatFixture()
        let tasks = TaskActivityModel(app: fixture.app)
        let home = try RelaySession(profile: fixture.home, mailStore: nil)
        let office = try RelaySession(profile: fixture.office, mailStore: nil)
        tasks.receive(task("new", step: 2, started: 2_000), from: home)
        tasks.receive(task("old", step: 4, started: 1_000), from: home)  // a late message of an older turn
        #expect(tasks.activeTask?.turnID == "new" && tasks.activeTask?.step == 2)
        tasks.receive(task("new", step: 3, state: "done", started: 2_000), from: home)
        tasks.receive(task("new", step: 4, started: 2_000), from: home)  // after the end: ignored
        #expect(tasks.activeTask?.state == .done && tasks.activeTask?.step == 3)
        tasks.receive(task("other", step: 1, started: 3_000), from: office)
        #expect(tasks.activeTask == nil, "another agent's task shows only in the Live Activity")
        tasks.receive(["type": "task", "turn_id": ""], from: home)  // invalid: ignored
        #expect(tasks.current?.turnID == "other")
    }

    // MARK: PlaceMonitor

    @Test func placeRemindersTellTheAgentWhatHappened() {
        let arrive = PlaceReminder(title: "Buy milk", note: "the oat one", placeName: "Market Hall", latitude: 52.5, longitude: 13.4,
                                   radius: 150, trigger: .enter, repeats: false, profileID: nil)
        #expect(PlaceMonitor.message(for: arrive) == "📍 I arrived at Market Hall. Reminder: Buy milk (the oat one)")
        let leave = PlaceReminder(title: "Lock the door", note: nil, placeName: "Home", latitude: 52.5, longitude: 13.4,
                                  radius: 150, trigger: .exit, repeats: true, profileID: nil)
        #expect(PlaceMonitor.message(for: leave) == "📍 I left Home. Reminder: Lock the door")
    }

    @Test func invalidPlaceRequestsAreUnavailable() async throws {
        let query = try #require(PhoneQuery.parse(ConsentApprovalTests.query(.geofence, params: ["action": "add", "title": "x"])))
        await #expect(throws: PhoneSourceUnavailable.self) {
            _ = try await PlaceMonitor.shared.handle(query, profileID: UUID())
        }
    }
}
