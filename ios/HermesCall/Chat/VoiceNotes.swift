import AVFoundation
import Foundation
import HermesCallCore
import os

/// Records a voice note as AAC (.m4a, mono) for the chat; the bridge transcribes it.
@MainActor @Observable
final class VoiceRecorder {
    static let maxSeconds: TimeInterval = 300
    private(set) var isRecording = false
    private(set) var elapsed: TimeInterval = 0
    private var recorder: AVAudioRecorder?
    private var ticker: Task<Void, Never>?
    private let log = Logger(subsystem: "de.quavon.hermescall", category: "voice-note")

    private var fileURL: URL { FileManager.default.temporaryDirectory.appendingPathComponent("voice-note.m4a") }

    func start() async -> Bool {
        guard !isRecording, await AVAudioApplication.requestRecordPermission() else { return false }
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try audio.setActive(true)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 24_000, AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 32_000,
            ]
            let recorder = try AVAudioRecorder(url: fileURL, settings: settings)
            guard recorder.record(forDuration: Self.maxSeconds) else { return false }
            self.recorder = recorder
            isRecording = true
            elapsed = 0
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(200))
                    guard let self, let recorder = self.recorder else { return }
                    self.elapsed = recorder.currentTime
                    if !recorder.isRecording { return }
                }
            }
            return true
        } catch {
            log.error("recording failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Stops and returns the note, or nil when cancelled or shorter than half a second.
    func stop(keep: Bool) -> OutgoingFile? {
        ticker?.cancel()
        let duration = recorder?.currentTime ?? elapsed
        recorder?.stop()
        recorder = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        guard keep, duration >= 0.5, let data = try? Data(contentsOf: fileURL) else { return nil }
        return OutgoingFile(kind: .voice, name: "Voice note.m4a", mime: "audio/mp4", data: data, duration: duration)
    }
}

/// Plays one voice note at a time, through an audio engine so the presence can show its spectrum.
@MainActor @Observable
final class VoicePlayer {
    private(set) var playing: String?
    /// Bands of what is playing (the presence speaks voice replies); nil when idle.
    private(set) var spectrum: SpectrumAnalyzer?
    private var engine: AVAudioEngine?
    /// Bumped per playback, so a stopped playback's completion cannot stop the next one.
    private var generation = 0
    /// While a call owns the audio session, nothing plays and the session is left alone.
    var isCallActive: () -> Bool = { false }
    private let log = Logger(subsystem: "de.quavon.hermescall", category: "voice-note")

    func toggle(id: String, url: URL) {
        if playing == id {
            stop()
        } else {
            play(id: id, url: url)
        }
    }

    func play(id: String, url: URL) {
        stop()
        guard !isCallActive() else { return }
        generation += 1
        let current = generation
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            let file = try AVAudioFile(forReading: url)
            let engine = AVAudioEngine(), node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: file.processingFormat)
            let format = engine.mainMixerNode.outputFormat(forBus: 0)
            let analyzer = SpectrumAnalyzer(sampleRate: format.sampleRate)
            engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                guard let samples = buffer.floatChannelData?[0] else { return }
                analyzer.feed(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)))
            }
            node.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor in if self?.generation == current { self?.stop() } }
            }
            try engine.start()
            node.play()
            self.engine = engine
            spectrum = analyzer
            playing = id
        } catch {
            log.error("playback failed: \(error.localizedDescription, privacy: .public)")
            stop()
        }
    }

    func stop() {
        engine?.mainMixerNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        spectrum = nil
        if playing != nil, !isCallActive() {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        playing = nil
    }
}
