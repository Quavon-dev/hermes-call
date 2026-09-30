import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(CallCoordinator.self) private var calls
    @Environment(PhoneContextModel.self) private var phone
    @Environment(TaskActivityModel.self) private var tasks
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false
    @State private var speechStatus: String?

    var body: some View {
        @Bindable var preferences = app.preferences
        NavigationStack {
            Form {
                Section {
                    Picker("Default talk mode", selection: $preferences.talkMode) {
                        ForEach(TalkMode.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Appearance", selection: $preferences.appearance) {
                        ForEach(Appearance.allCases) { Text($0.title).tag($0) }
                    }
                    if let profile = app.activeProfile {
                        LabeledContent("\(profile.bridgeName)'s colour") {
                            PalettePicker(selection: Binding(get: { app.activeProfile?.agentPalette ?? .gold },
                                                             set: { app.setPalette(profile.id, to: $0) }))
                        }
                    }
                    AppIconPicker()
                    if preferences.appearance == .hud {
                        Toggle("Captions during calls", isOn: $preferences.showCaptions)
                        Toggle("Feel the voice (haptics)", isOn: $preferences.voiceHaptics)
                    }
                    Toggle("Show calls in Phone app Recents", isOn: $preferences.includeInRecents)
                        .onChange(of: preferences.includeInRecents) { calls.applyRecentsPreference() }
                } footer: {
                    Text("If iCloud syncs your call history, Recents entries (agent name, time, duration) are synced by Apple too.")
                }
                Section {
                    Picker("Speech recognition", selection: $preferences.speechRecognition) {
                        ForEach(SpeechRecognition.allCases) { Text($0.title).tag($0) }
                    }
                    .onChange(of: preferences.speechRecognition) { _, choice in
                        if choice == .iPhone { Task { await prepareOnDeviceSpeech() } }
                    }
                    if let speechStatus {
                        Text(speechStatus).font(.footnote).foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("On iPhone uses Apple's on-device English model: your words are recognized on this phone and "
                         + "only the text goes to the bridge, usually a little faster. Audio still reaches the bridge "
                         + "so you can interrupt the agent.")
                }
                Section {
                    Toggle("Show message text in notifications", isOn: $preferences.showMessageText)
                    Toggle("Answer my voice notes by voice", isOn: $preferences.voiceReplies)
                    if preferences.voiceReplies {
                        Toggle("Play voice replies automatically", isOn: $preferences.autoPlayVoiceReplies)
                    }
                } header: {
                    Text("Chat")
                } footer: {
                    Text("Messages are decrypted on this iPhone for the lock screen and the widget; Apple and your relay only "
                         + "see ciphertext. Turn this off to show just \"New message\". The chat history is stored only on "
                         + "this iPhone. Voice replies are spoken by your bridge and play only while the app is open, never "
                         + "during a call.")
                }
                Section {
                    Toggle("Show task details on the Lock Screen", isOn: $preferences.taskDetailsOnLockScreen)
                        .onChange(of: preferences.taskDetailsOnLockScreen) { tasks.sendPreferences() }
                } header: {
                    Text("Tasks")
                } footer: {
                    Text("Longer tasks show on the Lock Screen and in the Dynamic Island. While the app is closed, updates come "
                         + "as pushes Apple can read: only \"Working…\" and the step count, unless you turn this on. "
                         + "Never what the agent searches for.")
                }
                Section {
                    NavigationLink { PhoneAccessView() } label: { Label("Phone access", systemImage: "iphone.gen3") }
                } header: {
                    Text("Agent")
                } footer: {
                    Text("Decide what your agent may ask this iPhone for: location, calendar, battery and more. Everything is off until you allow it.")
                }
                Section {
                    Label("Audio and messages are end-to-end encrypted to your bridge.", systemImage: "lock.fill")
                    Label("No analytics, no crash reporting, no third-party services.", systemImage: "hand.raised.fill")
                    Label("Keys are stored only in this phone's Keychain.", systemImage: "key.fill")
                    Label("Result cards: your bridge fetches their images; maps of places load Apple Maps tiles.",
                          systemImage: "map.fill")
                } header: {
                    Text("Privacy")
                }
                .font(.subheadline)
                Section {
                    Button("Delete all data", role: .destructive) { confirmingDelete = true }
                } footer: {
                    Text("Unpairs every relay (the bridge revokes this phone), deletes all keys, chats, phone access rules, the request log and settings.")
                }
                Section {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–")
                    NavigationLink("Acknowledgements") { AcknowledgementsView() }
                }
            }
            .navigationTitle("Settings")
            .task {
                if preferences.speechRecognition == .iPhone { await prepareOnDeviceSpeech() }
            }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
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
