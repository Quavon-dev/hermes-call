import Foundation

/// One chat message as stored on this phone (history never leaves the device).
public struct ChatMessage: Codable, Sendable, Identifiable, Hashable {
    public enum Role: String, Codable, Sendable { case owner, agent, system }

    public enum Status: String, Codable, Sendable {
        /// Owner messages: waiting for the relay, handed to the relay, confirmed by the bridge, gave up.
        case pending, sent, delivered, failed
        /// Agent and system messages.
        case received
    }

    public let id: String
    public var role: Role
    /// `text`, `missed_call`, `declined_call`, `call` (local call summary), `approval`.
    public var kind: String
    public var text: String
    public var attachments: [ChatAttachment]
    public var date: Date
    public var status: Status
    /// Voice notes: what the bridge understood.
    public var transcript: String?
    public var replyTo: String?
    /// Result cards (`kind == "presentation"`).
    public var presentation: Presentation?

    public init(id: String, role: Role, kind: String = "text", text: String, attachments: [ChatAttachment] = [],
                date: Date = Date(), status: Status, transcript: String? = nil, replyTo: String? = nil,
                presentation: Presentation? = nil) {
        self.id = id
        self.role = role
        self.kind = kind
        self.text = text
        self.attachments = attachments
        self.date = date
        self.status = status
        self.transcript = transcript
        self.replyTo = replyTo
        self.presentation = presentation
    }

    /// One line for notifications, the widget and Siri.
    public var preview: String {
        switch kind {
        case "missed_call": return "Missed call: \(text)"
        case "declined_call": return "Declined call: \(text)"
        case "presentation" where presentation != nil:
            let count = presentation?.items.count ?? 0
            return "\(presentation?.title ?? "Results") · \(count) \(count == 1 ? "item" : "items")"
        default: break
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return ChatText.plain(trimmed) }
        guard let first = attachments.first else { return "" }
        switch first.kind {
        case .photo: return "📷 Photo"
        case .voice: return "🎙 Voice note"
        case .file: return "📎 \(first.name)"
        }
    }
}

public struct ChatAttachment: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable { case photo, voice, file }

    public let id: String
    public var kind: Kind
    public var name: String
    public var mime: String
    public var size: Int
    /// File name inside the chat's attachment directory, once the bytes are on this phone.
    public var localFile: String?
    /// Agent attachments not downloaded yet: relay blob and its key.
    public var blobID: String?
    public var key: String?
    public var duration: Double?

    public init(id: String = UUID().uuidString, kind: Kind, name: String, mime: String, size: Int, localFile: String? = nil,
                blobID: String? = nil, key: String? = nil, duration: Double? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.mime = mime
        self.size = size
        self.localFile = localFile
        self.blobID = blobID
        self.key = key
        self.duration = duration
    }
}

public enum ChatText {
    /// Markdown reduced to plain text for previews (lock screen, widget).
    public static func plain(_ markdown: String, limit: Int = 280) -> String {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let text = (try? AttributedString(markdown: markdown, options: options)).map { String($0.characters) } ?? markdown
        let line = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }
}

/// History and attachments of each relay profile's chat, in the app group (readable by the
/// extensions), protected by iOS data protection until the first unlock after boot.
public actor ChatStore {
    public static let maxMessages = 3000
    public static let shared = ChatStore()

    private let root: URL
    /// Messages and the file's modification date when read: the share extension writes too.
    private var cache: [UUID: (messages: [ChatMessage], modified: Date?)] = [:]

    public init(root: URL = SharedContainer.directory.appendingPathComponent("Chats", isDirectory: true)) {
        self.root = root
    }

    private func file(_ profile: UUID) -> URL { root.appendingPathComponent("\(profile.uuidString).json") }

    public func attachmentDirectory(_ profile: UUID) -> URL {
        root.appendingPathComponent(profile.uuidString, isDirectory: true)
    }

    public func messages(_ profile: UUID) -> [ChatMessage] {
        let modified = modificationDate(profile)
        if let cached = cache[profile], cached.modified == modified { return cached.messages }
        let loaded = (try? Data(contentsOf: file(profile))).flatMap { try? JSONDecoder().decode([ChatMessage].self, from: $0) } ?? []
        cache[profile] = (loaded, modified)
        return loaded
    }

    private func modificationDate(_ profile: UUID) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: file(profile).path))?[.modificationDate] as? Date
    }

    /// Inserts or replaces by id, keeping date order. Returns false when the id was already stored.
    @discardableResult
    public func upsert(_ message: ChatMessage, in profile: UUID) throws -> Bool {
        var all = messages(profile)
        let isNew: Bool
        if let index = all.firstIndex(where: { $0.id == message.id }) {
            all[index] = message
            isNew = false
        } else {
            let index = all.lastIndex { $0.date <= message.date }.map { $0 + 1 } ?? 0
            all.insert(message, at: index)
            isNew = true
        }
        try write(trimmed(all, profile: profile), profile: profile)
        return isNew
    }

    public func update(_ id: String, in profile: UUID, _ change: @Sendable (inout ChatMessage) -> Void) throws {
        var all = messages(profile)
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        change(&all[index])
        try write(all, profile: profile)
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
        cache[profile] = nil
        try? FileManager.default.removeItem(at: file(profile))
        try? FileManager.default.removeItem(at: attachmentDirectory(profile))
    }

    public func deleteAll() {
        cache = [:]
        try? FileManager.default.removeItem(at: root)
    }

    private func trimmed(_ all: [ChatMessage], profile: UUID) -> [ChatMessage] {
        guard all.count > Self.maxMessages else { return all }
        let dropped = all.prefix(all.count - Self.maxMessages)
        let directory = attachmentDirectory(profile)
        for file in dropped.flatMap(\.attachments).compactMap(\.localFile) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
        }
        return Array(all.suffix(Self.maxMessages))
    }

    private func write(_ all: [ChatMessage], profile: UUID) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        try JSONEncoder().encode(all).write(to: file(profile), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        cache[profile] = (all, modificationDate(profile))
    }
}

/// The newest message for the home-screen widget.
public struct ChatSnapshot: Codable, Sendable, Hashable {
    public var agentName: String
    public var preview: String
    public var date: Date
    public var fromAgent: Bool

    public init(agentName: String, preview: String, date: Date, fromAgent: Bool) {
        self.agentName = agentName
        self.preview = preview
        self.date = date
        self.fromAgent = fromAgent
    }

    static var url: URL { SharedContainer.directory.appendingPathComponent("widget.json") }

    public static func load() -> ChatSnapshot? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(ChatSnapshot.self, from: $0) }
    }

    public func save() {
        try? JSONEncoder().encode(self).write(to: Self.url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    public static func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// E2E chat message bodies (docs/protocol.md, "Chat") ⇄ `ChatMessage`.
public enum ChatWire {
    public static let maxText = 12_000
    static let kinds: Set<String> = ["text", "missed_call", "declined_call", "presentation"]

    /// A `chat` body from the bridge (agent reply, or the owner's message mirrored from another phone).
    public static func message(from body: [String: JSON], date: Date = Date()) -> ChatMessage? {
        guard body["type"]?.string == "chat", let id = body["id"]?.string, (try? Base64URL.decode(id, length: 16)) != nil
        else { return nil }
        let role: ChatMessage.Role = body["role"]?.string == "owner" ? .owner : .agent
        let kind = body["kind"]?.string.flatMap { kinds.contains($0) ? $0 : nil } ?? "text"
        let text = String((body["text"]?.string ?? "").prefix(maxText))
        var attachments: [ChatAttachment] = []
        if case .array(let raw)? = body["attachments"] {
            for item in raw.prefix(4) {
                guard let kindName = item["kind"]?.string, let kind = ChatAttachment.Kind(rawValue: kindName),
                      let blobID = item["blob_id"]?.string, let key = item["key"]?.string,
                      (try? Base64URL.decode(key, length: 32)) != nil else { continue }
                let name = String((item["name"]?.string ?? kindName).prefix(120))
                attachments.append(ChatAttachment(kind: kind, name: name, mime: item["mime"]?.string ?? "application/octet-stream",
                                                  size: Int(item["size"]?.int ?? 0), blobID: blobID, key: key))
            }
        }
        let presentation = kind == "presentation" && role == .agent ? Presentation.parse(body["presentation"]) : nil
        guard !text.isEmpty || !attachments.isEmpty || presentation != nil else { return nil }
        let status: ChatMessage.Status = role == .owner ? .delivered : .received
        return ChatMessage(id: id, role: role, kind: presentation == nil && kind == "presentation" ? "text" : kind, text: text,
                           attachments: attachments, date: date, status: status, replyTo: body["reply_to"]?.string,
                           presentation: presentation)
    }

    /// The body the phone sends for an owner message whose attachments are already uploaded.
    /// `voiceReplies`: a voice note asks the agent to answer by voice too (ignored without a voice attachment).
    public static func body(for message: ChatMessage, uploads: [(attachment: ChatAttachment, blobID: String, key: Data)],
                            voiceReplies: Bool = false) -> [String: JSON] {
        var body: [String: JSON] = ["type": "chat", "id": .string(message.id), "text": .string(message.text)]
        if voiceReplies, message.attachments.contains(where: { $0.kind == .voice }) { body["voice_replies"] = true }
        if let replyTo = message.replyTo { body["reply_to"] = .string(replyTo) }
        body["attachments"] = .array(uploads.map { upload in
            .object([
                "kind": .string(upload.attachment.kind.rawValue), "blob_id": .string(upload.blobID),
                "key": .string(Base64URL.encode(upload.key)), "name": .string(upload.attachment.name),
                "mime": .string(upload.attachment.mime),
            ])
        })
        return body
    }
}
