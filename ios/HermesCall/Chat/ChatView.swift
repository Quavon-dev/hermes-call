import HermesCallCore
import QuickLook
import SwiftUI

struct ChatView: View {
    @Environment(AppModel.self) private var app
    @Environment(ChatModel.self) private var chat
    @Environment(CallCoordinator.self) private var calls
    @State private var preview: URL?
    @State private var searching = false
    @State private var query = ""
    /// A search hit that was just opened: outlined for a moment.
    @State private var highlighted: String?
    @State private var pendingDelete: ChatMessage?
    /// Older pages load only after the first scroll to the newest message.
    @State private var settled = false
    @FocusState private var composing: Bool
    @FocusState private var searchFocused: Bool

    private var hud: Bool { app.preferences.appearance == .hud }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if searching { searchBar }
                ZStack {
                    messageList
                    if searching && !query.trimmingCharacters(in: .whitespaces).isEmpty { searchResults }
                }
                if chat.agentTyping && !searching {
                    TypingIndicator(hud: hud)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 4)
                        .transition(.opacity)
                }
                if !searching { ChatComposer(hud: hud, composing: $composing) }
            }
            .animation(.easeInOut(duration: 0.2), value: chat.agentTyping)
            .animation(.easeInOut(duration: 0.2), value: searching)
            .background { if hud { Color.black.ignoresSafeArea() } }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(hud ? AnyShapeStyle(Color.black) : AnyShapeStyle(.bar), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar { toolbar }
            .quickLookPreview($preview)
            .confirmationDialog("Delete this message on this iPhone?", isPresented: Binding(
                get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible, presenting: pendingDelete) { message in
                Button("Delete", role: .destructive) { Task { await chat.delete(message) } }
            } message: { _ in
                Text("\(chat.agentName) keeps its own copy of the conversation.")
            }
        }
        .onAppear { chat.isVisible = true }
        .onDisappear {
            chat.isVisible = false
            chat.player.stop()
        }
        .task(id: app.activeProfile?.id) {
            settled = false
            closeSearch()
            await chat.reload()
            #if DEBUG
            await showDemoState()
            #endif
        }
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await chat.search(query)
        }
    }

    // MARK: messages

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    if chat.window.hasOlder {
                        pageLoader.onAppear { loadOlder(proxy) }
                    } else if chat.messages.isEmpty {
                        emptyState.padding(.top, 80)
                    }
                    ForEach(Array(chat.messages.enumerated()), id: \.element.id) { index, message in
                        if index == 0 || !Calendar.current.isDate(chat.messages[index - 1].date, inSameDayAs: message.date) {
                            DayHeader(date: message.date)
                        }
                        row(message).id(message.id)
                    }
                    if chat.window.hasNewer {
                        pageLoader.onAppear { Task { await chat.loadNewer() } }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            // No .defaultScrollAnchor(.bottom): with a lazy stack and the keyboard it loops layout forever.
            .onAppear { scrollToEnd(proxy, animated: false) }
            .onChange(of: chat.shownProfileID) { scrollToEnd(proxy, animated: false) }
            .onChange(of: chat.messages.last?.id) { if !chat.window.hasNewer { scrollToEnd(proxy) } }
            .onChange(of: composing) { _, focused in if focused { scrollToEnd(proxy) } }
            .onChange(of: highlighted) { _, id in
                guard let id else { return }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(80))
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                    try? await Task.sleep(for: .seconds(2))
                    if highlighted == id { withAnimation { highlighted = nil } }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if chat.window.hasNewer { latestButton(proxy) }
            }
        }
    }

    private func row(_ message: ChatMessage) -> some View {
        MessageRow(message: message, agentName: chat.agentName, hud: hud, player: chat.player, highlighted: highlighted == message.id,
                   open: { attachment in Task { preview = await chat.attachmentURL(attachment) } },
                   play: { attachment, fraction in
                       Task {
                           guard let url = await chat.attachmentURL(attachment) else { return }
                           if let fraction {
                               if chat.player.playing == attachment.id {
                                   chat.player.seek(to: fraction)
                               } else {
                                   chat.player.play(id: attachment.id, url: url, from: fraction)
                               }
                           } else {
                               chat.player.toggle(id: attachment.id, url: url)
                           }
                       }
                   },
                   retry: { Task { await chat.retry(message) } },
                   delete: { pendingDelete = message })
    }

    private var pageLoader: some View {
        ProgressView().frame(maxWidth: .infinity).padding(8)
    }

    private func loadOlder(_ proxy: ScrollViewProxy) {
        guard settled else { return }
        let anchor = chat.messages.first?.id
        Task {
            await chat.loadOlder()
            // Keep the message that was on top where it was.
            if let anchor { proxy.scrollTo(anchor, anchor: .top) }
        }
    }

    private func latestButton(_ proxy: ScrollViewProxy) -> some View {
        Button {
            Task {
                await chat.reload()
                scrollToEnd(proxy)
            }
        } label: {
            Image(systemName: "arrow.down").font(.body.bold()).frame(width: 40, height: 40)
        }
        .buttonStyle(.glass)
        .clipShape(Circle())
        .padding(12)
        .accessibilityLabel("Show the newest messages")
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy, animated: Bool = true) {
        guard let last = chat.messages.last?.id else {
            settled = true
            return
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            if animated {
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(last, anchor: .bottom) }
            } else {
                proxy.scrollTo(last, anchor: .bottom)
            }
            try? await Task.sleep(for: .milliseconds(300))
            settled = true
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.shield").font(.largeTitle).foregroundStyle(hud ? HUD.glow : .secondary)
            Text("Chat with \(chat.agentName)").font(.headline)
            Text("Messages, photos and voice notes are end-to-end encrypted to your bridge. The history stays on this iPhone.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
    }

    // MARK: search

    private var searchBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search messages", text: $query)
                    .focused($searchFocused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear")
                }
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 38)
            .background(.quaternary, in: Capsule())
            Button("Done") { closeSearch() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(hud ? AnyShapeStyle(Color.black) : AnyShapeStyle(.bar))
        .onAppear { searchFocused = true }
    }

    private var searchResults: some View {
        List {
            if chat.searchResults.isEmpty {
                Text("No messages found").foregroundStyle(.secondary)
            }
            ForEach(chat.searchResults) { message in
                Button { open(message) } label: { SearchHitRow(message: message, agentName: chat.agentName, query: query) }
                    .buttonStyle(.plain)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(hud ? .hidden : .automatic)
        .background(hud ? AnyShapeStyle(Color.black) : AnyShapeStyle(.background))
    }

    private func open(_ hit: ChatMessage) {
        Task {
            guard await chat.reveal(hit.id) else { return }
            closeSearch()
            highlighted = hit.id
        }
    }

    #if DEBUG
    /// `-ChatDemoQuery` / `-ChatDemoPlay` (see `ChatDemo`).
    private func showDemoState() async {
        if let demo = ChatDemo.query {
            searching = true
            query = demo
        }
        if let text = ChatDemo.reveal, let hit = chat.messages.first(where: { $0.text.contains(text) }) {
            try? await Task.sleep(for: .seconds(1))
            open(hit)
        }
        if ChatDemo.plays, let voice = chat.messages.flatMap(\.attachments).first(where: { $0.kind == .voice }),
           let url = await chat.attachmentURL(voice) {
            try? await Task.sleep(for: .seconds(1))
            chat.player.play(id: voice.id, url: url, from: 0.35)
        }
    }
    #endif

    private func closeSearch() {
        searching = false
        query = ""
        searchFocused = false
        chat.clearSearch()
    }

    // MARK: toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            VStack(spacing: 1) {
                if hud {
                    HUD.label(chat.agentName, size: 12).foregroundStyle(HUD.light)
                } else {
                    Text(chat.agentName).font(.headline)
                }
                Text(subtitle).font(.caption2).foregroundStyle(chat.agentTyping ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
            .accessibilityElement(children: .combine)
        }
        ToolbarItem(placement: .topBarLeading) {
            Button {
                composing = false
                searching = true
            } label: {
                Label("Search", systemImage: "magnifyingglass")
            }
            .disabled(searching)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                Button { Task { await calls.startCall() } } label: { Label("Call now", systemImage: "phone.fill") }
                    .disabled(app.relayStatus != .connected || calls.inCall)
                Button { Task { await chat.send(text: ChatModel.callMeText) } } label: {
                    Label("Ask \(chat.agentName) to call me", systemImage: "phone.arrow.down.left")
                }
            } label: {
                Label("Call", systemImage: "phone")
            } primaryAction: {
                Task { await calls.startCall() }
            }
            .disabled(calls.inCall)
        }
    }

    private var subtitle: String {
        if chat.agentTyping { return "typing…" }
        switch app.relayStatus {
        case .connected: return "end-to-end encrypted"
        case .connecting: return "connecting…"
        case .disconnected: return "offline · messages wait in the outbox"
        }
    }
}

/// One search hit: who, when, and the text around the match.
private struct SearchHitRow: View {
    let message: ChatMessage
    let agentName: String
    let query: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(message.role == .owner ? "You" : message.role == .agent ? agentName : "Call").font(.subheadline.bold())
                Spacer()
                Text(message.date, format: .dateTime.day().month(.abbreviated).hour().minute()).font(.caption).foregroundStyle(.secondary)
            }
            Text(snippet).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    /// The preview starting shortly before the match, with the match in bold.
    private var snippet: AttributedString {
        // Text and transcript first; for a message without either, its preview ("🎙 Voice note", a file name).
        let parts = [message.text, message.transcript ?? ""].filter { !$0.isEmpty }
        let plain = message.role == .system ? message.systemText
            : ChatText.plain(parts.isEmpty ? message.preview : parts.joined(separator: " · "), limit: 2000)
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard let range = plain.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return AttributedString(String(plain.prefix(160)))
        }
        let start = plain.index(range.lowerBound, offsetBy: -40, limitedBy: plain.startIndex) ?? plain.startIndex
        var text = AttributedString((start > plain.startIndex ? "…" : "") + plain[start..<range.lowerBound])
        var match = AttributedString(plain[range])
        match.inlinePresentationIntent = .stronglyEmphasized
        match.foregroundColor = .primary
        text += match + AttributedString(String(plain[range.upperBound...].prefix(120)))
        return text
    }
}
