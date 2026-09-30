import HermesCallCore
import SwiftUI

struct AddRelayView: View {
    /// A `hermescall://pair…` link opened on this iPhone: filled in, and confirmed like a scanned one.
    var initialLink: String?
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var method = Method.code
    @State private var address = ""
    @State private var code = ""
    @State private var deviceName = "iPhone"
    @State private var pairing = false
    @State private var error: String?
    @State private var confirmation: Confirmation?

    /// Nothing pairs without the user seeing where to: scanned/pasted links name the relay, and a
    /// self-signed relay's key must be accepted explicitly.
    enum Confirmation: Identifiable {
        case link(PairingInvite)
        case selfSigned(PairingInvite, pin: String)
        var id: String {
            switch self {
            case .link(let invite): "link-\(invite.relay.authority)"
            case .selfSigned(_, let pin): "pin-\(pin)"
            }
        }
    }

    enum Method: String, CaseIterable, Identifiable {
        case code = "Enter code", scan = "Scan QR"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Method", selection: $method) {
                    ForEach(Method.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)

                if method == .code {
                    Section {
                        TextField("relay.example.com", text: $address)
                            .accessibilityIdentifier("pair.address")
                            .textContentType(.URL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Code, e.g. K7Q-4TXP9", text: $code)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .font(.body.monospaced())
                    } header: {
                        Text("Relay and pairing code")
                    } footer: {
                        Text("You can also paste the whole hermescall:// link into the address field.")
                    }
                } else {
                    Section {
                        QRScannerSection { link in
                            address = link
                            method = .code
                            prepare()
                        }
                        .frame(height: 280)
                        .listRowInsets(EdgeInsets())
                    } footer: {
                        Text("Point the camera at the QR code printed by `hermes-call-bridge device add`.")
                    }
                }

                Section("This phone") {
                    TextField("Name shown on the bridge", text: $deviceName)
                }

                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                            .accessibilityIdentifier("pair.error")
                    }
                }
            }
            .alert(confirmationTitle, isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }),
                   presenting: confirmation) { item in
                Button("Cancel", role: .cancel) {}
                Button(isSelfSigned(item) ? "Trust and pair" : "Pair") { Task { await pair(confirmed(item)) } }
            } message: { item in
                Text(confirmationMessage(item))
            }
            .navigationTitle("Add relay")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                guard let initialLink, address.isEmpty else { return }
                address = initialLink
                prepare()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if pairing {
                        ProgressView()
                    } else {
                        Button("Pair") { prepare() }
                            .disabled(method == .scan || address.isEmpty || (code.isEmpty && !address.hasPrefix("hermescall:")))
                    }
                }
            }
        }
    }

    private func makeInvite() throws -> PairingInvite {
        if address.hasPrefix("hermescall:") { return try PairingInvite(link: address) }
        return PairingInvite(kind: .device, relay: try RelayAddress(parsing: address), pin: "", code: try PairingCode(parsing: code))
    }

    private func prepare() {
        error = nil
        do {
            let invite = try makeInvite()
            guard invite.kind == .device else { throw ProtocolError.invalidLink }
            if address.hasPrefix("hermescall:") {
                confirmation = .link(invite)
            } else {
                Task { await pair(invite) }
            }
        } catch {
            self.error = Self.explain(.invalidInput, relay: address)
        }
    }

    private var confirmationTitle: String {
        if case .selfSigned? = confirmation { return "Unknown certificate" }
        return "Pair with this relay?"
    }

    private func isSelfSigned(_ item: Confirmation) -> Bool {
        if case .selfSigned = item { return true }
        return false
    }

    private func confirmed(_ item: Confirmation) -> PairingInvite {
        switch item {
        case .link(let invite): invite
        case .selfSigned(let invite, let pin): PairingInvite(kind: invite.kind, relay: invite.relay, pin: pin, code: invite.code)
        }
    }

    private func confirmationMessage(_ item: Confirmation) -> String {
        switch item {
        case .link(let invite):
            let key = invite.pin.isEmpty ? "public certificate" : "pinned key \(Self.fingerprint(invite.pin))"
            return "Relay: \(invite.relay.authority)\nTLS: \(key)\n\nOnly continue if this is the relay your bridge uses."
        case .selfSigned(let invite, let pin):
            return "\(invite.relay.authority) uses its own certificate with key\n\(Self.fingerprint(pin))\n\n"
                + "Continue only if this matches the pin= part of the pairing link on your bridge "
                + "(or the TLS pin printed by hermescall-relay)."
        }
    }

    static func fingerprint(_ pin: String) -> String {
        stride(from: 0, to: min(pin.count, 24), by: 4).map { offset in
            let start = pin.index(pin.startIndex, offsetBy: offset)
            return String(pin[start..<pin.index(start, offsetBy: min(4, pin.count - offset))])
        }.joined(separator: " ") + "…"
    }

    private func pair(_ invite: PairingInvite) async {
        error = nil
        pairing = true
        defer { pairing = false }
        do {
            try await app.pair(invite: invite, deviceName: deviceName.isEmpty ? "iPhone" : deviceName)
            dismiss()
        } catch ProtocolError.selfSignedRelay(let pin) {
            confirmation = .selfSigned(invite, pin: pin)
        } catch {
            self.error = Self.explain(PairingFailure.classify(error), relay: invite.relay.authority)
        }
    }

    /// What went wrong and what to do, per failure.
    static func explain(_ failure: PairingFailure, relay: String) -> String {
        switch failure {
        case .invalidInput:
            "Check the relay address and the 8-character code (like K7Q-4TXP9), or paste the whole hermescall:// link."
        case .unreachable:
            "Can't reach the relay at \(relay). Check the address and that this iPhone is online."
        case .tlsMismatch:
            "The relay's certificate does not match the pairing link, so nothing was sent. If the relay got a new "
                + "certificate, create a new code on the bridge; otherwise someone may be in between."
        case .rateLimited:
            "Too many pairing attempts from this network. Wait 15 minutes, then try again with a new code."
        case .relayBusy:
            "The relay is busy right now. Try again in a minute."
        case .wrongOrExpiredCode:
            "Wrong or expired code. Codes work only for a few minutes and a few tries: create a new one on the bridge."
        case .other:
            "Pairing did not work. Create a new code on the bridge and try again."
        }
    }
}
