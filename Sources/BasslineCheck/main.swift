import BasslineCore
import Foundation

/// Verification runner for `BasslineCore`.
///
/// XCTest ships with full Xcode, not with the Command Line Tools, so
/// `swift test` cannot run in a CLT-only setup. This executable covers the same
/// behaviour with plain assertions and runs anywhere:
///
///     swift run -c release BasslineCheck
///
/// Exits 0 when everything passes, 1 otherwise.
enum Check {
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var passes = 0

    static func expect(_ condition: Bool, _ message: String) {
        if condition {
            passes += 1
        } else {
            failures += 1
            print("  FAIL: \(message)")
        }
    }

    static func expect(
        _ value: Double,
        equals expected: Double,
        accuracy: Double,
        _ message: String
    ) {
        expect(abs(value - expected) <= accuracy, "\(message) (got \(value), expected \(expected) ± \(accuracy))")
    }

    static func section(_ name: String) {
        print("\n\(name)")
    }
}

let sampleRate: Double = 48_000

func makeTone(frequency: Double, frameCount: Int, channels: Int, amplitude: Float = 0.5) -> [Float] {
    var samples = [Float](repeating: 0, count: frameCount * channels)
    for frame in 0..<frameCount {
        let value = amplitude * sinf(Float(2 * Double.pi * frequency * Double(frame) / sampleRate))
        for channel in 0..<channels {
            samples[frame * channels + channel] = value
        }
    }
    return samples
}

func feed(_ analyzer: SpectrumAnalyzer, samples: [Float], channels: Int, repeats: Int) {
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

/// Runs `process` on a background thread with a hard timeout.
///
/// A zero-length chunk in the accumulation loop does not crash, it spins the
/// audio thread forever. Without a timeout this check would hang instead of
/// failing, which is exactly how the freeze reached the app.
func expectTerminates(
    _ label: String,
    frameCounts: [Int],
    channels: Int,
    timeout: TimeInterval = 10
) {
    let semaphore = DispatchSemaphore(value: 0)

    let thread = Thread {
        let analyzer = SpectrumAnalyzer(initialSampleRate: sampleRate)
        var hostTime = 0.0
        for frameCount in frameCounts {
            let samples = makeTone(frequency: 440, frameCount: frameCount, channels: channels, amplitude: 0.4)
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
        semaphore.signal()
    }
    thread.stackSize = 1 << 20
    thread.start()

    let result = semaphore.wait(timeout: .now() + timeout)
    Check.expect(result == .success, "\(label): process did not return within \(Int(timeout))s — accumulation loop is stuck")
}

// MARK: - Accumulation loop (regression: app froze on first audio buffer)

Check.section("Accumulation loop terminates")
expectTerminates("repeated hop-sized buffers", frameCounts: Array(repeating: 512, count: 200), channels: 2)
expectTerminates("small buffers", frameCounts: Array(repeating: 64, count: 400), channels: 2)
expectTerminates("large buffers", frameCounts: Array(repeating: 4096, count: 20), channels: 2)
expectTerminates("mono buffers", frameCounts: Array(repeating: 512, count: 200), channels: 1)
expectTerminates(
    "irregular buffer sizes",
    frameCounts: [1, 7, 512, 513, 1024, 3, 2048, 511, 1, 1023, 512, 512, 512],
    channels: 2
)

Check.section("Frames are actually produced")
do {
    let analyzer = SpectrumAnalyzer(initialSampleRate: sampleRate)
    feed(analyzer, samples: makeTone(frequency: 440, frameCount: 512, channels: 2), channels: 2, repeats: 20)
    Check.expect(
        analyzer.frames.writtenFrameCount >= 15,
        "expected at least 15 frames from 20 hop-sized buffers, got \(analyzer.frames.writtenFrameCount)"
    )
}

// MARK: - Analyzer behaviour

Check.section("Analyzer")
do {
    let analyzer = SpectrumAnalyzer(initialSampleRate: sampleRate)
    feed(analyzer, samples: [Float](repeating: 0, count: 512 * 2), channels: 2, repeats: 20)

    var bands = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
    let result = analyzer.frames.read(age: 0, into: &bands)
    Check.expect(result != nil, "silence should still publish a frame")
    if let result {
        Check.expect(result.level < SpectrumAnalyzer.silenceThreshold, "silence level should be below the threshold")
    }
    Check.expect(bands.allSatisfy { $0 < 0.05 }, "silence should produce no band energy")
}

do {
    let analyzer = SpectrumAnalyzer(initialSampleRate: sampleRate)
    feed(analyzer, samples: makeTone(frequency: 1_000, frameCount: 512, channels: 2), channels: 2, repeats: 60)

    var bands = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
    Check.expect(analyzer.frames.read(age: 0, into: &bands) != nil, "tone should publish a frame")

    let peak = bands.max() ?? 0
    let peakIndex = bands.firstIndex(of: peak) ?? 0
    let mapping = BandMapping(bandCount: SpectrumAnalyzer.bandCount, binCount: 512, sampleRate: sampleRate)
    let band = mapping.bands[peakIndex]
    let binWidth = sampleRate / 2 / 512
    let centerBin = band.lowBin >= 0
        ? Double(band.lowBin + band.highBin) / 2
        : Double(band.interpolationBin)

    Check.expect(peak > 0.1, "a 1 kHz tone should produce visible energy")
    Check.expect(centerBin * binWidth, equals: 1_000, accuracy: 300, "peak band should sit near 1 kHz")
}

do {
    var heights: [Float] = []
    for amplitude in [Float(0.02), Float(0.8)] {
        let analyzer = SpectrumAnalyzer(initialSampleRate: sampleRate)
        feed(
            analyzer,
            samples: makeTone(frequency: 500, frameCount: 512, channels: 2, amplitude: amplitude),
            channels: 2,
            repeats: 30
        )
        var bands = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
        _ = analyzer.frames.read(age: 0, into: &bands)
        heights.append(bands.max() ?? 0)
    }
    // Per-frame normalization would make these identical.
    Check.expect(heights[1] > heights[0], "a loud tone should render taller than a quiet one")
}

do {
    let stereo = SpectrumAnalyzer(initialSampleRate: sampleRate)
    let mono = SpectrumAnalyzer(initialSampleRate: sampleRate)
    feed(stereo, samples: makeTone(frequency: 800, frameCount: 512, channels: 2), channels: 2, repeats: 40)
    feed(mono, samples: makeTone(frequency: 800, frameCount: 512, channels: 1), channels: 1, repeats: 40)

    var stereoBands = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
    var monoBands = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
    _ = stereo.frames.read(age: 0, into: &stereoBands)
    _ = mono.frames.read(age: 0, into: &monoBands)

    var maxDelta: Float = 0
    for index in 0..<SpectrumAnalyzer.bandCount {
        maxDelta = max(maxDelta, abs(stereoBands[index] - monoBands[index]))
    }
    Check.expect(maxDelta < 0.05, "mono and stereo downmix should agree (max delta \(maxDelta))")
}

do {
    let analyzer = SpectrumAnalyzer(initialSampleRate: sampleRate)
    analyzer.updateSampleRate(44_100)
    Check.expect(analyzer.currentSampleRate == 44_100, "sample rate change should be accepted")
}

// MARK: - Spectrum shape
//
// Regression: an over-wide dB window plus full roll-off compensation lifted
// every band to a similar height, so the strip rendered as a near-flat line
// with the treble end moving as much as the bass end.

Check.section("Spectrum keeps its shape")
do {
    // Pink-ish content: energy falling with frequency, like real music.
    let frameCount = 512
    var samples = [Float](repeating: 0, count: frameCount * 2)
    let tones: [(Double, Float)] = [(60, 0.60), (250, 0.24), (1_000, 0.10), (4_000, 0.04), (12_000, 0.015)]
    for frame in 0..<frameCount {
        var value: Float = 0
        for (frequency, amplitude) in tones {
            value += amplitude * sinf(Float(2 * Double.pi * frequency * Double(frame) / sampleRate))
        }
        samples[frame * 2] = value
        samples[frame * 2 + 1] = value
    }

    let analyzer = SpectrumAnalyzer(initialSampleRate: sampleRate)
    feed(analyzer, samples: samples, channels: 2, repeats: 60)

    var bands = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
    _ = analyzer.frames.read(age: 0, into: &bands)

    let third = SpectrumAnalyzer.bandCount / 3
    let low = bands[0..<third].max() ?? 0
    let high = bands[(third * 2)...].max() ?? 0

    Check.expect(low > 0.35, "bass should reach a useful height (got \(low))")
    Check.expect(
        low - high > 0.25,
        "falling content should render as a falling curve, not a flat line (bass \(low) vs treble \(high))"
    )

    let spread = (bands.max() ?? 0) - (bands.min() ?? 0)
    Check.expect(spread > 0.4, "the spectrum should keep visible contrast (spread \(spread))")
}

// MARK: - Band mapping

Check.section("Band mapping")
do {
    let binCount = 512
    let mapping = BandMapping(bandCount: 48, binCount: binCount, sampleRate: sampleRate)
    Check.expect(mapping.bands.count == 48, "band count should match the request")

    var monotonic = true
    var inRange = true
    var previousLow: Int32 = 0
    for band in mapping.bands {
        if band.lowBin >= 0 {
            if band.lowBin > band.highBin { inRange = false }
            if band.lowBin < 1 || band.highBin >= Int32(binCount) { inRange = false }
            if band.lowBin < previousLow { monotonic = false }
            previousLow = band.lowBin
        } else if band.interpolationBin < 1 || band.interpolationBin > Float(binCount - 2) {
            inRange = false
        }
    }
    Check.expect(monotonic, "band low bins should increase")
    Check.expect(inRange, "band bins should stay inside the spectrum")

    if let first = mapping.bands.first, let last = mapping.bands.last {
        Check.expect(last.tiltDB > first.tiltDB, "tilt should rise with frequency")
        Check.expect(Double(first.tiltDB), equals: 0, accuracy: 0.01, "tilt should start at 0 dB")
    }

    let narrow = BandMapping(bandCount: 48, binCount: binCount, sampleRate: 8_000)
    Check.expect(
        narrow.bands.allSatisfy { $0.lowBin < 0 || $0.highBin < Int32(binCount) },
        "a low sample rate should stay within Nyquist"
    )
}

// MARK: - Frame ring

Check.section("Frame ring")
do {
    let ring = SpectrumFrameRing(capacity: 4, bandCount: 3)
    var destination = [Float](repeating: 0, count: 3)
    Check.expect(ring.read(age: 0, into: &destination) == nil, "empty ring should return nil")

    let bands = [Float](repeating: 0.5, count: 3)
    bands.withUnsafeBufferPointer { ring.write(bands: $0.baseAddress!, time: 12, level: 0.25) }
    let result = ring.read(age: 0, into: &destination)
    Check.expect(result?.time == 12, "should read back the written timestamp")
    Check.expect(result?.level == 0.25, "should read back the written level")
    Check.expect(destination == bands, "should read back the written bands")
}

do {
    let ring = SpectrumFrameRing(capacity: 8, bandCount: 2)
    for index in 0..<5 {
        let bands = [Float](repeating: Float(index), count: 2)
        bands.withUnsafeBufferPointer {
            ring.write(bands: $0.baseAddress!, time: Double(index), level: Float(index))
        }
    }
    var destination = [Float](repeating: 0, count: 2)
    Check.expect(ring.read(age: 0, into: &destination)?.time == 4, "age 0 should be the newest frame")
    Check.expect(ring.read(age: 2, into: &destination)?.time == 2, "age 2 should walk back two frames")
}

do {
    let ring = SpectrumFrameRing(capacity: 4, bandCount: 1)
    for index in 0..<10 {
        let bands = [Float](repeating: Float(index), count: 1)
        bands.withUnsafeBufferPointer {
            ring.write(bands: $0.baseAddress!, time: Double(index), level: 0)
        }
    }
    var destination = [Float](repeating: 0, count: 1)
    Check.expect(ring.read(age: 0, into: &destination)?.time == 9, "newest frame should survive wraparound")
    Check.expect(ring.read(age: 4, into: &destination) == nil, "overwritten frames should not be returned")
    Check.expect(ring.writtenFrameCount == 10, "write counter should track every write")
}

Check.section("Frame ring under concurrent access")
do {
    let bandCount = 32
    let ring = SpectrumFrameRing(capacity: 16, bandCount: bandCount)
    let iterations = 20_000
    let semaphore = DispatchSemaphore(value: 0)

    DispatchQueue.global().async {
        for index in 0..<iterations {
            let value = Float(index % 100)
            let bands = [Float](repeating: value, count: bandCount)
            bands.withUnsafeBufferPointer {
                ring.write(bands: $0.baseAddress!, time: Double(index), level: value)
            }
        }
        semaphore.signal()
    }

    var destination = [Float](repeating: 0, count: bandCount)
    var torn = false
    for _ in 0..<iterations {
        if let result = ring.read(age: 0, into: &destination) {
            // Every band in a frame holds the same value, so any mismatch means
            // a torn read slipped through the seqlock.
            if !destination.allSatisfy({ $0 == destination[0] }) || destination[0] != result.level {
                torn = true
                break
            }
        }
    }
    _ = semaphore.wait(timeout: .now() + 30)
    Check.expect(!torn, "concurrent reads should never observe a torn frame")
}

// MARK: - Reader

Check.section("Reader")
do {
    let ring = SpectrumFrameRing(capacity: 8, bandCount: 4)
    let reader = SpectrumReader(ring: ring)
    Check.expect(reader.sample(at: 1) == nil, "empty ring should produce no sample")

    func write(_ value: Float, time: Double) {
        let bands = [Float](repeating: value, count: 4)
        bands.withUnsafeBufferPointer { ring.write(bands: $0.baseAddress!, time: time, level: value) }
    }

    write(0, time: 1)
    write(1, time: 2)

    if let sample = reader.sample(at: 1.5) {
        Check.expect(Double(sample.bands[0]), equals: 0.5, accuracy: 0.001, "bands should interpolate between frames")
        Check.expect(Double(sample.level), equals: 0.5, accuracy: 0.001, "level should interpolate between frames")
    } else {
        Check.expect(false, "expected an interpolated sample")
    }
}

do {
    let ring = SpectrumFrameRing(capacity: 8, bandCount: 4)
    let reader = SpectrumReader(ring: ring)
    let bands = [Float](repeating: 0.7, count: 4)
    bands.withUnsafeBufferPointer { ring.write(bands: $0.baseAddress!, time: 10, level: 0.7) }

    if let sample = reader.sample(at: 12) {
        Check.expect(sample.age, equals: 2, accuracy: 0.001, "stale data should report its age")
    } else {
        Check.expect(false, "expected a stale sample")
    }
}

do {
    let ring = SpectrumFrameRing(capacity: 8, bandCount: 4)
    let reader = SpectrumReader(ring: ring)
    Check.expect(!reader.hasNewFrames(), "no frames written yet")

    let bands = [Float](repeating: 0.4, count: 4)
    bands.withUnsafeBufferPointer { ring.write(bands: $0.baseAddress!, time: 1, level: 0.4) }
    Check.expect(reader.hasNewFrames(), "a new frame should be reported once")
    Check.expect(!reader.hasNewFrames(), "the same frame should not be reported twice")
}

// MARK: - Result

print("\n----------------------------------------")
if Check.failures == 0 {
    print("All checks passed (\(Check.passes))")
    exit(0)
} else {
    print("\(Check.failures) failed, \(Check.passes) passed")
    exit(1)
}
