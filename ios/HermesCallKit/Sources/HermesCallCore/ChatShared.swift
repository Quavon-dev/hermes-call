import Foundation

/// A paired agent as the extensions see it (widget agent picker, share sheet default): no keys.
public struct AgentInfo: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public var name: String
    /// `AgentPalette` raw value.
    public var palette: String

    public init(id: UUID, name: String, palette: String) {
        self.id = id
        self.name = name
        self.palette = palette
    }
}

/// The paired agents and which one is active, written by the app into the app group.
public enum AgentDirectory {
    static let agentsKey = "agents"
    static let activeKey = "agents.active"

    public static func save(_ agents: [AgentInfo], active: UUID?, defaults: UserDefaults = SharedContainer.defaults) {
        defaults.set(try? JSONEncoder().encode(agents), forKey: agentsKey)
        defaults.set(active?.uuidString, forKey: activeKey)
    }

    public static func agents(defaults: UserDefaults = SharedContainer.defaults) -> [AgentInfo] {
        defaults.data(forKey: agentsKey).flatMap { try? JSONDecoder().decode([AgentInfo].self, from: $0) } ?? []
    }

    public static func activeID(defaults: UserDefaults = SharedContainer.defaults) -> UUID? {
        defaults.string(forKey: activeKey).flatMap(UUID.init(uuidString:))
    }

    public static func clear(defaults: UserDefaults = SharedContainer.defaults) {
        defaults.removeObject(forKey: agentsKey)
        defaults.removeObject(forKey: activeKey)
    }
}

/// The app icon badge: unread agent messages, counted by the notification extension and the app.
public enum ChatBadge {
    static let key = "badge.unread"

    /// Adds one; returns the new count.
    @discardableResult
    public static func increment(defaults: UserDefaults = SharedContainer.defaults) -> Int {
        let count = defaults.integer(forKey: key) + 1
        defaults.set(count, forKey: key)
        return count
    }

    public static func count(defaults: UserDefaults = SharedContainer.defaults) -> Int { defaults.integer(forKey: key) }

    public static func reset(defaults: UserDefaults = SharedContainer.defaults) {
        defaults.set(0, forKey: key)
    }

    /// The app's own count (the sum of `UnreadCounts`) replaces what the notification extension added.
    public static func set(_ count: Int, defaults: UserDefaults = SharedContainer.defaults) {
        defaults.set(max(count, 0), forKey: key)
    }
}

/// The newest message per agent for the widgets (and the newest overall).
public struct ChatSnapshot: Codable, Sendable, Hashable {
    public var agentName: String
    public var preview: String
    public var date: Date
    public var fromAgent: Bool
    public var profileID: UUID?

    public init(agentName: String, preview: String, date: Date, fromAgent: Bool, profileID: UUID? = nil) {
        self.agentName = agentName
        self.preview = preview
        self.date = date
        self.fromAgent = fromAgent
        self.profileID = profileID
    }

    static func url(_ profile: UUID?, directory: URL) -> URL {
        directory.appendingPathComponent(profile.map { "widget-\($0.uuidString).json" } ?? "widget.json")
    }

    /// The newest message of `profile`, or the newest of all agents when nil.
    public static func load(profile: UUID? = nil, directory: URL = SharedContainer.directory) -> ChatSnapshot? {
        (try? Data(contentsOf: url(profile, directory: directory))).flatMap { try? JSONDecoder().decode(ChatSnapshot.self, from: $0) }
    }

    public func save(directory: URL = SharedContainer.directory) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        let targets: [UUID?] = profileID.map { [nil, $0] } ?? [nil]
        for target in targets {
            try? data.write(to: Self.url(target, directory: directory), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    public static func clear(directory: URL = SharedContainer.directory) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix("widget") && file.pathExtension == "json" {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
