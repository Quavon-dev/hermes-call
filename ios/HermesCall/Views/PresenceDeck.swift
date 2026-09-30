import HermesCallCore
import SwiftUI

/// Result cards coming out of the presence: each flies from the sphere (above this view) along a
/// brief beam of light and lands in a plain, readable row. Swipe down on the title to put them back.
struct PresenceDeck: View {
    let message: ChatMessage
    let presentation: Presentation
    let dismiss: () -> Void
    @State private var landed = false
    @State private var beams = false
    @State private var selected: Presentation.Item?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let cardWidth: CGFloat = 228

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            GeometryReader { geo in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(Array(presentation.items.enumerated()), id: \.element.id) { index, item in
                            ResultCard(item: item, hud: true, width: Self.cardWidth)
                                .fixedSize(horizontal: false, vertical: true)
                                .onTapGesture { selected = item }
                                .accessibilityAddTraits(.isButton)
                                .accessibilityAction(named: "Details") { selected = item }
                                .modifier(FlyOut(landed: landed, index: index, from: origin(for: index, in: geo.size),
                                                 reduceMotion: reduceMotion))
                        }
                    }
                    .padding(.horizontal, 20)
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
                .scrollClipDisabled()
                .overlay(alignment: .top) { beamLayer(in: geo.size) }
            }
        }
        .onAppear(perform: unfold)
        .onChange(of: message.id) {
            landed = false
            unfold()
        }
        .sheet(item: $selected) { ResultDetail(item: $0, hud: true) }
        .accessibilityAction(named: "Close results", fold)
    }

    private var header: some View {
        HStack(spacing: 10) {
            HUD.label(presentation.title, size: 11).foregroundStyle(HUD.light).lineLimit(1)
            HUD.label("\(presentation.items.count)", size: 9)
            Spacer()
            Button(action: fold) {
                Image(systemName: "chevron.down").font(.footnote.weight(.semibold)).foregroundStyle(HUD.glow)
                    .frame(width: Metrics.iconButton, height: Metrics.iconButton)
            }
            .accessibilityLabel("Close results")
        }
        .padding(.leading, 20)
        .padding(.trailing, 8)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 20).onEnded { if $0.translation.height > 50 { fold() } })
        .opacity(landed ? 1 : 0)
        .animation(.easeOut(duration: 0.3), value: landed)
    }

    /// Where a card starts: the sphere's center, above this view.
    private func origin(for index: Int, in size: CGSize) -> CGSize {
        let x = size.width / 2 - (20 + Self.cardWidth / 2 + CGFloat(index) * (Self.cardWidth + 12))
        return CGSize(width: x, height: -size.height * 0.9)
    }

    private func beamLayer(in size: CGSize) -> some View {
        Canvas { context, canvas in
            context.blendMode = .plusLighter
            let top = CGPoint(x: canvas.width / 2, y: -size.height * 0.9)
            for index in 0..<min(presentation.items.count, 3) {
                let target = CGPoint(x: 20 + Self.cardWidth / 2 + CGFloat(index) * (Self.cardWidth + 12), y: 0)
                var beam = Path()
                beam.move(to: top)
                beam.addLine(to: target)
                context.stroke(beam, with: .linearGradient(Gradient(colors: [HUD.light.opacity(0.7), HUD.glow.opacity(0.05)]),
                                                           startPoint: top, endPoint: target), lineWidth: 1)
            }
        }
        .frame(height: 1)
        .opacity(beams ? 1 : 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func unfold() {
        guard !reduceMotion else { return landed = true }
        beams = true
        withAnimation { landed = true }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            withAnimation(.easeOut(duration: 0.6)) { beams = false }
        }
    }

    private func fold() {
        withAnimation(.easeIn(duration: reduceMotion ? 0.15 : 0.35)) { landed = false }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 150 : 380))
            dismiss()
        }
    }
}

/// A card's flight out of the sphere: tiny at the heart, full size in its slot.
private struct FlyOut: ViewModifier {
    let landed: Bool
    let index: Int
    let from: CGSize
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .scaleEffect(landed ? 1 : 0.08)
            .offset(landed || reduceMotion ? .zero : from)
            .opacity(landed ? 1 : 0)
            .animation(reduceMotion ? .easeInOut(duration: 0.2)
                : .spring(response: 0.6, dampingFraction: 0.82).delay(landed ? Double(index) * 0.08 : 0), value: landed)
    }
}
