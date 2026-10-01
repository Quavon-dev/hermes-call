import HermesCallCore
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// HUD appearance: the whole app is the presence. Tap it to talk, hold it to push-to-talk, spin it,
/// swipe up for the conversation, long-press anywhere for more. Its rings show what waits for you
/// (requests, unread messages, results); results come out of it as cards.
struct PresenceView: View {
    @Environment(AppModel.self) private var app
    @Environment(CallCoordinator.self) private var calls
    @Environment(ChatModel.self) private var chat
    @Environment(PhoneContextModel.self) private var phone
    @Environment(TaskActivityModel.self) private var tasks
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    @State private var engine = PresenceEngine()
    @State private var haptics = PresenceHaptics()
    @State private var motion = PresenceMotion()
    @State private var mood = PresenceMood.State.idle
    @State private var touch: PresenceTouch?
    @State private var holdTimer: Task<Void, Never>?
    @State private var holdingToTalk = false
    @State private var menuOrigin: CGPoint?
    @State private var sheet: PresenceSheet?
    @State private var choosingPhotos = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var importingFile = false
    @State private var dropTargeted = false
    @State private var focusedRing: Int?
    @AppStorage("presenceHints") private var hintUses = 0

    enum PresenceSheet: String, Identifiable {
        case history, settings, relays, phoneAccess, look
        var id: String { rawValue }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                PresenceCanvas(engine: engine, paused: canvasPaused,
                               framesPerSecond: FrameBudget.shared.framesPerSecond(reduceMotion: reduceMotion))
                    .ignoresSafeArea()
                touchLayer
                VStack(spacing: 0) {
                    header.padding(.top, 6)
                    ConnectionBanner(hud: true).padding(.top, 18)
                    taskLabel
                    Spacer(minLength: 0)
                    captionsView
                    if let cards = chat.spotlight, let presentation = cards.presentation {
                        PresenceDeck(message: cards, presentation: presentation) { chat.dismissSpotlight() }
                            .frame(height: min(290, geo.size.height * 0.36))
                            .transition(.opacity)
                    }
                    bottom.padding(.bottom, 12)
                }
                if dropTargeted {
                    Circle().stroke(HUD.light.opacity(0.6), lineWidth: 1)
                        .frame(width: engine.radius * 2.4, height: engine.radius * 2.4)
                        .position(engine.center)
                        .allowsHitTesting(false)
                }
                if let menuOrigin {
                    RadialMenu(origin: menuOrigin, items: menuItems) { self.menuOrigin = nil }
                }
            }
            .onChange(of: layoutKey(geo.size), initial: true) { old, new in place(in: geo.size, animated: old != new) }
        }
        .background(Color.black.ignoresSafeArea())
        .hudStyle(true)
        .onDrop(of: [.image, .fileURL, .url, .plainText], isTargeted: $dropTargeted) { providers in
            Task { await receiveDrop(providers) }
            return true
        }
        .sheet(item: $sheet) { sheet in sheetView(sheet) }
        .sheet(item: Binding(get: { calls.pendingApproval }, set: { if $0 == nil { calls.pendingApproval = nil } })) {
            ApprovalSheet(approval: $0).interactiveDismissDisabled().hudStyle(true)
        }
        .photosPicker(isPresented: $choosingPhotos, selection: $photoItems, maxSelectionCount: 4, matching: .images)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            Task { await sendPhotos(items) }
        }
        .fileImporter(isPresented: $importingFile, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { sendFile(url) }
        }
        .onAppear(perform: start)
        .onDisappear(perform: stop)
        .onChange(of: inCall) { _, live in callChanged(live) }
        .onChange(of: calls.isConnected) { _, connected in
            if connected, holdingToTalk { calls.setTalking(true) }
        }
        .onChange(of: ringKey, initial: true) { syncRings() }
        .onChange(of: app.tab) { _, tab in
            // Notifications and hermescall://chat ask for the chat: here that is the history.
            if tab == .chat {
                sheet = .history
                app.tab = .call
            }
        }
        .onChange(of: voiceReplyPlaying) { _, playing in voiceReplyChanged(playing) }
        .onChange(of: presencePalette) { _, palette in engine.palette = palette }
        .task(id: app.activeProfile?.id) { await chat.reload() }
    }

    // MARK: layout

    private func layoutKey(_ size: CGSize) -> String { "\(Int(size.width))x\(Int(size.height))-\(chat.spotlight != nil)" }

    private func place(in size: CGSize, animated: Bool) {
        let cards = chat.spotlight?.presentation != nil
        let radius = min(size.width, size.height) * (cards ? 0.27 : 0.38)
        engine.place(center: CGPoint(x: size.width / 2, y: size.height * (cards ? 0.3 : 0.44)), radius: radius, animated: animated)
    }

    private var inCall: Bool { calls.inCall }

    /// Nothing to draw while another screen covers the presence or the app is not in front (battery, heat).
    private var canvasPaused: Bool {
        scenePhase != .active || [.settings, .relays, .phoneAccess, .look].contains(sheet)
    }

    private var agentName: String {
        if inCall { return calls.peerName }
        return app.activeProfile?.bridgeName ?? RelayProfile.defaultAgentName
    }

    // MARK: text around the presence

    private var header: some View {
        HStack(spacing: 10) {
            HUD.label(agentName, size: 11).foregroundStyle(HUD.light)
            Rectangle().fill(HUD.glow.opacity(0.4)).frame(width: 16, height: 0.5)
            if inCall {
                Group {
                    if calls.reconnecting {
                        Text("RECONNECTING").foregroundStyle(HUD.alert)
                    } else if let since = connectedSince {
                        Text(timerInterval: since...Date.distantFuture, countsDown: false)
                    } else {
                        Text("LINKING")
                    }
                }
                .font(.caption2.monospaced().weight(.medium))
                .foregroundStyle(HUD.glow.opacity(0.85))
                if mood != .idle { HUD.label(moodLabel, size: 9).padding(.leading, 2).transition(.opacity) }
                if calls.isDemoCall { HUD.label("· demo", size: 8).opacity(0.7) }
                if calls.isMuted { Image(systemName: "mic.slash").font(.caption2).foregroundStyle(HUD.alert) }
            } else {
                Circle().fill(statusColor).frame(width: 5, height: 5)
                HUD.label(statusText, size: 9)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: mood)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .accessibilityElement(children: .combine)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .bottom) { pageDots.offset(y: 14) }
        .overlay(alignment: .trailing) {
            // The same menu as a long-press, for those who don't know the gesture.
            Button { menuOrigin = CGPoint(x: engine.center.x, y: engine.center.y + engine.radius * 0.6) } label: {
                Image(systemName: "ellipsis").font(.body.weight(.semibold)).foregroundStyle(HUD.glow.opacity(0.8))
                    .frame(width: Metrics.iconButton, height: Metrics.iconButton)
            }
            .accessibilityLabel("More")
            .padding(.trailing, 8)
        }
    }

    /// What the agent is doing on a longer task (the tasks ring shows how far).
    @ViewBuilder private var taskLabel: some View {
        if let task = tasks.activeTask {
            HStack(spacing: 8) {
                HUD.label(task.state == .running ? task.label : (task.state == .done ? "done" : "failed"), size: 8)
                if let total = task.total { HUD.label("\(task.step) / \(total)", size: 8).opacity(0.6) }
            }
            .padding(.top, app.profiles.count > 1 ? 22 : 10)
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.3), value: task)
            .accessibilityElement(children: .combine)
        }
    }

    /// One dot per paired agent (only with more than one); swipe sideways to switch.
    @ViewBuilder private var pageDots: some View {
        if app.profiles.count > 1, !inCall {
            HStack(spacing: 6) {
                ForEach(app.profiles) { profile in
                    Circle().fill(profile.id == app.activeProfile?.id ? Color(profile.agentPalette.glow) : HUD.glow.opacity(0.25))
                        .frame(width: 4, height: 4)
                }
            }
            .accessibilityHidden(true)
        }
    }

    private var connectedSince: Date? {
        if case .connected(let since) = calls.phase { return since }
        return nil
    }

    private var moodLabel: String {
        switch mood {
        case .idle: ""
        case .listening: "listening"
        case .thinking: "thinking"
        case .speaking: "speaking"
        }
    }

    private var statusColor: Color {
        switch app.relayStatus {
        case .connected: HUD.glow
        case .connecting: HUD.alert.opacity(0.6)
        case .disconnected: HUD.alert
        }
    }

    private var statusText: String {
        if app.activeProfile?.isDemo == true { return "demo · on this iPhone" }
        switch app.relayStatus {
        case .connected: return "online"
        case .connecting: return "linking"
        case .disconnected: return "offline"
        }
    }

    /// The last spoken lines, fading after a few seconds (real text, not drawn into the scene).
    @ViewBuilder private var captionsView: some View {
        if app.preferences.showCaptions, inCall {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                VStack(spacing: 6) {
                    ForEach(recentCaptions(at: timeline.date)) { caption in
                        Text(caption.text)
                            .font(caption.fromAgent ? .subheadline.monospaced() : .footnote.monospaced())
                            .foregroundStyle(caption.fromAgent ? HUD.light : HUD.glow.opacity(0.7))
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                .animation(.easeOut(duration: 0.4), value: recentCaptions(at: timeline.date).map(\.id))
                .padding(.horizontal, 28)
                .padding(.bottom, 10)
            }
            .allowsHitTesting(false)
        }
    }

    private func recentCaptions(at date: Date) -> [CallCoordinator.Caption] {
        calls.captions.filter { date.timeIntervalSince($0.date) < 9 }.suffix(2)
    }

    @ViewBuilder private var bottom: some View {
        if inCall {
            VStack(spacing: 6) {
                HStack(spacing: 36) {
                    callToggle(symbol: calls.isSpeaker ? "speaker.wave.3.fill" : "speaker.wave.1", on: calls.isSpeaker,
                               label: calls.isSpeaker ? "Speaker on" : "Speaker off") { calls.toggleSpeaker() }
                    Button { perform(.endCall) } label: {
                        Image(systemName: "phone.down.fill").font(.callout.weight(.semibold)).foregroundStyle(HUD.light)
                            .frame(width: Metrics.iconButton, height: Metrics.iconButton)
                            .background(Circle().fill(HUD.alert.opacity(0.3)))
                            .overlay(Circle().stroke(HUD.alert.opacity(0.8), lineWidth: 0.75))
                    }
                    .accessibilityLabel("End call")
                    callToggle(symbol: calls.isMuted ? "mic.slash.fill" : "mic", on: calls.isMuted,
                               label: calls.isMuted ? "Microphone muted" : "Microphone on") { calls.setMuted(!calls.isMuted) }
                }
                if calls.reconnecting {
                    HUD.label("network changed · reconnecting", size: 8).foregroundStyle(HUD.alert)
                        .accessibilityLabel("Reconnecting the call")
                } else {
                    HUD.label(calls.talkMode == .pushToTalk ? "hold to talk · swipe down to end" : "tap to interrupt · swipe down to end", size: 7)
                        .opacity(0.5)
                        .accessibilityHidden(true)
                }
            }
        } else if case .ended(let reason) = calls.phase, reason != "Call ended." {
            Text(reason).font(.footnote).foregroundStyle(HUD.glow.opacity(0.7)).multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        } else if hintUses < 4, chat.spotlight == nil {
            HUD.label(app.relayStatus == .connected ? "tap to talk · hold to speak · long-press for more" : "relay offline", size: 8)
                .opacity(0.55)
                .accessibilityHidden(true)
        }
    }

    /// A small round call switch next to End (speaker, mute): lit while on.
    private func callToggle(symbol: String, on: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.callout.weight(.semibold))
                .foregroundStyle(on ? HUD.deep : HUD.light)
                .frame(width: Metrics.iconButton, height: Metrics.iconButton)
                .background(Circle().fill(on ? HUD.glow.opacity(0.85) : HUD.glow.opacity(0.08)))
                .overlay(Circle().stroke(HUD.glow.opacity(on ? 0 : 0.5), lineWidth: 0.75))
        }
        .accessibilityLabel(label)
    }

    // MARK: sheets and menu

    @ViewBuilder private func sheetView(_ sheet: PresenceSheet) -> some View {
        Group {
            switch sheet {
            case .history:
                ChatHome(opensActiveChat: true).presentationDetents([.medium, .large]).presentationBackground(.black)
            case .settings: SettingsView()
            case .relays: ProfilesView()
            case .phoneAccess: NavigationStack { PhoneAccessView() }
            case .look: LookSheet { engine.absorb() }
            }
        }
        .hudStyle(true)
    }

    private var menuItems: [RadialMenuItem] {
        if inCall {
            return [
                RadialMenuItem(id: "mute", title: calls.isMuted ? "Unmute" : "Mute", symbol: calls.isMuted ? "mic" : "mic.slash") {
                    calls.setMuted(!calls.isMuted)
                },
                RadialMenuItem(id: "speaker", title: calls.isSpeaker ? "Earpiece" : "Speaker", symbol: "speaker.wave.2") {
                    calls.toggleSpeaker()
                },
                RadialMenuItem(id: "chat", title: "Chat", symbol: "text.bubble") { sheet = .history },
                RadialMenuItem(id: "look", title: "Look", symbol: "camera.viewfinder") { sheet = .look },
                RadialMenuItem(id: "end", title: "End", symbol: "phone.down.fill", destructive: true) { perform(.endCall) },
            ]
        }
        return [
            RadialMenuItem(id: "chat", title: "Chat", symbol: "text.bubble") { sheet = .history },
            RadialMenuItem(id: "photo", title: "Photo", symbol: "photo") { choosingPhotos = true },
            RadialMenuItem(id: "file", title: "File", symbol: "doc") { importingFile = true },
            RadialMenuItem(id: "access", title: "Access", symbol: "iphone.gen3") { sheet = .phoneAccess },
            RadialMenuItem(id: "relays", title: "Relays", symbol: "antenna.radiowaves.left.and.right") { sheet = .relays },
            RadialMenuItem(id: "settings", title: "Settings", symbol: "gearshape") { sheet = .settings },
        ]
    }

    // MARK: touch

    private var touchLayer: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged(touchMoved)
                .onEnded(touchEnded))
            .accessibilityElement()
            .accessibilityLabel("\(agentName), \(inCall ? (moodLabel.isEmpty ? "on a call" : moodLabel) : statusText)")
            .accessibilityIdentifier("presence")
            .accessibilityValue(focusedRing.flatMap { PresenceRings.summary(engine.rings[$0]) } ?? ringsSummary)
            .accessibilityHint(inCall ? "Double-tap to interrupt." : "Double-tap to call.")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { perform(PresenceIntent.action(for: .tapHeart, inCall: inCall, talkMode: calls.talkMode, canCall: canCall)) }
            .accessibilityAdjustableAction { direction in cycleRing(direction == .increment ? 1 : -1) }
            .accessibilityAction(named: "Open conversation") { sheet = .history }
            .accessibilityAction(named: "More") { menuOrigin = engine.center }
            .accessibilityAction(named: inCall ? "End call" : "Settings") { inCall ? perform(.endCall) : (sheet = .settings) }
    }

    private var canCall: Bool {
        PresenceDemo.forced || (app.relayStatus == .connected && app.activeProfile != nil)
    }

    private func touchMoved(_ value: DragGesture.Value) {
        guard var current = touch else {
            touch = PresenceTouch(at: value.startLocation, onHeart: engine.isInHeart(value.startLocation),
                                  onSphere: engine.isOnSphere(value.startLocation))
            holdTimer = Task { @MainActor in
                try? await Task.sleep(for: .seconds(PresenceTouch.holdSeconds))
                guard !Task.isCancelled, var held = touch, let gesture = held.holdElapsed() else { return }
                touch = held
                haptics.tick(sharpness: 0.4)
                handle(gesture)
            }
            return
        }
        if let delta = current.move(to: value.location) { engine.drag(by: delta, scale: engine.radius) }
        if current.kind != .pending { holdTimer?.cancel() }
        touch = current
    }

    private func touchEnded(_ value: DragGesture.Value) {
        holdTimer?.cancel()
        guard var current = touch else { return }
        touch = nil
        let ring = current.kind == .pending ? engine.ring(at: value.startLocation) : nil
        let wasSpinning = current.kind == .spinning
        if let gesture = current.end(at: value.location, ring: ring) { handle(gesture) }
        if wasSpinning { engine.fling(velocity: value.velocity, scale: engine.radius) }
    }

    private func handle(_ gesture: PresenceGesture) {
        var kind: PresenceRingKind?
        if case .tapRing(let index) = gesture { kind = engine.rings[index].kind }
        if gesture == .holdEnded, holdingToTalk {
            holdingToTalk = false
            calls.setTalking(false)
            return
        }
        perform(PresenceIntent.action(for: gesture, inCall: inCall, talkMode: calls.talkMode, canCall: canCall, ringKind: kind))
    }

    private func perform(_ action: PresenceAction) {
        switch action {
        case .startCall(let mode):
            hintUses += 1
            haptics.tick()
            engine.ignite()
            holdingToTalk = mode == .pushToTalk
            Task { await calls.startCall(talkMode: mode) }
        case .interrupt:
            haptics.tick(sharpness: 1)
            engine.ignite()
            calls.interrupt()
        case .beginTalking:
            calls.setTalking(true)
        case .endTalking:
            calls.setTalking(false)
        case .openHistory:
            sheet = .history
        case .endCall:
            haptics.tick(sharpness: 0.9, intensity: 0.8)
            calls.hangUp()
        case .openMenu(let point):
            menuOrigin = point
        case .showResults:
            if let latest = latestResults { chat.showOnPresence(latest) }
        case .showRequests:
            haptics.tick(sharpness: 0.3)
        case .switchAgent(let step):
            switchAgent(step)
        case .none:
            break
        }
    }

    // MARK: rings

    private struct RingKey: Equatable {
        var unread: Int, requests: Int, results: Bool, focused: Int?, task: TaskUpdate?
    }

    private var ringKey: RingKey {
        let requests = (phone.prompt == nil ? 0 : 1) + (chat.pendingApproval == nil ? 0 : 1) + (calls.pendingApproval == nil ? 0 : 1)
        return RingKey(unread: chat.unread, requests: requests, results: latestResults != nil && chat.spotlight == nil,
                       focused: focusedRing, task: tasks.activeTask)
    }

    /// The newest result cards of the last day, if not on screen already.
    private var latestResults: ChatMessage? {
        chat.messages.last { $0.presentation != nil && Date().timeIntervalSince($0.date) < 86_400 }
    }

    private func syncRings() {
        let key = ringKey
        let wasRunning = engine.rings[PresenceRings.tasksRing].active
        engine.rings = PresenceRings.states(unread: key.unread, requests: key.requests, hasResults: key.results,
                                            focused: key.focused, task: key.task)
        if wasRunning, key.task?.state == .done { engine.taskFinished() }
    }

    private var ringsSummary: String {
        engine.rings.compactMap(PresenceRings.summary).joined(separator: ", ")
    }

    private func cycleRing(_ step: Int) {
        let active = engine.rings.indices.filter { engine.rings[$0].lit > 0 }
        guard !active.isEmpty else { return focusedRing = nil }
        let position = focusedRing.flatMap { active.firstIndex(of: $0) } ?? (step > 0 ? -1 : active.count)
        focusedRing = active[(position + step + active.count) % active.count]
    }

    // MARK: agents

    /// The call's agent while a call is on (it may be another paired agent ringing), else the active one.
    private var presencePalette: AgentPalette {
        if inCall, let id = calls.profileID, let profile = app.profiles.first(where: { $0.id == id }) {
            return profile.agentPalette
        }
        return app.activeProfile?.agentPalette ?? .gold
    }

    /// The presence comes apart, takes the next agent's colour and forms again.
    private func switchAgent(_ step: Int) {
        guard let next = app.neighbor(step), !engine.isBroken else { return }
        haptics.tick(sharpness: 0.5)
        engine.breakApart()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(PresenceEngine.breakSeconds * 0.7))
            // A call may have started meanwhile: never switch under it.
            guard !inCall, app.neighbor(step)?.id == next.id else { return }
            app.activate(next.id)
        }
    }

    // MARK: call

    private func start() {
        engine.reduceMotion = reduceMotion
        engine.palette = presencePalette
        engine.snapPalette()
        engine.tiltSource = { [motion] in motion.tilt }
        engine.bandSource = { [calls, chat, weak engine] in
            if calls.inCall {
                guard let spectrum = calls.spectrum() else { return nil }
                // Listening: the rings follow your voice, softer; otherwise the agent's.
                return engine?.mood == .listening ? spectrum.mic.map { $0 * 0.7 } : spectrum.agent
            }
            return chat.player.spectrum?.bands()
        }
        // Voice levels are read by the presence every frame (no polling): the call's, or a voice reply's.
        engine.levelSource = { [calls, chat] in
            if calls.inCall { return calls.liveLevels() }
            return (Double(chat.player.spectrum?.currentLevel ?? 0), 0)
        }
        engine.onMood = { mood = $0 }
        engine.onVoice = { [calls, haptics, app] level in
            guard app.preferences.voiceHaptics, calls.isConnected, !calls.isDemoCall else { return }
            haptics.follow(voice: level)
        }
        if !reduceMotion { motion.start() }
        engine.assemble()
        if PresenceDemo.autoStart {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2.2))
                perform(.startCall(app.preferences.talkMode))
            }
        }
    }

    private func stop() {
        motion.stop()
        haptics.stopVoice()
    }

    private func callChanged(_ live: Bool) {
        engine.inCall = live
        if live {
            engine.ignite()
        } else {
            holdingToTalk = false
            haptics.stopVoice()
            engine.breakApart()
            // Another paired agent called: the conversation continues with it.
            if let id = calls.profileID, id != app.activeProfile?.id, app.profiles.contains(where: { $0.id == id }) {
                app.activate(id)
            }
        }
    }

    private var voiceReplyPlaying: Bool { chat.player.playing != nil }

    /// A voice reply playing outside a call: the presence speaks it (levels come from `levelSource`).
    private func voiceReplyChanged(_ playing: Bool) {
        guard !inCall else { return }
        engine.inCall = playing
    }

    // MARK: sending things into the presence

    private func absorbed() {
        engine.ignite()
        haptics.tick(sharpness: 0.2, intensity: 0.9)
    }

    private func sendPhotos(_ items: [PhotosPickerItem]) async {
        var files: [OutgoingFile] = []
        for (index, item) in items.enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self), let jpeg = PhotoEncoder.jpeg(data) else { continue }
            files.append(OutgoingFile(kind: .photo, name: "Photo \(index + 1).jpg", mime: "image/jpeg", data: jpeg))
        }
        guard !files.isEmpty else { return }
        absorbed()
        await chat.send(text: "", files: files)
    }

    private func sendFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let file = try? OutgoingFile.from(url: url) else { return app.lastError = "Files can be at most 10 MB." }
        absorbed()
        Task { await chat.send(text: "", files: [file]) }
    }

    /// Photos, files, links or text dropped onto the presence go to the agent.
    private func receiveDrop(_ providers: [NSItemProvider]) async {
        var files: [OutgoingFile] = []
        var texts: [String] = []
        for provider in providers.prefix(4) {
            if let data = await DropLoader.data(provider, type: .image), let jpeg = PhotoEncoder.jpeg(data) {
                files.append(OutgoingFile(kind: .photo, name: "Photo \(files.count + 1).jpg", mime: "image/jpeg", data: jpeg))
            } else if let file = await DropLoader.file(provider) {
                files.append(file)
            } else if let text = await DropLoader.text(provider) {
                texts.append(text)
            }
        }
        guard !files.isEmpty || !texts.isEmpty else { return }
        absorbed()
        await chat.send(text: texts.joined(separator: "\n"), files: files)
    }
}

/// Loads dropped items. NSItemProvider calls back on its own queue, so those callbacks are made outside
/// the main actor (Swift would otherwise treat them as main-actor code and trap on that queue).
@MainActor
enum DropLoader {
    static func data(_ provider: NSItemProvider, type: UTType) async -> Data? {
        guard provider.hasItemConformingToTypeIdentifier(type.identifier) else { return nil }
        return await withCheckedContinuation { continuation in
            Self.loadData(provider, type: type) { continuation.resume(returning: $0) }
        }
    }

    static func file(_ provider: NSItemProvider) async -> OutgoingFile? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) || provider.hasItemConformingToTypeIdentifier(UTType.data.identifier)
        else { return nil }
        return await withCheckedContinuation { continuation in
            Self.loadFile(provider) { continuation.resume(returning: $0) }
        }
    }

    static func text(_ provider: NSItemProvider) async -> String? {
        if let url = await data(provider, type: .url).flatMap({ URL(dataRepresentation: $0, relativeTo: nil) }) { return url.absoluteString }
        return await data(provider, type: .plainText).flatMap { String(data: $0, encoding: .utf8) }
    }

    private nonisolated static func loadData(_ provider: NSItemProvider, type: UTType, done: @escaping @Sendable (Data?) -> Void) {
        _ = provider.loadDataRepresentation(for: type) { data, _ in done(data) }
    }

    private nonisolated static func loadFile(_ provider: NSItemProvider, done: @escaping @Sendable (OutgoingFile?) -> Void) {
        _ = provider.loadFileRepresentation(for: .data, openInPlace: false) { url, _, _ in
            done(url.flatMap { try? OutgoingFile.from(url: $0) })
        }
    }
}
