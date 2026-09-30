import HermesCallCore
import SwiftUI

/// The Call tab in Standard appearance. (In HUD appearance the presence replaces the whole app:
/// Presence/PresenceView.swift.)
struct HomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(CallCoordinator.self) private var calls
    @State private var showingProfiles = false
    @State private var showingSettings = false

    var body: some View {
        @Bindable var preferences = app.preferences
        NavigationStack {
            VStack(spacing: 32) {
                if let profile = app.activeProfile {
                    RelayStatusCard(profile: profile, status: app.relayStatus)
                }
                Spacer()
                Button {
                    Task { await calls.startCall() }
                } label: {
                    VStack(spacing: 12) {
                        Image(systemName: "phone.fill").font(.system(size: 44))
                        Text("Call \(agentName)").font(.title2.bold())
                    }
                    .foregroundStyle(.white)
                    .frame(width: 200, height: 200)
                    .background(Circle().fill(app.relayStatus == .connected ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.gray)))
                }
                .accessibilityLabel("Call \(agentName)")
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
                    Button { showingProfiles = true } label: { Label("Relays", systemImage: "antenna.radiowaves.left.and.right") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                }
            }
            .sheet(isPresented: $showingProfiles) { ProfilesView() }
            .sheet(isPresented: $showingSettings) { SettingsView() }
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
                Text(profile.label).font(.headline)
                Text("\(profile.bridgeName) · \(text)").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "lock.fill").foregroundStyle(.secondary).accessibilityLabel("End-to-end encrypted")
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
