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
                .agentTheme()
        }
        .phonePrompt(enabled: calls.pendingApproval == nil)
        .fullScreenCover(isPresented: $looking) { LookSheet().agentTheme() }
    }

    private var standard: some View {
        VStack(spacing: 20) {
            ConnectionBanner()
            Spacer()
            Text(calls.peerName).font(.largeTitle.bold()).multilineTextAlignment(.center)
            status.font(.title3).foregroundStyle(.secondary)
            if !calls.callReason.isEmpty {
                Text(calls.callReason)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
            }
            if calls.isDemoCall {
                Label("Demo call · simulated on this iPhone, nothing is recorded", systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Label("End-to-end encrypted via \(calls.relayLabel)", systemImage: "lock.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if calls.audio.isInterrupted {
                Label("Audio paused by another call or app", systemImage: "pause.circle")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.orange)
            }
            captions
            Spacer()
            if app.preferences.talkMode == .pushToTalk {
                pushToTalkButton
            }
            HStack(spacing: 28) {
                RoundButton(icon: calls.isMuted ? "mic.slash.fill" : "mic.fill", label: calls.isMuted ? "Unmute" : "Mute",
                            active: calls.isMuted) { calls.setMuted(!calls.isMuted) }
                RoundButton(icon: "speaker.wave.3.fill", label: "Speaker", active: calls.isSpeaker) { calls.toggleSpeaker() }
                AudioOutputButton(size: buttonSize)
                RoundButton(icon: "camera.viewfinder", label: "Look", active: false) { looking = true }
                    .disabled(!calls.isConnected || calls.isDemoCall)
            }
            Button(role: .destructive) {
                calls.hangUp()
            } label: {
                Image(systemName: "phone.down.fill")
                    .font(.title)
                    .foregroundStyle(.white)
                    .frame(width: buttonSize, height: buttonSize)
                    .background(Circle().fill(.red))
            }
            .accessibilityLabel("Hang up")
            .accessibilityIdentifier("call.hangUp")
            .padding(.bottom, 32)
        }
        .padding()
    }

    @ScaledMetric(relativeTo: .title2) private var buttonSize = Metrics.callButton

    /// The last spoken lines (bridge captions, or the demo's).
    @ViewBuilder private var captions: some View {
        let recent = calls.captions.suffix(2)
        if !recent.isEmpty {
            VStack(spacing: 6) {
                ForEach(recent) { caption in
                    Text(caption.text)
                        .font(caption.fromAgent ? .body : .subheadline)
                        .foregroundStyle(caption.fromAgent ? .primary : .secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                }
            }
            .padding(.horizontal)
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder private var status: some View {
        switch calls.phase {
        case .connected where calls.reconnecting:
            Label("Reconnecting…", systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.orange)
                .symbolEffect(.rotate, options: .repeat(.continuous))
                .accessibilityLabel("Reconnecting the call")
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
    @ScaledMetric(relativeTo: .title2) private var size = Metrics.callButton

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.title2)
                    .frame(width: size, height: size)
                    .background(Circle().fill(active ? Color.primary : Color.secondary.opacity(0.2)))
                    .foregroundStyle(active ? Color(.systemBackground) : Color.primary)
                Text(label).font(.caption).lineLimit(1).minimumScaleFactor(0.8)
            }
        }
        .buttonStyle(.plain)
    }
}

/// iOS' output picker (AirPods, car, speaker…) in the look of the other call buttons.
private struct AudioOutputButton: View {
    let size: CGFloat

    var body: some View {
        VStack(spacing: 6) {
            RoutePicker()
                .frame(width: size * 0.45, height: size * 0.45)
                .frame(width: size, height: size)
                .background(Circle().fill(Color.secondary.opacity(0.2)))
            Text("Audio").font(.caption).lineLimit(1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Audio output")
    }
}

struct ApprovalSheet: View {
    let approval: CallCoordinator.Approval
    @Environment(CallCoordinator.self) private var calls

    var body: some View {
        ApprovalPanel(command: approval.command, details: approval.details, step: calls.approvalStep, voiceNote: true,
                      onDeny: { Task { await calls.answerApproval(.deny) } },
                      onApprove: { Task { await calls.answerApproval(.once) } },
                      onApproveSession: approval.allowsSession ? { Task { await calls.answerApproval(.session) } } : nil)
    }
}
