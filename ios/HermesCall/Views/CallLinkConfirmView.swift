import HermesCallCore
import SwiftUI

/// "Call Atlas?" for a `hermescall://call` link opened by another app or a web page: the microphone goes
/// live only after the owner says so, and only then does the link's agent become the active one.
struct CallLinkConfirmView: View {
    /// The agent the link names (nil: the active one).
    let agentID: UUID?
    let onCall: () -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    private var agent: RelayProfile? {
        agentID.flatMap { id in app.profiles.first { $0.id == id } } ?? app.activeProfile
    }

    private var name: String { agent?.bridgeName ?? RelayProfile.defaultAgentName }
    private var palette: AgentPalette { agent?.agentPalette ?? .gold }
    private var hud: Bool { app.preferences.appearance == .hud }

    var body: some View {
        VStack(spacing: 18) {
            emblem
            VStack(spacing: 6) {
                Text("Call \(name)?").font(.title2.bold()).multilineTextAlignment(.center)
                    .accessibilityIdentifier("callLink.title")
                Text("A link opened in another app wants to start a call. Your microphone is live once you call.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                Button(role: .cancel) { dismiss() } label: { Text("Cancel").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("callLink.cancel")
                Button(action: onCall) { Label("Call", systemImage: "phone.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                    .tint(hud ? Color(palette.glow) : .green)
                    .accessibilityIdentifier("callLink.call")
            }
            .controlSize(.large)
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .padding(.bottom, 12)
        .presentationDetents([.height(340), .medium])
        .presentationDragIndicator(.visible)
        .presentationBackground(hud ? AnyShapeStyle(Color.black) : AnyShapeStyle(Color(.systemBackground)))
    }

    /// The agent's presence still (its colour), as on the Home Screen widget.
    @ViewBuilder private var emblem: some View {
        let still = UIImage(contentsOfFile: SharedContainer.presenceStillURL(palette).path)
        ZStack {
            Circle().fill(Color(palette.ember).opacity(hud ? 0.35 : 0.18))
            if let still {
                Image(uiImage: still).resizable().scaledToFill().clipShape(Circle()).padding(6)
            } else {
                Image(systemName: "phone.fill").font(.system(size: 30, weight: .semibold)).foregroundStyle(Color(palette.alert))
            }
        }
        .frame(width: 88, height: 88)
        .accessibilityHidden(true)
    }
}
