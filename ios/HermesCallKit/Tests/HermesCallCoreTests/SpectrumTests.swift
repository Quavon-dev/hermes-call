import Foundation
import Testing
@testable import HermesCallCore

@Suite struct SpectrumTests {
    private func sine(_ hz: Float, rate: Float = 48_000, count: Int = 2048, amplitude: Float = 0.5) -> [Float] {
        (0..<count).map { amplitude * sin(2 * .pi * hz * Float($0) / rate) }
    }

    /// The band whose edges contain `hz`.
    private func band(of hz: Float) -> Int {
        SpectrumAnalyzer.edges.indices.dropLast().first { SpectrumAnalyzer.edges[$0] <= hz && hz < SpectrumAnalyzer.edges[$0 + 1] }!
    }

    @Test func edgesAreLogSpacedFrom80HzTo8kHz() {
        let edges = SpectrumAnalyzer.edges
        #expect(edges.count == SpectrumAnalyzer.bandCount + 1)
        #expect(abs(edges.first! - 80) < 0.01 && abs(edges.last! - 8000) < 0.5)
        let ratios = zip(edges.dropFirst(), edges).map { $0 / $1 }
        #expect(ratios.allSatisfy { abs($0 - ratios[0]) < 0.001 })
    }

    @Test(arguments: [200, 600, 2000, 5000] as [Float])
    func aSinePeaksInItsBand(_ hz: Float) {
        let analyzer = SpectrumAnalyzer(sampleRate: 48_000)
        let samples = sine(hz)
        samples.withUnsafeBufferPointer { analyzer.feed($0) }
        var bands: [Float] = []
        // A few reads at 60 Hz let the smoothing settle.
        for frame in 0..<30 {
            samples.withUnsafeBufferPointer { analyzer.feed($0) }
            bands = analyzer.bands(now: Double(frame) / 60)
        }
        let loudest = bands.indices.max { bands[$0] < bands[$1] }!
        #expect(loudest == band(of: hz), "bands: \(bands)")
        #expect(bands[loudest] > 0.6)
        #expect(analyzer.currentLevel > 0.3)
    }

    @Test func silenceDecaysToZero() {
        let analyzer = SpectrumAnalyzer(sampleRate: 48_000)
        sine(1000).withUnsafeBufferPointer { analyzer.feed($0) }
        _ = analyzer.bands(now: 0)
        var bands: [Float] = []
        for frame in 1...120 { bands = analyzer.bands(now: Double(frame) / 60) }
        #expect(bands.allSatisfy { $0 < 0.01 })
    }

    @Test func int16InputMatchesFloatInput() {
        let floats = sine(2000)
        let ints = floats.map { Int16($0 * 32767) }
        let a = SpectrumAnalyzer(sampleRate: 48_000), b = SpectrumAnalyzer(sampleRate: 48_000)
        floats.withUnsafeBufferPointer { a.feed($0) }
        ints.withUnsafeBufferPointer { b.feed(int16: $0) }
        let (bandsA, bandsB) = (a.bands(now: 0), b.bands(now: 0))
        #expect(zip(bandsA, bandsB).allSatisfy { abs($0 - $1) < 0.01 })
    }

    @Test func foldIgnoresQuietBins() {
        let bands = SpectrumAnalyzer.fold(magnitudes: [Float](repeating: 1e-7, count: 256), sampleRate: 48_000, size: 1024)
        #expect(bands == [Float](repeating: 0, count: 8))
    }
}
