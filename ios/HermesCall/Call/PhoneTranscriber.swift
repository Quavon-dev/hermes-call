import AVFoundation
import os
import Speech

/// On-device speech-to-text for calls (iOS 26 SpeechAnalyzer). Audio never leaves the phone for
/// recognition; only the finished utterance text is sent to the bridge (end-to-end encrypted).
/// `feed` runs on the audio tap thread; all mutable state is behind `lock`.
final class PhoneTranscriber: @unchecked Sendable {
    enum Availability: Equatable { case ready, needsDownload, unavailable }

    static let locale = Locale(identifier: "en-US")
    private static let endSilence: TimeInterval = 0.55
    private static let minSpeech: TimeInterval = 0.2

    private let log = Logger(subsystem: "de.quavon.hermescall", category: "stt")
    private let lock = NSLock()
    private let onUtterance: @Sendable (String, Int) -> Void
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var format: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var results: Task<Void, Never>?
    private var pending = ""
    private var speechSeconds: TimeInterval = 0
    private var silenceSeconds: TimeInterval = 0
    private var noiseFloor: Float = 0.003
    private var speechEnded: Date?
    private var gated = false

    init(onUtterance: @escaping @Sendable (String, Int) -> Void) {
        self.onUtterance = onUtterance
    }

    static func availability() async -> Availability {
        guard SpeechTranscriber.isAvailable,
              await SpeechTranscriber.supportedLocale(equivalentTo: locale) != nil else { return .unavailable }
        let installed = await SpeechTranscriber.installedLocales
        return installed.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) } ? .ready : .needsDownload
    }

    /// Downloads Apple's on-device English model if needed (once, from Apple).
    static func install() async throws {
        let module = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
    }

    func start() async throws {
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(200))
        let module = SpeechTranscriber(locale: Self.locale, transcriptionOptions: [],
                                       reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
        guard let best = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw PhoneTranscriberError.unavailable
        }
        let analyzer = SpeechAnalyzer(modules: [module])
        try await analyzer.prepareToAnalyze(in: best)
        try await analyzer.start(inputSequence: stream)
        let task = Task { [weak self] in
            do {
                for try await result in module.results {
                    self?.received(String(result.text.characters), final: result.isFinal)
                }
            } catch {
                self?.log.error("transcription stopped: \(error.localizedDescription, privacy: .public)")
            }
        }
        lock.withLock {
            self.analyzer = analyzer
            transcriber = module
            input = continuation
            format = best
            results = task
        }
    }

    func stop() async {
        let analyzer = lock.withLock {
            input?.finish()
            input = nil
            results?.cancel()
            defer { self.analyzer = nil }
            return self.analyzer
        }
        await analyzer?.cancelAndFinishNow()
    }

    /// Muted, or push-to-talk not held: the microphone is not transcribed.
    func setGated(_ gated: Bool) {
        let finish = lock.withLock {
            defer { self.gated = gated }
            return gated && !self.gated && speechSeconds >= Self.minSpeech
        }
        if finish { endUtterance() }
    }

    /// Called on the audio tap thread.
    func feed(_ buffer: AVAudioPCMBuffer) {
        let finish: Bool = lock.withLock {
            guard let input, let format, !gated, let converted = convert(buffer, to: format) else { return false }
            input.yield(AnalyzerInput(buffer: converted))
            detectEndOfSpeech(converted)
            return silenceSeconds >= Self.endSilence && speechSeconds >= Self.minSpeech
        }
        if finish { endUtterance() }
    }

    // MARK: private

    private func detectEndOfSpeech(_ buffer: AVAudioPCMBuffer) {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        let count = Int(buffer.frameLength)
        var energy: Float = 0
        for index in 0..<count { energy += samples[index] * samples[index] }
        let rms = (energy / Float(count)).squareRoot()
        let seconds = Double(count) / buffer.format.sampleRate
        if rms > max(noiseFloor * 3.5, 0.008) {
            speechSeconds += seconds
            silenceSeconds = 0
        } else {
            noiseFloor = 0.98 * noiseFloor + 0.02 * rms
            if speechSeconds > 0 { silenceSeconds += seconds }
        }
    }

    private func endUtterance() {
        let analyzer = lock.withLock {
            speechSeconds = 0
            silenceSeconds = 0
            speechEnded = Date()
            return self.analyzer
        }
        Task { [log] in
            do {
                try await analyzer?.finalize(through: nil)
            } catch {
                log.error("finalize failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func received(_ text: String, final: Bool) {
        guard final else { return }
        let done: (String, Int)? = lock.withLock {
            pending += text
            guard let ended = speechEnded else { return nil }
            let utterance = pending.trimmingCharacters(in: .whitespacesAndNewlines)
            pending = ""
            speechEnded = nil
            return utterance.isEmpty ? nil : (utterance, Int(Date().timeIntervalSince(ended) * 1000))
        }
        guard let (utterance, elapsed) = done else { return }
        log.info("utterance finalized \(elapsed, privacy: .public) ms after end of speech")
        onUtterance(utterance, elapsed)
    }

    private func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        if converter?.inputFormat != buffer.format { converter = AVAudioConverter(from: buffer.format, to: format) }
        guard let converter,
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(
                  Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 32)
        else { return nil }
        let input = OneShotInput(buffer)
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in input.next(status) }
        return error == nil ? out : nil
    }
}

/// Hands one buffer to AVAudioConverter, then reports "no data now". The converter calls its input
/// block synchronously inside `convert(to:error:)`, but newer SDKs type the block `@Sendable`, so
/// the state lives here instead of in captured variables.
private final class OneShotInput: @unchecked Sendable {
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

enum PhoneTranscriberError: Error { case unavailable }
