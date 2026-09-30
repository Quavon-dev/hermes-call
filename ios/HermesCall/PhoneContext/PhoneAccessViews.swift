import HermesCallCore
import PhotosUI
import SwiftUI

/// Shows the pending phone query (Ask / clipboard / pickers) wherever the app is, calls included.
struct PhonePromptModifier: ViewModifier {
    /// Only one presenter at a time: the call screen while in a call, the root otherwise.
    let enabled: Bool
    @Environment(PhoneContextModel.self) private var phone

    func body(content: Content) -> some View {
        content.sheet(item: Binding(get: { enabled ? phone.prompt : nil }, set: { _ in })) { prompt in
            PhoneQuerySheet(prompt: prompt).interactiveDismissDisabled().agentTheme()
        }
    }
}

extension View {
    func phonePrompt(enabled: Bool = true) -> some View { modifier(PhonePromptModifier(enabled: enabled)) }
}

struct PhoneQuerySheet: View {
    let prompt: PhonePrompt
    @Environment(PhoneContextModel.self) private var phone
    @Environment(AppModel.self) private var app
    @State private var photos: [PhotosPickerItem] = []
    @State private var importing = false

    private var capability: PhoneCapability { prompt.query.capability }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: capability.symbol).font(.title).foregroundStyle(.tint)
                    .frame(width: Metrics.iconButton, height: Metrics.iconButton)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(prompt.agentName) asks for").font(.subheadline).foregroundStyle(.secondary)
                    Text(capability.title + (prompt.query.precise ? " (precise)" : "")).font(.title2.bold())
                }
            }
            if let item = prompt.query.newItem { NewItemCard(item: item, capability: capability) }
            Text("“\(prompt.query.reason)”").font(.body.italic())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(.quaternary, in: RoundedRectangle(cornerRadius: Metrics.cornerRadius))
            Label(capability.shares, systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary)
            Text("Sent end-to-end encrypted to your own bridge, this time only. Change the rule in Settings › Phone access.")
                .font(.footnote).foregroundStyle(.secondary)
            HStack {
                Text("Closes in").font(.caption).foregroundStyle(.secondary)
                Text(timerInterval: Date()...max(Date(), prompt.query.expires), countsDown: true).font(.caption.monospacedDigit())
            }
            buttons
        }
        .padding()
        .presentationDetents([.medium, .large])
        // A decision: an opaque sheet, so nothing behind it shows through the item and the buttons.
        .presentationBackground(app.preferences.appearance == .hud ? AnyShapeStyle(Color.black) : AnyShapeStyle(Color(.systemBackground)))
        .hudStyle(app.preferences.appearance == .hud)
        .disabled(phone.answering)
        .onChange(of: photos) { _, items in
            guard !items.isEmpty else { return }
            Task { await sendPhotos(items) }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item],
                      allowsMultipleSelection: prompt.query.maxFiles > 1) { result in
            sendFiles(result)
        }
    }

    @ViewBuilder private var buttons: some View {
        HStack(spacing: 12) {
            Button(role: .cancel) { Task { await phone.respond(to: prompt.id, allow: false) } } label: { Text("Deny").frame(maxWidth: .infinity) }
                .buttonStyle(.bordered)
            switch capability {
            case .photos:
                PhotosPicker(selection: $photos, maxSelectionCount: prompt.query.maxFiles, matching: .images) {
                    Text(prompt.query.maxFiles > 1 ? "Choose photos" : "Choose a photo").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            case .files:
                Button { importing = true } label: { Text("Choose files").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
            default:
                Button { Task { await phone.respond(to: prompt.id, allow: true) } } label: {
                    Text(capability.writes ? "Add" : "Allow once").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("phone.allow")
            }
        }
        .controlSize(.large)
    }

    private func sendPhotos(_ items: [PhotosPickerItem]) async {
        var files: [OutgoingFile] = []
        for (index, item) in items.enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self), let jpeg = PhotoEncoder.jpeg(data) else { continue }
            files.append(OutgoingFile(kind: .photo, name: "Photo \(index + 1).jpg", mime: "image/jpeg", data: jpeg))
        }
        await phone.respond(to: prompt.id, files: files)
    }

    private func sendFiles(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        let files = urls.compactMap { url -> OutgoingFile? in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            return try? OutgoingFile.from(url: url)
        }
        Task { await phone.respond(to: prompt.id, files: files) }
    }
}

/// What the agent wants to add, exactly as it will be created.
private struct NewItemCard: View {
    let item: PhoneNewItem
    let capability: PhoneCapability

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.title).font(.headline)
            if let start = item.start, let end = item.end {
                Label(Self.range(start, end), systemImage: "clock")
            }
            if let due = item.due {
                Label("Due \(due.formatted(date: .abbreviated, time: .shortened))", systemImage: "bell")
            }
            if let location = item.location { Label(location, systemImage: "mappin") }
            if let notes = item.notes { Text(notes).font(.footnote).foregroundStyle(.secondary).lineLimit(6) }
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: Metrics.cornerRadius))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(capability.title): \(item.title)")
    }

    private static func range(_ start: Date, _ end: Date) -> String {
        start.formatted(date: .abbreviated, time: .shortened) + " – " + end.formatted(date: .omitted, time: .shortened)
    }
}

/// Settings › Phone access: No / Ask / Yes per capability, and the request log.
struct PhoneAccessView: View {
    @Environment(PhoneContextModel.self) private var phone
    @State private var rules: [PhoneCapability: PhonePermission] = [:]

    var body: some View {
        Form {
            Section {
                ForEach(PhoneCapability.allCases) { capability in
                    VStack(alignment: .leading, spacing: 8) {
                        Label(capability.title, systemImage: capability.symbol)
                        Picker(capability.title, selection: binding(capability)) {
                            ForEach(capability.permissions) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        Text(capability.shares).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            } footer: {
                Text("What your agent may ask this iPhone. No: refused at once. Ask: you decide each time. Yes: answered "
                     + "without asking (iOS still asks once for its own permission). Clipboard, photos and files always "
                     + "need you. Answers go end-to-end encrypted to your own bridge only.")
            }
            Section {
                NavigationLink("Recent requests") { PhoneRequestsView() }
                NavigationLink { PlaceRemindersView() } label: {
                    LabeledContent("Place reminders", value: "\(PlaceMonitor.shared.reminders.count)")
                }
                Button("Open iOS Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            } footer: {
                Text("If a request shows “unavailable”, iOS permission for it is off — turn it on in iOS Settings › Hermes Call.")
            }
        }
        .navigationTitle("Phone access")
        .onAppear {
            rules = Dictionary(uniqueKeysWithValues: PhoneCapability.allCases.map { ($0, phone.settings.permission(for: $0)) })
        }
    }

    private func binding(_ capability: PhoneCapability) -> Binding<PhonePermission> {
        Binding(get: { rules[capability] ?? .no }, set: { value in
            phone.settings.set(value, for: capability)
            rules[capability] = phone.settings.permission(for: capability)
        })
    }
}

struct PhoneRequestsView: View {
    @State private var entries: [PhoneRequestRecord] = []

    var body: some View {
        List {
            if entries.isEmpty {
                Text("No requests yet.").foregroundStyle(.secondary)
            }
            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Label(entry.capability.title, systemImage: entry.capability.symbol).font(.headline)
                        Spacer()
                        Text(entry.outcome.rawValue.capitalized + (entry.delivered == false ? " · not delivered" : ""))
                            .font(.caption.bold()).foregroundStyle(color(entry.outcome))
                    }
                    Text("\(entry.agentName): “\(entry.reason)”").font(.subheadline)
                    Text(entry.date, format: .dateTime.day().month().hour().minute()).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Recent requests")
        .task { entries = await PhoneRequestLog.shared.entries() }
    }

    private func color(_ outcome: PhoneAnswerStatus) -> Color {
        switch outcome {
        case .ok: .green
        case .denied: .red
        case .unavailable, .timeout: .orange
        }
    }
}

/// Settings › Phone access › Place reminders: what the agent asked this iPhone to watch (swipe to delete).
struct PlaceRemindersView: View {
    private let monitor = PlaceMonitor.shared

    var body: some View {
        List {
            Section {
                if monitor.reminders.isEmpty {
                    Text("No place reminders.").foregroundStyle(.secondary)
                }
                ForEach(monitor.reminders) { reminder in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(reminder.title).font(.headline)
                        Text("\(reminder.trigger == .enter ? "Arriving at" : "Leaving") \(reminder.placeName)"
                             + (reminder.repeats ? " · every time" : ""))
                            .font(.subheadline).foregroundStyle(.secondary)
                        if let note = reminder.note { Text(note).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                .onDelete { offsets in
                    let ids = offsets.map { monitor.reminders[$0].id }
                    Task { for id in ids { await monitor.remove(id) } }
                }
            } footer: {
                Text("Your agent sets these when you ask (\"remind me when I'm at the supermarket\"). This iPhone watches "
                     + "the places itself (at most \(PlaceReminderStore.maxReminders)) and never sends your location to the agent. "
                     + "Searching for a place by name asks Apple Maps with only an area of about 5 km around you. For reminders while the app is closed, allow location "
                     + "access \"Always\".")
            }
        }
        .navigationTitle("Place reminders")
    }
}
