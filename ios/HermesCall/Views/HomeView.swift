import HermesCallCore
import SwiftUI

/// The Call tab in Standard appearance. (In HUD appearance the presence replaces the whole app:
/// Presence/PresenceView.swift.)
struct HomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(CallCoordinator.self) private var calls
    @State private var showingProfiles = false
    @State private var showingSettings = false
    @ScaledMetric(relativeTo: .title) private var callSize: CGFloat = 200

    var body: some View {
        @Bindable var preferences = app.preferences
        NavigationStack {
            VStack(spacing: 32) {
                if let profile = app.activeProfile {
                    RelayStatusCard(profile: profile, status: app.relayStatus)
                }
                ConnectionBanner()
                Spacer()
                Button {
                    Task { await calls.startCall() }
                } label: {
                    VStack(spacing: 12) {
                        Image(systemName: "phone.fill").font(.largeTitle)
                        Text("Call \(agentName)").font(.title2.bold()).multilineTextAlignment(.center).minimumScaleFactor(0.7)
                    }
                    .foregroundStyle(.white)
                    .padding()
                    .frame(width: min(callSize, 300), height: min(callSize, 300))
                    .background(Circle().fill(app.relayStatus == .connected ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.gray)))
                }
                .accessibilityLabel("Call \(agentName)")
                .accessibilityIdentifier("home.call")
                .disabled(app.relayStatus != .connected || calls.inCall)
                .accessibilityHint("Starts a voice call with your assistant")

                Picker("Talk mode", selection: $preferences.talkMode) {
                    ForEach(TalkMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 40)

                if case .ended(let reason) = calls.phase {
                    Text(reason).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Hermes Call")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingProfiles = true } label: { Label("Agents", systemImage: "person.2.wave.2") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                        .accessibilityIdentifier("home.settings")
                }
            }
            .sheet(isPresented: $showingProfiles) { ProfilesView().agentTheme() }
            .sheet(isPresented: $showingSettings) { SettingsView().agentTheme() }
        }
    }

    private var agentName: String { app.activeProfile?.bridgeName ?? RelayProfile.defaultAgentName }
}

struct RelayStatusCard: View {
    let profile: RelayProfile
    let status: RelaySession.Status

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(color).frame(width: 12, height: 12).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.bridgeName).font(.headline)
                Text(profile.isDemo ? "Demo · runs on this iPhone, offline" : "\(profile.label) · \(text)")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            if profile.isDemo {
                Text("DEMO").font(.caption2.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Capsule().fill(.tint.opacity(0.2)))
            } else {
                Image(systemName: "lock.fill").foregroundStyle(.secondary).accessibilityLabel("End-to-end encrypted")
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(.quaternary))
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch status {
        case .connected: .green
        case .connecting: .orange
        case .disconnected: .red
        }
    }

    private var text: String {
        switch status {
        case .connected: "connected"
        case .connecting: "connecting…"
        case .disconnected: "offline"
        }
    }
}
