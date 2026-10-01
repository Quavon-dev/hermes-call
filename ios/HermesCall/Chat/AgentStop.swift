import Foundation
import HermesCallCore
import UIKit

/// The emergency stop from the chat, the presence and the intents (docs/protocol.md, "Stop"): `/stop` goes
/// through the durable chat path (the bridge also ends the task and cuts off a call's turn); a call with that
/// agent is cut off here at once, and a demo call simply ends.
@MainActor
enum AgentStop {
    /// nil: the active agent.
    @discardableResult
    static func request(chat: ChatModel, calls: CallCoordinator?, profileID: UUID? = nil) async -> ChatModel.StopResult {
        let target = profileID ?? chat.app.activeProfile?.id
        if let calls, calls.inCall, calls.profileID == nil || calls.profileID == target {
            if calls.isDemoCall { calls.hangUp() } else { calls.interrupt() }
        }
        return await chat.requestStop(profileID: target)
    }

    /// A tap on Stop: a light haptic, then the request (the chat shows "Stop requested").
    static func tapped(chat: ChatModel, calls: CallCoordinator?) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task { await request(chat: chat, calls: calls) }
    }

    /// For `StopAgentIntent`: never activates the agent or opens a screen.
    static func fromIntent(app: AppModel, chat: ChatModel, calls: CallCoordinator?, agent: UUID?) async -> StopAgentIntent.Outcome {
        guard let profile = agent.flatMap({ id in app.profiles.first { $0.id == id } }) ?? app.activeProfile else { return .notPaired }
        guard profile.isDemo || app.mayShare else { return .needsConsent }
        switch await request(chat: chat, calls: calls, profileID: profile.id) {
        case .delivered: return .requested
        case .queued: return .queued
        case .unavailable: return .notPaired
        }
    }
}
