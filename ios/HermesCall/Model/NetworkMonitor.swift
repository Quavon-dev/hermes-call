import Foundation
import Network
import SwiftUI

/// Whether this iPhone has a network path. When it comes back (or changes, e.g. Wi-Fi → cellular), the
/// relay connection is retried at once instead of after its backoff (up to 30 s).
@MainActor @Observable
final class NetworkMonitor {
    private(set) var isOnline = true
    private(set) var isExpensive = false
    /// Called when a usable path appears after none, or the interface changes.
    var onPathRestored: (() -> Void)?

    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private var updates: Task<Void, Never>?
    @ObservationIgnored private var lastInterfaces: [NWInterface.InterfaceType] = []

    func start() {
        guard updates == nil else { return }
        updates = Task { [weak self, monitor] in
            for await path in monitor {
                self?.update(online: path.status == .satisfied, expensive: path.isExpensive,
                             interfaces: path.availableInterfaces.map(\.type))
            }
        }
    }

    func update(online: Bool, expensive: Bool, interfaces: [NWInterface.InterfaceType]) {
        let restored = Self.shouldReconnect(wasOnline: isOnline, isOnline: online, before: lastInterfaces, after: interfaces)
        isOnline = online
        isExpensive = expensive
        lastInterfaces = interfaces
        if restored { onPathRestored?() }
    }

    /// Reconnect when the network came back, or when the phone moved to another network while online.
    nonisolated static func shouldReconnect(wasOnline: Bool, isOnline: Bool, before: [NWInterface.InterfaceType],
                                            after: [NWInterface.InterfaceType]) -> Bool {
        guard isOnline else { return false }
        return !wasOnline || (!before.isEmpty && before.first != after.first)
    }
}

/// "Offline" / "Can't reach the relay" under the presence and on the call and chat screens.
struct ConnectionBanner: View {
    @Environment(AppModel.self) private var app
    @Environment(NetworkMonitor.self) private var network
    var hud = false
    /// Shown only after it has been true for a moment, so a quick reconnect does not flash it.
    @State private var shown: String?

    var body: some View {
        Group {
            if let shown { banner(shown) }
        }
        .task(id: text) {
            if text != nil { try? await Task.sleep(for: .seconds(2.5)) }
            guard !Task.isCancelled else { return }
            withAnimation { shown = text }
        }
    }

    private func banner(_ text: String) -> some View {
        Group {
            Label(text, systemImage: network.isOnline ? "antenna.radiowaves.left.and.right.slash" : "wifi.slash")
                .font(.footnote.weight(.medium))
                .foregroundStyle(hud ? HUD.alert : Color.orange)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(hud ? Color.black.opacity(0.6) : Color.orange.opacity(0.12)))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("connectionBanner")
                .transition(.opacity)
        }
    }

    private var text: String? {
        guard app.activeProfile?.isDemo == false else { return nil }
        if !network.isOnline { return "No internet connection" }
        if app.relayStatus == .disconnected { return "Can't reach your relay · retrying" }
        return nil
    }
}
