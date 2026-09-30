import AVFoundation
import Foundation
import HermesCallCore
import os

/// Records a voice note as AAC (.m4a, mono) for the chat; the bridge transcribes it.
@MainActor @Observable
final class VoiceRecorder {
    enum Start: Equatable { case recording, denied, failed }

    static let maxSeconds: TimeInterval = 300
    /// Levels (0…1) kept for the live waveform.
    static let liveBars = 40
    private(set) var isRecording = false
    private(set) var elapsed: TimeInterval = 0
    /// The newest input levels, oldest first, for the recording bar.
    private(set) var levels: [Float] = []
    private var recorder: AVAudioRecorder?
    private var ticker: Task<Void, Never>?
    private let log = Logger(subsystem: "de.quavon.hermescall", category: "voice-note")

    private var fileURL: URL { FileManager.default.temporaryDirectory.appendingPathComponent("voice-note.m4a") }

    func start() async -> Start {
        guard !isRecording else { return .failed }
        guard await AVAudioApplication.requestRecordPermission() else { return .denied }
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try audio.setActive(true)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 24_000, AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 32_000,
            ]
            let recorder = try AVAudioRecorder(url: fileURL, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.record(forDuration: Self.maxSeconds) else { return .failed }
            self.recorder = recorder
            isRecording = true
            elapsed = 0
            levels = []
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard let self, let recorder = self.recorder else { return }
                    recorder.updateMeters()
                    self.elapsed = recorder.currentTime
                    self.levels = Array((self.levels + [VoiceWaveform.level(decibels: recorder.averagePower(forChannel: 0))])
                        .suffix(Self.liveBars))
                    if !recorder.isRecording { return }
                }
            }
            return .recording
        } catch {
            log.error("recording failed: \(error.localizedDescription, privacy: .public)")
            return .failed
        }
    }

    /// Stops and returns the note, or nil when cancelled or shorter than half a second.
    func stop(keep: Bool) -> OutgoingFile? {
        ticker?.cancel()
        let duration = recorder?.currentTime ?? elapsed
        recorder?.stop()
        recorder = nil
        isRecording = false
        levels = []
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        guard keep, duration >= 0.5, let data = try? Data(contentsOf: fileURL) else { return nil }
        return OutgoingFile(kind: .voice, name: "Voice note.m4a", mime: "audio/mp4", data: data, duration: duration)
    }
}

/// Plays one voice note at a time, through an audio engine so the presence can show its spectrum.
/// Pause, seek and speed (pitch kept) for the chat's voice note player.
@MainActor @Observable
final class VoicePlayer {
    static let rates: [Float] = [1, 1.5, 2]
    private static let rateKey = "voiceNotes.rate"

    /// The note that is loaded (playing or paused).
    private(set) var playing: String?
    private(set) var isPaused = false
    /// Position in the loaded note, 0…1, and its length in seconds.
    private(set) var progress: Double = 0
    private(set) var duration: TimeInterval = 0
    /// Playback speed, remembered across notes.
    private(set) var rate: Float
    /// Bands of what is playing (the presence speaks voice replies); nil when idle.
    private(set) var spectrum: SpectrumAnalyzer?
    /// While a call owns the audio session, nothing plays and the session is left alone.
    var isCallActive: () -> Bool = { false }

    private var engine: AVAudioEngine?
    private var node: AVAudioPlayerNode?
    private var pitch: AVAudioUnitTimePitch?
    private var file: AVAudioFile?
    private var url: URL?
    /// The file frame the current segment started at.
    private var segmentStart: AVAudioFramePosition = 0
    /// Bumped per segment, so a stopped segment's completion cannot stop the next one.
    private var generation = 0
    private var ticker: Task<Void, Never>?
    private let log = Logger(subsystem: "de.quavon.hermescall", category: "voice-note")

    init() {
        let saved = UserDefaults.standard.float(forKey: Self.rateKey)
        rate = Self.rates.contains(saved) ? saved : 1
    }

    /// Play, pause or resume.
    func toggle(id: String, url: URL) {
        if playing == id {
            isPaused ? resume() : pause()
        } else {
            play(id: id, url: url)
        }
    }

    func play(id: String, url: URL, from fraction: Double = 0) {
        stop()
        guard !isCallActive() else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            let file = try AVAudioFile(forReading: url)
            let engine = AVAudioEngine(), node = AVAudioPlayerNode(), pitch = AVAudioUnitTimePitch()
            pitch.rate = rate
            engine.attach(node)
            engine.attach(pitch)
            engine.connect(node, to: pitch, format: file.processingFormat)
            engine.connect(pitch, to: engine.mainMixerNode, format: file.processingFormat)
            let format = engine.mainMixerNode.outputFormat(forBus: 0)
            let analyzer = SpectrumAnalyzer(sampleRate: format.sampleRate)
            engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                guard let samples = buffer.floatChannelData?[0] else { return }
                analyzer.feed(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)))
            }
            try engine.start()
            (self.engine, self.node, self.pitch, self.file, self.url) = (engine, node, pitch, file, url)
            spectrum = analyzer
            playing = id
            duration = Double(file.length) / file.processingFormat.sampleRate
            schedule(from: fraction)
            node.play()
            startTicker()
        } catch {
            log.error("playback failed: \(error.localizedDescription, privacy: .public)")
            stop()
        }
    }

    func pause() {
        guard playing != nil, !isPaused else { return }
        updateProgress()
        node?.pause()
        engine?.pause()
        isPaused = true
    }

    func resume() {
        guard playing != nil, isPaused, !isCallActive(), let engine else { return }
        do {
            try engine.start()
            node?.play()
            isPaused = false
        } catch {
            log.error("resume failed: \(error.localizedDescription, privacy: .public)")
            stop()
        }
    }

    /// Jumps within the loaded note (keeps playing or paused).
    func seek(to fraction: Double) {
        guard playing != nil, let node else { return }
        let wasPaused = isPaused
        node.stop()
        schedule(from: fraction)
        if !wasPaused { node.play() }
    }

    func cycleRate() {
        let next = Self.rates[((Self.rates.firstIndex(of: rate) ?? 0) + 1) % Self.rates.count]
        rate = next
        pitch?.rate = next
        UserDefaults.standard.set(next, forKey: Self.rateKey)
    }

    func stop() {
        ticker?.cancel()
        ticker = nil
        engine?.mainMixerNode.removeTap(onBus: 0)
        node?.stop()
        engine?.stop()
        (engine, node, pitch, file, url) = (nil, nil, nil, nil, nil)
        spectrum = nil
        if playing != nil, !isCallActive() {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        playing = nil
        isPaused = false
        progress = 0
        duration = 0
    }

    private func schedule(from fraction: Double) {
        guard let file, let node else { return }
        generation += 1
        let current = generation
        let start = AVAudioFramePosition(Double(file.length) * min(max(fraction, 0), 0.999))
        segmentStart = start
        progress = Double(start) / Double(max(file.length, 1))
        node.scheduleSegment(file, startingFrame: start, frameCount: AVAudioFrameCount(file.length - start), at: nil,
                             completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in if self?.generation == current { self?.stop() } }
        }
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                self?.updateProgress()
            }
        }
    }

    private func updateProgress() {
        guard !isPaused, let node, let file, let nodeTime = node.lastRenderTime,
              let playerTime = node.playerTime(forNodeTime: nodeTime) else { return }
        let frame = segmentStart + playerTime.sampleTime
        progress = min(1, max(0, Double(frame) / Double(max(file.length, 1))))
    }
}

/// Bar heights for a voice note, read from its file once and kept in memory.
actor VoiceWaveform {
    static let shared = VoiceWaveform()
    static let bars = 36
    private var cache: [URL: [Float]] = [:]

    /// 0…1 for an input level in dBFS (quiet speech ≈ -40, loud ≈ -10).
    nonisolated static func level(decibels: Float) -> Float {
        min(1, max(0.04, (decibels + 50) / 45))
    }

    func bars(for url: URL) -> [Float] {
        if let cached = cache[url] { return cached }
        let bars = (try? Self.read(url)) ?? []
        cache[url] = bars
        return bars
    }

    private static func read(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let total = Int(file.length)
        let chunk: AVAudioFrameCount = 16_384
        guard total > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { return [] }
        let perBar = max(1, total / bars)
        var sums = [Float](repeating: 0, count: bars), counts = [Int](repeating: 0, count: bars)
        var position = 0
        // In chunks: a five-minute note would otherwise need ~30 MB of samples at once.
        while position < total {
            try file.read(into: buffer, frameCount: chunk)
            guard buffer.frameLength > 0, let samples = buffer.floatChannelData?[0] else { break }
            for index in 0..<Int(buffer.frameLength) {
                let bar = min(bars - 1, (position + index) / perBar)
                sums[bar] += samples[index] * samples[index]
                counts[bar] += 1
            }
            position += Int(buffer.frameLength)
        }
        return (0..<bars).map { bar in
            guard counts[bar] > 0 else { return 0.04 }
            let rms = (sums[bar] / Float(counts[bar])).squareRoot()
            return level(decibels: 20 * log10(max(rms, 1e-6)))
        }
    }
}
