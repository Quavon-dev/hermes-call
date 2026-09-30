import HermesCallCore
import Intents
import SwiftUI

@main
struct HermesCallApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app: AppModel
    @State private var calls: CallCoordinator
    @State private var chat: ChatModel
    @State private var phone: PhoneContextModel
    @State private var tasks: TaskActivityModel
    @State private var push: PushRegistrar
    @State private var notifications: ChatNotifications
    @State private var network = NetworkMonitor()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if DEBUG
        UITestSupport.resetIfRequested()
        ChatDemo.seedIfRequested()
        #endif
        let app = AppModel()
        let router = MessageRouter()
        let calls = CallCoordinator(app: app, router: router)
        let links = AgentLinks(app: app)
        let chat = ChatModel(app: app, links: links)
        links.demo.chat = chat
        let phone = PhoneContextModel(app: app)
        let tasks = TaskActivityModel(app: app)
        router.onTask = { [weak tasks] message, session in tasks?.receive(message, from: session) }
        router.onPhone = { [weak phone] message, session in phone?.receive(message, from: session) }
        router.onChat = { [weak chat] message, session in chat?.receive(message, from: session) }
        calls.onCallEnded = { [weak chat] profile, duration, incoming in
            chat?.noteCall(profile: profile, duration: duration, incoming: incoming)
        }
        app.onConnected = { [weak chat, weak tasks] session in
            chat?.connected(session)
            tasks?.connected(session)
        }
        chat.isInCall = { [weak calls] in calls?.inCall ?? false }
        chat.player.isCallActive = { [weak calls] in calls?.inCall ?? false }
        _app = State(initialValue: app)
        _calls = State(initialValue: calls)
        _chat = State(initialValue: chat)
        _phone = State(initialValue: phone)
        _tasks = State(initialValue: tasks)
        _push = State(initialValue: PushRegistrar(app: app, calls: calls))
        _notifications = State(initialValue: ChatNotifications(app: app, chat: chat, phone: phone))
        AppServices.shared.configure(app: app, chat: chat, calls: calls)
        PlaceMonitor.shared.tellAgent = { [weak chat] text, profile in await chat?.send(text: text, profileID: profile) }
        PlaceMonitor.shared.start()
        WatchBridge.shared.configure(app: app, chat: chat, calls: calls)
        #if DEBUG
        if ChatDemo.enabled { app.tab = .chat }
        tasks.runDemoIfRequested()
        PresenceStill.renderIconCandidatesIfRequested()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .environment(calls)
                .environment(chat)
                .environment(phone)
                .environment(tasks)
                .environment(network)
                .onAppear {
                    delegate.notifications = notifications
                    network.onPathRestored = { [app] in app.reconnectNow() }
                    network.start()
                    if !app.realProfiles.isEmpty { notifications.requestAuthorization() }
                }
                .onChange(of: app.realProfiles.count) { _, count in
                    if count > 0 { notifications.requestAuthorization() }
                }
                .onOpenURL { url in open(url) }
                #if DEBUG
                .task(id: app.activeProfile?.id) {
                    try? await Task.sleep(for: .seconds(1))
                    phone.showDemoPromptIfRequested()
                }
                #endif
                .onContinueUserActivity(NSStringFromClass(INStartCallIntent.self)) { activity in callBack(activity) }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active:
                app.isForeground = true
                app.connect()
            case .background: app.enterBackground()
            default: app.isForeground = false
            }
        }
    }

    /// `hermescall://pair…` (a pairing link opened on this iPhone: confirmed before pairing), `hermescall://chat`
    /// and `hermescall://call` (widget, shortcuts; `?agent=<id>` picks the agent).
    private func open(_ url: URL) {
        guard url.scheme == "hermescall" else { return }
        if url.host == "pair" { return app.route = .pair(url.absoluteString) }
        let agent = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "agent" }?.value
        let id = agent.flatMap(UUID.init(uuidString:))
        switch url.host {
        case "chat": app.openChat(id)
        case "call":
            if let id, id != app.activeProfile?.id { app.activate(id) }
            app.tab = .call
            Task { await calls.startCall() }
        default: break
        }
    }

    /// A tap on a Hermes Call entry in the Phone app's Recents (CallKit, `includesCallsInRecents`):
    /// call that agent back. The handle is the bridge name the call was shown with.
    private func callBack(_ activity: NSUserActivity) {
        let intent = activity.interaction?.intent as? INStartCallIntent
        if let name = intent?.contacts?.first?.personHandle?.value,
           let profile = app.profiles.first(where: { $0.bridgeName == name }) {
            app.activate(profile.id)
        }
        app.tab = .call
        Task { await calls.startCall() }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(CallCoordinator.self) private var calls
    @Environment(ChatModel.self) private var chat
    /// "Not now" on the consent screen: not asked again until the next launch (actions still ask).
    @State private var consentDeferred = false

    /// HUD appearance: the presence is the whole app (and the call screen).
    private var presence: Bool { app.preferences.appearance == .hud }

    /// Standard appearance shows calls on their own screen.
    private var callScreen: Bool { !presence && calls.inCall && calls.phase != .ringing }

    /// Asked once, right after the first agent (or the demo) is added, before anything can be sent.
    private var askConsent: Bool { !app.profiles.isEmpty && !app.preferences.aiConsent && !consentDeferred }

    var body: some View {
        @Bindable var app = app
        Group {
            if app.profiles.isEmpty {
                OnboardingView()
            } else if presence {
                PresenceView()
            } else {
                TabView(selection: $app.tab) {
                    Tab("Call", systemImage: "phone.fill", value: AppTab.call) { HomeView() }
                    Tab("Chat", systemImage: "bubble.left.and.bubble.right.fill", value: AppTab.chat) { ChatHome() }
                        .badge(chat.unread)
                }
            }
        }
        .fullScreenCover(isPresented: .constant(callScreen)) { InCallView().agentTheme() }
        .fullScreenCover(isPresented: Binding(get: { askConsent && !callScreen }, set: { if !$0 { consentDeferred = true } })) {
            ConsentView { consentDeferred = true }.agentTheme()
        }
        .phonePrompt(enabled: !callScreen && chat.pendingApproval == nil)
        .sheet(item: Binding(get: { callScreen ? nil : chat.pendingApproval }, set: { if $0 == nil { chat.pendingApproval = nil } })) {
            ChatApprovalSheet(approval: $0).interactiveDismissDisabled().agentTheme()
        }
        .sheet(item: $app.route) { route in routeView(route).agentTheme() }
        .hudStyle(app.preferences.appearance == .hud)
        .onChange(of: calls.inCall) { _, live in if live { chat.player.stop() } }
        .task {
            // The Home Screen icon can be out of step with the setting (reinstall, restore): fix it once active.
            try? await Task.sleep(for: .seconds(1.5))
            AppIconSwitcher.apply(app.preferences.appIcon, appearance: app.preferences.appearance)
            #if DEBUG
            // `-SetIcon presence|standard`: switch the icon for a test.
            if let forced = UserDefaults.standard.string(forKey: "SetIcon").flatMap(AppIconChoice.init(rawValue:)) {
                AppIconSwitcher.apply(forced, appearance: app.preferences.appearance)
            }
            #endif
        }
        .alert(app.error?.title ?? "Hermes Call", isPresented: Binding(get: { app.error != nil }, set: { if !$0 { app.error = nil } }),
               presenting: app.error) { error in
            if let action = error.recoveryTitle, let recovery = error.recovery {
                Button(action) { recover(recovery) }
            }
            Button(error.recovery == nil ? "OK" : "Not now", role: .cancel) {}
        } message: { error in
            Text(error.message)
        }
    }

    @ViewBuilder private func routeView(_ route: AppRoute) -> some View {
        switch route {
        case .consent: ConsentView()
        case .relays: ProfilesView()
        case .pair(let link): AddRelayView(initialLink: link)
        }
    }

    private func recover(_ recovery: AppError.Recovery) {
        switch recovery {
        case .openSettings:
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        case .reviewConsent:
            app.route = .consent
        case .showRelays:
            app.route = .relays
        }
    }
}
