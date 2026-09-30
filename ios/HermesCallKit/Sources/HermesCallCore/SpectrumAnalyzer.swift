import Accelerate
import Foundation
import os

/// Turns live audio into 8 log-spaced voice bands (80 Hz – 8 kHz) for the presence.
///
/// `feed` is called on the audio render thread: it only copies samples into a small ring under a
/// try-lock (dropping the buffer when the reader holds it), so it never blocks audio. `bands()` runs
/// the FFT on the caller's thread (a 512-point FFT costs microseconds) and smooths the result:
/// fast attack, slow release.
public final class SpectrumAnalyzer: @unchecked Sendable {
    public static let bandCount = 8
    public static let lowHz: Float = 80
    public static let highHz: Float = 8000

    public let sampleRate: Float
    public let size: Int
    private let log2n: vDSP_Length
    private let fft: FFTSetup?
    private let window: [Float]
    private let lock = OSAllocatedUnfairLock()
    // Guarded by `lock`.
    private var ring: [Float]
    private var writeIndex = 0
    private var fresh = 0
    // Reader side (the caller of `bands()`), not shared with the render thread.
    private var smoothed = [Float](repeating: 0, count: bandCount)
    private var level: Float = 0
    private var lastRead: Double?

    /// `size` defaults to ≈ 21 ms of audio (1024 points at 48 kHz, 512 at 24 kHz), enough to split the low voice bands.
    public init(sampleRate: Double, size: Int? = nil) {
        let size = size ?? (sampleRate >= 32_000 ? 1024 : 512)
        precondition(size >= 64 && size & (size - 1) == 0, "size must be a power of two")
        self.sampleRate = Float(sampleRate)
        self.size = size
        log2n = vDSP_Length(log2(Double(size)))
        fft = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningNormalized, count: size, isHalfWindow: false)
        ring = [Float](repeating: 0, count: size)
    }

    deinit { if let fft { vDSP_destroy_fftsetup(fft) } }

    // MARK: writer (audio thread)

    public func feed(_ samples: UnsafeBufferPointer<Float>) {
        guard lock.lockIfAvailable() else { return }
        defer { lock.unlock() }
        for sample in samples.suffix(size) {
            ring[writeIndex] = sample
            writeIndex = (writeIndex + 1) & (size - 1)
        }
        fresh += samples.count
    }

    /// 16-bit PCM (WebRTC's playout format).
    public func feed(int16 samples: UnsafeBufferPointer<Int16>) {
        guard lock.lockIfAvailable() else { return }
        defer { lock.unlock() }
        for sample in samples.suffix(size) {
            ring[writeIndex] = Float(sample) / 32768
            writeIndex = (writeIndex + 1) & (size - 1)
        }
        fresh += samples.count
    }

    public func reset() {
        lock.withLock {
            for index in ring.indices { ring[index] = 0 }
            fresh = 0
        }
        smoothed = [Float](repeating: 0, count: Self.bandCount)
        level = 0
        lastRead = nil
    }

    // MARK: reader

    /// The newest bands (0…1), smoothed over time. Decays to silence when no audio arrives.
    public func bands(now: Double = ProcessInfo.processInfo.systemUptime) -> [Float] {
        let dt = Float(min(0.1, max(0.001, now - (lastRead ?? now - 1.0 / 60))))
        lastRead = now
        var target = [Float](repeating: 0, count: Self.bandCount)
        var rms: Float = 0
        if let samples = snapshot() {
            target = Self.fold(magnitudes: magnitudes(samples), sampleRate: sampleRate, size: size)
            rms = vDSP.rootMeanSquare(samples)
        }
        for index in smoothed.indices {
            let rate: Float = target[index] > smoothed[index] ? 40 : 7  // attack fast, release slow
            smoothed[index] += (target[index] - smoothed[index]) * (1 - exp(-rate * dt))
        }
        level += (min(1, rms * 4) - level) * (1 - exp(-(rms * 4 > level ? 40 : 7) * dt))
        return smoothed
    }

    /// Overall loudness (0…1), smoothed like the bands; valid after `bands()`.
    public var currentLevel: Float { level }

    /// The last `size` samples in order, or nil when nothing new arrived since the last read.
    private func snapshot() -> [Float]? {
        lock.withLock {
            guard fresh > 0 else { return nil }
            fresh = 0
            return Array(ring[writeIndex...] + ring[..<writeIndex])
        }
    }

    private func magnitudes(_ samples: [Float]) -> [Float] {
        let half = size / 2
        var windowed = vDSP.multiply(samples, window)
        var real = [Float](repeating: 0, count: half), imaginary = [Float](repeating: 0, count: half)
        var result = [Float](repeating: 0, count: half)
        // No FFT setup (out of memory at init): silence rather than a crash.
        guard let fft else { return result }
        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                guard let realBase = realPointer.baseAddress, let imaginaryBase = imaginaryPointer.baseAddress else { return }
                var split = DSPSplitComplex(realp: realBase, imagp: imaginaryBase)
                windowed.withUnsafeMutableBytes { raw in
                    guard let complex = raw.bindMemory(to: DSPComplex.self).baseAddress else { return }
                    vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(half))
                }
                vDSP_fft_zrip(fft, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                split.imagp[0] = 0  // packed Nyquist term
                vDSP_zvabs(&split, 1, &result, 1, vDSP_Length(half))
            }
        }
        // zrip output is scaled by 2; the Hann window halves amplitude: normalize a full-scale sine to ≈ 1.
        return vDSP.multiply(2 / Float(size), result)
    }

    // MARK: pure band folding (unit-tested)

    /// Band edges in Hz: `bandCount + 1` log-spaced values from `lowHz` to `highHz`.
    public static var edges: [Float] {
        (0...bandCount).map { lowHz * pow(highHz / lowHz, Float($0) / Float(bandCount)) }
    }

    /// FFT magnitudes (bin k = k · sampleRate / size) → 8 band levels in 0…1 (−60 dB … 0 dB).
    public static func fold(magnitudes: [Float], sampleRate: Float, size: Int) -> [Float] {
        let edges = edges
        let binHz = sampleRate / Float(size)
        return (0..<bandCount).map { band in
            // Bins whose centre lies in the band; a band narrower than one bin takes the bin nearest its centre.
            let first = max(1, Int((edges[band] / binHz).rounded(.up)))
            let last = min(magnitudes.count - 1, Int((edges[band + 1] / binHz).rounded(.up)) - 1)
            let peak: Float
            if first <= last {
                peak = magnitudes[first...last].max() ?? 0
            } else {
                let centre = Int((sqrt(edges[band] * edges[band + 1]) / binHz).rounded())
                peak = magnitudes.indices.contains(centre) ? magnitudes[centre] : 0
            }
            let db = 20 * log10(max(peak, 1e-6))
            return min(1, max(0, (db + 60) / 60))
        }
    }
}
