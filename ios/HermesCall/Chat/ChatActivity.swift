import HermesCallCore
import SwiftUI
import UIKit

extension ChatModel {
    func run(_ command: SlashCommand, calls: CallCoordinator) {
        UISelectionFeedbackGenerator().selectionChanged()
        if command == .stop { return AgentStop.tapped(chat: self, calls: calls) }
        Task { await send(text: command.text) }
    }
}

struct TaskFeedCard: View {
    let steps: [TaskUpdate]
    let hud: Bool
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var latest: TaskUpdate? { steps.last }
    private var tint: Color { hud ? HUD.glow : HUD.alert }

    var body: some View {
        if let latest {
            VStack(alignment: .leading, spacing: 10) {
                Button { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { expanded.toggle() } } label: {
                    header(latest)
                }
                .buttonStyle(.plain)
                .disabled(steps.count < 2)
                if let preview = latest.preview, !preview.isEmpty {
                    CommandPreview(text: preview, isCommand: latest.isCommand, hud: hud, lines: expanded ? 8 : 3)
                        .id("preview-\(latest.step)")
                        .transition(.push(from: .bottom).combined(with: .opacity))
                }
                if let total = latest.total, total > 1 {
                    ProgressView(value: Double(min(latest.step, total)), total: Double(total))
                        .tint(tint)
                        .animation(.smooth, value: latest.step)
                }
                if expanded {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(steps.dropLast(), id: \.step) { step in StepRow(step: step, hud: hud) }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(12)
            .frame(maxWidth: 360, alignment: .leading)
            .background {
                if hud {
                    RoundedRectangle(cornerRadius: 18).fill(tint.opacity(0.06))
                } else {
                    BubbleSurface.agent(RoundedRectangle(cornerRadius: 18))
                }
            }
            .overlay { ScanningBorder(running: latest.state == .running && !reduceMotion, tint: tint) }
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: latest.step)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityText(latest))
            .accessibilityIdentifier("chat.activity")
        }
    }

    private func header(_ latest: TaskUpdate) -> some View {
        HStack(spacing: 10) {
            ToolGlyph(symbol: latest.symbol, state: latest.state, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(latest.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(hud ? AnyShapeStyle(HUD.light) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                    .id("label-\(latest.step)")
                    .transition(.push(from: .bottom).combined(with: .opacity))
                HStack(spacing: 6) {
                    Text(stepText(latest)).contentTransition(.numericText(value: Double(latest.step)))
                    switch latest.state {
                    case .running: Text(Date(timeIntervalSince1970: Double(latest.startedAt) / 1000), style: .timer).monospacedDigit()
                    case .done: Text("Done")
                    case .failed: Text("Stopped")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if steps.count > 1 {
                Image(systemName: "chevron.down")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 180 : 0))
            }
        }
        .contentShape(Rectangle())
    }

    private func stepText(_ update: TaskUpdate) -> String {
        update.total.map { "Step \(update.step) of \($0)" } ?? "Step \(update.step)"
    }

    private func accessibilityText(_ update: TaskUpdate) -> String {
        [update.label, stepText(update), update.preview].compactMap(\.self).joined(separator: ", ")
    }
}

private struct ToolGlyph: View {
    let symbol: String
    let state: TaskContentState.State
    let tint: Color

    var body: some View {
        ZStack {
            Circle().fill(tint.opacity(0.16))
            Image(systemName: shown)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(state == .failed ? Color.red : tint)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.pulse, isActive: state == .running)
        }
        .frame(width: 34, height: 34)
        .accessibilityHidden(true)
    }

    private var shown: String {
        switch state {
        case .running: symbol
        case .done: "checkmark"
        case .failed: "xmark"
        }
    }
}

private struct CommandPreview: View {
    let text: String
    let isCommand: Bool
    let hud: Bool
    let lines: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if isCommand { Text("$").foregroundStyle(hud ? HUD.glow : .green) }
            Text(text).foregroundStyle(isCommand ? Color.white.opacity(0.92) : Color.secondary).lineLimit(lines)
        }
        .font(.caption.monospaced())
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 10).fill(isCommand ? AnyShapeStyle(Color.black.opacity(hud ? 0.7 : 0.85)) : AnyShapeStyle(.quinary))
        }
        .textSelection(.enabled)
    }
}

private struct StepRow: View {
    let step: TaskUpdate
    let hud: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: step.state == .failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(step.state == .failed ? Color.red : (hud ? HUD.glow : Color.green))
            VStack(alignment: .leading, spacing: 1) {
                Label(step.label, systemImage: step.symbol).font(.caption.weight(.medium))
                if let preview = step.preview, !preview.isEmpty {
                    Text(step.isCommand ? "$ " + preview : preview)
                        .font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}

private struct ScanningBorder: View {
    let running: Bool
    let tint: Color
    @State private var angle = 0.0

    var body: some View {
        RoundedRectangle(cornerRadius: 18)
            .strokeBorder(
                AngularGradient(colors: [tint.opacity(0), tint.opacity(0.9), tint.opacity(0)], center: .center,
                                angle: .degrees(angle)),
                lineWidth: 1.5)
            .opacity(running ? 1 : 0)
            .animation(.easeOut(duration: 0.4), value: running)
            .onAppear { withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) { angle = 360 } }
            .allowsHitTesting(false)
    }
}

struct StreamingBubble: View {
    let text: String
    let hud: Bool

    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                MarkdownText(text)
                Caret(tint: hud ? HUD.glow : HUD.alert)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background {
                if hud {
                    RoundedRectangle(cornerRadius: 16).fill(HUD.glow.opacity(0.05))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(HUD.glow.opacity(0.22), lineWidth: 0.75))
                } else {
                    BubbleSurface.agent(RoundedRectangle(cornerRadius: 22))
                }
            }
            .animation(.smooth(duration: 0.25), value: text)
            Spacer(minLength: 48)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("writing: \(text)")
    }
}

private struct Caret: View {
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Capsule().fill(tint).frame(width: 10, height: 3)
            .phaseAnimator(reduceMotion ? [1.0] : [1.0, 0.15]) { caret, opacity in caret.opacity(opacity) } animation: { _ in
                .easeInOut(duration: 0.5)
            }
            .accessibilityHidden(true)
    }
}

struct TypingIndicator: View {
    let hud: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    let wave = reduceMotion ? 0.5 : (sin(time * 6 - Double(index) * 0.9) + 1) / 2
                    Circle().frame(width: 8, height: 8).offset(y: -4 * wave).opacity(0.35 + 0.65 * wave)
                }
            }
        }
        .foregroundStyle(hud ? HUD.glow : .secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background {
            if hud {
                RoundedRectangle(cornerRadius: 20).fill(HUD.glow.opacity(0.06))
            } else {
                BubbleSurface.agent(RoundedRectangle(cornerRadius: 22))
            }
        }
        .accessibilityElement()
        .accessibilityLabel("typing")
    }
}

struct SlashSuggestions: View {
    let commands: [SlashCommand]
    let hud: Bool
    let pick: (SlashCommand) -> Void

    private static let rowHeight: CGFloat = 52

    var body: some View {
        ScrollView {
            VStack(spacing: 0) { rows }.padding(.vertical, 4)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(CGFloat(commands.count), 4.5) * Self.rowHeight + 8)
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .modifier(SuggestionSurface(hud: hud))
    }

    private var rows: some View {
        ForEach(commands) { command in
            Button { pick(command) } label: {
                HStack(spacing: 12) {
                    Image(systemName: command.symbol)
                        .font(.body.weight(.medium))
                        .foregroundStyle(hud ? HUD.glow : HUD.alert)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(command.text).font(.subheadline.monospaced().weight(.semibold))
                            if let arguments = command.arguments {
                                Text(arguments).font(.caption.monospaced()).foregroundStyle(.tertiary).lineLimit(1)
                            }
                        }
                        Text(command.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: command.runsAtOnce ? "arrow.up.circle.fill" : "text.cursor")
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .frame(height: Self.rowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("slash.\(command.name)")
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }
}

/// The slash-command list: a glass panel above the composer (Standard), black with a hairline (HUD).
private struct SuggestionSurface: ViewModifier {
    let hud: Bool

    func body(content: Content) -> some View {
        if hud {
            content
                .background(RoundedRectangle(cornerRadius: 22).fill(Color.black))
                .overlay(RoundedRectangle(cornerRadius: 22).stroke(HUD.glow.opacity(0.35), lineWidth: 0.75))
                .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        } else {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22))
        }
    }
}

struct Arrival: ViewModifier {
    let active: Bool
    let fromTrailing: Bool
    @State private var plays = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .keyframeAnimator(initialValue: 1.0, trigger: plays) { view, progress in
                view
                    .opacity(progress)
                    .scaleEffect(0.9 + 0.1 * progress, anchor: fromTrailing ? .bottomTrailing : .bottomLeading)
                    .offset(y: 16 * (1 - progress))
            } keyframes: { _ in
                MoveKeyframe(0.0)
                SpringKeyframe(1.0, duration: 0.5, spring: .bouncy(duration: 0.45, extraBounce: 0.1))
            }
            .onAppear { if active { play() } }
            .onChange(of: active) { _, now in if now { play() } }
    }

    private func play() {
        if !reduceMotion { plays += 1 }
    }
}
