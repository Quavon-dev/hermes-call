import Foundation

/// What the agent may ask the phone for (docs/protocol.md, "Phone context").
public enum PhoneCapability: String, CaseIterable, Codable, Sendable, Identifiable {
    case location, battery, device, calendar, reminders, contacts, motion, focus
    case nowPlaying = "now_playing"
    case health, home, clipboard, photos, files, geofence
    /// Write capabilities: the agent asks to add something (shown to the owner before it is created).
    case reminderCreate = "reminder_create"
    case calendarCreate = "calendar_create"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .location: "Location"
        case .battery: "Battery"
        case .device: "Device status"
        case .calendar: "Calendar"
        case .reminders: "Reminders"
        case .contacts: "Contacts"
        case .motion: "Motion & steps"
        case .focus: "Focus"
        case .nowPlaying: "Now playing"
        case .health: "Health summary"
        case .home: "Home"
        case .clipboard: "Clipboard"
        case .photos: "Photos"
        case .files: "Files"
        case .geofence: "Place reminders"
        case .reminderCreate: "Add reminders"
        case .calendarCreate: "Add calendar events"
        }
    }

    public var symbol: String {
        switch self {
        case .location: "location.fill"
        case .battery: "battery.75percent"
        case .device: "iphone"
        case .calendar: "calendar"
        case .reminders: "checklist"
        case .contacts: "person.crop.circle"
        case .motion: "figure.walk"
        case .focus: "moon.fill"
        case .nowPlaying: "music.note"
        case .health: "heart.fill"
        case .home: "house.fill"
        case .clipboard: "doc.on.clipboard"
        case .photos: "photo.on.rectangle"
        case .files: "doc"
        case .geofence: "mappin.and.ellipse"
        case .reminderCreate: "checklist.checked"
        case .calendarCreate: "calendar.badge.plus"
        }
    }

    /// What an answer contains, in the owner's words.
    public var shares: String {
        switch self {
        case .location: "Where you are (about 1 km unless the agent asks for precise) and the place name."
        case .battery: "Battery level, charging and Low Power Mode."
        case .device: "Model, iOS version, network type, free storage, time zone."
        case .calendar: "Titles, times and places of your upcoming events (up to 14 days)."
        case .reminders: "Your open reminders with due dates."
        case .contacts: "Phone numbers and e-mail of contacts matching a name the agent names (up to 5)."
        case .motion: "Whether you walk, drive or sit still, and today's steps."
        case .focus: "Whether a Focus is on (not which one)."
        case .nowPlaying: "The song playing in the Music app."
        case .health: "Today's steps and active energy, last night's sleep, resting heart rate."
        case .home: "Your Home accessories, rooms, and whether they are on."
        case .clipboard: "The text on your clipboard."
        case .photos: "Photos you pick yourself."
        case .files: "Files you pick yourself."
        case .geofence: "Reminders for places (\"when I'm at the supermarket\"). This iPhone watches the place itself; your "
            + "location is never sent to the agent. With Yes, the agent also learns when a reminder fires."
        case .reminderCreate: "Adds a reminder (title, due date, note) to your Reminders. With Ask you see it before it is added."
        case .calendarCreate: "Adds an event (title, time, place, note) to your calendar. With Ask you see it before it is added."
        }
    }

    /// Changes something on the phone instead of reading it.
    public var writes: Bool { self == .reminderCreate || self == .calendarCreate }

    /// Clipboard and pickers always need the owner in the loop.
    public var allowsYes: Bool { ![.clipboard, .photos, .files].contains(self) }
    public var isPicker: Bool { self == .photos || self == .files }
    public var permissions: [PhonePermission] { allowsYes ? PhonePermission.allCases : [.no, .ask] }

    /// Seconds the owner has to answer (the bridge waits 10 s longer).
    public var answerWindow: TimeInterval { isPicker ? 120 : 60 }
}

public enum PhonePermission: String, CaseIterable, Codable, Sendable, Identifiable {
    case no, ask, yes
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .no: "No"
        case .ask: "Ask"
        case .yes: "Yes"
        }
    }
}

/// No / Ask / Yes per capability, in the app group (so extensions and intents can read them). Default: No.
public struct PhoneAccessSettings {
    public static let keyPrefix = "phoneAccess."
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = SharedContainer.defaults) {
        self.defaults = defaults
    }

    public func permission(for capability: PhoneCapability) -> PhonePermission {
        let stored = defaults.string(forKey: Self.keyPrefix + capability.rawValue).flatMap(PhonePermission.init(rawValue:)) ?? .no
        return stored == .yes && !capability.allowsYes ? .ask : stored
    }

    public func set(_ permission: PhonePermission, for capability: PhoneCapability) {
        let value = permission == .yes && !capability.allowsYes ? .ask : permission
        defaults.set(value.rawValue, forKey: Self.keyPrefix + capability.rawValue)
    }

    public func reset() {
        for capability in PhoneCapability.allCases { defaults.removeObject(forKey: Self.keyPrefix + capability.rawValue) }
    }
}

/// A `phone_query` from the bridge, validated.
public struct PhoneQuery: Sendable, Equatable, Identifiable {
    public let queryID: String
    public let capability: PhoneCapability
    public let reason: String
    public let expires: Date
    public let params: [String: JSON]

    public var id: String { queryID }

    public static let maxReason = 300

    public static func parse(_ body: [String: JSON], now: Date = Date()) -> PhoneQuery? {
        guard body["type"]?.string == "phone_query",
              let queryID = body["query_id"]?.string, (try? Base64URL.decode(queryID, length: 16)) != nil,
              let capability = body["capability"]?.string.flatMap(PhoneCapability.init(rawValue:)),
              let reason = body["reason"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !reason.isEmpty, reason.count <= maxReason,
              let expiresMs = body["expires"]?.int
        else { return nil }
        let expires = Date(timeIntervalSince1970: Double(expiresMs) / 1000)
        // Never keep a prompt open longer than the capability's window (+ clock skew), whatever the bridge says.
        let latest = now.addingTimeInterval(capability.answerWindow + 120)
        guard expires > now else { return nil }
        var params: [String: JSON] = [:]
        if case .object(let raw)? = body["params"] { params = raw }
        return PhoneQuery(queryID: queryID, capability: capability, reason: reason, expires: min(expires, latest), params: params)
    }

    public var precise: Bool { params["accuracy"]?.string == "precise" }
    public var days: Int { Self.clamp(params["days"]?.int, 1...14, default: 1) }
    public var limit: Int {
        capability == .reminders ? Self.clamp(params["limit"]?.int, 1...30, default: 15) : Self.clamp(params["limit"]?.int, 1...25, default: 10)
    }
    public var maxFiles: Int { Self.clamp(params["max"]?.int, 1...4, default: 1) }
    /// `reminder_create` / `calendar_create`: the item to add, validated; nil when the params are unusable.
    public var newItem: PhoneNewItem? { PhoneNewItem.parse(capability, params) }

    /// Contacts: the name to look up (required; never a full dump).
    public var name: String? {
        guard let name = params["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), (1...100).contains(name.count)
        else { return nil }
        return name
    }

    private static func clamp(_ value: Int64?, _ range: ClosedRange<Int>, default fallback: Int) -> Int {
        guard let value else { return fallback }
        return min(range.upperBound, max(range.lowerBound, Int(value)))
    }
}

/// A reminder or calendar event the agent asks to add (`reminder_create`: title, due?, notes?;
/// `calendar_create`: title, start, end, location?, notes?). Times are ISO 8601.
public struct PhoneNewItem: Sendable, Equatable {
    public let title: String
    public let notes: String?
    /// Reminder: when it is due (optional).
    public let due: Date?
    /// Event: start and end (end after start, at most 14 days long).
    public let start: Date?
    public let end: Date?
    public let location: String?

    public static let maxTitle = 200
    public static let maxNotes = 1000
    public static let maxLocation = 200

    static func parse(_ capability: PhoneCapability, _ params: [String: JSON]) -> PhoneNewItem? {
        guard capability.writes, let title = text(params["title"], maxTitle) else { return nil }
        let notes = text(params["notes"], maxNotes)
        switch capability {
        case .reminderCreate:
            var due: Date?
            if let raw = params["due"] {
                guard let parsed = date(raw) else { return nil }
                due = parsed
            }
            return PhoneNewItem(title: title, notes: notes, due: due, start: nil, end: nil, location: nil)
        case .calendarCreate:
            guard let start = params["start"].flatMap(date), let end = params["end"].flatMap(date), end > start,
                  end.timeIntervalSince(start) <= 14 * 86_400 else { return nil }
            return PhoneNewItem(title: title, notes: notes, due: nil, start: start, end: end,
                                location: text(params["location"], maxLocation))
        default:
            return nil
        }
    }

    private static func text(_ value: JSON?, _ limit: Int) -> String? {
        guard let raw = value?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty, raw.count <= limit else { return nil }
        return raw
    }

    private static func date(_ value: JSON) -> Date? {
        guard let text = value.string else { return nil }
        if let date = try? Date(text, strategy: .iso8601) { return date }
        return try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text)
    }
}

public enum PhoneAnswerStatus: String, Codable, Sendable {
    case ok, denied, unavailable, timeout
}

public enum PhoneAnswer {
    public static let maxData = 16 * 1024

    /// The `phone_answer` body; oversized data becomes `unavailable` (the bridge would reject it).
    public static func body(queryID: String, status: PhoneAnswerStatus, data: [String: JSON]? = nil) -> [String: JSON] {
        var body: [String: JSON] = ["type": "phone_answer", "query_id": .string(queryID), "status": .string(status.rawValue)]
        if status == .ok, let data {
            guard let size = try? JSON.object(data).encoded().count, size <= maxData else {
                body["status"] = .string(PhoneAnswerStatus.unavailable.rawValue)
                return body
            }
            body["data"] = .object(data)
        }
        return body
    }

    /// What the phone does before asking iOS for anything.
    public enum Decision: Equatable, Sendable { case deny, ask, answer }

    public static func decide(_ permission: PhonePermission, for capability: PhoneCapability) -> Decision {
        switch permission {
        case .no: .deny
        case .ask: .ask
        case .yes: capability.allowsYes ? .answer : .ask
        }
    }

    /// Approximate location: rounded to 2 decimals (≈ 1.1 km north–south).
    public static func coarse(_ degrees: Double) -> Double { (degrees * 100).rounded() / 100 }
}

/// Every query and its outcome, on this phone only (last 200).
public struct PhoneRequestRecord: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var date: Date
    public var capability: PhoneCapability
    public var reason: String
    public var agentName: String
    public var outcome: PhoneAnswerStatus
    /// False when the answer could not be sent to the bridge (the agent then saw a timeout).
    public var delivered: Bool?

    public init(id: UUID = UUID(), date: Date = Date(), capability: PhoneCapability, reason: String, agentName: String,
                outcome: PhoneAnswerStatus, delivered: Bool? = nil) {
        self.id = id
        self.date = date
        self.capability = capability
        self.reason = reason
        self.agentName = agentName
        self.outcome = outcome
        self.delivered = delivered
    }
}

public actor PhoneRequestLog {
    public static let maxEntries = 200
    public static let shared = PhoneRequestLog()
    private let url: URL

    public init(url: URL = SharedContainer.directory.appendingPathComponent("phone-requests.json")) {
        self.url = url
    }

    /// Newest first.
    public func entries() -> [PhoneRequestRecord] {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([PhoneRequestRecord].self, from: $0) } ?? []
    }

    public func append(_ record: PhoneRequestRecord) {
        let all = Array(([record] + entries()).prefix(Self.maxEntries))
        try? JSONEncoder().encode(all).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    public func deleteAll() {
        try? FileManager.default.removeItem(at: url)
    }
}
