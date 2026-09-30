import HermesCallCore
import SwiftUI

/// Asked once, before anything reaches an agent (App Review guideline 5.1.2(i)): what is shared, with whom,
/// and that the owner's agent may hand it to a third-party AI service. Revocable in Settings › Privacy.
struct ConsentView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    /// Where it was opened from: onboarding / first use (blocking) or Settings (a toggle already explains it).
    var onDone: () -> Void = {}

    private var agentName: String { app.activeProfile?.bridgeName ?? RelayProfile.defaultAgentName }
    private var demo: Bool { app.activeProfile?.isDemo == true }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Image(systemName: "hand.raised.square.on.square.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text("Before you talk to \(agentName)").font(.largeTitle.bold())
                // First, so it is never under the buttons: the demo keeps everything on this iPhone.
                if demo {
                    Label("You are trying the demo: the demo agent runs on this iPhone and nothing leaves it.",
                          systemImage: "info.circle")
                        .font(.footnote)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: Metrics.cornerRadius))
                }
                Text("Hermes Call connects you to your own AI agent. To answer you, it sends what you share to that "
                     + "agent — and your agent may pass it on to the AI service its owner set it up with (for example "
                     + "a cloud language model provider).")
                    .font(.body)
                VStack(alignment: .leading, spacing: 14) {
                    Item(symbol: "waveform", title: "Your voice during calls",
                         text: "Call audio, or only the text of what you say when speech is recognised on this iPhone.")
                    Item(symbol: "bubble.left.and.text.bubble.right", title: "Messages and voice notes",
                         text: "What you write or record in the chat, and replies you send from notifications.")
                    Item(symbol: "photo.on.rectangle", title: "Photos, files and camera pictures",
                         text: "Only the ones you send, share or show with Look during a call.")
                    Item(symbol: "iphone.gen3", title: "Phone data you allow",
                         text: "Location, calendar, health numbers and more — each off until you set it to Ask or Yes in Phone access.")
                }
                VStack(alignment: .leading, spacing: 8) {
                    Label("Sent end-to-end encrypted to your own bridge; your relay and Apple cannot read it.", systemImage: "lock.fill")
                    Label("The developer of Hermes Call never receives it.", systemImage: "person.crop.circle.badge.xmark")
                    Label("Change your mind any time in Settings › Privacy.", systemImage: "gearshape")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .padding(24)
        }
        .safeAreaInset(edge: .bottom) { buttons }
        .hudStyle(app.preferences.appearance == .hud)
    }

    private var buttons: some View {
        VStack(spacing: 10) {
            Button {
                app.preferences.aiConsent = true
                finish()
            } label: {
                Text("Allow sharing with my agent").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("consent.allow")
            Button("Not now") { finish() }
                .accessibilityIdentifier("consent.notNow")
            Text("Without it, calls, messages and phone answers stay switched off.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private func finish() {
        onDone()
        dismiss()
    }

    private struct Item: View {
        let symbol: String
        let title: String
        let text: String

        var body: some View {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: symbol).font(.title3).foregroundStyle(.tint).frame(width: 32).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(text).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}
