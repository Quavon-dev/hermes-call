import Foundation

/// A place-based reminder the agent set (`geofence` capability). Stored and watched on this phone only.
public struct PlaceReminder: Codable, Sendable, Identifiable, Hashable {
    public enum Trigger: String, Codable, Sendable { case enter, exit }

    public let id: String
    public var title: String
    public var note: String?
    public var placeName: String
    public var latitude: Double
    public var longitude: Double
    public var radius: Double
    public var trigger: Trigger
    public var repeats: Bool
    public var created: Date
    /// Which paired agent set it (the "you arrived" message goes back to that one).
    public var profileID: UUID?

    public init(id: String = UUID().uuidString.lowercased(), title: String, note: String? = nil, placeName: String,
                latitude: Double, longitude: Double, radius: Double, trigger: Trigger, repeats: Bool,
                created: Date = Date(), profileID: UUID? = nil) {
        self.id = id
        self.title = title
        self.note = note
        self.placeName = placeName
        self.latitude = latitude
        self.longitude = longitude
        self.radius = radius
        self.trigger = trigger
        self.repeats = repeats
        self.created = created
        self.profileID = profileID
    }

    /// The `list` answer entry (never coordinates: the agent set them, and a query's result stays on the phone).
    public var summary: [String: JSON] {
        ["id": .string(id), "title": .string(title), "place_name": .string(placeName), "trigger": .string(trigger.rawValue),
         "repeat": .bool(repeats)]
    }
}

/// A validated `geofence` query (docs/protocol.md, "Phone context").
public enum GeofenceRequest: Sendable, Equatable {
    public enum Place: Sendable, Equatable {
        case coordinate(latitude: Double, longitude: Double, radius: Double)
        /// Resolved on the phone with Apple's place search near the current location.
        case query(String)
    }

    case add(title: String, note: String?, place: Place, trigger: PlaceReminder.Trigger, repeats: Bool)
    case remove(id: String)
    case list

    public static let radiusRange = 100.0...2000.0
    public static let defaultRadius = 150.0

    public static func parse(_ params: [String: JSON]) -> GeofenceRequest? {
        switch params["action"]?.string {
        case "list":
            return .list
        case "remove":
            guard let id = params["id"]?.string, (1...64).contains(id.count) else { return nil }
            return .remove(id: id)
        case "add":
            guard let title = trimmed(params["title"], max: 120), let place = parsePlace(params["place"]) else { return nil }
            var note: String?
            if let raw = params["note"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
                guard raw.count <= 500 else { return nil }
                note = raw
            }
            let trigger: PlaceReminder.Trigger
            switch params["trigger"]?.string {
            case nil, "enter": trigger = .enter
            case "exit": trigger = .exit
            default: return nil
            }
            return .add(title: title, note: note, place: place, trigger: trigger, repeats: params["repeat"]?.bool ?? false)
        default:
            return nil
        }
    }

    private static func trimmed(_ value: JSON?, max: Int) -> String? {
        guard let text = value?.string?.trimmingCharacters(in: .whitespacesAndNewlines), (1...max).contains(text.count) else { return nil }
        return text
    }

    private static func parsePlace(_ value: JSON?) -> Place? {
        if let query = trimmed(value?["query"], max: 120) { return .query(query) }
        guard let latitude = value?["lat"]?.number, let longitude = value?["lon"]?.number,
              (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        let radius = value?["radius_m"]?.number ?? defaultRadius
        guard radiusRange.contains(radius) else { return nil }
        return .coordinate(latitude: latitude, longitude: longitude, radius: radius)
    }
}

/// Place reminders on this phone (app group file). iOS monitors at most 20 regions per app.
public actor PlaceReminderStore {
    public static let maxReminders = 20
    public static let shared = PlaceReminderStore()
    private let url: URL

    public enum StoreError: Error, Equatable { case full }

    public init(url: URL = SharedContainer.directory.appendingPathComponent("place-reminders.json")) {
        self.url = url
    }

    public func all() -> [PlaceReminder] {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([PlaceReminder].self, from: $0) } ?? []
    }

    public func reminder(_ id: String) -> PlaceReminder? { all().first { $0.id == id } }

    public func add(_ reminder: PlaceReminder) throws {
        var reminders = all()
        guard reminders.count < Self.maxReminders else { throw StoreError.full }
        reminders.append(reminder)
        try save(reminders)
    }

    @discardableResult
    public func remove(_ id: String) -> Bool {
        var reminders = all()
        guard reminders.contains(where: { $0.id == id }) else { return false }
        reminders.removeAll { $0.id == id }
        try? save(reminders)
        return true
    }

    public func deleteAll() {
        try? FileManager.default.removeItem(at: url)
    }

    private func save(_ reminders: [PlaceReminder]) throws {
        try JSONEncoder().encode(reminders).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
