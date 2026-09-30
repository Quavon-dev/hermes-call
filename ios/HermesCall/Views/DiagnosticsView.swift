import HermesCallCore
import OSLog
import SwiftUI

/// Settings › Diagnostics: what to check when calls or messages do not arrive, and a redacted log to
/// send along with a bug report (nothing leaves the phone unless the owner shares it).
struct DiagnosticsView: View {
    @Environment(AppModel.self) private var app
    @Environment(NetworkMonitor.self) private var network
    @State private var roundTrip: [UUID: String] = [:]
    @State private var log: String?
    @State private var collecting = false

    var body: some View {
        Form {
            Section("This iPhone") {
                LabeledContent("Hermes Call", value: Self.appVersion)
                LabeledContent("iOS", value: UIDevice.current.systemVersion)
                LabeledContent("Network", value: network.isOnline ? (network.isExpensive ? "Online (cellular or hotspot)" : "Online") : "Offline")
                LabeledContent("Call pushes", value: app.pushToken == nil ? "No VoIP token yet" : "Token received")
                LabeledContent("Push environment", value: PushEnvironment.current)
            }
            ForEach(app.realProfiles) { profile in agentSection(profile) }
            if app.realProfiles.isEmpty {
                Section {
                    Text(app.profiles.isEmpty ? "No paired agents." : "No paired agents. The demo agent runs on this iPhone and has no connection to check.")
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Button(collecting ? "Collecting…" : "Collect the last hour's log") { Task { await collect() } }
                    .disabled(collecting)
                if let log {
                    ShareLink(item: log, subject: Text("Hermes Call log"), preview: SharePreview("Hermes Call log")) {
                        Label("Share log", systemImage: "square.and.arrow.up")
                    }
                    Button { UIPasteboard.general.string = log } label: { Label("Copy log", systemImage: "doc.on.doc") }
                    Text(log.suffix(1200)).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(12)
                }
            } header: {
                Text("Log")
            } footer: {
                Text("Only this app's own messages. Tokens, keys, ids, addresses and e-mail addresses are replaced by "
                     + "placeholders. Nothing is sent unless you share it.")
            }
        }
        .navigationTitle("Diagnostics")
    }

    private func agentSection(_ profile: RelayProfile) -> some View {
        Section(profile.bridgeName) {
            LabeledContent("Relay", value: profile.relay.authority)
            LabeledContent("Relay version", value: app.relayInfo[profile.id]?.displayVersion ?? "Not connected yet")
            LabeledContent("Bridge version", value: bridgeVersion(profile))
            LabeledContent("Connection", value: connection(profile))
            LabeledContent("Round trip", value: roundTrip[profile.id] ?? "–")
            LabeledContent("Incoming calls", value: registered(app.preferences.pushRegistrations[profile.id.uuidString]))
            LabeledContent("Chat notifications", value: registered(app.preferences.alertRegistrations[profile.id.uuidString]))
            Button("Measure round trip") { Task { await measure(profile) } }
                .disabled(app.openSession(for: profile.id) == nil)
        }
    }

    /// Bridges before 0.7 do not answer the app's `hello`.
    private func bridgeVersion(_ profile: RelayProfile) -> String {
        if let info = app.bridgeInfo[profile.id] { return info.displayVersion }
        guard let since = app.upSince(profile.id) else { return "Not connected yet" }
        return Date().timeIntervalSince(since) > 5 ? "0.6.2 or older" : "Asking…"
    }

    private func connection(_ profile: RelayProfile) -> String {
        switch app.status(of: profile.id) {
        case .connected:
            return app.upSince(profile.id).map { "Connected since \($0.formatted(date: .omitted, time: .shortened))" } ?? "Connected"
        case .connecting: return "Connecting…"
        case .disconnected:
            return app.openSession(for: profile.id) == nil ? "Not connected (only while the app is open)" : "Not connected (retrying)"
        }
    }

    private func registered(_ value: String?) -> String {
        guard let value else { return "Not registered" }
        return "Registered (\(value.split(separator: ":").first ?? "?"))"
    }

    private func measure(_ profile: RelayProfile) async {
        roundTrip[profile.id] = "…"
        guard let session = app.openSession(for: profile.id), let rtt = await session.pingRelay() else {
            roundTrip[profile.id] = "No answer"
            return
        }
        roundTrip[profile.id] = "\(Int((Double(rtt.components.attoseconds) / 1e15 + Double(rtt.components.seconds) * 1000).rounded())) ms"
    }

    private func collect() async {
        collecting = true
        defer { collecting = false }
        log = await DiagnosticLog.collect(since: Date().addingTimeInterval(-3600))
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }
}

/// This app's log entries (os_log, this process only), redacted.
enum DiagnosticLog {
    static let subsystem = "de.quavon.hermescall"

    static func collect(since: Date) async -> String {
        await Task.detached(priority: .utility) {
            do {
                let store = try OSLogStore(scope: .currentProcessIdentifier)
                let entries = try store.getEntries(at: store.position(date: since))
                let lines = entries.compactMap { $0 as? OSLogEntryLog }
                    .filter { $0.subsystem.hasPrefix(subsystem) }
                    .map { "\($0.date.formatted(.iso8601.time(includingFractionalSeconds: false))) [\($0.category)] \(redact($0.composedMessage))" }
                return lines.isEmpty ? "No log entries in the last hour." : lines.joined(separator: "\n")
            } catch {
                return "The log could not be read (\(error.localizedDescription))."
            }
        }.value
    }

    private static let patterns: [(String, String)] = [
        (#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "<email>"),
        (#"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"#, "<uuid>"),
        (#"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, "<ip>"),
        (#"\b[0-9a-fA-F:]*:[0-9a-fA-F:]+:[0-9a-fA-F:]+\b"#, "<ip>"),
        (#"\b[0-9a-fA-F]{16,}\b"#, "<hex>"),
        // Standard base64 (keys, signatures): `+`, `/` and padding split it into runs the next pattern misses.
        // Mixed case and a digit, so paths like /var/lib/hermescall stay readable.
        (#"(?=[A-Za-z0-9+/]*[0-9])(?=[A-Za-z0-9+/]*[A-Z])(?=[A-Za-z0-9+/]*[a-z])[A-Za-z0-9+/]{16,}={0,2}"#, "<token>"),
        (#"[A-Za-z0-9_-]{20,}"#, "<token>"),
        // Pairing codes (K7Q-4TXP9, typed in any case, with or without the dash): need a digit, so words stay.
        (#"(?i)\b(?=[a-z0-9-]*[0-9])[a-z0-9]{3}-?[a-z0-9]{5}\b"#, "<code>"),
        (#"\b(?:[a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}\b"#, "<host>"),
    ]

    /// Removes anything that could identify the owner, a key or a server.
    static func redact(_ text: String) -> String {
        patterns.reduce(text) { result, pattern in
            result.replacingOccurrences(of: pattern.0, with: pattern.1, options: .regularExpression)
        }
    }
}
