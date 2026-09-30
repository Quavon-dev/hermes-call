import HermesCallCore
import SwiftUI

struct ProfilesView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var addingRelay = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(app.profiles) { profile in
                        NavigationLink {
                            ProfileDetailView(profile: profile)
                        } label: {
                            HStack {
                                Circle().fill(Color(profile.agentPalette.glow)).frame(width: 10, height: 10)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading) {
                                    Text(profile.label).font(.headline)
                                    Text("\(profile.bridgeName) · \(profile.relay.authority)")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if profile.id == app.activeProfile?.id {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                                        .accessibilityLabel("Active")
                                }
                            }
                        }
                        .swipeActions(edge: .leading) {
                            Button("Use") { app.activate(profile.id) }.tint(.accentColor)
                        }
                    }
                } footer: {
                    Text("Swipe right to switch the active relay, e.g. between home and a VPS. In the HUD appearance, "
                         + "swipe sideways next to the presence to switch agents.")
                }
            }
            .navigationTitle("Relays")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) {
                    Button { addingRelay = true } label: { Label("Add relay", systemImage: "plus") }
                }
            }
            .sheet(isPresented: $addingRelay) { AddRelayView() }
        }
    }
}

struct ProfileDetailView: View {
    let profile: RelayProfile
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var agentName = ""
    @State private var confirmingUnpair = false

    private var palette: Binding<AgentPalette> {
        Binding(get: { app.profiles.first { $0.id == profile.id }?.agentPalette ?? .gold },
                set: { app.setPalette(profile.id, to: $0) })
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Relay") {
                    TextField("Label", text: $label).multilineTextAlignment(.trailing)
                        .onSubmit { app.rename(profile.id, to: label) }
                }
                LabeledContent("Assistant") {
                    TextField(RelayProfile.defaultAgentName, text: $agentName).multilineTextAlignment(.trailing)
                        .onSubmit { app.renameAgent(profile.id, to: agentName) }
                }
                LabeledContent("Colour") { PalettePicker(selection: palette) }
            } header: {
                Text("Names")
            } footer: {
                Text("The assistant name is shown when you call and on incoming calls. The colour is its light in the "
                     + "HUD appearance and in widgets.")
            }
            Section("Paired device") {
                LabeledContent("Relay", value: profile.relay.authority)
                LabeledContent("TLS", value: profile.pin.isEmpty ? "Public certificate" : "Pinned key \(profile.pin.prefix(8))…")
                LabeledContent("This phone's ID", value: "\(profile.deviceID.prefix(6))…")
                LabeledContent("Paired", value: profile.created.formatted(date: .abbreviated, time: .shortened))
            }
            Section {
                if profile.id != app.activeProfile?.id {
                    Button("Use this relay") { app.activate(profile.id) }
                }
                Button("Unpair", role: .destructive) { confirmingUnpair = true }
            } footer: {
                Text("Unpairing asks the bridge to revoke this phone and deletes its keys here.")
            }
        }
        .navigationTitle(profile.label)
        .onAppear {
            label = profile.label
            agentName = profile.bridgeName
        }
        .onDisappear {
            if label != profile.label { app.rename(profile.id, to: label) }
            if agentName != profile.bridgeName { app.renameAgent(profile.id, to: agentName) }
        }
        .confirmationDialog("Unpair \(profile.label)?", isPresented: $confirmingUnpair, titleVisibility: .visible) {
            Button("Unpair", role: .destructive) {
                Task {
                    await app.unpair(profile.id)
                    dismiss()
                }
            }
        }
    }
}

/// A row of colour dots (one per palette).
struct PalettePicker: View {
    @Binding var selection: AgentPalette

    var body: some View {
        HStack(spacing: 10) {
            ForEach(AgentPalette.allCases) { palette in
                Button { selection = palette } label: {
                    Circle().fill(Color(palette.glow)).frame(width: 22, height: 22)
                        .overlay(Circle().stroke(Color.primary.opacity(selection == palette ? 0.9 : 0), lineWidth: 2).padding(-4))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(palette.title)
                .accessibilityAddTraits(selection == palette ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }
}
