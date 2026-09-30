import HermesCallCore
import LocalAuthentication
import SwiftUI

/// The owner's answer to an approval request. `session` (allow this command until the Hermes session ends)
/// only when the bridge offered it; approving either way needs Face ID or the passcode.
enum ApprovalChoice: String, Sendable {
    case once, session, deny

    /// Whether an `approval_request` offers "Allow for this session" (its `choices` list it; older bridges send none).
    nonisolated static func allowsSession(_ body: [String: JSON]) -> Bool {
        guard case .array(let choices)? = body["choices"] else { return false }
        return choices.contains(.string(ApprovalChoice.session.rawValue))
    }
}

/// What Face ID or the passcode said about approving a command.
enum OwnerCheck: Equatable, Sendable {
    case confirmed
    /// The owner or iOS cancelled (a call came in, the app left the screen): the request stays open.
    case cancelled
    /// This iPhone cannot confirm the owner (no passcode set): the request stays open, it can only be denied.
    case unavailable
}

/// Confirms that the owner approves; injectable so tests need no Face ID.
@MainActor
protocol OwnerAuthenticator {
    func confirm(reason: String) async -> OwnerCheck
}

struct DeviceOwnerAuthenticator: OwnerAuthenticator {
    func confirm(reason: String) async -> OwnerCheck {
        do {
            return try await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) ? .confirmed : .cancelled
        } catch let error as LAError where error.code == .passcodeNotSet {
            return .unavailable
        } catch {
            return .cancelled
        }
    }
}

/// Where an approval request stands on screen. Nothing is ever approved or denied without the owner
/// pressing a button: a cancelled Face ID leaves the request open instead of denying it.
enum ApprovalStep: Equatable, Sendable {
    case waiting, confirming, retry, unavailable

    static let reason = "Approve the command your assistant wants to run."

    /// The step after a Face ID / passcode check that did not confirm.
    static func after(_ check: OwnerCheck) -> ApprovalStep {
        switch check {
        case .confirmed: .waiting
        case .cancelled: .retry
        case .unavailable: .unavailable
        }
    }
}

/// The approval request, the same for calls and chat: command, what it does, Deny / Approve once (and
/// Allow for this session when the bridge offers it), and a retry state when Face ID was cancelled.
struct ApprovalPanel: View {
    let command: String
    let details: String
    let step: ApprovalStep
    var voiceNote = false
    let onDeny: () -> Void
    let onApprove: () -> Void
    /// Set when the bridge offers `session`: a third button.
    var onApproveSession: (() -> Void)?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Label("Your assistant wants to run a command that needs your approval.", systemImage: "exclamationmark.shield")
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                if !details.isEmpty {
                    Text(details).foregroundStyle(.secondary)
                }
                ScrollView {
                    Text(command)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .frame(minHeight: 64)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                status
                HStack {
                    Button(role: .cancel, action: onDeny) { Text("Deny").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered)
                    Button(action: onApprove) { Text(step == .retry ? "Try again" : "Approve once").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .disabled(step == .unavailable)
                }
                .controlSize(.large)
                .disabled(step == .confirming)
                if let onApproveSession {
                    Button(action: onApproveSession) { Text("Allow for this session").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered)
                        .tint(.orange)
                        .controlSize(.large)
                        .disabled(step == .confirming || step == .unavailable)
                        .accessibilityHint("Allows this command again until the agent's session ends. Needs Face ID or your passcode.")
                }
            }
            .padding()
            .navigationTitle("Approval needed")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder private var status: some View {
        switch step {
        case .retry:
            Label("Face ID or the passcode was cancelled, so nothing was approved. Try again, or deny.",
                  systemImage: "faceid")
                .font(.footnote).foregroundStyle(.orange)
        case .unavailable:
            Label("Approving needs a passcode on this iPhone (Settings › Face ID & Passcode). You can deny the command.",
                  systemImage: "lock.slash")
                .font(.footnote).foregroundStyle(.orange)
        case .waiting, .confirming:
            Text((onApproveSession == nil
                  ? "Approving requires Face ID or your passcode and applies to this one command only."
                  : "Approving requires Face ID or your passcode. “Allow for this session” lets this command run again until the agent’s session ends.")
                 + (voiceNote ? " Voice never approves." : ""))
                .fixedSize(horizontal: false, vertical: true)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
