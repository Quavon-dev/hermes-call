import Foundation
import HermesCallCore
import os
import UIKit
import WatchConnectivity

/// The iPhone side of the Apple Watch app. The watch has no relay keys: the iPhone sends it the active
/// agent's latest messages (text only if "Show message text in notifications" is on) and does what it
/// asks — start a call here, or send a dictated message.
@MainActor
final class WatchBridge: NSObject {
    static let shared = WatchBridge()

    private var app: AppModel?
    private var chat: ChatModel?
    private var calls: CallCoordinator?
    private var lastSent: WatchSnapshot?
    private let log = Logger(subsystem: "de.quavon.hermescall", category: "watch")

    func configure(app: AppModel, chat: ChatModel, calls: CallCoordinator) {
        self.app = app
        self.chat = chat
        self.calls = calls
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Sends the current snapshot when it changed (and a watch app is installed).
    func publish() {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated, WCSession.default.isWatchAppInstalled,
              let snapshot = makeSnapshot() else { return }
        guard snapshot != lastSent, let data = try? JSONEncoder().encode(snapshot) else { return }
        var context: [String: Any] = [WatchLink.snapshot: data]
        if let still = Self.still(snapshot.palette), still.count < 50_000 { context[WatchLink.still] = still }
        do {
            try WCSession.default.updateApplicationContext(context)
            lastSent = snapshot
        } catch {
            log.error("watch update failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The same rendered presence as the widgets, small enough for the application context (≤ 65 KB).
    private static func still(_ palette: String) -> Data? {
        guard let agent = AgentPalette(rawValue: palette),
              let image = UIImage(contentsOfFile: SharedContainer.presenceStillURL(agent).path) else { return nil }
        let size = CGSize(width: 150, height: 150)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).pngData { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }

    private func makeSnapshot() -> WatchSnapshot? {
        guard let app, let chat else { return nil }
        let showText = app.preferences.showMessageText
        // Right after an agent switch the chat still holds the previous agent's messages: send none until it reloaded.
        let current = chat.shownProfileID == app.activeProfile?.id ? chat.messages : []
        let messages = current.filter { $0.role != .system }.suffix(WatchSnapshot.maxMessages).map { message in
            WatchSnapshot.Message(id: message.id, fromAgent: message.role == .agent,
                                  text: showText ? String(message.preview.prefix(300)) : "New message", date: message.date)
        }
        return WatchSnapshot(agentName: app.activeProfile?.bridgeName ?? RelayProfile.defaultAgentName,
                             palette: app.activeProfile?.agentPalette.rawValue ?? "gold", paired: !app.profiles.isEmpty,
                             messages: Array(messages))
    }

    fileprivate func perform(_ message: [String: Any]) async -> [String: Any] {
        guard let app, let chat, let calls, app.activeProfile != nil else { return ["ok": false, "error": "Pair a relay first."] }
        switch message[WatchLink.action] as? String {
        case WatchLink.callAction:
            guard !calls.inCall else { return ["ok": false, "error": "Already on a call."] }
            await calls.startCall()
            return ["ok": calls.inCall]
        case WatchLink.messageAction:
            guard let text = message[WatchLink.text] as? String, !text.isEmpty, text.count <= WatchLink.maxText else {
                return ["ok": false]
            }
            await chat.send(text: text)
            return ["ok": true]
        default:
            return ["ok": false]
        }
    }
}

extension WatchBridge: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        Task { @MainActor in self.publish() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // A different watch was paired: activate again for it.
        session.activate()
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.lastSent = nil
            self.publish()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        nonisolated(unsafe) let message = message
        nonisolated(unsafe) let reply = replyHandler
        Task { @MainActor in
            let answer = await self.perform(message)
            nonisolated(unsafe) let sendable = answer
            reply(sendable)
        }
    }
}
