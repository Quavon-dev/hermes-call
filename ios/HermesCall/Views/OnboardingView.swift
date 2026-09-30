import SwiftUI

struct OnboardingView: View {
    @State private var addingRelay = false

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Image(systemName: "phone.bubble.fill")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            VStack(spacing: 8) {
                Text("Hermes Call").font(.largeTitle.bold())
                Text("Talk to your own Hermes agent — and let it call you.")
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 16) {
                Point(icon: "lock.shield", text: "Calls are end-to-end encrypted between this phone and your bridge.")
                Point(icon: "server.rack", text: "Traffic goes only through a relay you run yourself — no cloud services.")
                Point(icon: "waveform.slash", text: "No audio is stored. Pairing keys stay in this phone's Keychain.")
            }
            .padding(.horizontal)
            Spacer()
            Button {
                addingRelay = true
            } label: {
                Text("Add your relay").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Text("On your bridge, run `hermes-call-bridge device add` to get a code or QR.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .sheet(isPresented: $addingRelay) { AddRelayView() }
    }

    private struct Point: View {
        let icon: String
        let text: String

        var body: some View {
            Label { Text(text) } icon: { Image(systemName: icon).foregroundStyle(.tint) }
        }
    }
}
