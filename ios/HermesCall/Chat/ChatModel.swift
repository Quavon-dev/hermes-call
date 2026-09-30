import Foundation
import HermesCallCore
import LocalAuthentication
import os
import UIKit
import UniformTypeIdentifiers
import WidgetKit

/// A file the owner attaches to a message.
struct OutgoingFile: Sendable {
    let kind: ChatAttachment.Kind
    let name: String
    let mime: String
    let data: Data
    var duration: Double?
}

struct ChatApproval: Identifiable, Equatable {
    let id: String
    let profileID: UUID
    let command: String
    let details: String
    /// Acked in the relay mailbox only once answered, so the request survives the app being closed.
    let mailID: String?
}

/// The chat with the agent of each paired relay: history on this phone, an outbox that survives
/// being offline, agent replies from the relay mailbox, attachments and chat approvals.
@MainActor @Observable
final class ChatModel {
    private(set) var messages: [ChatMessage] = []
    private(set) var agentTyping = false
    private(set) var unread = 0
    var pendingApproval: ChatApproval?
    /// The newest result cards, unfolded on the presence (Home in HUD appearance, the call screen) until dismissed.
    private(set) var spotlight: ChatMessage?
    /// Plays voice notes and voice replies (the presence shows what it plays).
    let player = VoicePlayer()
    /// Set by the app: voice replies never play over a call.
    var isInCall: () -> Bool = { false }
    /// The chat screen is on screen (no banners for it, no unread count).
    var isVisible = false { didSet { if isVisible { unread = 0 } } }

    static let ackTimeout: Duration = .seconds(20)
    /// The bridge forgets chat approval requests after 10 minutes.
    static let approvalLifetimeMs: Int64 = 600_000
    static let callMeText = "Please call me when you can."
    private nonisolated static let chatTypes: Set<String> = ["chat", "chat_ack", "typing", "approval_done"]

    private let app: AppModel
    private let store: ChatStore
    private let log = Logger(subsystem: "de.quavon.hermescall", category: "chat")
    private var shownProfile: UUID?
    private var typingReset: Task<Void, Never>?
    private var acks: [String: CheckedContinuation<Bool, Never>] = [:]
    private var inFlight: Set<String> = []
    private var approvalAnswering = false

    init(app: AppModel, store: ChatStore = .shared) {
        self.app = app
        self.store = store
    }

    /// Messages the chat takes from the shared relay connections.
    nonisolated static func handles(_ message: [String: JSON]) -> Bool {
        guard let type = message["type"]?.string else { return false }
        return chatTypes.contains(type) || (type == "approval_request" && message["chat"]?.bool == true)
    }

    var agentName: String { app.activeProfile?.bridgeName ?? RelayProfile.defaultAgentName }

    func attachmentURL(_ attachment: ChatAttachment) async -> URL? {
        await fileURL(attachment.localFile)
    }

    /// A downloaded file of the shown chat (attachments, result card images).
    func fileURL(_ localFile: String?) async -> URL? {
        guard let profile = shownProfile, let localFile else { return nil }
        return await store.attachmentDirectory(profile).appendingPathComponent(localFile)
    }

    func dismissSpotlight() { spotlight = nil }

    /// The relay profile whose chat `messages` holds (it lags behind an agent switch while reloading).
    var shownProfileID: UUID? { shownProfile }

    /// Shows stored result cards on the presence again (from the chat).
    func showOnPresence(_ message: ChatMessage) {
        guard message.presentation != nil else { return }
        spotlight = message
    }

    /// Shows the active relay's chat.
    func reload() async {
        let profile = app.activeProfile?.id
        shownProfile = profile
        messages = profile == nil ? [] : await store.messages(profile!)
        agentTyping = false
    }

    // MARK: incoming

    func receive(_ body: [String: JSON], from session: RelaySession) {
        let profile = session.profile
        let mailID = body["mail_id"]?.string
        Task {
            switch body["type"]?.string {
            case "chat": await receiveChat(body, profile: profile, session: session)
            case "chat_ack": await receiveAck(body, profile: profile.id)
            case "typing" where profile.id == shownProfile: showTyping()
            case "approval_request":
                if showApproval(body, profile: profile.id, mailID: mailID) { return }
            case "approval_done":
                if let pending = pendingApproval, pending.id == body["request_id"]?.string {
                    pendingApproval = nil
                    if let pendingMail = pending.mailID { try? await session.ackMail([pendingMail]) }
                }
            default: break
            }
            if let mailID { try? await session.ackMail([mailID]) }
        }
    }

    private func receiveChat(_ body: [String: JSON], profile: RelayProfile, session: RelaySession) async {
        guard var message = ChatWire.message(from: body) else { return }
        for index in message.attachments.indices {
            message.attachments[index] = await download(message.attachments[index], profile: profile.id, session: session)
        }
        if var presentation = message.presentation {
            for index in presentation.items.indices {
                presentation.items[index].image = await downloadImage(presentation.items[index].image, name: "\(message.id)-\(index)",
                                                                      profile: profile.id, session: session)
            }
            message.presentation = presentation
        }
        do {
            guard try await store.upsert(message, in: profile.id) else { return }
        } catch {
            log.error("storing a message failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        if message.role == .agent {
            agentTyping = false
            autoPlay(message, profile: profile.id)
            if message.presentation != nil, profile.id == app.activeProfile?.id { spotlight = message }
            saveSnapshot(message, agentName: profile.bridgeName)
            if !(isVisible && profile.id == shownProfile) { unread += 1 }
        }
        if profile.id == shownProfile { messages = await store.messages(profile.id) }
    }

    /// A voice reply plays by itself when the owner wants it, the app is open and no call is on.
    private func autoPlay(_ message: ChatMessage, profile: UUID) {
        guard app.preferences.voiceReplies, app.preferences.autoPlayVoiceReplies, app.isForeground, !isInCall(),
              profile == app.activeProfile?.id, Date().timeIntervalSince(message.date) < 120,
              let voice = message.attachments.first(where: { $0.kind == .voice }), let file = voice.localFile else { return }
        Task { player.play(id: voice.id, url: await store.attachmentDirectory(profile).appendingPathComponent(file)) }
    }

    /// Agent attachments are fetched right away (the relay keeps them 7 days) and deleted there.
    private func download(_ attachment: ChatAttachment, profile: UUID, session: RelaySession) async -> ChatAttachment {
        guard let blobID = attachment.blobID, let keyText = attachment.key,
              let key = try? Base64URL.decode(keyText, length: 32) else { return attachment }
        do {
            let data = try Blob.open(try await session.downloadBlob(blobID), key: key)
            var stored = attachment
            stored.localFile = try await store.saveAttachment(data, id: attachment.id, name: attachment.name, in: profile)
            stored.size = data.count
            stored.blobID = nil
            stored.key = nil
            try? await session.deleteBlob(blobID)
            return stored
        } catch {
            log.error("attachment download failed: \(String(describing: error), privacy: .public)")
            return attachment
        }
    }

    /// Card images come as encrypted blobs from the bridge (it fetched them; the phone never contacts third parties).
    private func downloadImage(_ image: Presentation.Image?, name: String, profile: UUID,
                               session: RelaySession) async -> Presentation.Image? {
        guard var image, let blobID = image.blobID, let keyText = image.key,
              let key = try? Base64URL.decode(keyText, length: 32) else { return image }
        do {
            let data = try Blob.open(try await session.downloadBlob(blobID), key: key)
            guard UIImage(data: data) != nil else { return nil }
            image.localFile = try await store.saveAttachment(data, id: name, name: "card.jpg", in: profile)
            image.blobID = nil
            image.key = nil
            try? await session.deleteBlob(blobID)
            return image
        } catch {
            log.error("card image download failed: \(String(describing: error), privacy: .public)")
            return image
        }
    }

    private func receiveAck(_ body: [String: JSON], profile: UUID) async {
        guard let id = body["id"]?.string else { return }
        let transcript = body["transcript"]?.string
        try? await store.update(id, in: profile) { message in
            message.status = .delivered
            if let transcript { message.transcript = transcript }
        }
        acks.removeValue(forKey: id)?.resume(returning: true)
        if profile == shownProfile { messages = await store.messages(profile) }
    }

    /// The widget shows the newest message (or only that there is one, when previews are off).
    private func saveSnapshot(_ message: ChatMessage, agentName: String) {
        let preview = app.preferences.showMessageText ? message.preview : "New message"
        ChatSnapshot(agentName: agentName, preview: preview, date: message.date, fromAgent: message.role == .agent).save()
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func showTyping() {
        agentTyping = true
        typingReset?.cancel()
        typingReset = Task {
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled { agentTyping = false }
        }
    }

    /// True when the request is shown (its mail is acked once answered).
    private func showApproval(_ body: [String: JSON], profile: UUID, mailID: String?) -> Bool {
        let age = Int64(Date().timeIntervalSince1970 * 1000) - (body["ts"]?.int ?? 0)
        guard age < Self.approvalLifetimeMs, let id = body["request_id"]?.string, !id.isEmpty,
              let command = body["command"]?.string, command.count <= CallCoordinator.maxApprovalText,
              let details = body["description"]?.string, details.count <= CallCoordinator.maxApprovalText,
              pendingApproval == nil || pendingApproval?.id == id
        else { return false }
        pendingApproval = ChatApproval(id: id, profileID: profile, command: command, details: details, mailID: mailID)
        return true
    }

    /// Approving needs Face ID / passcode; denying never does.
    func answerApproval(approve: Bool) async {
        guard let approval = pendingApproval, !approvalAnswering,
              let profile = app.profiles.first(where: { $0.id == approval.profileID }) else { return }
        approvalAnswering = true
        defer { approvalAnswering = false }
        var choice = "deny"
        if approve {
            let reason = "Approve the command your assistant wants to run."
            if (try? await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) == true {
                choice = "once"
            }
        }
        guard pendingApproval?.id == approval.id else { return }
        pendingApproval = nil
        await withSession(profile) { session in
            try await session.send(["type": "approval", "request_id": .string(approval.id), "choice": .string(choice)], mail: true)
            if let mailID = approval.mailID { try await session.ackMail([mailID]) }
        }
    }

    // MARK: outgoing

    /// Stores the message first (so nothing typed is lost), then sends it.
    func send(text: String, files: [OutgoingFile] = [], profileID: UUID? = nil) async {
        guard let profile = profileID.flatMap({ id in app.profiles.first { $0.id == id } }) ?? app.activeProfile else { return }
        let trimmed = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(ChatWire.maxText))
        guard !trimmed.isEmpty || !files.isEmpty else { return }
        var message = ChatMessage(id: E2EChannel.newMessageID(), role: .owner, text: trimmed, status: .pending)
        do {
            for file in files.prefix(4) {
                var attachment = ChatAttachment(kind: file.kind, name: file.name, mime: file.mime, size: file.data.count,
                                                duration: file.duration)
                attachment.localFile = try await store.saveAttachment(file.data, id: attachment.id, name: file.name, in: profile.id)
                message.attachments.append(attachment)
            }
            try await store.upsert(message, in: profile.id)
        } catch {
            app.lastError = "The message could not be saved."
            return
        }
        saveSnapshot(message, agentName: profile.bridgeName)
        if profile.id == shownProfile { messages = await store.messages(profile.id) }
        await deliver(message.id, profile: profile)
    }

    enum AskResult: Sendable { case answered(String), sent, failed }

    /// Siri / Shortcuts: send, then keep the connection open briefly for a quick answer.
    func ask(_ text: String, wait: Duration = .seconds(25)) async -> AskResult {
        guard let profile = app.activeProfile else { return .failed }
        let asked = Date()
        guard let session = try? app.borrowSession(for: profile) else { return .failed }
        defer { app.releaseSession(session) }
        await send(text: text, profileID: profile.id)
        guard await store.messages(profile.id).last(where: { $0.role == .owner })?.status == .delivered else { return .failed }
        let deadline = ContinuousClock.now + wait
        while ContinuousClock.now < deadline {
            if let reply = await store.messages(profile.id).last(where: { $0.role == .agent && $0.date >= asked }) {
                return .answered(reply.preview)
            }
            try? await Task.sleep(for: .milliseconds(400))
        }
        return .sent
    }

    func retry(_ message: ChatMessage) async {
        guard let profile = app.activeProfile else { return }
        await deliver(message.id, profile: profile)
    }

    /// Adds "Call · 2:31" after a call, so the chat shows the whole conversation history.
    func noteCall(profile: UUID, duration: TimeInterval, incoming: Bool) {
        let minutes = Int(duration) / 60, seconds = Int(duration) % 60
        let text = "\(incoming ? "Incoming" : "Outgoing") call · \(minutes):\(String(format: "%02d", seconds))"
        let entry = ChatMessage(id: E2EChannel.newMessageID(), role: .system, kind: "call", text: text, status: .received)
        Task {
            _ = try? await store.upsert(entry, in: profile)
            if profile == shownProfile { messages = await store.messages(profile) }
        }
    }

    /// A relay connection came up: collect mail and resend what did not arrive.
    func connected(_ session: RelaySession) {
        let profile = session.profile
        Task {
            do { try await session.fetchMail() } catch { log.error("mail fetch failed: \(String(describing: error), privacy: .public)") }
            let unsent = await store.messages(profile.id).filter { $0.role == .owner && ($0.status == .pending || $0.status == .sent) }
            for message in unsent.suffix(20) { await deliver(message.id, profile: profile) }
        }
    }

    private func deliver(_ id: String, profile: RelayProfile) async {
        guard !inFlight.contains(id) else { return }
        inFlight.insert(id)
        defer { inFlight.remove(id) }
        let delivered = await withSession(profile) { session in
            guard let message = await self.store.messages(profile.id).first(where: { $0.id == id }) else { return false }
            let body = try await self.upload(message, profile: profile.id, session: session)
            try await session.send(body, mail: true)
            try await self.setStatus(.sent, id: id, profile: profile.id)
            return await self.waitForAck(id)
        } ?? false
        if !delivered { try? await setStatus(.failed, id: id, profile: profile.id) }
    }

    private func upload(_ message: ChatMessage, profile: UUID, session: RelaySession) async throws -> [String: JSON] {
        var uploads: [(attachment: ChatAttachment, blobID: String, key: Data)] = []
        let directory = await store.attachmentDirectory(profile)
        for attachment in message.attachments {
            guard let file = attachment.localFile else { continue }
            let data = try Data(contentsOf: directory.appendingPathComponent(file))
            let (key, sealed) = try Blob.seal(data)
            uploads.append((attachment, try await session.uploadBlob(sealed), key))
        }
        return ChatWire.body(for: message, uploads: uploads, voiceReplies: app.preferences.voiceReplies)
    }

    private func waitForAck(_ id: String) async -> Bool {
        await withCheckedContinuation { continuation in
            acks[id]?.resume(returning: false)
            acks[id] = continuation
            Task {
                try? await Task.sleep(for: Self.ackTimeout)
                self.acks.removeValue(forKey: id)?.resume(returning: false)
            }
        }
    }

    /// Never downgrades a message the bridge already confirmed.
    private func setStatus(_ status: ChatMessage.Status, id: String, profile: UUID) async throws {
        try await store.update(id, in: profile) { message in
            if message.status != .delivered { message.status = status }
        }
        if profile == shownProfile { messages = await store.messages(profile) }
    }

    /// Runs `work` on a connection to `profile`'s relay that stays open while it runs (also in the background).
    @discardableResult
    private func withSession<T: Sendable>(_ profile: RelayProfile, _ work: @escaping (RelaySession) async throws -> T) async -> T? {
        guard let session = try? app.borrowSession(for: profile) else { return nil }
        defer { app.releaseSession(session) }
        do {
            try await session.waitUntilConnected(timeout: 15)
            return try await work(session)
        } catch {
            log.error("chat send failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}

extension OutgoingFile {
    /// Photos from the picker, files from the importer or the share sheet.
    static func from(url: URL) throws -> OutgoingFile {
        let data = try Data(contentsOf: url)
        guard data.count <= Blob.maxPlaintext else { throw ProtocolError.invalidField }
        let type = UTType(filenameExtension: url.pathExtension)
        let mime = type?.preferredMIMEType ?? "application/octet-stream"
        let kind: ChatAttachment.Kind = type?.conforms(to: .image) == true ? .photo : .file
        return OutgoingFile(kind: kind, name: url.lastPathComponent, mime: mime, data: data)
    }
}
