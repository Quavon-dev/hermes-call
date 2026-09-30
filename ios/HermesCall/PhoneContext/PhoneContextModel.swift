import Foundation
import HermesCallCore
import os
import UserNotifications

/// A query waiting for the owner's decision (the "Ask" setting, clipboard and pickers).
struct PhonePrompt: Identifiable, Equatable {
    let query: PhoneQuery
    let profileID: UUID
    let agentName: String
    let mailID: String?
    var id: String { query.queryID }
}

/// Answers the agent's `phone_query`s by the owner's No / Ask / Yes rules (docs/protocol.md,
/// "Phone context"). Nothing is read from iOS before the rule allows it; every query is logged here.
@MainActor @Observable
final class PhoneContextModel {
    /// The prompt on screen; more wait in `queue`.
    private(set) var prompt: PhonePrompt?
    private var queue: [PhonePrompt] = []
    private(set) var answering = false

    nonisolated static let notificationCategory = "phone"
    private nonisolated static let types: Set<String> = ["phone_query", "query_done"]

    private let app: AppModel
    let settings: PhoneAccessSettings
    private let log = Logger(subsystem: "de.quavon.hermescall", category: "phone")
    /// Query ids already handled (mail can arrive twice: live and from the mailbox).
    private var handled: [String] = []
    /// Denied from the notification before the query reached the app (it arrives with the mail).
    private var deniedEarly: Set<String> = []

    init(app: AppModel, settings: PhoneAccessSettings = PhoneAccessSettings()) {
        self.app = app
        self.settings = settings
    }

    nonisolated static func handles(_ message: [String: JSON]) -> Bool {
        message["type"]?.string.map(types.contains) ?? false
    }

    // MARK: incoming

    func receive(_ body: [String: JSON], from session: RelaySession) {
        let mailID = body["mail_id"]?.string
        if body["type"]?.string == "query_done" {
            if let id = body["query_id"]?.string { close(id) }
            return
        }
        guard let query = PhoneQuery.parse(body), !handled.contains(query.queryID) else {
            ack(mailID, session)
            return
        }
        handled = Array((handled + [query.queryID]).suffix(200))
        let profile = session.profile
        let request = PhonePrompt(query: query, profileID: profile.id, agentName: profile.bridgeName, mailID: mailID)
        if deniedEarly.remove(query.queryID) != nil {
            Task { await finish(request, status: .denied) }
            return
        }
        switch Self.decision(consent: app.mayShare, permission: settings.permission(for: query.capability), for: query) {
        case .deny:
            Task { await finish(request, status: .denied) }
        case .answer:
            Task { await fetchAndAnswer(request) }
        case .ask:
            enqueue(request)
        }
    }

    /// Nothing is answered before the owner agreed to share with their agent (ConsentView); a write
    /// capability whose item is unusable is never shown.
    nonisolated static func decision(consent: Bool, permission: PhonePermission, for query: PhoneQuery) -> PhoneAnswer.Decision {
        guard consent else { return .deny }
        if query.capability.writes, query.newItem == nil { return .deny }
        return PhoneAnswer.decide(permission, for: query.capability)
    }

    private func enqueue(_ request: PhonePrompt) {
        if prompt == nil { prompt = request } else { queue.append(request) }
        if !app.isForeground { Task { await notify(request) } }
        Task {
            try? await Task.sleep(for: .seconds(max(0, request.query.expires.timeIntervalSinceNow)))
            if isOpen(request.id) {
                close(request.id)
                await finish(request, status: .timeout)
            }
        }
    }

    #if DEBUG
    /// `-PhoneDemoPrompt YES` (App Store screenshots): the active agent asks to add a calendar event (Ask).
    func showDemoPromptIfRequested() {
        guard UserDefaults.standard.bool(forKey: "PhoneDemoPrompt"), prompt == nil, let profile = app.activeProfile,
              let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date()),
              let start = Calendar.current.date(bySettingHour: 15, minute: 0, second: 0, of: tomorrow) else { return }
        let iso = ISO8601DateFormatter()
        let body: [String: JSON] = [
            "type": "phone_query", "query_id": .string(Base64URL.encode(Sodium.randomBytes(16))), "capability": "calendar_create",
            "reason": "You booked the dentist for tomorrow. Shall I put it in your calendar?",
            "expires": .int(Int64((Date().timeIntervalSince1970 + 280) * 1000)),
            "params": ["title": "Dentist", "start": .string(iso.string(from: start)),
                       "end": .string(iso.string(from: start.addingTimeInterval(3600))), "location": "Dr. Weber, 2nd floor"],
        ]
        guard let query = PhoneQuery.parse(body) else { return }
        enqueue(PhonePrompt(query: query, profileID: profile.id, agentName: profile.bridgeName, mailID: nil))
    }
    #endif

    private func isOpen(_ id: String) -> Bool { prompt?.id == id || queue.contains { $0.id == id } }

    private func close(_ id: String) {
        queue.removeAll { $0.id == id }
        if prompt?.id == id { prompt = queue.isEmpty ? nil : queue.removeFirst() }
        Task { await Self.removeNotifications(for: id) }
    }

    /// Both the extension's push notification and our own local one carry the query id.
    private static func removeNotifications(for id: String) async {
        let center = UNUserNotificationCenter.current()
        let matching = await center.deliveredNotifications()
            .filter { $0.request.content.userInfo["query"] as? String == id }
            .map(\.request.identifier)
        center.removeDeliveredNotifications(withIdentifiers: matching)
    }

    // MARK: owner's decision

    /// Allow once / Deny for everything except the pickers. `id`: the prompt the owner answered
    /// (a newer one may have replaced it meanwhile — then nothing happens).
    func respond(to id: String, allow: Bool) async {
        guard let request = prompt, request.id == id, !answering else { return }
        answering = true
        defer { answering = false }
        close(request.id)
        if allow { await fetchAndAnswer(request) } else { await finish(request, status: .denied) }
    }

    /// "Deny" on the query's notification, also while the app is in the background: the query may not
    /// have arrived yet, so the app connects to the agent's relay briefly to fetch it.
    func deny(queryID: String, profileID: UUID?) async {
        if let request = [prompt].compactMap({ $0 }).first(where: { $0.id == queryID }) ?? queue.first(where: { $0.id == queryID }) {
            close(queryID)
            await finish(request, status: .denied)
            return
        }
        guard !handled.contains(queryID) else { return }
        deniedEarly.insert(queryID)
        guard let profile = app.profiles.first(where: { $0.id == profileID }) ?? app.activeProfile,
              let session = try? app.borrowSession(for: profile) else { return }
        defer { app.releaseSession(session) }
        // Up to 10 s for the mail fetch that brings the query (then it is denied in `receive`).
        let deadline = ContinuousClock.now + .seconds(10)
        while deniedEarly.contains(queryID), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    /// Photos / files the owner picked (none = deny). Uploaded as encrypted blobs for the bridge.
    func respond(to id: String, files: [OutgoingFile]) async {
        guard let request = prompt, request.id == id, !answering else { return }
        answering = true
        defer { answering = false }
        close(request.id)
        guard !files.isEmpty else { return await finish(request, status: .denied) }
        let refs: [JSON]? = await withSession(request.profileID) { session in
            var refs: [JSON] = []
            for file in files.prefix(request.query.maxFiles) {
                let (key, sealed) = try Blob.seal(file.data)
                let blobID = try await session.uploadBlob(sealed)
                refs.append(["blob_id": .string(blobID), "key": .string(Base64URL.encode(key)), "name": .string(file.name),
                             "mime": .string(file.mime)])
            }
            return refs
        }
        guard let refs else { return await finish(request, status: .unavailable) }
        await finish(request, status: .ok, data: ["files": .array(refs)])
    }

    /// Reading iOS must finish before the query expires; a late answer would be dropped by the bridge
    /// after the data already left the phone.
    private func fetchAndAnswer(_ request: PhonePrompt) async {
        let query = request.query
        do {
            let profileID = request.profileID
            let data = try await withTimeout(seconds: max(1, query.expires.timeIntervalSinceNow - 3)) {
                if query.capability == .geofence { return try await PlaceMonitor.shared.handle(query, profileID: profileID) }
                return try await PhoneSources.fetch(query)
            }
            guard query.expires > Date() else { return await finish(request, status: .timeout) }
            await finish(request, status: .ok, data: data)
        } catch {
            log.info("phone query \(request.query.capability.rawValue, privacy: .public) unavailable")
            await finish(request, status: .unavailable)
        }
    }

    private func finish(_ request: PhonePrompt, status: PhoneAnswerStatus, data: [String: JSON]? = nil) async {
        let body = PhoneAnswer.body(queryID: request.query.queryID, status: status, data: data)
        let outcome = body["status"]?.string.flatMap(PhoneAnswerStatus.init(rawValue:)) ?? status
        let mailID = request.mailID
        let delivered = await withSession(request.profileID) { session in
            try await session.send(body, mail: true)
            if let mailID { try await session.ackMail([mailID]) }
            return true
        } ?? false
        await PhoneRequestLog.shared.append(PhoneRequestRecord(capability: request.query.capability, reason: request.query.reason,
                                                               agentName: request.agentName, outcome: outcome, delivered: delivered))
        log.info("phone query \(request.query.capability.rawValue, privacy: .public): \(outcome.rawValue, privacy: .public)")
    }

    // MARK: helpers

    /// "Ask" while the app is in the background (e.g. during a call from the lock screen).
    private func notify(_ request: PhonePrompt) async {
        let center = UNUserNotificationCenter.current()
        // The push for this query may already be showing (decrypted by the extension).
        guard await !center.deliveredNotifications().contains(where: { $0.request.content.userInfo["query"] as? String == request.id })
        else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(request.agentName) asks for: \(request.query.capability.title)"
        content.body = request.query.reason
        content.categoryIdentifier = Self.notificationCategory
        content.interruptionLevel = .timeSensitive
        content.userInfo = ["profile": request.profileID.uuidString, "query": request.id]
        content.filterCriteria = request.profileID.uuidString
        try? await center.add(UNNotificationRequest(identifier: "phone-\(request.id)", content: content, trigger: nil))
    }

    private func ack(_ mailID: String?, _ session: RelaySession) {
        guard let mailID else { return }
        Task { try? await session.ackMail([mailID]) }
    }

    @discardableResult
    private func withSession<T: Sendable>(_ profileID: UUID, _ work: @escaping (RelaySession) async throws -> T) async -> T? {
        guard let profile = app.profiles.first(where: { $0.id == profileID }),
              let session = try? app.borrowSession(for: profile) else { return nil }
        defer { app.releaseSession(session) }
        do {
            try await session.waitUntilConnected(timeout: 15)
            return try await work(session)
        } catch {
            log.error("phone answer not sent: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// "Delete all data".
    func deleteAll() async {
        settings.reset()
        await PhoneRequestLog.shared.deleteAll()
        await PlaceMonitor.shared.deleteAll()
        queue = []
        prompt = nil
    }
}
