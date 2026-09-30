import SwiftUI

struct RadialMenuItem: Identifiable {
    let id: String
    let title: String
    let symbol: String
    var destructive = false
    let action: () -> Void
}

/// Long-press menu that blooms around the finger. Items are real buttons (VoiceOver reads them
/// in order); tap outside to close.
struct RadialMenu: View {
    let origin: CGPoint
    let items: [RadialMenuItem]
    let dismiss: () -> Void
    @State private var open = false

    static let radius: CGFloat = 96
    static let itemSize: CGFloat = 56

    var body: some View {
        GeometryReader { geo in
            let margin = Self.radius + Self.itemSize / 2 + 12
            let center = CGPoint(x: min(max(origin.x, margin), geo.size.width - margin),
                                 y: min(max(origin.y, margin + 40), geo.size.height - margin - 110))
            ZStack {
                Color.black.opacity(open ? 0.72 : 0)
                    .ignoresSafeArea()
                    .onTapGesture(perform: close)
                    .accessibilityHidden(true)
                Circle().stroke(HUD.glow.opacity(open ? 0.25 : 0), lineWidth: 0.75)
                    .frame(width: Self.radius * 2, height: Self.radius * 2)
                    .position(center)
                    .accessibilityHidden(true)
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    let angle = -Double.pi / 2 + Double(index) / Double(items.count) * 2 * .pi
                    let point = CGPoint(x: center.x + cos(angle) * Self.radius, y: center.y + sin(angle) * Self.radius)
                    Button {
                        close()
                        item.action()
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 20, weight: .medium))
                                .foregroundStyle(item.destructive ? HUD.alert : HUD.light)
                                .frame(width: Self.itemSize, height: Self.itemSize)
                                .background(Circle().fill(Color.black.opacity(0.8)))
                                .overlay(Circle().stroke((item.destructive ? HUD.alert : HUD.glow).opacity(0.5), lineWidth: 0.75))
                            HUD.label(item.title, size: 8).fixedSize()
                        }
                    }
                    .buttonStyle(.plain)
                    .position(open ? point : center)
                    .scaleEffect(open ? 1 : 0.3)
                    .opacity(open ? 1 : 0)
                    .animation(.spring(response: 0.35, dampingFraction: 0.75).delay(Double(index) * 0.025), value: open)
                    .accessibilityLabel(item.title)
                }
            }
        }
        .onAppear { open = true }
        .accessibilityAction(.escape, close)
    }

    private func close() {
        open = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            dismiss()
        }
    }
}
