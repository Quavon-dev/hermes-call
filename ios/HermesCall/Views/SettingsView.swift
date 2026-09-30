import HermesCallCore
import SwiftUI

/// Settings: the paired agents first (each with its own page), then calls, appearance, chat, tasks,
/// privacy, diagnostics and the rest.
struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(CallCoordinator.self) private var calls
    @Environment(PhoneContextModel.self) private var phone
    @Environment(TaskActivityModel.self) private var tasks
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false
    @State private var addingAgent = false

    var body: some View {
        NavigationStack {
            Form {
                agents
                CallSettingsSection()
                AppearanceSettingsSection()
                ChatSettingsSection()
                PrivacySettingsSection()
                Section {
                    NavigationLink { DiagnosticsView() } label: { Label("Diagnostics", systemImage: "stethoscope") }
                        .accessibilityIdentifier("settings.diagnostics")
                    if let guide = OnboardingView.setupGuide {
                        Link(destination: guide) { Label("Setup guide", systemImage: "book") }
                    }
                } footer: {
                    Text("Connection state, push registration and a log without personal data, for when something does not arrive.")
                }
                Section {
                    Button("Delete all data", role: .destructive) { confirmingDelete = true }
                } footer: {
                    Text("Unpairs every agent (the bridge revokes this phone), deletes all keys, chats, phone access rules, the request log and settings.")
                }
                Section {
                    LabeledContent("Version", value: DiagnosticsView.appVersion)
                    NavigationLink("Acknowledgements") { AcknowledgementsView() }
                }
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $addingAgent) { AddRelayView().agentTheme() }
            .confirmationDialog("Delete all Hermes Call data?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete everything", role: .destructive) {
                    Task {
                        calls.hangUp()
                        await phone.deleteAll()
                        await tasks.endAll()
                        await app.deleteAllData()
                        dismiss()
                    }
                }
            }
        }
    }

    private var agents: some View {
        Section {
            ForEach(app.profiles) { profile in
                NavigationLink { ProfileDetailView(profile: profile) } label: { AgentRow(profile: profile) }
                    .accessibilityIdentifier("agent.\(profile.bridgeName)")
            }
            Button { addingAgent = true } label: { Label("Add an agent", systemImage: "plus") }
        } header: {
            Text("Agents")
        } footer: {
            Text("Each agent has its own name, colour, relay and chat. Tap one to change it or to unpair.")
        }
    }
}

/// An agent in a list: colour, name, relay (or "Demo · on this iPhone"), and whether it is the active one.
struct AgentRow: View {
    let profile: RelayProfile
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(Color(profile.agentPalette.glow)).frame(width: 12, height: 12).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.bridgeName).font(.headline)
                Text(profile.isDemo ? "Demo · runs on this iPhone" : profile.relay.authority)
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            if profile.id == app.activeProfile?.id {
                Text("Active").font(.caption.weight(.semibold)).foregroundStyle(.tint)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct CallSettingsSection: View {
    @Environment(AppModel.self) private var app
    @Environment(CallCoordinator.self) private var calls
    @State private var speechStatus: String?

    var body: some View {
        @Bindable var preferences = app.preferences
        Section {
            Picker("Default talk mode", selection: $preferences.talkMode) {
                ForEach(TalkMode.allCases) { Text($0.title).tag($0) }
            }
            Picker("Speech recognition", selection: $preferences.speechRecognition) {
                ForEach(SpeechRecognition.allCases) { Text($0.title).tag($0) }
            }
            .onChange(of: preferences.speechRecognition) { _, choice in
                if choice == .iPhone { Task { await prepareOnDeviceSpeech() } }
            }
            if let speechStatus {
                Text(speechStatus).font(.footnote).foregroundStyle(.secondary)
            }
            Toggle("Show calls in Phone app Recents", isOn: $preferences.includeInRecents)
                .onChange(of: preferences.includeInRecents) { calls.applyRecentsPreference() }
        } header: {
            Text("Calls")
        } footer: {
            Text("On iPhone uses Apple's on-device English model: your words are recognised on this phone and only the "
                 + "text goes to the bridge. Audio still reaches the bridge so you can interrupt the agent. If iCloud "
                 + "syncs your call history, Recents entries (agent name, time, duration) are synced by Apple too.")
        }
        .task {
            if preferences.speechRecognition == .iPhone { await prepareOnDeviceSpeech() }
        }
    }

    private func prepareOnDeviceSpeech() async {
        switch await PhoneTranscriber.availability() {
        case .ready:
            speechStatus = nil
        case .unavailable:
            speechStatus = "On-device recognition is not available on this iPhone; the bridge keeps transcribing."
            app.preferences.speechRecognition = .bridge
        case .needsDownload:
            speechStatus = "Downloading Apple's on-device speech model…"
            do {
                try await PhoneTranscriber.install()
                speechStatus = nil
            } catch {
                speechStatus = "The speech model could not be downloaded; the bridge keeps transcribing."
                app.preferences.speechRecognition = .bridge
            }
        }
    }
}

private struct AppearanceSettingsSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var preferences = app.preferences
        Section("Appearance") {
            Picker("Appearance", selection: $preferences.appearance) {
                ForEach(Appearance.allCases) { Text($0.title).tag($0) }
            }
            AppIconPicker()
            if preferences.appearance == .hud {
                Toggle("Captions during calls", isOn: $preferences.showCaptions)
                Toggle("Feel the voice (haptics)", isOn: $preferences.voiceHaptics)
            }
        }
    }
}

private struct ChatSettingsSection: View {
    @Environment(AppModel.self) private var app
    @Environment(TaskActivityModel.self) private var tasks

    var body: some View {
        @Bindable var preferences = app.preferences
        Section {
            Toggle("Show message text in notifications", isOn: $preferences.showMessageText)
            Toggle("Answer my voice notes by voice", isOn: $preferences.voiceReplies)
            if preferences.voiceReplies {
                Toggle("Play voice replies automatically", isOn: $preferences.autoPlayVoiceReplies)
            }
            Toggle("Show task details on the Lock Screen", isOn: $preferences.taskDetailsOnLockScreen)
                .onChange(of: preferences.taskDetailsOnLockScreen) { tasks.sendPreferences() }
        } header: {
            Text("Chat and tasks")
        } footer: {
            Text("Messages are decrypted on this iPhone for the lock screen and the widget; Apple and your relay only see "
                 + "ciphertext. Voice replies play only while the app is open, never during a call. Longer tasks show on "
                 + "the Lock Screen; while the app is closed their updates come as pushes Apple can read: only "
                 + "\"Working…\" and the step count, unless you turn on task details.")
        }
    }
}

private struct PrivacySettingsSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var preferences = app.preferences
        Section {
            Toggle("Share with my agent", isOn: $preferences.aiConsent)
                .accessibilityIdentifier("settings.consent")
            Button("What is shared") { app.route = .consent }
            NavigationLink { PhoneAccessView() } label: { Label("Phone access", systemImage: "iphone.gen3") }
            DisclosureGroup("What stays private") {
                Label("Audio and messages are end-to-end encrypted to your bridge.", systemImage: "lock.fill")
                Label("No analytics, no crash reporting, no third-party services.", systemImage: "hand.raised.fill")
                Label("Keys are stored only in this phone's Keychain.", systemImage: "key.fill")
                Label("Result cards: your bridge fetches their images; maps of places load Apple Maps tiles.", systemImage: "map.fill")
            }
            .font(.subheadline)
        } header: {
            Text("Privacy")
        } footer: {
            Text(preferences.aiConsent
                 ? "What you share goes to your agent, which may pass it to the AI service it uses. Turn this off to stop "
                     + "calls, messages and phone answers."
                 : "Off: calls, messages and phone answers stay switched off until you allow sharing with your agent.")
        }
    }
}
