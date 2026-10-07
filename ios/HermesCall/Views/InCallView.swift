import HermesCallCore
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
        VStack(spacing: 0) {
            ConnectionBanner()
            header.padding(.top, 32)
            if let task = tasks.activeTask, task.state == .running {
                CallTaskRow(task: task).padding(.top, 16).transition(.opacity)
            }
            CallTranscript(captions: Array(calls.captions.suffix(4)), hud: false)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.vertical, 16)
            if app.preferences.talkMode == .pushToTalk {
                pushToTalkButton.padding(.bottom, 24)
            }
            controls.padding(.bottom, 24)
        }
        .padding(.horizontal, 20)
        .background(Color(.systemBackground))
        .animation(.easeInOut(duration: 0.2), value: tasks.activeTask?.step)
        .animation(.easeInOut(duration: 0.2), value: tasks.activeTask?.state)
    }

    @Environment(TaskActivityModel.self) private var tasks

    private var header: some View {
        VStack(spacing: 6) {
            AgentAvatar(name: calls.peerName, size: 88, speaking: speaking)
                .padding(.bottom, 10)
            Text(calls.peerName).font(.title2.weight(.semibold)).multilineTextAlignment(.center).lineLimit(2)
            status.font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            if !calls.callReason.isEmpty {
                Text(calls.callReason).font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).lineLimit(3).padding(.top, 4)
            }
            Group {
                if calls.isDemoCall {
                    Label("Demo call · simulated on this iPhone", systemImage: "info.circle")
                } else {
                    Label("End-to-end encrypted", systemImage: "lock.fill")
                }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.top, 4)
            if calls.audio.isInterrupted {
                Label("Audio paused by another call or app", systemImage: "pause.circle")
                    .font(.footnote.weight(.medium)).foregroundStyle(.orange)
            }
        }
    }

    private var speaking: Bool {
        guard calls.isConnected, let level = calls.agentPlayoutLevel else { return false }
        return level > 0.06
    }

    private var controls: some View {
        VStack(spacing: 28) {
            HStack(spacing: 0) {
                CallControl(icon: calls.isMuted ? "mic.slash.fill" : "mic.fill", label: calls.isMuted ? "Unmute" : "Mute",
                            active: calls.isMuted) { calls.setMuted(!calls.isMuted) }
                CallControl(icon: "speaker.wave.3.fill", label: "Speaker", active: calls.isSpeaker) { calls.toggleSpeaker() }
                AudioOutputButton(size: buttonSize)
                CallControl(icon: "camera.viewfinder", label: "Look", active: false) { looking = true }
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
        }
    }

    @ScaledMetric(relativeTo: .title2) private var buttonSize = Metrics.callButton

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
            .font(.headline)
            .foregroundStyle(.white)
            .frame(width: 140, height: 140)
            .background(Circle().fill(calls.isTalking ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tint)))
            .scaleEffect(calls.isTalking ? 1.05 : 1)
            .animation(.spring(duration: 0.2), value: calls.isTalking)
            .sensoryFeedback(.impact(weight: .light), trigger: calls.isTalking)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in calls.setTalking(true) }
                    .onEnded { _ in calls.setTalking(false) }
            )
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Push to talk")
    }
}

struct AgentAvatar: View {
    let name: String
    var size: CGFloat = 44
    var speaking = false

    var body: some View {
        Circle().fill(HUD.alert)
            .frame(width: size, height: size)
            .overlay {
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .padding(5)
            .overlay(Circle().stroke(HUD.alert.opacity(speaking ? 0.5 : 0), lineWidth: 2.5))
            .animation(.easeInOut(duration: 0.25), value: speaking)
            .accessibilityHidden(true)
    }
}

private struct CallTaskRow: View {
    let task: TaskUpdate

    var body: some View {
        Label(task.label, systemImage: task.symbol)
            .font(.footnote.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(Color(.secondarySystemBackground)))
            .contentTransition(.opacity)
            .accessibilityElement(children: .combine)
    }
}

struct CallTranscript: View {
    let captions: [CallCoordinator.Caption]
    let hud: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 6) {
                ForEach(captions) { caption in
                    HStack {
                        if !caption.fromAgent { Spacer(minLength: 48) }
                        Text(caption.text)
                            .font(.callout)
                            .foregroundStyle(caption.fromAgent ? Color.primary : .white)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 18)
                                .fill(caption.fromAgent ? AnyShapeStyle(Color(.secondarySystemBackground)) : AnyShapeStyle(HUD.ownerBubble)))
                        if caption.fromAgent { Spacer(minLength: 48) }
                    }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
        }
        .defaultScrollAnchor(.bottom)
        .scrollBounceBehavior(.basedOnSize)
        .animation(.easeOut(duration: 0.25), value: captions.map(\.id))
        .accessibilityElement(children: .combine)
    }
}

private struct CallControl: View {
    let icon: String
    let label: String
    let active: Bool
    let action: () -> Void
    @ScaledMetric(relativeTo: .title2) private var size = Metrics.callButton
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.title2)
                    .frame(width: size, height: size)
                    .foregroundStyle(active ? Color(.systemBackground) : Color.primary)
                    .background(Circle().fill(active ? AnyShapeStyle(Color.primary) : AnyShapeStyle(Color(.secondarySystemBackground))))
                Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            }
            .opacity(isEnabled ? 1 : 0.4)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: active)
    }
}

private struct AudioOutputButton: View {
    let size: CGFloat

    var body: some View {
        VStack(spacing: 6) {
            RoutePicker()
                .frame(width: size * 0.45, height: size * 0.45)
                .frame(width: size, height: size)
                .background(Circle().fill(Color(.secondarySystemBackground)))
            Text("Audio").font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
        }
        .frame(maxWidth: .infinity)
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
