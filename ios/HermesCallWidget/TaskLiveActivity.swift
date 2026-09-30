import ActivityKit
import HermesCallCore
import SwiftUI
import WidgetKit

/// The agent at work: Lock Screen banner and Dynamic Island. The content comes from the app (while it
/// runs) or from relay pushes (then the label is "Working…" unless the owner allowed step names).
struct TaskLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: HermesTaskAttributes.self) { context in
            TaskLockScreenView(state: context.state)
                .activityBackgroundTint(Gold.deep.opacity(0.92))
                .activitySystemActionForegroundColor(Gold.light)
                .widgetURL(URL(string: "hermescall://open"))
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    PresenceEmblem(progress: state.progressShown).frame(width: 44, height: 44)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    TaskTimer(state: state).font(.system(.body, design: .monospaced)).foregroundStyle(Gold.glow)
                        .frame(maxWidth: 70, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(TaskText.agentName).font(.system(.caption, design: .monospaced)).foregroundStyle(Gold.glow)
                        Text(TaskText.headline(state)).font(.system(.subheadline, design: .monospaced)).lineLimit(1)
                            .foregroundStyle(Gold.light)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    TaskProgressBar(state: state).padding(.top, 4)
                }
            } compactLeading: {
                PresenceEmblem(progress: state.progressShown).frame(width: 22, height: 22)
            } compactTrailing: {
                Text(TaskText.compact(state)).font(.system(.caption, design: .monospaced).monospacedDigit())
                    .foregroundStyle(Gold.glow).frame(maxWidth: 44)
            } minimal: {
                PresenceEmblem(progress: state.progressShown).frame(width: 20, height: 20)
            }
            .widgetURL(URL(string: "hermescall://open"))
            .keylineTint(Gold.glow)
        }
    }
}

private enum TaskText {
    static var agentName: String { SharedContainer.agentName }

    static func headline(_ state: TaskContentState) -> String {
        switch state.state {
        case .running: state.label
        case .done: "Done"
        case .failed: "Stopped"
        }
    }

    static func compact(_ state: TaskContentState) -> String {
        if state.state == .done { return "✓" }
        if let total = state.total { return "\(state.step)/\(total)" }
        return "\(state.step)"
    }

    static func steps(_ state: TaskContentState) -> String {
        if let total = state.total { return "Step \(state.step) of \(total)" }
        return state.step == 1 ? "1 step" : "\(state.step) steps"
    }
}

private extension TaskContentState {
    var progressShown: Double? { state == .running ? (fraction ?? 0.15) : 1 }
}

/// Elapsed time, counting while the agent works.
private struct TaskTimer: View {
    let state: TaskContentState

    var body: some View {
        if state.state == .running {
            Text(timerInterval: state.startDate...Date.distantFuture, countsDown: false)
        } else {
            Text(Duration.seconds(max(0, Date().timeIntervalSince(state.startDate))).formatted(.time(pattern: .minuteSecond)))
        }
    }
}

private struct TaskProgressBar: View {
    let state: TaskContentState

    var body: some View {
        if let fraction = state.fraction, state.state == .running {
            ProgressView(value: fraction).tint(Gold.glow)
        } else if state.state == .running {
            // No total: a bar that fills over the first few minutes, so it never looks stuck.
            ProgressView(timerInterval: state.startDate...state.startDate.addingTimeInterval(180), countsDown: false) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
            .tint(Gold.glow)
        } else {
            ProgressView(value: 1).tint(state.state == .done ? Gold.light : Gold.ember)
        }
    }
}

private struct TaskLockScreenView: View {
    let state: TaskContentState

    var body: some View {
        HStack(spacing: 14) {
            PresenceEmblem(progress: state.progressShown).frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(TaskText.agentName.uppercased()).font(.system(size: 11, weight: .medium, design: .monospaced))
                        .tracking(2).foregroundStyle(Gold.glow)
                    Spacer()
                    TaskTimer(state: state).font(.system(.caption, design: .monospaced)).foregroundStyle(Gold.glow.opacity(0.8))
                }
                Text(TaskText.headline(state)).font(.system(.headline, design: .monospaced)).foregroundStyle(Gold.light).lineLimit(1)
                TaskProgressBar(state: state)
                Text(TaskText.steps(state)).font(.system(.caption2, design: .monospaced)).foregroundStyle(Gold.glow.opacity(0.7))
            }
        }
        .padding(16)
    }
}
