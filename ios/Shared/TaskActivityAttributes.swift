import ActivityKit
import HermesCallCore

/// The agent's work on a longer task, as a Live Activity (Lock Screen, Dynamic Island).
/// Compiled into the app and the widget extension. No fields: a push-to-start carries `"attributes": {}`,
/// so nothing about the agent travels through Apple; the widget reads the name and colour from the app group.
struct HermesTaskAttributes: ActivityAttributes {
    typealias ContentState = TaskContentState
}
