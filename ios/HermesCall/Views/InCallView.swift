import SwiftUI

struct InCallView: View {
    @Environment(AppModel.self) private var app
    @Environment(CallCoordinator.self) private var calls
    @State private var looking = false

    var body: some View {
        // HUD appearance never shows this screen: the presence itself is the call (PresenceView).
        standard
        .sheet(item: Binding(get: { calls.pendingApproval }, set: { if $0 == nil { calls.pendingApproval = nil } })) { approval in
            ApprovalSheet(approval: approval)
                .interactiveDismissDisabled()
        }
        .phonePrompt(enabled: calls.pendingApproval == nil)
        .fullScreenCover(isPresented: $looking) { LookSheet() }
    }

    private var standard: some View {
        VStack(spacing: 24) {
            Spacer()
            Text(calls.peerName).font(.largeTitle.bold())
            status.font(.title3).foregroundStyle(.secondary)
            if !calls.callReason.isEmpty {
                Text(calls.callReason)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
            }
            Label("End-to-end encrypted via \(calls.relayLabel)", systemImage: "lock.fill")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            if app.preferences.talkMode == .pushToTalk {
                pushToTalkButton
            }
            HStack(spacing: 48) {
                RoundButton(icon: calls.isMuted ? "mic.slash.fill" : "mic.fill", label: calls.isMuted ? "Unmute" : "Mute",
                            active: calls.isMuted) { calls.setMuted(!calls.isMuted) }
                RoundButton(icon: "speaker.wave.3.fill", label: "Speaker", active: calls.isSpeaker) { calls.toggleSpeaker() }
                RoundButton(icon: "camera.viewfinder", label: "Look", active: false) { looking = true }
                    .disabled(!calls.isConnected)
            }
            Button(role: .destructive) {
                calls.hangUp()
            } label: {
                Image(systemName: "phone.down.fill")
                    .font(.title)
                    .foregroundStyle(.white)
                    .frame(width: Metrics.callButton, height: Metrics.callButton)
                    .background(Circle().fill(.red))
            }
            .accessibilityLabel("Hang up")
            .padding(.bottom, 32)
        }
        .padding()
    }

    @ViewBuilder private var status: some View {
        switch calls.phase {
        case .connected(let since):
            Text(timerInterval: since...Date.distantFuture, countsDown: false)
        case .ended(let reason):
            Text(reason)
        default:
            Text("Connecting…")
        }
    }

    private var pushToTalkButton: some View {
        Text(calls.isTalking ? "Listening…" : "Hold to talk")
            .font(.title3.bold())
            .foregroundStyle(.white)
            .frame(width: 180, height: 180)
            .background(Circle().fill(calls.isTalking ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tint)))
            .scaleEffect(calls.isTalking ? 1.08 : 1)
            .animation(.spring(duration: 0.2), value: calls.isTalking)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in calls.setTalking(true) }
                    .onEnded { _ in calls.setTalking(false) }
            )
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Push to talk")
    }
}

private struct RoundButton: View {
    let icon: String
    let label: String
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.title2)
                    .frame(width: Metrics.callButton, height: Metrics.callButton)
                    .background(Circle().fill(active ? Color.primary : Color.secondary.opacity(0.2)))
                    .foregroundStyle(active ? Color(.systemBackground) : Color.primary)
                Text(label).font(.caption)
            }
        }
        .buttonStyle(.plain)
    }
}

struct ApprovalSheet: View {
    let approval: CallCoordinator.Approval
    @Environment(CallCoordinator.self) private var calls
    @State private var looking = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Label("Your assistant wants to run a command that needs your approval.", systemImage: "exclamationmark.shield")
                    .font(.headline)
                if !approval.details.isEmpty {
                    Text(approval.details).foregroundStyle(.secondary)
                }
                ScrollView {
                    Text(approval.command)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                Text("Approving requires Face ID or your passcode and applies to this one command only. Voice never approves.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                HStack {
                    Button(role: .cancel) { Task { await calls.answerApproval(approve: false) } } label: { Text("Deny").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered)
                    Button { Task { await calls.answerApproval(approve: true) } } label: { Text("Approve once").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                }
                .controlSize(.large)
            }
            .padding()
            .navigationTitle("Approval needed")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
}
