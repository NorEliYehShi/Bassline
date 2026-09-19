import XCTest
@testable import BasslineCore

final class SpectrumAnalyzerTests: XCTestCase {
    private let sampleRate: Double = 48_000

    private func makeTone(frequency: Double, frameCount: Int, channels: Int, amplitude: Float = 0.5) -> [Float] {
        var samples = [Float](repeating: 0, count: frameCount * channels)
        for frame in 0..<frameCount {
            let value = amplitude * sinf(Float(2 * Double.pi * frequency * Double(frame) / sampleRate))
            for channel in 0..<channels {
                samples[frame * channels + channel] = value
            }
        }
        return samples
    }

    private func feed(_ analyzer: SpectrumAnalyzer, samples: [Float], channels: Int, repeats: Int) {
        let frameCount = samples.count / channels
        samples.withUnsafeBufferPointer { buffer in
            for index in 0..<repeats {
                analyzer.process(
                    buffer: buffer.baseAddress!,
                    frameCount: frameCount,
                    channelCount: channels,
                    sampleRate: sampleRate,
                    hostTime: Double(index) * Double(frameCount) / sampleRate
                )
            }
        }
    }

    func testSilenceProducesNoEnergy() {
        let analyzer = SpectrumAnalyzer(initialSampleRate: sampleRate)
        let silence = [Float](repeating: 0, count: 512 * 2)
        feed(analyzer, samples: silence, channels: 2, repeats: 20)

        var bands = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
        let result = analyzer.frames.read(age: 0, into: &bands)
        XCTAssertNotNil(result)
        XCTAssertLessThan(result!.level, SpectrumAnalyzer.silenceThreshold)
        XCTAssertTrue(bands.allSatisfy { $0 < 0.05 })
    }

    func testToneLandsInTheExpectedBand() {
        let analyzer = SpectrumAnalyzer(initialSampleRate: sampleRate)
        let tone = makeTone(frequency: 1_000, frameCount: 512, channels: 2)
        feed(analyzer, samples: tone, channels: 2, repeats: 60)

        var bands = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
        XCTAssertNotNil(analyzer.frames.read(age: 0, into: &bands))

        let peakIndex = bands.firstIndex(of: bands.max() ?? 0) ?? 0
        let mapping = BandMapping(bandCount: SpectrumAnalyzer.bandCount, binCount: 512, sampleRate: sampleRate)
        let band = mapping.bands[peakIndex]
        let binWidth = sampleRate / 2 / 512

        let centerBin = band.lowBin >= 0
            ? Double(band.lowBin + band.highBin) / 2
            : Double(band.interpolationBin)
        XCTAssertEqual(centerBin * binWidth, 1_000, accuracy: 250)
    }

    func testQuietAndLoudToneDifferInHeight() {
        var heights: [Float] = []
        for amplitude in [Float(0.02), Float(0.8)] {
            let analyzer = SpectrumAnalyzer(initialSampleRate: sampleRate)
            let tone = makeTone(frequency: 500, frameCount: 512, channels: 2, amplitude: amplitude)
            feed(analyzer, samples: tone, channels: 2, repeats: 30)

            var bands = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
            XCTAssertNotNil(analyzer.frames.read(age: 0, into: &bands))
            heights.append(bands.max() ?? 0)
        }
        // Per-frame normalization would make these identical.
        XCTAssertGreaterThan(heights[1], heights[0])
    }

    func testMonoAndStereoAgree() {
        let stereoAnalyzer = SpectrumAnalyzer(initialSampleRate: sampleRate)
        let monoAnalyzer = SpectrumAnalyzer(initialSampleRate: sampleRate)

        feed(stereoAnalyzer, samples: makeTone(frequency: 800, frameCount: 512, channels: 2), channels: 2, repeats: 40)
        feed(monoAnalyzer, samples: makeTone(frequency: 800, frameCount: 512, channels: 1), channels: 1, repeats: 40)

        var stereoBands = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
        var monoBands = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
        XCTAssertNotNil(stereoAnalyzer.frames.read(age: 0, into: &stereoBands))
        XCTAssertNotNil(monoAnalyzer.frames.read(age: 0, into: &monoBands))

        for index in 0..<SpectrumAnalyzer.bandCount {
            XCTAssertEqual(stereoBands[index], monoBands[index], accuracy: 0.02)
        }
    }

    func testSampleRateChangeIsAccepted() {
        let analyzer = SpectrumAnalyzer(initialSampleRate: sampleRate)
        analyzer.updateSampleRate(44_100)
        XCTAssertEqual(analyzer.currentSampleRate, 44_100)
    }
}
