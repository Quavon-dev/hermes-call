import HermesCallCore
import SwiftUI

extension EnvironmentValues {
    /// Drawn inside the owner's coloured bubble (Standard appearance): quiet parts are white, not grey.
    @Entry var onOwnerBubble = false
}

/// Secondary text and graphics that stay readable on the owner's bubble (see `OwnerBubble`).
enum BubbleStyle {
    static func secondary(_ onBubble: Bool) -> AnyShapeStyle {
        onBubble ? AnyShapeStyle(Color.white.opacity(Double(OwnerBubble.secondaryOpacity))) : AnyShapeStyle(.secondary)
    }

    static func unplayed(_ onBubble: Bool) -> AnyShapeStyle {
        onBubble ? AnyShapeStyle(Color.white.opacity(Double(OwnerBubble.unplayedOpacity))) : AnyShapeStyle(.secondary.opacity(0.55))
    }
}

struct MessageRow: View {
    let message: ChatMessage
    let agentName: String
    let hud: Bool
    let player: VoicePlayer
    var highlighted = false
    let open: (ChatAttachment) -> Void
    /// nil: play or pause; a fraction: play from there (scrubbing).
    let play: (ChatAttachment, Double?) -> Void
    let retry: () -> Void
    let delete: () -> Void

    var body: some View {
        if let presentation = message.presentation {
            PresentationBubble(message: message, presentation: presentation, hud: hud)
                .contextMenu { deleteButton }
        } else if message.role == .system {
            Label(message.systemText, systemImage: systemSymbol)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity)
                .contextMenu { deleteButton }
        } else {
            HStack(alignment: .bottom) {
                if isOwner { Spacer(minLength: 48) }
                VStack(alignment: isOwner ? .trailing : .leading, spacing: 4) {
                    bubble
                    footer
                }
                if !isOwner { Spacer(minLength: 48) }
            }
        }
    }

    private var isOwner: Bool { message.role == .owner }

    private var systemSymbol: String {
        switch message.call?.direction {
        case .incoming: "phone.arrow.down.left"
        case .outgoing: "phone.arrow.up.right"
        case nil: "phone"
        }
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 8) {
            if message.kind == "missed_call" || message.kind == "declined_call" {
                Label(message.kind == "missed_call" ? "Missed call from \(agentName)" : "You declined a call",
                      systemImage: "phone.arrow.down.left")
                    .font(.caption.bold())
                    .foregroundStyle(hud ? HUD.alert : .red)
            }
            ForEach(message.attachments) { attachment in
                AttachmentView(attachment: attachment, player: player, open: { open(attachment) },
                               play: { play(attachment, $0) })
            }
            if let transcript = message.transcript, !transcript.isEmpty {
                Text(transcript).font(.callout.italic()).foregroundStyle(BubbleStyle.secondary(isOwner && !hud))
            }
            if !message.text.isEmpty {
                if isOwner {
                    Text(MarkdownText.attributed(message.text)).textSelection(.enabled)
                } else {
                    MarkdownText(message.text)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // Links and controls in the owner's blue bubble are white (not the bubble's own tint).
        .tint(isOwner && !hud ? .white : nil)
        .environment(\.onOwnerBubble, isOwner && !hud)
        .background { background }
        .overlay {
            if highlighted {
                // A ring just outside the bubble, so it shows on the coloured owner bubble too.
                RoundedRectangle(cornerRadius: 22).stroke(hud ? HUD.glow : HUD.alert, lineWidth: 3).padding(-5)
                    .shadow(color: (hud ? HUD.glow : HUD.alert).opacity(0.5), radius: 6)
                    .transition(.opacity)
            }
        }
        .foregroundStyle(isOwner && !hud ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .contextMenu {
            if !message.text.isEmpty {
                Button { UIPasteboard.general.string = message.text } label: { Label("Copy", systemImage: "doc.on.doc") }
            }
            deleteButton
        }
    }

    private var deleteButton: some View {
        Button(role: .destructive, action: delete) { Label("Delete on This iPhone", systemImage: "trash") }
    }

    @ViewBuilder private var background: some View {
        if hud {
            let tint = isOwner ? HUD.light : HUD.glow
            RoundedRectangle(cornerRadius: 16).fill(tint.opacity(isOwner ? 0.1 : 0.05))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(tint.opacity(0.22), lineWidth: 0.75))
        } else {
            RoundedRectangle(cornerRadius: 18).fill(isOwner ? AnyShapeStyle(HUD.ownerBubble) : AnyShapeStyle(.quaternary))
        }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Text(message.date, style: .time)
            if isOwner { statusIcon }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder private var statusIcon: some View {
        switch message.status {
        case .pending: Image(systemName: "clock").accessibilityLabel("Waiting to send")
        case .sent: Image(systemName: "checkmark").accessibilityLabel("Sent")
        case .delivered: Image(systemName: "checkmark.circle.fill").accessibilityLabel("Delivered")
        case .failed:
            Button(action: retry) {
                Label("Not delivered – tap to retry", systemImage: "exclamationmark.circle.fill").foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        case .received: EmptyView()
        }
    }
}

/// "Today", "Yesterday", or the date, between the messages of different days.
struct DayHeader: View {
    let date: Date

    var body: some View {
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.vertical, 3)
            .background(.quaternary.opacity(0.6), in: Capsule())
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .accessibilityAddTraits(.isHeader)
    }

    private var title: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let sameYear = calendar.isDate(date, equalTo: Date(), toGranularity: .year)
        return date.formatted(sameYear ? .dateTime.weekday(.wide).day().month(.wide) : .dateTime.day().month(.wide).year())
    }
}

struct AttachmentView: View {
    let attachment: ChatAttachment
    let player: VoicePlayer
    let open: () -> Void
    let play: (Double?) -> Void
    @Environment(ChatModel.self) private var chat
    @Environment(\.onOwnerBubble) private var onBubble
    @State private var image: UIImage?

    var body: some View {
        switch attachment.kind {
        case .photo:
            Button(action: open) {
                Group {
                    if let image {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Rectangle().fill(.quaternary).overlay { Image(systemName: "photo") }
                    }
                }
                .frame(width: 220, height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Photo")
            .task(id: attachment.localFile) { await loadThumbnail() }
        case .voice:
            VoiceNoteView(attachment: attachment, player: player, play: play)
        case .file:
            Button(action: open) {
                Label {
                    VStack(alignment: .leading) {
                        Text(attachment.name).lineLimit(2)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file))
                            .font(.caption).foregroundStyle(BubbleStyle.secondary(onBubble))
                    }
                } icon: {
                    Image(systemName: "doc.fill").font(.title2)
                }
            }
            .buttonStyle(.plain)
            .disabled(attachment.localFile == nil)
        }
    }

    private func loadThumbnail() async {
        guard let url = await chat.attachmentURL(attachment) else { return }
        image = await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 660,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                  ] as CFDictionary) else { return nil }
            return UIImage(cgImage: thumbnail)
        }.value
    }
}

/// Play/pause, a waveform to scrub in, the time and the speed.
struct VoiceNoteView: View {
    let attachment: ChatAttachment
    let player: VoicePlayer
    let play: (Double?) -> Void
    @Environment(ChatModel.self) private var chat
    @Environment(\.onOwnerBubble) private var onBubble
    @State private var bars: [Float] = []

    private var isCurrent: Bool { player.playing == attachment.id }
    private var isPlaying: Bool { isCurrent && !player.isPaused }
    private var total: TimeInterval { isCurrent && player.duration > 0 ? player.duration : attachment.duration ?? 0 }
    private var progress: Double { isCurrent ? player.progress : 0 }

    var body: some View {
        HStack(spacing: 10) {
            Button { play(nil) } label: {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 34))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPlaying ? "Pause" : "Play voice note")
            VStack(alignment: .leading, spacing: 4) {
                WaveformBars(bars: bars, progress: progress, onBubble: onBubble)
                    .frame(width: 160, height: 28)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                        play(min(max(value.location.x / 160, 0), 1))
                    })
                    .accessibilityElement()
                    .accessibilityLabel("Voice note")
                    .accessibilityValue(Self.clock(progress * total) + " of " + Self.clock(total))
                    .accessibilityAdjustableAction { direction in
                        play(min(max(progress + (direction == .increment ? 0.1 : -0.1), 0), 1))
                    }
                HStack {
                    Text(isCurrent ? Self.clock(progress * total) : Self.clock(total)).font(.caption.monospacedDigit())
                    Spacer()
                    if isCurrent {
                        Button { player.cycleRate() } label: {
                            Text(player.rate == 1 ? "1×" : player.rate == 1.5 ? "1.5×" : "2×")
                                .font(.caption.bold().monospacedDigit())
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(.secondary.opacity(0.25), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Playback speed \(player.rate.formatted())")
                    }
                }
                .foregroundStyle(BubbleStyle.secondary(onBubble))
            }
        }
        .disabled(attachment.localFile == nil)
        .task(id: attachment.localFile) {
            guard let url = await chat.attachmentURL(attachment) else { return }
            bars = await VoiceWaveform.shared.bars(for: url)
        }
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded(.down))
        return "\(whole / 60):\(String(format: "%02d", whole % 60))"
    }
}

/// Bars of a voice note's loudness; the played part is drawn stronger.
struct WaveformBars: View {
    let bars: [Float]
    let progress: Double
    var onBubble = false

    var body: some View {
        Canvas { context, size in
            let values = bars.isEmpty ? Array(repeating: Float(0.15), count: VoiceWaveform.bars) : bars
            let step = size.width / CGFloat(values.count)
            for (index, value) in values.enumerated() {
                let height = max(3, CGFloat(value) * size.height)
                let rect = CGRect(x: CGFloat(index) * step + step * 0.2, y: (size.height - height) / 2, width: step * 0.6, height: height)
                let played = (Double(index) + 0.5) / Double(values.count) <= progress
                context.fill(Path(roundedRect: rect, cornerRadius: step * 0.3),
                             with: .style(played ? (onBubble ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary)) : BubbleStyle.unplayed(onBubble)))
            }
        }
    }
}

struct TypingIndicator: View {
    let hud: Bool

    var body: some View {
        Image(systemName: "ellipsis")
            .font(.title3.bold())
            .symbolEffect(.variableColor.iterative.dimInactiveLayers)
            .foregroundStyle(hud ? HUD.glow : .secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 16).fill(.quaternary))
            .accessibilityLabel("typing")
    }
}

struct ChatApprovalSheet: View {
    let approval: ChatApproval
    @Environment(ChatModel.self) private var chat

    var body: some View {
        ApprovalPanel(command: approval.command, details: approval.details, step: chat.approvalStep,
                      onDeny: { Task { await chat.answerApproval(approve: false) } },
                      onApprove: { Task { await chat.answerApproval(approve: true) } })
    }
}
