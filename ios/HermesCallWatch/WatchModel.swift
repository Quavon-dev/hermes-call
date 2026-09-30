import Foundation
import UIKit
import os
import WatchConnectivity
import WidgetKit

/// The watch side of WatchConnectivity: the latest snapshot from the iPhone, and requests to it.
@MainActor @Observable
final class WatchModel: NSObject {
    private(set) var snapshot: WatchSnapshot
    private(set) var reachable = false
    var status: String?

    private let log = Logger(subsystem: "de.quavon.hermescall.watchkitapp", category: "link")
    private static let storeKey = "snapshot"

    override init() {
        snapshot = (UserDefaults.standard.data(forKey: Self.storeKey))
            .flatMap { try? JSONDecoder().decode(WatchSnapshot.self, from: $0) } ?? .empty
        still = UserDefaults.standard.data(forKey: Self.stillKey).flatMap(UIImage.init(data:))
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    var palette: WatchPalette { WatchPalette(snapshot.palette) }
    /// The iPhone's rendered presence in the agent's colour, once received.
    private(set) var still: UIImage?
    private static let stillKey = "still"

    /// The call runs on the iPhone (audio on the iPhone or its AirPods); the watch only starts it.
    func call() {
        send([WatchLink.action: WatchLink.callAction], done: "Calling on your iPhone…")
    }

    func sendMessage(_ text: String) {
        let trimmed = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(WatchLink.maxText))
        guard !trimmed.isEmpty else { return }
        send([WatchLink.action: WatchLink.messageAction, WatchLink.text: trimmed], done: "Sent")
    }

    private func send(_ message: [String: Any], done: String) {
        guard WCSession.default.activationState == .activated, WCSession.default.isReachable else {
            status = "Open Hermes Call on your iPhone."
            return
        }
        status = nil
        Self.deliver(message) { [weak self] ok, error in
            Task { @MainActor in self?.status = ok ? done : (error ?? "Your iPhone could not do that.") }
        }
    }

    /// WatchConnectivity calls back on its own queue: the handlers must not be main-actor closures.
    private nonisolated static func deliver(_ message: [String: Any], result: @escaping @Sendable (Bool, String?) -> Void) {
        WCSession.default.sendMessage(message, replyHandler: { reply in
            result(reply["ok"] as? Bool ?? false, reply["error"] as? String)
        }, errorHandler: { _ in
            result(false, "Your iPhone is not reachable.")
        })
    }

    fileprivate func applyStill(_ data: Data?) {
        guard let data, let image = UIImage(data: data) else { return }
        still = image
        UserDefaults.standard.set(data, forKey: Self.stillKey)
    }

    fileprivate func apply(_ data: Data?) {
        guard let data, let snapshot = try? JSONDecoder().decode(WatchSnapshot.self, from: data) else { return }
        self.snapshot = snapshot
        UserDefaults.standard.set(data, forKey: Self.storeKey)
        WatchPalette.share(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }
}

extension WatchModel: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        let data = session.receivedApplicationContext[WatchLink.snapshot] as? Data
        let still = session.receivedApplicationContext[WatchLink.still] as? Data
        let reachable = session.isReachable
        Task { @MainActor in
            self.reachable = reachable
            self.apply(data)
            self.applyStill(still)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let data = applicationContext[WatchLink.snapshot] as? Data
        let still = applicationContext[WatchLink.still] as? Data
        Task { @MainActor in
            self.apply(data)
            self.applyStill(still)
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in self.reachable = reachable }
    }
}
