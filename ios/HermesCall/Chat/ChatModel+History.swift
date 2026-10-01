// SPDX-License-Identifier: MIT
import Foundation
import HermesCallCore

/// D4: a newly paired phone imports the recent chat from its bridge (`ChatHistorySync`): once per agent,
/// only while this phone's chat with it is empty (so messages deleted here never come back), and only
/// from bridges that list `history`. Imported messages count as read.
extension ChatModel {
    static let historySyncedKey = "historySynced"

    func historySynced(_ profile: UUID) -> Bool {
        (unreadDefaults.stringArray(forKey: Self.historySyncedKey) ?? []).contains(profile.uuidString)
    }

    func markHistorySynced(_ profile: UUID) {
        historyPages[profile] = nil
        let synced = unreadDefaults.stringArray(forKey: Self.historySyncedKey) ?? []
        guard !synced.contains(profile.uuidString) else { return }
        unreadDefaults.set(synced + [profile.uuidString], forKey: Self.historySyncedKey)
    }

    /// The bridge answered `hello`: ask for the history if this agent's chat is new here.
    func bridgeHello(_ profileID: UUID, _ info: BridgeInfo) {
        guard info.supports(ChatHistorySync.cap), !historySynced(profileID), historyPages[profileID] == nil,
              let profile = app.profiles.first(where: { $0.id == profileID }), !profile.isDemo else { return }
        Task {
            guard await store.count(profileID) == 0 else { return markHistorySynced(profileID) }
            log.info("asking the bridge for the chat history")
            requestHistory(profile, before: nil)
        }
    }

    private func requestHistory(_ profile: RelayProfile, before: Int64?) {
        historyPages[profile.id, default: 0] += 1
        Task {
            let sent = await withSession(profile) { session in
                try await session.send(ChatHistorySync.request(before: before), mail: false)
                return true
            }
            // Not sent: the next connect (and `hello`) tries again.
            if sent != true { historyPages[profile.id] = nil }
        }
    }

    /// One page: attachments downloaded, then only messages this phone does not have yet are stored.
    func receiveHistory(_ body: [String: JSON], profile: RelayProfile, session: any ChatLink) async {
        guard historyPages[profile.id] != nil, let page = ChatHistorySync.page(from: body) else { return }
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
            historyPages[profile.id] = nil
            return
        }
        if profile.id == shownProfileID { await reload() }
        await refreshInbox()
        onHistoryChanged?(profile.id)
        if page.more, let next = page.next, (historyPages[profile.id] ?? 0) < ChatHistorySync.maxPages {
            requestHistory(profile, before: next)
        } else {
            markHistorySynced(profile.id)
        }
    }
}
