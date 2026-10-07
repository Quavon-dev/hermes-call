import HermesCallCore
import QuickLook
import SwiftUI

struct ChatView: View {
    @Environment(AppModel.self) private var app
    @Environment(ChatModel.self) private var chat
    @Environment(CallCoordinator.self) private var calls
    @Environment(TaskActivityModel.self) private var tasks
    @State private var preview: URL?
    @State private var searching = false
    @State private var query = ""
    /// A search hit that was just opened: outlined for a moment.
    @State private var highlighted: String?
    @State private var pendingDelete: ChatMessage?
    /// Older pages load only after the first scroll to the newest message.
    @State private var settled = false
    @State private var arriving: String?
    @State private var draftSeen = Date.distantPast
    @State private var atBottom = true
    @FocusState private var composing: Bool
    @FocusState private var searchFocused: Bool

    /// Pushed from the chat list (which owns the navigation stack) instead of standing alone.
    var embedded = false

    private var hud: Bool { app.preferences.appearance == .hud }

    var body: some View {
        Group {
            if embedded {
                screen
            } else {
                NavigationStack { screen }
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

    private var screen: some View {
        VStack(spacing: 0) {
            if searching { searchBar }
            ZStack {
                messageList
                if searching && !query.trimmingCharacters(in: .whitespaces).isEmpty { searchResults }
            }
            if !searching { ChatComposer(hud: hud, composing: $composing) }
        }
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

    // MARK: messages

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if chat.window.hasOlder {
                        pageLoader.onAppear { loadOlder(proxy) }
                    } else if chat.messages.isEmpty {
                        emptyState.padding(.top, 80)
                    }
                    ForEach(Array(chat.messages.enumerated()), id: \.element.id) { index, message in
                        if index == 0 || !Calendar.current.isDate(chat.messages[index - 1].date, inSameDayAs: message.date) {
                            DayHeader(date: message.date).padding(.top, 8)
                        }
                        let joinsPrevious = index > 0 && chat.messages[index - 1].joins(message)
                        let joinsNext = index + 1 < chat.messages.count && message.joins(chat.messages[index + 1])
                        row(message, joinsPrevious: joinsPrevious, joinsNext: joinsNext).id(message.id)
                            .padding(.top, joinsPrevious ? 2 : 10)
                            .modifier(Arrival(active: arriving == message.id, fromTrailing: message.role == .owner))
                    }
                    if chat.window.hasNewer {
                        pageLoader.onAppear { Task { await chat.loadNewer() } }
                    } else {
                        liveTail.id(Self.liveID).padding(.top, 10)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            .onScrollPhaseChange { _, phase, context in
                if phase == .interacting, highlighted != nil { withAnimation(.easeOut(duration: 0.6)) { highlighted = nil } }
                if phase == .idle {
                    atBottom = context.geometry.visibleRect.maxY >= context.geometry.contentSize.height - 160
                }
            }
            // No .defaultScrollAnchor(.bottom): with a lazy stack and the keyboard it loops layout forever.
            .onAppear { scrollToEnd(proxy, animated: false) }
            .onChange(of: chat.shownProfileID) { scrollToEnd(proxy, animated: false) }
            .onChange(of: chat.messages.last?.id) { _, id in
                guard !chat.window.hasNewer else { return }
                markArrival(id)
                scrollToEnd(proxy)
            }
            .onChange(of: chat.agentDraft) { _, draft in
                if draft != nil { draftSeen = Date() }
                followLive(proxy)
            }
            .onChange(of: chat.agentTyping) { followLive(proxy) }
            .onChange(of: tasks.activeTrail) { followLive(proxy) }
            .onChange(of: composing) { _, focused in if focused { scrollToEnd(proxy) } }
            .onChange(of: highlighted) { _, id in
                guard let id else { return }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(80))
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                    // Long enough to find it; scrolling away ends it earlier.
                    try? await Task.sleep(for: .seconds(4))
                    if highlighted == id { withAnimation(.easeOut(duration: 0.6)) { highlighted = nil } }
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: atBottom)
            .overlay(alignment: .bottomTrailing) {
                if chat.window.hasNewer || !atBottom {
                    latestButton(proxy).transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
        }
    }

    private func row(_ message: ChatMessage, joinsPrevious: Bool, joinsNext: Bool) -> some View {
        MessageRow(message: message, agentName: chat.agentName, hud: hud, player: chat.player, highlighted: highlighted == message.id,
                   joinsPrevious: joinsPrevious, joinsNext: joinsNext,
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

    private static let liveID = "chat.live"

    private var liveTrail: [TaskUpdate] { searching ? [] : tasks.activeTrail }

    private var liveTail: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !liveTrail.isEmpty {
                TaskFeedCard(steps: liveTrail, hud: hud)
                    .transition(.asymmetric(insertion: .scale(scale: 0.92, anchor: .bottomLeading).combined(with: .opacity),
                                            removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading))))
            }
            if let draft = chat.agentDraft {
                StreamingBubble(text: draft, hud: hud)
                    .transition(.asymmetric(insertion: .scale(scale: 0.9, anchor: .bottomLeading).combined(with: .opacity),
                                            removal: .opacity))
            } else if chat.agentTyping {
                TypingIndicator(hud: hud)
                    .transition(.scale(scale: 0.6, anchor: .bottomLeading).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 1, alignment: .leading)
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: liveTrail.isEmpty)
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: chat.agentDraft == nil)
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: chat.agentTyping)
    }

    private func markArrival(_ id: String?) {
        guard settled, let id, let message = chat.messages.last, message.id == id else { return }
        let replacesDraft = message.role == .agent && Date().timeIntervalSince(draftSeen) < 2
        arriving = replacesDraft ? nil : id
        if message.role == .agent { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
    }

    private func followLive(_ proxy: ScrollViewProxy) {
        guard settled, atBottom, !chat.window.hasNewer else { return }
        Task { @MainActor in
            for delay in [80, 420] {
                try? await Task.sleep(for: .milliseconds(delay))
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(Self.liveID, anchor: .bottom) }
            }
        }
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
                if chat.window.hasNewer { await chat.reload() }
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
        guard let lastMessage = chat.messages.last?.id else {
            settled = true
            return
        }
        let last = chat.window.hasNewer ? lastMessage : Self.liveID
        atBottom = true
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

    private static let starters = ["What can you do?", "Plan my day", "What's on my calendar today?"]

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.shield").font(.largeTitle).foregroundStyle(hud ? HUD.glow : .secondary)
            Text("Chat with \(chat.agentName)").font(.headline)
            Text("Messages, photos and voice notes are end-to-end encrypted to your bridge. The history stays on this iPhone.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            VStack(spacing: 8) {
                ForEach(Self.starters, id: \.self) { prompt in
                    Button { Task { await chat.send(text: prompt) } } label: {
                        Text(prompt).font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .background(Capsule().fill(hud ? AnyShapeStyle(HUD.glow.opacity(0.1)) : AnyShapeStyle(.tint.opacity(0.12))))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(hud ? HUD.glow : HUD.alert)
                }
            }
            .padding(.top, 8)
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
                Text(subtitle).font(.caption2)
                    .foregroundStyle(agentWorking || chat.agentDraft != nil ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: subtitle)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("chat.title")
        }
        ToolbarItem(placement: embedded ? .topBarTrailing : .topBarLeading) {
            Button {
                composing = false
                searching = true
            } label: {
                Label("Search", systemImage: "magnifyingglass")
            }
            .disabled(searching)
        }
        if agentWorking && !searching {
            // Its own red circle, not part of the call button's glass capsule.
            ToolbarItem(placement: .topBarTrailing) { stopButton }
                .sharedBackgroundVisibility(.hidden)
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                Button { Task { await calls.startCall() } } label: { Label("Call now", systemImage: "phone.fill") }
                    .disabled(app.relayStatus != .connected || calls.inCall)
                Button { Task { await chat.send(text: ChatModel.callMeText) } } label: {
                    Label("Ask \(chat.agentName) to call me", systemImage: "phone.arrow.down.left")
                }
                Divider()
                Button { chat.run(.new, calls: calls) } label: { Label(SlashCommand.new.summary, systemImage: SlashCommand.new.symbol) }
                Button { chat.run(.retry, calls: calls) } label: { Label(SlashCommand.retry.summary, systemImage: SlashCommand.retry.symbol) }
                Divider()
                // Always here, also while the agent looks idle (a turn without tools shows nothing).
                Button(role: .destructive) { AgentStop.tapped(chat: chat, calls: calls) } label: {
                    Label("Stop agent", systemImage: "stop.circle")
                }
            } label: {
                Label("Call", systemImage: "phone")
            } primaryAction: {
                if !calls.inCall { Task { await calls.startCall() } }
            }
        }
    }

    /// The agent is typing or a task of it runs: Stop sits next to the call button.
    private var agentWorking: Bool { StopCommand.agentIsWorking(typing: chat.agentTyping, task: tasks.activeTask) }

    private var stopButton: some View {
        // Drawn by hand: a system prominent style in the toolbar mutes the white glyph to pink.
        Button { AgentStop.tapped(chat: chat, calls: calls) } label: {
            Image(systemName: "stop.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: Metrics.iconButton, height: Metrics.iconButton)
                .background(Circle().fill(hud ? HUD.emergency : Color.red))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stop \(chat.agentName)")
        .accessibilityIdentifier("chat.stop")
    }

    private var subtitle: String {
        if chat.agentDraft != nil { return "writing…" }
        if let task = tasks.activeTask, task.state == .running { return task.label + "…" }
        if chat.agentTyping { return "typing…" }
        if app.activeProfile?.isDemo == true { return "demo · stays on this iPhone" }
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
                Text(ChatDates.hitLabel(message.date)).font(.caption).foregroundStyle(.secondary)
            }
            Text(snippet).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    /// The part around the match (text, transcript, file name or card), the match in bold.
    private var snippet: AttributedString {
        let found = SearchSnippet(message: message, query: query)
        guard let match = found.match else { return AttributedString(found.text) }
        var text = AttributedString(String(found.text[..<match.lowerBound]))
        var marked = AttributedString(String(found.text[match]))
        marked.inlinePresentationIntent = .stronglyEmphasized
        marked.foregroundColor = .primary
        text += marked + AttributedString(String(found.text[match.upperBound...]))
        return text
    }
}
