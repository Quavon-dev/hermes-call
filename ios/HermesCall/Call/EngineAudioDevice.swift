import AVFoundation
import HermesCallCore
import os
@preconcurrency import WebRTC

/// WebRTC audio through our own AVAudioEngine (voice processing = echo cancellation), so the same
/// microphone audio can also feed on-device speech recognition, and both directions feed the
/// presence's voice spectrum.
final class EngineAudioDevice: NSObject, RTCAudioDevice, @unchecked Sendable {
    static let shared = EngineAudioDevice()

    /// The agent's voice as it is played (8 bands, read by the presence).
    let agentSpectrum = SpectrumAnalyzer(sampleRate: EngineAudioDevice.rate)
    /// The owner's voice after echo cancellation.
    let micSpectrum = SpectrumAnalyzer(sampleRate: EngineAudioDevice.rate)

    /// Voice-processed microphone audio in the input node's format (called on the audio tap thread).
    var onMicBuffer: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)?

    private static let rate = 48_000.0
    private let log = Logger(subsystem: "de.quavon.hermescall", category: "audio")
    private let lock = NSLock()
    private let engine = AVAudioEngine()
    private let ioFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate, channels: 1, interleaved: true)!
    private var delegate: RTCAudioDeviceDelegate?
    private var converter: AVAudioConverter?
    private var source: AVAudioSourceNode?
    private var wantsPlayout = false
    private var wantsRecording = false
    private var running = false

    // MARK: RTCAudioDevice properties

    var deviceInputSampleRate: Double { Self.rate }
    var inputIOBufferDuration: TimeInterval { AVAudioSession.sharedInstance().ioBufferDuration }
    var inputNumberOfChannels: Int { 1 }
    var inputLatency: TimeInterval { AVAudioSession.sharedInstance().inputLatency }
    var deviceOutputSampleRate: Double { Self.rate }
    var outputIOBufferDuration: TimeInterval { AVAudioSession.sharedInstance().ioBufferDuration }
    var outputNumberOfChannels: Int { 1 }
    var outputLatency: TimeInterval { AVAudioSession.sharedInstance().outputLatency }
    var isInitialized: Bool { lock.withLock { delegate != nil } }
    var isPlayoutInitialized: Bool { isInitialized }
    var isRecordingInitialized: Bool { isInitialized }
    var isPlaying: Bool { lock.withLock { wantsPlayout && running } }
    var isRecording: Bool { lock.withLock { wantsRecording && running } }

    func initialize(with delegate: RTCAudioDeviceDelegate) -> Bool {
        lock.withLock { self.delegate = delegate }
        return true
    }

    func terminateDevice() -> Bool {
        stopEngine()
        lock.withLock { delegate = nil }
        return true
    }

    func initializePlayout() -> Bool { true }
    func initializeRecording() -> Bool { true }

    func startPlayout() -> Bool {
        lock.withLock { wantsPlayout = true }
        return startEngineIfPossible()
    }

    func stopPlayout() -> Bool {
        lock.withLock { wantsPlayout = false }
        stopEngineIfIdle()
        return true
    }

    func startRecording() -> Bool {
        lock.withLock { wantsRecording = true }
        return startEngineIfPossible()
    }

    func stopRecording() -> Bool {
        lock.withLock { wantsRecording = false }
        stopEngineIfIdle()
        return true
    }

    /// CallKit activated the audio session: start now if WebRTC asked before activation.
    func sessionActivated() {
        _ = startEngineIfPossible()
    }

    // MARK: engine

    /// Returns true even when the session is not active yet; `sessionActivated` retries.
    private func startEngineIfPossible() -> Bool {
        let (wanted, alreadyRunning) = lock.withLock { (wantsPlayout || wantsRecording, running) }
        guard wanted, !alreadyRunning else { return true }
        do {
            try configureGraph()
            engine.prepare()
            try engine.start()
            lock.withLock { running = true }
            log.info("audio engine started")
        } catch {
            log.info("audio engine not started yet: \(error.localizedDescription, privacy: .public)")
        }
        return true
    }

    private func stopEngineIfIdle() {
        guard lock.withLock({ !wantsPlayout && !wantsRecording }) else { return }
        stopEngine()
    }

    private func stopEngine() {
        guard lock.withLock({ running }) else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if let source {
            engine.detach(source)
            self.source = nil
        }
        lock.withLock { running = false }
    }

    private func configureGraph() throws {
        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true)
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else { throw PhoneTranscriberError.unavailable }
        converter = AVAudioConverter(from: inputFormat, to: ioFormat)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(inputFormat.sampleRate / 100), format: inputFormat) {
            [weak self] buffer, time in self?.recorded(buffer, at: time)
        }
        if source == nil {
            let node = AVAudioSourceNode(format: ioFormat) { [weak self] _, timestamp, frames, audio in
                self?.playout(timestamp: timestamp, frames: frames, into: audio) ?? noErr
            }
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: ioFormat)
            source = node
        }
    }

    private func playout(timestamp: UnsafePointer<AudioTimeStamp>, frames: AVAudioFrameCount,
                         into audio: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        guard let delegate = lock.withLock({ wantsPlayout ? delegate : nil }) else {
            for buffer in UnsafeMutableAudioBufferListPointer(audio) {
                memset(buffer.mData, 0, Int(buffer.mDataByteSize))
            }
            return noErr
        }
        var flags = AudioUnitRenderActionFlags()
        let status = delegate.getPlayoutData(&flags, timestamp, 0, frames, audio)
        if status == noErr, let buffer = UnsafeMutableAudioBufferListPointer(audio).first, let data = buffer.mData {
            let count = min(Int(frames), Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size)
            agentSpectrum.feed(int16: UnsafeBufferPointer(start: data.assumingMemoryBound(to: Int16.self), count: count))
        }
        return status
    }

    private func recorded(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        onMicBuffer?(buffer, time)

        guard let delegate = lock.withLock({ wantsRecording ? delegate : nil }), let converter,
              let converted = AVAudioPCMBuffer(pcmFormat: ioFormat,
                                               frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * Self.rate
                                                   / buffer.format.sampleRate) + 32)
        else { return }
        let input = OneShotInput(buffer)
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in input.next(status) }
        guard error == nil, converted.frameLength > 0 else { return }
        if let samples = converted.int16ChannelData?[0] {
            micSpectrum.feed(int16: UnsafeBufferPointer(start: samples, count: Int(converted.frameLength)))
        }
        var flags = AudioUnitRenderActionFlags()
        var timestamp = time.audioTimeStamp
        _ = delegate.deliverRecordedData(&flags, &timestamp, 1, converted.frameLength, converted.audioBufferList, nil, nil)
    }
}
