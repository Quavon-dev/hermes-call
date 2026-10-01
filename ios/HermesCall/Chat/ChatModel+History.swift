// SPDX-License-Identifier: MIT
import Foundation
import HermesCallCore

/// D4: a newly paired phone imports the recent chat from its bridge (`ChatHistorySync`): once per agent,
/// only while this phone's chat with it is empty (so messages deleted here never come back), and only
/// from bridges that list `history`. Imported messages count as read. An import under way is kept across
/// launches (`ChatHistorySync.Progress`) and resumed on the next `hello`; a page that does not arrive within
/// `historyPageTimeout` may be asked for again.
extension ChatModel {
    static let historySyncedKey = "historySynced"
    /// When this phone first ran an app version with history sync: agents paired before it are never filled in.
    static let historySinceKey = "historySince"

    /// Called at launch: the first launch of a version with history sync notes the time (`pairedBeforeHistorySync`).
    func noteHistorySyncStart() {
        guard unreadDefaults.object(forKey: Self.historySinceKey) == nil else { return }
        unreadDefaults.set(Date(), forKey: Self.historySinceKey)
    }

    private func pairedBeforeHistorySync(_ profile: RelayProfile) -> Bool {
        guard let since = unreadDefaults.object(forKey: Self.historySinceKey) as? Date else { return false }
        return profile.created < since
    }

    /// The history request of one agent in this launch.
    enum HistoryRequest: Equatable {
        /// Asked for a page (the token tells the page timeout which request it belongs to).
        case waiting(UUID)
        /// A page arrived and is being stored.
        case importing
    }

    func historySynced(_ profile: UUID) -> Bool {
        (unreadDefaults.stringArray(forKey: Self.historySyncedKey) ?? []).contains(profile.uuidString)
    }

    func markHistorySynced(_ profile: UUID) {
        historyRequests[profile] = nil
        ChatHistorySync.setProgress(nil, for: profile, in: unreadDefaults)
        let synced = unreadDefaults.stringArray(forKey: Self.historySyncedKey) ?? []
        guard !synced.contains(profile.uuidString) else { return }
        unreadDefaults.set(synced + [profile.uuidString], forKey: Self.historySyncedKey)
    }

    /// The bridge answered `hello`: ask for the history if this agent's chat is new here, or go on with an
    /// import that was cut short.
    func bridgeHello(_ profileID: UUID, _ info: BridgeInfo) {
        guard info.supports(ChatHistorySync.cap), !historySynced(profileID), historyRequests[profileID] == nil,
              let profile = app.profiles.first(where: { $0.id == profileID }), !profile.isDemo else { return }
        let token = UUID()
        historyRequests[profileID] = .waiting(token)
        Task {
            let progress = ChatHistorySync.progress(for: profileID, in: unreadDefaults)
            let plan = ChatHistorySync.plan(progress: progress, localCount: await store.count(profileID),
                                            pairedBeforeSync: pairedBeforeHistorySync(profile))
            guard historyRequests[profileID] == .waiting(token) else { return }
            switch plan {
            case .markSynced:
                markHistorySynced(profileID)
            case .request(let before):
                log.info("asking the bridge for the chat history")
                if progress == nil {
                    ChatHistorySync.setProgress(.init(pages: 0, next: nil), for: profileID, in: unreadDefaults)
                }
                requestHistory(profile, before: before, token: token)
            }
        }
    }

    private func requestHistory(_ profile: RelayProfile, before: Int64?, token: UUID = UUID()) {
        historyRequests[profile.id] = .waiting(token)
        Task {
            let sent = await withSession(profile) { session in
                try await session.send(ChatHistorySync.request(before: before), mail: false)
                return true
            }
            guard historyRequests[profile.id] == .waiting(token) else { return }
            // Not sent: the next connect (and `hello`) tries again.
            guard sent == true else { return historyRequests[profile.id] = nil }
            try? await Task.sleep(for: historyPageTimeout)
            guard historyRequests[profile.id] == .waiting(token) else { return }
            log.info("history: no page in time; the next connect asks again")
            historyRequests[profile.id] = nil
        }
    }

    /// One page: attachments downloaded, then only messages this phone does not have yet are stored.
    func receiveHistory(_ body: [String: JSON], profile: RelayProfile, session: any ChatLink) async {
        guard case .waiting = historyRequests[profile.id], let page = ChatHistorySync.page(from: body) else { return }
        historyRequests[profile.id] = .importing
        var messages: [ChatMessage] = []
        for var message in page.messages {
            for index in message.attachments.indices {
                message.attachments[index] = await download(message.attachments[index], profile: profile.id, session: session)
            }
            messages.append(message)
        }
        do {
            let added = try await store.insertNew(messages, in: profile.id)
            log.info("history: \(added.count, privacy: .public) message(s) imported")
        } catch {
            log.error("history import failed: \(error.localizedDescription, privacy: .public)")
            historyRequests[profile.id] = nil  // the progress stays: the next `hello` asks for this page again
            return
        }
        if profile.id == shownProfileID { await reload() }
        await refreshInbox()
        onHistoryChanged?(profile.id)
        let pages = (ChatHistorySync.progress(for: profile.id, in: unreadDefaults)?.pages ?? 0) + 1
        if page.more, let next = page.next, pages < ChatHistorySync.maxPages {
            ChatHistorySync.setProgress(.init(pages: pages, next: next), for: profile.id, in: unreadDefaults)
            requestHistory(profile, before: next)
        } else {
            markHistorySynced(profile.id)
        }
    }
}
