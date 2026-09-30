import HermesCallCore
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
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let app = AppModel()
        let calls = CallCoordinator(app: app)
        let chat = ChatModel(app: app)
        let phone = PhoneContextModel(app: app)
        let tasks = TaskActivityModel(app: app)
        calls.onTaskMessage = { [weak tasks] message, session in tasks?.receive(message, from: session) }
        calls.onPhoneMessage = { [weak phone] message, session in phone?.receive(message, from: session) }
        calls.onChatMessage = { [weak chat] message, session in chat?.receive(message, from: session) }
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
        _notifications = State(initialValue: ChatNotifications(app: app, chat: chat))
        AppServices.shared.configure(app: app, chat: chat, calls: calls)
        PlaceMonitor.shared.tellAgent = { [weak chat] text, profile in await chat?.send(text: text, profileID: profile) }
        PlaceMonitor.shared.start()
        WatchBridge.shared.configure(app: app, chat: chat, calls: calls)
        #if DEBUG
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
                .onAppear {
                    delegate.notifications = notifications
                    if !app.profiles.isEmpty { notifications.requestAuthorization() }
                }
                .onChange(of: app.profiles.count) { _, count in
                    if count > 0 { notifications.requestAuthorization() }
                }
                .onOpenURL { url in open(url) }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            app.isForeground = phase == .active
            switch phase {
            case .active: app.connect()
            case .background where !app.isBorrowed: app.disconnect()
            default: break
            }
        }
    }

    /// `hermescall://chat` and `hermescall://call` (widget, shortcuts); pairing links are handled by onboarding.
    private func open(_ url: URL) {
        guard url.scheme == "hermescall" else { return }
        switch url.host {
        case "chat": app.tab = .chat
        case "call":
            app.tab = .call
            Task { await calls.startCall() }
        default: break
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(CallCoordinator.self) private var calls
    @Environment(ChatModel.self) private var chat

    /// HUD appearance: the presence is the whole app (and the call screen).
    private var presence: Bool { app.preferences.appearance == .hud }

    /// What the Apple Watch shows; it is updated when this changes.
    private var watchKey: String {
        let profile = app.activeProfile
        return [profile?.id.uuidString, chat.shownProfileID?.uuidString, profile?.bridgeName, profile?.agentPalette.rawValue, chat.messages.last?.id,
                String(app.preferences.showMessageText)].map { $0 ?? "-" }.joined(separator: "|")
    }

    /// Standard appearance shows calls on their own screen.
    private var callScreen: Bool { !presence && calls.inCall && calls.phase != .ringing }

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
                    Tab("Chat", systemImage: "bubble.left.and.bubble.right.fill", value: AppTab.chat) { ChatView() }
                        .badge(chat.unread)
                }
            }
        }
        .fullScreenCover(isPresented: .constant(callScreen)) { InCallView() }
        .phonePrompt(enabled: !callScreen && chat.pendingApproval == nil)
        .sheet(item: Binding(get: { callScreen ? nil : chat.pendingApproval }, set: { if $0 == nil { chat.pendingApproval = nil } })) {
            ChatApprovalSheet(approval: $0).interactiveDismissDisabled()
        }
        .hudStyle(app.preferences.appearance == .hud)
        .onChange(of: calls.inCall) { _, live in if live { chat.player.stop() } }
        .onChange(of: watchKey, initial: true) { WatchBridge.shared.publish() }
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
        .alert("Hermes Call", isPresented: Binding(get: { app.lastError != nil }, set: { if !$0 { app.lastError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(app.lastError ?? "")
        }
    }
}
