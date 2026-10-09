// SPDX-License-Identifier: MIT
import HermesCallCore
import SwiftUI

/// The chat tab (and the presence's chat sheet): with one agent its chat, with several a list of every
/// agent's conversation (newest first, unread per agent) that opens a chat by switching to its agent.
/// Every agent stays connected while the app is open (`AppModel.standby`), so switching tears nothing down.
struct ChatHome: View {
    @Environment(AppModel.self) private var app
    @Environment(ChatModel.self) private var chat
    /// The presence's chat sheet starts in the active agent's chat (the list is one step back).
    var opensActiveChat = false
    @State private var path: [UUID] = []

    var body: some View {
        if app.profiles.count > 1 {
            NavigationStack(path: $path) {
                ChatInboxList(open: open)
                    .navigationDestination(for: UUID.self) { _ in ChatView(embedded: true) }
            }
            .task(id: app.chatRequest) { followRequest() }
            .onAppear {
                if opensActiveChat, path.isEmpty, let active = app.activeProfile?.id { path = [active] }
            }
        } else {
            ChatView()
                .task(id: app.chatRequest) { app.chatRequest = nil }
        }
    }

    private func open(_ id: UUID) {
        app.activate(id)
        path = [id]
    }

    /// A notification, deep link or intent asked for a chat.
    private func followRequest() {
        guard let id = app.chatRequest else { return }
        app.chatRequest = nil
        if path != [id] { path = [id] }
    }
}

struct ChatInboxList: View {
    @Environment(AppModel.self) private var app
    @Environment(ChatModel.self) private var chat
    let open: (UUID) -> Void
    @State private var showingSettings = false
    @State private var addingAgent = false

    private var hud: Bool { app.preferences.appearance == .hud }

    var body: some View {
        List(chat.inbox) { row in
            Button { open(row.id) } label: {
                ChatInboxRow(row: row, hud: hud, status: app.profiles.first { $0.id == row.id }?.isDemo == true
                             ? .connected : app.status(of: row.id))
            }
            .buttonStyle(.plain)
            .listRowBackground(hud ? Color.black : Color.clear)
            .accessibilityIdentifier("inbox.\(row.name)")
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background { if hud { Color.black.ignoresSafeArea() } else { AmbientBackground() } }
        .navigationTitle("Chats")
        .navigationBarTitleDisplayMode(hud ? .inline : .large)
        .toolbarBackground(hud ? AnyShapeStyle(Color.black) : AnyShapeStyle(.clear), for: .navigationBar)
        .toolbar {
            if !hud {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                        .accessibilityIdentifier("home.settings")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { addingAgent = true } label: { Label("Add an agent", systemImage: "plus") }
                }
            }
        }
        .sheet(isPresented: $showingSettings) { SettingsView().agentTheme() }
        .sheet(isPresented: $addingAgent) { AddRelayView().agentTheme() }
        .task { await chat.refreshInbox() }
    }
}

/// One agent: its colour, name, when and what it last said, and how many of its messages are unread.
struct ChatInboxRow: View {
    let row: InboxRow
    let hud: Bool
    let status: RelaySession.Status

    private var accent: Color { Color(hud ? row.palette.glow : row.palette.alert) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                Circle().fill(accent.gradient).frame(width: 44, height: 44)
                    .overlay { Text(String(row.name.prefix(1)).uppercased()).font(.headline).foregroundStyle(.white) }
                Circle().fill(status == .connected ? Color.green : Color.gray)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(hud ? Color.black : Color(.systemBackground), lineWidth: 2))
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(row.name).font(.headline).foregroundStyle(hud ? HUDColor.light(row.palette) : .primary).lineLimit(1)
                    Spacer(minLength: 8)
                    if let date = row.latest?.date {
                        Text(ChatDates.listLabel(date)).font(.caption)
                            .foregroundStyle(row.unread > 0 ? AnyShapeStyle(accent) : AnyShapeStyle(.secondary))
                    }
                }
                HStack(alignment: .top) {
                    Text(row.latest == nil ? "No messages yet" : row.preview)
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    Spacer(minLength: 8)
                    if row.unread > 0 {
                        Text(row.unread > 99 ? "99+" : "\(row.unread)")
                            .font(.caption.bold().monospacedDigit()).foregroundStyle(hud ? Color.black : .white)
                            .padding(.horizontal, 7).frame(minWidth: 22, minHeight: 22)
                            .background(Capsule().fill(accent))
                    }
                }
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts = [row.name]
        if row.unread > 0 { parts.append("\(row.unread) unread") }
        if let latest = row.latest { parts.append(ChatDates.listLabel(latest.date)); parts.append(row.preview) }
        return parts.joined(separator: ", ")
    }
}

/// Palette colours by agent (the HUD's `HUD.light` follows only the active agent).
enum HUDColor {
    static func light(_ palette: AgentPalette) -> Color { Color(palette.light) }
}
