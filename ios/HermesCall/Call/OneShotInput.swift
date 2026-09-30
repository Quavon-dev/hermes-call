import AVFAudio

/// Hands one buffer to AVAudioConverter, then reports "no data now". The converter calls its input
/// block synchronously inside `convert(to:error:)`, but newer SDKs type the block `@Sendable`, so
/// the state lives here instead of in captured variables.
final class OneShotInput: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }

    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        guard let buffer else {
            status.pointee = .noDataNow
            return nil
        }
        self.buffer = nil
        status.pointee = .haveData
        return buffer
    }
}
