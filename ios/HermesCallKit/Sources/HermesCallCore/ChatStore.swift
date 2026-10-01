import Foundation

/// An owner message that still has to reach the bridge.
public struct OutboxEntry: Sendable, Equatable {
    public let profile: UUID
    public let message: ChatMessage
}

/// History, outbox and attachments of each relay profile's chat, in the app group (the share and
/// notification extensions use it too). One SQLite database in WAL mode; every operation opens its
/// own short connection and writes in `BEGIN IMMEDIATE` transactions, so the app and the extensions
/// can write at the same time without losing anything, and no process keeps a lock while suspended.
/// Protected by iOS data protection until the first unlock after boot (database, WAL and attachments).
public actor ChatStore {
    public static let shared = ChatStore()

    private let root: URL
    private let changedSignal: String?
    /// The history files of older versions are moved into the database once they can be read.
    private var migrated = false
    /// The store's change counter as of this instance's last read or write (see `changedElsewhere`).
    private var knownRevision: Int64 = -1

    /// `changedSignal`: posted after every write (nil: silent, for tests).
    public init(root: URL = SharedContainer.directory.appendingPathComponent("Chats", isDirectory: true),
                changedSignal: String? = SharedSignal.chatChanged) {
        self.root = root
        self.changedSignal = changedSignal
    }

    public func attachmentDirectory(_ profile: UUID) -> URL {
        root.appendingPathComponent(profile.uuidString, isDirectory: true)
    }

    // MARK: reading

    /// The whole history, oldest first.
    public func messages(_ profile: UUID) -> [ChatMessage] {
        read { db in
            try bodies(db, "SELECT body FROM messages WHERE profile = ? ORDER BY date, row", [.text(profile.uuidString)])
        } ?? []
    }

    /// The newest `limit` messages, oldest first.
    public func latest(_ profile: UUID, limit: Int) -> [ChatMessage] {
        read { db in
            try bodies(db, "SELECT body FROM messages WHERE profile = ? ORDER BY date DESC, row DESC LIMIT ?",
                       [.text(profile.uuidString), .int(Int64(limit))]).reversed()
        } ?? []
    }

    /// Up to `limit` messages just before (or after) the message `id`, oldest first; empty when `id` is unknown.
    public func messages(_ profile: UUID, before id: String, limit: Int) -> [ChatMessage] {
        page(profile, anchor: id, older: true, limit: limit)
    }

    public func messages(_ profile: UUID, after id: String, limit: Int) -> [ChatMessage] {
        page(profile, anchor: id, older: false, limit: limit)
    }

    public func message(_ id: String, in profile: UUID) -> ChatMessage? {
        read { db in try bodies(db, "SELECT body FROM messages WHERE profile = ? AND id = ?", [.text(profile.uuidString), .text(id)]).first }
            ?? nil
    }

    public func count(_ profile: UUID) -> Int {
        read { db in
            var count = 0
            try db.query("SELECT COUNT(*) FROM messages WHERE profile = ?", [.text(profile.uuidString)]) { count = Int($0.int(0)) }
            return count
        } ?? 0
    }

    /// Messages whose text, transcript, attachment names or card titles contain `query` (case and
    /// diacritics ignored), newest first.
    public func search(_ profile: UUID, for query: String, limit: Int = 100) -> [ChatMessage] {
        let needle = Self.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !needle.isEmpty else { return [] }
        let escaped = needle.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return read { db in
            try bodies(db, "SELECT body FROM messages WHERE profile = ? AND search LIKE ? ESCAPE '\\' ORDER BY date DESC, row DESC LIMIT ?",
                       [.text(profile.uuidString), .text("%\(escaped)%"), .int(Int64(limit))])
        } ?? []
    }

    /// Owner messages not confirmed by the bridge yet (all profiles when nil), oldest first. Messages another
    /// process is sending right now (see `claim`) are left out.
    public func outbox(_ profile: UUID? = nil, now: Date = Date()) -> [OutboxEntry] {
        read { db in
            var entries: [OutboxEntry] = []
            let filter = profile == nil ? "" : "AND profile = ?"
            let values: [SQLiteValue] = [.real(now.timeIntervalSince1970)] + (profile.map { [.text($0.uuidString)] } ?? [])
            try db.query("""
                SELECT profile, body FROM messages WHERE role = 'owner' AND status IN ('pending', 'sent')
                AND (lease_until IS NULL OR lease_until < ?) \(filter) ORDER BY date, row
                """, values) { row in
                guard let id = row.text(0).flatMap(UUID.init(uuidString:)), let body = row.blob(1),
                      let message = try? JSONDecoder().decode(ChatMessage.self, from: body) else { return }
                entries.append(OutboxEntry(profile: id, message: message))
            }
            return entries
        } ?? []
    }

    /// True once after another process (or store instance) wrote since this instance last looked.
    public func changedElsewhere() -> Bool {
        let current = read { db in try revision(db) } ?? knownRevision
        defer { knownRevision = current }
        return current != knownRevision
    }

    // MARK: writing

    /// Inserts or replaces by id (ordered by date). Returns false when the id was already stored.
    @discardableResult
    public func upsert(_ message: ChatMessage, in profile: UUID) throws -> Bool {
        try write { db in
            var exists = false
            try db.query("SELECT 1 FROM messages WHERE profile = ? AND id = ?", [.text(profile.uuidString), .text(message.id)]) { _ in
                exists = true
            }
            try store(db, message, profile: profile)
            return !exists
        }
    }

    /// Stores the messages whose ids are not here yet (history from the bridge); returns those it stored.
    @discardableResult
    public func insertNew(_ messages: [ChatMessage], in profile: UUID) throws -> [ChatMessage] {
        try write { db in
            var added: [ChatMessage] = []
            for message in messages {
                var exists = false
                try db.query("SELECT 1 FROM messages WHERE profile = ? AND id = ?", [.text(profile.uuidString), .text(message.id)]) { _ in
                    exists = true
                }
                guard !exists else { continue }
                try store(db, message, profile: profile)
                added.append(message)
            }
            return added
        }
    }

    /// Changes a stored message; returns it as stored (nil when unknown).
    @discardableResult
    public func update(_ id: String, in profile: UUID, _ change: @Sendable (inout ChatMessage) -> Void) throws -> ChatMessage? {
        try write { db in
            guard var message = try bodies(db, "SELECT body FROM messages WHERE profile = ? AND id = ?",
                                           [.text(profile.uuidString), .text(id)]).first else { return nil }
            change(&message)
            try store(db, message, profile: profile)
            return message
        }
    }

    /// Deletes one message on this phone, with its files (the bridge keeps its own copy).
    public func delete(_ id: String, in profile: UUID) throws {
        let removed = try write { db -> ChatMessage? in
            let message = try bodies(db, "SELECT body FROM messages WHERE profile = ? AND id = ?",
                                     [.text(profile.uuidString), .text(id)]).first
            try db.run("DELETE FROM messages WHERE profile = ? AND id = ?", [.text(profile.uuidString), .text(id)])
            return message
        }
        guard let removed else { return }
        let directory = attachmentDirectory(profile)
        for file in Self.localFiles(removed) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
        }
    }

    /// Reserves an outbox message for one sender (`owner`) for `duration`, so the app and an extension
    /// never send it at the same time. True when this owner holds it now.
    public func claim(_ id: String, in profile: UUID, owner: String, for duration: TimeInterval, now: Date = Date()) -> Bool {
        (try? write { db in
            try db.run("""
                UPDATE messages SET lease_owner = ?, lease_until = ? WHERE profile = ? AND id = ?
                AND (lease_until IS NULL OR lease_until < ? OR lease_owner = ?)
                """, [.text(owner), .real(now.addingTimeInterval(duration).timeIntervalSince1970), .text(profile.uuidString), .text(id),
                      .real(now.timeIntervalSince1970), .text(owner)]) == 1
        }) ?? false
    }

    public func releaseClaim(_ id: String, in profile: UUID, owner: String) {
        _ = try? write { db in
            try db.run("UPDATE messages SET lease_owner = NULL, lease_until = NULL WHERE profile = ? AND id = ? AND lease_owner = ?",
                       [.text(profile.uuidString), .text(id), .text(owner)])
        }
    }

    /// Stores attachment bytes; returns the file name to put in `ChatAttachment.localFile`.
    public func saveAttachment(_ data: Data, id: String, name: String, in profile: UUID) throws -> String {
        let directory = attachmentDirectory(profile)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        let ext = (name as NSString).pathExtension.filter { $0.isLetter || $0.isNumber }.prefix(8)
        let fileName = ext.isEmpty ? id : "\(id).\(ext)"
        try data.write(to: directory.appendingPathComponent(fileName),
                       options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return fileName
    }

    public func deleteChat(_ profile: UUID) {
        _ = try? write { db in try db.run("DELETE FROM messages WHERE profile = ?", [.text(profile.uuidString)]) }
        try? FileManager.default.removeItem(at: attachmentDirectory(profile))
    }

    /// "Delete all data": the database (with its WAL) and every attachment.
    public func deleteAll() {
        try? FileManager.default.removeItem(at: root)
        knownRevision = -1
        if let changedSignal { SharedSignal.post(changedSignal) }
    }

    // MARK: database

    private var databasePath: String { root.appendingPathComponent("chat.sqlite").path }

    private func open() throws -> SQLiteConnection {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        let db = try SQLiteConnection(path: databasePath)
        try Self.prepare(db)
        if !migrated { migrated = try migrateJSONHistory(db) }
        return db
    }

    private func read<T>(_ body: (SQLiteConnection) throws -> T) -> T? {
        do {
            let db = try open()
            return try body(db)
        } catch {
            return nil
        }
    }

    private func write<T>(_ body: (SQLiteConnection) throws -> T) throws -> T {
        let db = try open()
        let result = try db.transaction {
            let result = try body(db)
            try db.run("UPDATE meta SET value = value + 1 WHERE key = 'revision'")
            knownRevision = try revision(db)
            return result
        }
        if let changedSignal { SharedSignal.post(changedSignal) }
        return result
    }

    private static let schemaVersion: Int64 = 1

    private static func prepare(_ db: SQLiteConnection) throws {
        try db.execute("PRAGMA synchronous = NORMAL")
        guard try version(db) < schemaVersion else { return }
        try db.execute("PRAGMA journal_mode = WAL")
        try db.transaction {
            guard try version(db) < schemaVersion else { return }
            try db.execute("""
                CREATE TABLE IF NOT EXISTS messages(
                    row INTEGER PRIMARY KEY AUTOINCREMENT,
                    profile TEXT NOT NULL, id TEXT NOT NULL, date REAL NOT NULL, role TEXT NOT NULL, status TEXT NOT NULL,
                    search TEXT NOT NULL, body BLOB NOT NULL, lease_owner TEXT, lease_until REAL,
                    UNIQUE(profile, id));
                CREATE INDEX IF NOT EXISTS messages_by_date ON messages(profile, date, row);
                CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value INTEGER NOT NULL);
                INSERT OR IGNORE INTO meta(key, value) VALUES ('revision', 0);
                PRAGMA user_version = \(schemaVersion);
                """)
        }
    }

    private static func version(_ db: SQLiteConnection) throws -> Int64 {
        var version: Int64 = 0
        try db.query("PRAGMA user_version") { version = $0.int(0) }
        return version
    }

    private func revision(_ db: SQLiteConnection) throws -> Int64 {
        var value: Int64 = 0
        try db.query("SELECT value FROM meta WHERE key = 'revision'") { value = $0.int(0) }
        return value
    }

    private func store(_ db: SQLiteConnection, _ message: ChatMessage, profile: UUID) throws {
        try db.run("""
            INSERT INTO messages(profile, id, date, role, status, search, body) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(profile, id) DO UPDATE SET date = excluded.date, role = excluded.role, status = excluded.status,
            search = excluded.search, body = excluded.body
            """, [.text(profile.uuidString), .text(message.id), .real(message.date.timeIntervalSince1970), .text(message.role.rawValue),
                  .text(message.status.rawValue), .text(Self.searchText(message)), .blob(try JSONEncoder().encode(message))])
    }

    private func bodies(_ db: SQLiteConnection, _ sql: String, _ values: [SQLiteValue]) throws -> [ChatMessage] {
        var messages: [ChatMessage] = []
        try db.query(sql, values) { row in
            if let body = row.blob(0), let message = try? JSONDecoder().decode(ChatMessage.self, from: body) { messages.append(message) }
        }
        return messages
    }

    private func page(_ profile: UUID, anchor id: String, older: Bool, limit: Int) -> [ChatMessage] {
        read { db in
            var position: (date: Double, row: Int64)?
            try db.query("SELECT date, row FROM messages WHERE profile = ? AND id = ?", [.text(profile.uuidString), .text(id)]) {
                position = ($0.real(0), $0.int(1))
            }
            guard let position else { return [] }
            let sql = older
                ? "SELECT body FROM messages WHERE profile = ? AND (date < ? OR (date = ? AND row < ?)) ORDER BY date DESC, row DESC LIMIT ?"
                : "SELECT body FROM messages WHERE profile = ? AND (date > ? OR (date = ? AND row > ?)) ORDER BY date, row LIMIT ?"
            let found = try bodies(db, sql, [.text(profile.uuidString), .real(position.date), .real(position.date), .int(position.row),
                                             .int(Int64(limit))])
            return older ? found.reversed() : found
        } ?? []
    }

    /// Moves `<profile>.json` files (versions before the database) into it. False while a file cannot be
    /// read yet (before the first unlock); tried again with the next operation.
    private func migrateJSONHistory(_ db: SQLiteConnection) throws -> Bool {
        let files = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
        var complete = true
        for file in files {
            guard let profile = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else { continue }
            guard let data = try? Data(contentsOf: file) else {
                complete = false
                continue
            }
            let messages = (try? JSONDecoder().decode([ChatMessage].self, from: data)) ?? []
            try db.transaction {
                for message in messages {
                    var exists = false
                    try db.query("SELECT 1 FROM messages WHERE profile = ? AND id = ?", [.text(profile.uuidString), .text(message.id)]) { _ in
                        exists = true
                    }
                    if !exists { try store(db, message.migratingLegacyCall(), profile: profile) }
                }
                try db.run("UPDATE meta SET value = value + 1 WHERE key = 'revision'")
            }
            try? FileManager.default.removeItem(at: file)
        }
        return complete
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// What search looks at.
    static func searchText(_ message: ChatMessage) -> String {
        var parts = [message.text, message.transcript ?? "", message.call?.text ?? ""]
        parts += message.attachments.map(\.name)
        if let presentation = message.presentation {
            parts.append(presentation.title)
            parts += presentation.items.flatMap { [$0.title, $0.subtitle ?? "", $0.detail ?? ""] }
        }
        return fold(parts.filter { !$0.isEmpty }.joined(separator: "\n"))
    }

    /// Files of a message kept in its chat's attachment directory.
    static func localFiles(_ message: ChatMessage) -> [String] {
        message.attachments.compactMap(\.localFile) + (message.presentation?.items.compactMap { $0.image?.localFile } ?? [])
    }
}
