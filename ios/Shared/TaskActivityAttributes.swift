import ActivityKit
import Foundation
import HermesCallCore

/// The agent's work on a longer task, as a Live Activity (Lock Screen, Dynamic Island).
/// Compiled into the app and the widget extension. The app fills in which agent it is when it starts the
/// activity itself; a push-to-start carries `"attributes": {}` (nothing about the agent travels through
/// Apple), so all fields are optional and the widget then shows the active agent from the app group.
struct HermesTaskAttributes: ActivityAttributes {
    typealias ContentState = TaskContentState

    var agentID: UUID?
    var agentName: String?
    /// `AgentPalette` raw value.
    var palette: String?
}
