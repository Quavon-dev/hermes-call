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
            VStack(spacing: 0) {
                ConnectionBanner()
                Spacer()
                VStack(spacing: 8) {
                    AgentAvatar(name: agentName, size: 96).padding(.bottom, 8)
                    Text(agentName).font(.title.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.6)
                    if let profile = app.activeProfile { status(profile) }
                }
                .accessibilityElement(children: .combine)
                Spacer()
                VStack(spacing: 12) {
                    Button {
                        Task { await calls.startCall() }
                    } label: {
                        Label("Call \(agentName)", systemImage: "phone.fill")
                            .font(.headline)
                            .lineLimit(1).minimumScaleFactor(0.7)
                            .frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .accessibilityLabel("Call \(agentName)")
                    .accessibilityIdentifier("home.call")
                    .disabled(!connected || calls.inCall)
                    .accessibilityHint("Starts a voice call with your assistant")
                    Button { app.tab = .chat } label: {
                        Label("Message", systemImage: "bubble.left.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    Picker("Talk mode", selection: $preferences.talkMode) {
                        ForEach(TalkMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.top, 8)
                    if case .ended(let reason) = calls.phase {
                        Text(reason).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                }
                .padding(.bottom, 24)
            }
            .padding(.horizontal, 24)
            .task {
                // `-PresenceDemoAuto YES` (debug): a simulated call starts by itself, as on the presence.
                guard PresenceDemo.autoStart, !calls.inCall else { return }
                try? await Task.sleep(for: .seconds(1.5))
                await calls.startCall()
            }
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

    private var connected: Bool { app.relayStatus == .connected }

    private func status(_ profile: RelayProfile) -> some View {
        HStack(spacing: 6) {
            Circle().fill(statusColor).frame(width: 7, height: 7)
            Text(statusText(profile))
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    private var statusColor: Color {
        switch app.relayStatus {
        case .connected: .green
        case .connecting: .orange
        case .disconnected: .red
        }
    }

    private func statusText(_ profile: RelayProfile) -> String {
        if profile.isDemo { return "Demo · runs on this iPhone" }
        switch app.relayStatus {
        case .connected: return "Connected · end-to-end encrypted"
        case .connecting: return "Connecting…"
        case .disconnected: return "Offline"
        }
    }

    private var agentName: String { app.activeProfile?.bridgeName ?? RelayProfile.defaultAgentName }
}
