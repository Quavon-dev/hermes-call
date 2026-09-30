import AVFoundation
import Foundation
import os

/// Records a voice note on the watch (AAC, mono, like the iPhone's); the iPhone sends it to the agent.
@MainActor @Observable
final class WatchVoiceRecorder {
    enum Start: Equatable { case recording, denied, failed }

    static let maxSeconds: TimeInterval = 120
    private(set) var isRecording = false
    private(set) var elapsed: TimeInterval = 0
    private var recorder: AVAudioRecorder?
    private var ticker: Task<Void, Never>?
    private var file: URL?
    private let log = Logger(subsystem: "de.quavon.hermescall.watchkitapp", category: "voice-note")

    func start() async -> Start {
        guard !isRecording else { return .failed }
        guard await AVAudioApplication.requestRecordPermission() else { return .denied }
        do {
            try AVAudioSession.sharedInstance().setCategory(.record, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            // Kept until WatchConnectivity has handed it to the iPhone (then WatchModel deletes it).
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("voice-\(UUID().uuidString).m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 24_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000,
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            guard recorder.record(forDuration: Self.maxSeconds) else { return .failed }
            self.recorder = recorder
            file = url
            isRecording = true
            elapsed = 0
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard let self, let recorder = self.recorder else { return }
                    self.elapsed = recorder.currentTime
                    if !recorder.isRecording { return }
                }
            }
            return .recording
        } catch {
            log.error("recording failed: \(error.localizedDescription, privacy: .public)")
            return .failed
        }
    }

    /// The note's file and length, or nil when discarded or shorter than half a second.
    func stop(keep: Bool) -> (file: URL, duration: TimeInterval)? {
        ticker?.cancel()
        let duration = recorder?.currentTime ?? elapsed
        recorder?.stop()
        recorder = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        guard let file else { return nil }
        self.file = nil
        guard keep, duration >= 0.5 else {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        return (file, duration)
    }
}
