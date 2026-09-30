import AVFoundation
import os

/// The "ringing" tone you hear while an outgoing call connects (425 Hz, 1 s on / 4 s off).
@MainActor
final class RingbackTone {
    private var player: AVAudioPlayer?

    func start() {
        guard player == nil else { return }
        do {
            let player = try AVAudioPlayer(data: Self.wav)
            player.numberOfLoops = -1
            player.volume = 0.5
            player.play()
            self.player = player
        } catch {
            Logger(subsystem: "de.quavon.hermescall", category: "call").error("ringback tone failed")
        }
    }

    func stop() {
        player?.stop()
        player = nil
    }

    static let wav: Data = {
        let rate = 16_000, toneSamples = rate, totalSamples = rate * 5, fade = rate / 100
        var pcm = Data(capacity: totalSamples * 2)
        for index in 0..<totalSamples {
            var sample = 0.0
            if index < toneSamples {
                let envelope = min(1, Double(min(index, toneSamples - index)) / Double(fade))
                sample = sin(2 * .pi * 425 * Double(index) / Double(rate)) * envelope * 0.4
            }
            withUnsafeBytes(of: Int16(sample * Double(Int16.max)).littleEndian) { pcm.append(contentsOf: $0) }
        }
        var header = Data()
        func append(_ value: some FixedWidthInteger) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
        header.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + pcm.count))
        header.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(rate)); append(UInt32(rate * 2)); append(UInt16(2)); append(UInt16(16))
        header.append(contentsOf: Array("data".utf8)); append(UInt32(pcm.count))
        return header + pcm
    }()
}
