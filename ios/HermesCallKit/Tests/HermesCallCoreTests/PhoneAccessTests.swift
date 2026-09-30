import Foundation
import Testing
@testable import HermesCallCore

struct PhoneAccessTests {
    let queryID = Base64URL.encode(Data(repeating: 7, count: 16))
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func body(_ capability: String = "location", reason: String = "Find restaurants nearby",
              expiresIn: TimeInterval = 60, params: [String: JSON] = [:]) -> [String: JSON] {
        ["type": "phone_query", "query_id": .string(queryID), "capability": .string(capability), "reason": .string(reason),
         "expires": .int(Int64((now.timeIntervalSince1970 + expiresIn) * 1000)), "params": .object(params)]
    }

    func settings() -> PhoneAccessSettings {
        PhoneAccessSettings(defaults: UserDefaults(suiteName: "hermescall.tests.\(UUID().uuidString)")!)
    }

    @Test func everythingIsNoByDefault() {
        let settings = settings()
        for capability in PhoneCapability.allCases { #expect(settings.permission(for: capability) == .no) }
    }

    @Test func clipboardAndPickersNeverAnswerWithoutTheOwner() {
        let settings = settings()
        for capability in [PhoneCapability.clipboard, .photos, .files] {
            settings.set(.yes, for: capability)
            #expect(settings.permission(for: capability) == .ask)
            #expect(PhoneAnswer.decide(.yes, for: capability) == .ask)
            #expect(!capability.permissions.contains(.yes))
        }
        settings.set(.yes, for: .battery)
        #expect(settings.permission(for: .battery) == .yes)
        #expect(PhoneAnswer.decide(.yes, for: .battery) == .answer)
        #expect(PhoneAnswer.decide(.no, for: .battery) == .deny)
        settings.reset()
        #expect(settings.permission(for: .battery) == .no)
    }

    @Test func validQueryParses() throws {
        let query = try #require(PhoneQuery.parse(body(params: ["accuracy": "precise"]), now: now))
        #expect(query.capability == .location && query.precise && query.reason == "Find restaurants nearby")
        #expect(query.expires.timeIntervalSince(now) == 60)
    }

    @Test func invalidQueriesAreDropped() {
        #expect(PhoneQuery.parse(body("camera"), now: now) == nil)
        #expect(PhoneQuery.parse(body(reason: "  "), now: now) == nil)
        #expect(PhoneQuery.parse(body(reason: String(repeating: "a", count: 301)), now: now) == nil)
        #expect(PhoneQuery.parse(body(expiresIn: -1), now: now) == nil)
        var badID = body()
        badID["query_id"] = "short"
        #expect(PhoneQuery.parse(badID, now: now) == nil)
    }

    @Test func promptsNeverOutliveTheirWindow() throws {
        let query = try #require(PhoneQuery.parse(body(expiresIn: 3600), now: now))
        #expect(query.expires.timeIntervalSince(now) == 180)
    }

    @Test func paramsAreClamped() throws {
        let calendar = try #require(PhoneQuery.parse(body("calendar", params: ["days": 99, "limit": 0]), now: now))
        #expect(calendar.days == 14 && calendar.limit == 1)
        let reminders = try #require(PhoneQuery.parse(body("reminders"), now: now))
        #expect(reminders.limit == 15)
        let photos = try #require(PhoneQuery.parse(body("photos", params: ["max": 9]), now: now))
        #expect(photos.maxFiles == 4 && photos.capability.answerWindow == 120)
        let contacts = try #require(PhoneQuery.parse(body("contacts"), now: now))
        #expect(contacts.name == nil)
    }

    @Test func answerBodiesStayMinimal() {
        let ok = PhoneAnswer.body(queryID: queryID, status: .ok, data: ["level": .double(0.5)])
        #expect(ok["status"]?.string == "ok" && ok["data"]?["level"] == .double(0.5))
        let denied = PhoneAnswer.body(queryID: queryID, status: .denied, data: ["level": .double(0.5)])
        #expect(denied["data"] == nil)
        let huge = PhoneAnswer.body(queryID: queryID, status: .ok, data: ["text": .string(String(repeating: "x", count: 20_000))])
        #expect(huge["status"]?.string == "unavailable" && huge["data"] == nil)
        #expect(PhoneAnswer.coarse(48.137_154) == 48.14)
    }

    @Test func requestLogKeepsTheNewest200() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        let log = PhoneRequestLog(url: url)
        for index in 0..<205 {
            await log.append(PhoneRequestRecord(capability: .battery, reason: "r\(index)", agentName: "Hermes", outcome: .ok))
        }
        let entries = await log.entries()
        #expect(entries.count == 200 && entries.first?.reason == "r204")
        await log.deleteAll()
        #expect(await log.entries().isEmpty)
    }
}

struct PresentationTests {
    let key = Base64URL.encode(Data(repeating: 1, count: 32))

    func chat(_ presentation: JSON, text: String = "Restaurants") -> [String: JSON] {
        ["type": "chat", "id": .string(Base64URL.encode(Data(repeating: 2, count: 16))), "role": "agent",
         "kind": "presentation", "text": .string(text), "presentation": presentation]
    }

    @Test func placesParse() throws {
        let raw: JSON = ["title": "Restaurants near you", "kind": "places", "items": .array([
            ["title": "Trattoria", "subtitle": "Italian", "url": "https://example.com/t", "lat": .double(48.1), "lon": .double(11.5),
             "image": ["blob_id": "abc", "key": .string(key), "size": 1200],
             "actions": .array([["label": "Call", "tel": "+49 89 123"], ["label": "Route", "maps": true],
                                ["label": "Menu", "url": "https://example.com/m"]])],
        ])]
        let message = try #require(ChatWire.message(from: chat(raw)))
        let presentation = try #require(message.presentation)
        #expect(message.kind == "presentation" && presentation.kind == .places)
        let item = presentation.items[0]
        #expect(item.hasLocation && item.image?.blobID == "abc" && item.actions.count == 3)
        #expect(item.actions[0].target == .tel("+49 89 123") && item.actions[1].target == .maps)
        #expect(message.preview == "Restaurants near you · 1 item")
        #expect(Presentation.telURL("+49 (89) 123")?.absoluteString == "tel:+4989123")
    }

    @Test func unsafeLinksAndBadValuesAreDropped() throws {
        let raw: JSON = ["title": "Links", "items": .array([
            ["title": "a", "url": "http://example.com", "lat": .double(95), "lon": .double(11),
             "actions": .array([["label": "x", "url": "javascript:alert(1)"], ["label": "y", "tel": "call me"],
                                ["label": "z", "maps": true], ["label": "w", "url": "https://user@evil.com"]])],
            ["subtitle": "no title"],
        ])]
        let presentation = try #require(ChatWire.message(from: chat(raw))?.presentation)
        #expect(presentation.kind == .list && presentation.items.count == 1)
        let item = presentation.items[0]
        #expect(item.url == nil && !item.hasLocation && item.actions.isEmpty)
    }

    @Test func atMostTenItemsAndBoundedText() throws {
        let items = (0..<15).map { index -> JSON in ["title": .string(String(repeating: "t", count: 500) + "\(index)")] }
        let presentation = try #require(Presentation.parse(["title": "Many", "items": .array(items)]))
        #expect(presentation.items.count == 10 && presentation.items[0].title.count == 120)
    }

    @Test func unusablePresentationFallsBackToText() throws {
        let message = try #require(ChatWire.message(from: chat(["title": "Empty", "items": .array([])], text: "Nothing found")))
        #expect(message.presentation == nil && message.kind == "text" && message.text == "Nothing found")
    }
}
