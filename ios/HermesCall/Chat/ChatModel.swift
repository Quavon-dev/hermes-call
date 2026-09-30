import Foundation
import HermesCallCore
import os
import UIKit
import UniformTypeIdentifiers
import UserNotifications
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

/// The chat with the agent of each paired relay: history on this phone (a window of it on screen), an
/// outbox that survives being offline and is shared with the share extension, agent replies from the
/// relay mailbox, attachments and chat approvals.
@MainActor @Observable
final class ChatModel {
    /// The loaded part of the shown chat (`messages`), newest page first; older pages load on demand.
    private(set) var window = ChatWindow()
    var messages: [ChatMessage] { window.messages }
    private(set) var agentTyping = false
    private(set) var unread = 0
    var pendingApproval: ChatApproval? { didSet { if pendingApproval?.id != oldValue?.id { approvalStep = .waiting } } }
    private(set) var approvalStep = ApprovalStep.waiting
    /// Face ID / passcode for approvals (a fake in tests).
    var authenticator: any OwnerAuthenticator = DeviceOwnerAuthenticator()
    /// The newest result cards, unfolded on the presence (Home in HUD appearance, the call screen) until dismissed.
    private(set) var spotlight: ChatMessage?
    /// Hits of the last `search`, newest first.
    private(set) var searchResults: [ChatMessage] = []
    /// Plays voice notes and voice replies (the presence shows what it plays).
    let player = VoicePlayer()
    /// Set by the app: voice replies never play over a call.
    var isInCall: () -> Bool = { false }
    /// The chat screen is on screen (no banners for it, no unread count).
    var isVisible = false { didSet { if isVisible { markRead() } } }
    /// A chat's history changed (stored, changed or deleted message): the watch follows.
    var onHistoryChanged: ((UUID) -> Void)?

    /// How long a sent message waits for the bridge's `chat_ack` before it counts as not delivered.
    var ackTimeout: Duration = .seconds(20)
    /// The bridge forgets chat approval requests after 10 minutes.
    static let approvalLifetimeMs: Int64 = 600_000
    static let callMeText = "Please call me when you can."
    static let widgetKind = "HermesCallChat"
    /// Outbox claims (`ChatStore.claim`): longer than connecting (15 s), uploading and the ack wait.
    static let claimOwner = "app"
    static let claimDuration: TimeInterval = 120
    private nonisolated static let chatTypes: Set<String> = ["chat", "chat_ack", "typing", "approval_done"]

    private let app: AppModel
    private let store: ChatStore
    private let links: ChatLinkProvider
    private let log = Logger(subsystem: "de.quavon.hermescall", category: "chat")
    private var shownProfile: UUID?
    private var typingReset: Task<Void, Never>?
    private var acks: [String: CheckedContinuation<Bool, Never>] = [:]
    private var inFlight: Set<String> = []
    private var loadingPage = false
    private var replyWaiters: [UUID: ReplyWaiter] = [:]
    private var listeners: [Task<Void, Never>] = []

    private struct ReplyWaiter {
        let profile: UUID
        let after: Date
        let continuation: CheckedContinuation<ChatMessage?, Never>
    }

    /// `listens`: answer the extensions' pings and follow their writes (off in tests).
    init(app: AppModel, store: ChatStore = .shared, links: ChatLinkProvider? = nil, listens: Bool = true) {
        self.app = app
        self.store = store
        self.links = links ?? RelayLinkProvider(app: app)
        if listens { listen() }
    }

    isolated deinit {
        listeners.forEach { $0.cancel() }
    }

    /// The share extension asks whether the app runs (it then leaves sending to the app); other processes
    /// signal their writes to the store.
    private func listen() {
        listeners.append(Task { [weak self] in
            for await _ in SharedSignal.observe(SharedSignal.appPing) {
                SharedSignal.post(SharedSignal.appPong)
                await self?.drainOutbox()
            }
        })
        listeners.append(Task { [weak self] in
            for await _ in SharedSignal.observe(SharedSignal.chatChanged) { await self?.storeChanged() }
        })
    }

    /// Messages the chat takes from the shared relay connections.
    nonisolated static func handles(_ message: [String: JSON]) -> Bool {
        guard let type = message["type"]?.string else { return false }
        return chatTypes.contains(type) || (type == "approval_request" && message["chat"]?.bool == true)
    }

    var agentName: String { app.activeProfile?.bridgeName ?? RelayProfile.defaultAgentName }

    /// The relay profile whose chat `messages` holds (it lags behind an agent switch while reloading).
    var shownProfileID: UUID? { shownProfile }

    func attachmentURL(_ attachment: ChatAttachment) async -> URL? {
        await fileURL(attachment.localFile)
    }

    /// A downloaded file of the shown chat (attachments, result card images).
    func fileURL(_ localFile: String?) async -> URL? {
        guard let profile = shownProfile, let localFile else { return nil }
        return await store.attachmentDirectory(profile).appendingPathComponent(localFile)
    }

    func dismissSpotlight() { spotlight = nil }

    /// Shows stored result cards on the presence again (from the chat).
    func showOnPresence(_ message: ChatMessage) {
        guard message.presentation != nil else { return }
        spotlight = message
    }

    /// The newest messages of a chat (the watch, CarPlay).
    func recentMessages(_ profile: UUID, limit: Int) async -> [ChatMessage] {
        await store.latest(profile, limit: limit)
    }

    // MARK: history on screen

    /// Shows the active relay's chat: its newest page.
    func reload() async {
        let profile = app.activeProfile?.id
        shownProfile = profile
        searchResults = []
        agentTyping = false
        guard let profile else {
            window = ChatWindow()
            return
        }
        #if DEBUG
        await ChatDemo.fillIfRequested(profile, store: store)
        #endif
        let latest = await store.latest(profile, limit: ChatWindow.pageSize)
        let total = await store.count(profile)
        guard shownProfile == profile else { return }
        var fresh = ChatWindow()
        fresh.showLatest(latest, total: total)
        window = fresh
    }

    /// The owner scrolled to the top of what is loaded.
    func loadOlder() async {
        guard let profile = shownProfile, window.hasOlder, let first = messages.first?.id, !loadingPage else { return }
        loadingPage = true
        defer { loadingPage = false }
        let older = await store.messages(profile, before: first, limit: ChatWindow.pageSize)
        guard shownProfile == profile, messages.first?.id == first else { return }
        window.prepend(older)
    }

    /// After a search jump: the owner scrolled to the bottom of what is loaded.
    func loadNewer() async {
        guard let profile = shownProfile, window.hasNewer, let last = messages.last?.id, !loadingPage else { return }
        loadingPage = true
        defer { loadingPage = false }
        let newer = await store.messages(profile, after: last, limit: ChatWindow.pageSize)
        guard shownProfile == profile, messages.last?.id == last else { return }
        window.append(newer)
    }

    /// Loads the messages around a search hit; false when it is gone.
    func reveal(_ id: String) async -> Bool {
        guard let profile = shownProfile, let hit = await store.message(id, in: profile) else { return false }
        let older = await store.messages(profile, before: id, limit: ChatWindow.pageSize / 2)
        let newer = await store.messages(profile, after: id, limit: ChatWindow.pageSize / 2)
        guard shownProfile == profile else { return false }
        window.showAround(hit, older: older, newer: newer)
        return true
    }

    func search(_ query: String) async {
        guard let profile = shownProfile else { return }
        let results = await store.search(profile, for: query)
        guard shownProfile == profile else { return }
        searchResults = results
    }

    func clearSearch() { searchResults = [] }

    /// Deletes a message on this phone only (the agent keeps its conversation).
    func delete(_ message: ChatMessage) async {
        guard let profile = shownProfile else { return }
        if let playing = player.playing, message.attachments.contains(where: { $0.id == playing }) { player.stop() }
        do {
            try await store.delete(message.id, in: profile)
        } catch {
            log.error("deleting a message failed: \(String(describing: error), privacy: .public)")
            app.lastError = "The message could not be deleted."
            return
        }
        window.remove(message.id)
        searchResults.removeAll { $0.id == message.id }
        if spotlight?.id == message.id { spotlight = nil }
        onHistoryChanged?(profile)
    }

    /// A stored or changed message: into the window when it belongs to the shown chat.
    private func apply(_ message: ChatMessage, profile: UUID) {
        if profile == shownProfile { window.apply(message) }
        onHistoryChanged?(profile)
    }

    /// Another process (the share extension) wrote to the store.
    private func storeChanged() async {
        guard await store.changedElsewhere(), let profile = shownProfile else { return }
        onHistoryChanged?(profile)
        guard !window.hasNewer else { return }
        let latest = await store.latest(profile, limit: max(ChatWindow.pageSize, messages.count))
        let total = await store.count(profile)
        guard shownProfile == profile, !window.hasNewer else { return }
        window.showLatest(latest, total: total)
    }

    // MARK: incoming

    func receive(_ body: [String: JSON], from session: RelaySession) {
        handle(body, profile: session.profile, link: session)
    }

    func handle(_ body: [String: JSON], profile: RelayProfile, link session: any ChatLink) {
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

    private func receiveChat(_ body: [String: JSON], profile: RelayProfile, session: any ChatLink) async {
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
        apply(message, profile: profile.id)
        guard message.role == .agent else { return }
        agentTyping = false
        autoPlay(message, profile: profile.id)
        if message.presentation != nil, profile.id == app.activeProfile?.id { spotlight = message }
        saveSnapshot(message, profile: profile)
        if !(isVisible && app.isForeground && profile.id == shownProfile) { countUnread() }
        answerWaiters(with: message, profile: profile.id)
    }

    /// A voice reply plays by itself when the owner wants it, the app is open and no call is on.
    private func autoPlay(_ message: ChatMessage, profile: UUID) {
        guard app.preferences.voiceReplies, app.preferences.autoPlayVoiceReplies, app.isForeground, !isInCall(),
              profile == app.activeProfile?.id, Date().timeIntervalSince(message.date) < 120,
              let voice = message.attachments.first(where: { $0.kind == .voice }), let file = voice.localFile else { return }
        Task { player.play(id: voice.id, url: await store.attachmentDirectory(profile).appendingPathComponent(file)) }
    }

    /// Agent attachments are fetched right away (the relay keeps them 7 days) and deleted there.
    private func download(_ attachment: ChatAttachment, profile: UUID, session: any ChatLink) async -> ChatAttachment {
        guard let blobID = attachment.blobID, let keyText = attachment.key,
              let key = try? Base64URL.decode(keyText, length: 32) else { return attachment }
        do {
            let data = try Blob.open(try await session.downloadBlob(blobID, maxSize: Blob.maxSealedSize), key: key)
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
                               session: any ChatLink) async -> Presentation.Image? {
        guard var image, let blobID = image.blobID, let keyText = image.key,
              let key = try? Base64URL.decode(keyText, length: 32) else { return image }
        do {
            let data = try Blob.open(try await session.downloadBlob(blobID, maxSize: Blob.maxSealedSize), key: key)
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
        if let updated = try? await store.update(id, in: profile, { message in
            message.status = .delivered
            if let transcript { message.transcript = transcript }
        }) {
            apply(updated, profile: profile)
        }
        acks.removeValue(forKey: id)?.resume(returning: true)
    }

    /// The widget shows the newest message (or only that there is one, when previews are off).
    private func saveSnapshot(_ message: ChatMessage, profile: RelayProfile) {
        let preview = app.preferences.showMessageText ? message.preview : "New message"
        ChatSnapshot(agentName: profile.bridgeName, preview: preview, date: message.date, fromAgent: message.role == .agent,
                     profileID: profile.id).save()
        WidgetCenter.shared.reloadTimelines(ofKind: Self.widgetKind)
    }

    private func countUnread() {
        unread += 1
        let badge = ChatBadge.increment()
        Task { try? await UNUserNotificationCenter.current().setBadgeCount(badge) }
    }

    private func markRead() {
        unread = 0
        ChatBadge.reset()
        Task { try? await UNUserNotificationCenter.current().setBadgeCount(0) }
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

    /// Approving needs Face ID / passcode; denying never does. `id`: only answer this request (the watch).
    /// A cancelled Face ID keeps the request open (Try again / Deny) instead of denying it.
    func answerApproval(approve: Bool, id: String? = nil) async {
        guard let approval = pendingApproval, id == nil || approval.id == id, approvalStep != .confirming,
              let profile = app.profiles.first(where: { $0.id == approval.profileID }) else { return }
        if approve {
            approvalStep = .confirming
            let check = await authenticator.confirm(reason: ApprovalStep.reason)
            guard pendingApproval?.id == approval.id else { return }
            guard check == .confirmed else { return approvalStep = ApprovalStep.after(check) }
        }
        guard pendingApproval?.id == approval.id else { return }
        pendingApproval = nil
        await withSession(profile) { session in
            try await session.send(["type": "approval", "request_id": .string(approval.id), "choice": .string(approve ? "once" : "deny")],
                                   mail: true)
            if let mailID = approval.mailID { try await session.ackMail([mailID]) }
        }
    }

    // MARK: outgoing

    /// Stores the message first (so nothing typed is lost), then sends it. Returns its id once stored.
    @discardableResult
    func send(text: String, files: [OutgoingFile] = [], profileID: UUID? = nil) async -> String? {
        guard let profile = profileID.flatMap({ id in app.profiles.first { $0.id == id } }) ?? app.activeProfile else { return nil }
        // Nothing goes to an agent before the owner agreed (the demo agent keeps everything on the phone).
        guard profile.isDemo || app.requireConsent() else { return nil }
        let trimmed = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(ChatWire.maxText))
        guard !trimmed.isEmpty || !files.isEmpty else { return nil }
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
            return nil
        }
        saveSnapshot(message, profile: profile)
        apply(message, profile: profile.id)
        await deliver(message.id, profile: profile)
        return message.id
    }

    enum AskResult: Sendable, Equatable { case answered(String), sent, failed }

    /// Siri / Shortcuts: send, then keep the connection open briefly for a quick answer.
    func ask(_ text: String, wait: Duration = .seconds(25)) async -> AskResult {
        guard let profile = app.activeProfile else { return .failed }
        let asked = Date()
        guard let session = try? app.borrowSession(for: profile) else { return .failed }
        defer { app.releaseSession(session) }
        guard let id = await send(text: text, profileID: profile.id),
              await store.message(id, in: profile.id)?.status == .delivered else { return .failed }
        if let reply = await waitForReply(profile: profile.id, after: asked, timeout: wait) { return .answered(reply.preview) }
        return .sent
    }

    /// The first agent message of `profile` dated `after` or later (already stored or arriving), or nil after `timeout`.
    private func waitForReply(profile: UUID, after: Date, timeout: Duration) async -> ChatMessage? {
        let token = UUID()
        return await withCheckedContinuation { continuation in
            replyWaiters[token] = ReplyWaiter(profile: profile, after: after, continuation: continuation)
            Task {
                if let stored = await store.latest(profile, limit: 20).last(where: { $0.role == .agent && $0.date >= after }) {
                    replyWaiters.removeValue(forKey: token)?.continuation.resume(returning: stored)
                    return
                }
                try? await Task.sleep(for: timeout)
                replyWaiters.removeValue(forKey: token)?.continuation.resume(returning: nil)
            }
        }
    }

    private func answerWaiters(with message: ChatMessage, profile: UUID) {
        for (token, waiter) in replyWaiters where waiter.profile == profile && message.date >= waiter.after {
            replyWaiters.removeValue(forKey: token)?.continuation.resume(returning: message)
        }
    }

    /// "Not delivered – tap to retry" in the shown chat: sent through that chat's agent.
    func retry(_ message: ChatMessage) async {
        guard let profileID = shownProfile, let profile = app.profiles.first(where: { $0.id == profileID }) else { return }
        try? await setStatus(.pending, id: message.id, profile: profileID)
        await deliver(message.id, profile: profile)
    }

    /// Adds "Outgoing call · 2:31" after a call, so the chat shows the whole conversation history.
    func noteCall(profile: UUID, duration: TimeInterval, incoming: Bool) {
        let entry = ChatMessage.callEntry(CallSummary(direction: incoming ? .incoming : .outgoing, duration: duration),
                                          id: E2EChannel.newMessageID())
        Task {
            guard (try? await store.upsert(entry, in: profile)) == true else { return }
            apply(entry, profile: profile)
        }
    }

    /// A relay connection came up: collect mail and send what did not arrive (all agents).
    func connected(_ session: RelaySession) {
        Task {
            do { try await session.fetchMail() } catch { log.error("mail fetch failed: \(String(describing: error), privacy: .public)") }
            await drainOutbox()
        }
    }

    /// Sends the outbox (of one agent, or all): messages written while offline or by the share extension.
    /// Runs with background time so a ping from the extension is honoured after the app leaves the screen.
    func drainOutbox(_ only: UUID? = nil) async {
        let background = UIApplication.shared.beginBackgroundTask(withName: "chat-outbox")
        defer { UIApplication.shared.endBackgroundTask(background) }
        let entries = await store.outbox(only)
        let byProfile = Dictionary(grouping: entries, by: \.profile)
        await withTaskGroup(of: Void.self) { group in
            for (profileID, pending) in byProfile {
                guard let profile = app.profiles.first(where: { $0.id == profileID }), profile.isDemo || app.mayShare else { continue }
                for entry in pending.suffix(20) { group.addTask { await self.deliver(entry.message.id, profile: profile) } }
            }
        }
    }

    private func deliver(_ id: String, profile: RelayProfile) async {
        guard !inFlight.contains(id) else { return }
        // The share extension may be sending it right now.
        guard await store.claim(id, in: profile.id, owner: Self.claimOwner, for: Self.claimDuration) else { return }
        inFlight.insert(id)
        let delivered = await withSession(profile) { session in
            guard let message = await self.store.message(id, in: profile.id) else { return false }
            if message.status == .delivered { return true }
            let body = try await self.upload(message, profile: profile.id, session: session)
            try await session.send(body, mail: true)
            try await self.setStatus(.sent, id: id, profile: profile.id)
            return await self.waitForAck(id)
        } ?? false
        if !delivered { try? await setStatus(.failed, id: id, profile: profile.id) }
        await store.releaseClaim(id, in: profile.id, owner: Self.claimOwner)
        inFlight.remove(id)
    }

    private func upload(_ message: ChatMessage, profile: UUID, session: any ChatLink) async throws -> [String: JSON] {
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
                try? await Task.sleep(for: self.ackTimeout)
                self.acks.removeValue(forKey: id)?.resume(returning: false)
            }
        }
    }

    /// Never downgrades a message the bridge already confirmed.
    private func setStatus(_ status: ChatMessage.Status, id: String, profile: UUID) async throws {
        let updated = try await store.update(id, in: profile) { message in
            if message.status != .delivered { message.status = status }
        }
        if let updated { apply(updated, profile: profile) }
    }

    /// Runs `work` on a connection to `profile`'s relay that stays open while it runs (also in the background).
    @discardableResult
    private func withSession<T: Sendable>(_ profile: RelayProfile, _ work: @escaping (any ChatLink) async throws -> T) async -> T? {
        await links.withLink(profile, work)
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
