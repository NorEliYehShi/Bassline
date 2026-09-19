import XCTest
@testable import BasslineCore

/// Regression tests for the frame-accumulation loop in `SpectrumAnalyzer`.
///
/// A zero-length chunk inside that loop does not crash: it spins the Core Audio
/// IO thread forever, which freezes the whole app. These tests run `process`
/// with a timeout so a hang fails the suite instead of hanging CI.
final class SpectrumAnalyzerLoopTests: XCTestCase {
    private let sampleRate: Double = 48_000

    private func feedWithTimeout(
        frameCounts: [Int],
        channels: Int,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let finished = expectation(description: "process returned")

        DispatchQueue.global().async { [sampleRate] in
            let analyzer = SpectrumAnalyzer(initialSampleRate: sampleRate)
            var hostTime = 0.0
            for frameCount in frameCounts {
                var samples = [Float](repeating: 0, count: frameCount * channels)
                for frame in 0..<frameCount {
                    let value = 0.4 * sinf(Float(2 * Double.pi * 440 * Double(frame) / sampleRate))
                    for channel in 0..<channels {
                        samples[frame * channels + channel] = value
                    }
                }
                samples.withUnsafeBufferPointer { buffer in
                    analyzer.process(
                        buffer: buffer.baseAddress!,
                        frameCount: frameCount,
                        channelCount: channels,
                        sampleRate: sampleRate,
                        hostTime: hostTime
                    )
                }
                hostTime += Double(frameCount) / sampleRate
            }
            finished.fulfill()
        }

        let result = XCTWaiter.wait(for: [finished], timeout: timeout)
        XCTAssertEqual(result, .completed, "process did not return: the accumulation loop is stuck", file: file, line: line)
    }

    /// The exact shape that froze the app: repeated buffers of exactly the hop
    /// size, before the ring has filled.
    func testRepeatedHopSizedBuffersTerminate() {
        feedWithTimeout(frameCounts: Array(repeating: 512, count: 200), channels: 2)
    }

    func testSmallBuffersTerminate() {
        feedWithTimeout(frameCounts: Array(repeating: 64, count: 400), channels: 2)
    }

    func testLargeBuffersTerminate() {
        feedWithTimeout(frameCounts: Array(repeating: 4096, count: 20), channels: 2)
    }

    func testIrregularBufferSizesTerminate() {
        feedWithTimeout(
            frameCounts: [1, 7, 512, 513, 1024, 3, 2048, 511, 1, 1023, 512, 512, 512],
            channels: 2
        )
    }

    func testMonoBuffersTerminate() {
        feedWithTimeout(frameCounts: Array(repeating: 512, count: 200), channels: 1)
    }

    /// Frames must actually be produced once enough audio has arrived, so a
    /// future "fix" that just breaks out of the loop early cannot pass.
    func testFramesAreProducedFromHopSizedBuffers() {
        let analyzer = SpectrumAnalyzer(initialSampleRate: sampleRate)
        let frameCount = 512
        var samples = [Float](repeating: 0, count: frameCount * 2)
        for frame in 0..<frameCount {
            let value = 0.4 * sinf(Float(2 * Double.pi * 440 * Double(frame) / sampleRate))
            samples[frame * 2] = value
            samples[frame * 2 + 1] = value
        }

        samples.withUnsafeBufferPointer { buffer in
            for index in 0..<20 {
                analyzer.process(
                    buffer: buffer.baseAddress!,
                    frameCount: frameCount,
                    channelCount: 2,
                    sampleRate: sampleRate,
                    hostTime: Double(index) * Double(frameCount) / sampleRate
                )
            }
        }

        // 20 buffers of 512 samples at a 512 hop: one frame per buffer once the
        // 1024-sample ring has filled.
        XCTAssertGreaterThanOrEqual(analyzer.frames.writtenFrameCount, 15)
    }
}
