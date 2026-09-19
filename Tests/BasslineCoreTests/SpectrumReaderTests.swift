import XCTest
@testable import BasslineCore

final class SpectrumReaderTests: XCTestCase {
    private func write(_ ring: SpectrumFrameRing, value: Float, time: Double) {
        let bands = [Float](repeating: value, count: ring.bandCount)
        bands.withUnsafeBufferPointer {
            ring.write(bands: $0.baseAddress!, time: time, level: value)
        }
    }

    func testReturnsNilWhenEmpty() {
        let ring = SpectrumFrameRing(capacity: 8, bandCount: 4)
        let reader = SpectrumReader(ring: ring)
        XCTAssertNil(reader.sample(at: 1))
    }

    func testInterpolatesBetweenFrames() {
        let ring = SpectrumFrameRing(capacity: 8, bandCount: 4)
        let reader = SpectrumReader(ring: ring)
        write(ring, value: 0, time: 1.0)
        write(ring, value: 1, time: 2.0)

        let sample = reader.sample(at: 1.5)
        XCTAssertNotNil(sample)
        XCTAssertEqual(sample!.bands[0], 0.5, accuracy: 0.001)
        XCTAssertEqual(sample!.level, 0.5, accuracy: 0.001)
    }

    func testReportsAgeForStaleData() {
        let ring = SpectrumFrameRing(capacity: 8, bandCount: 4)
        let reader = SpectrumReader(ring: ring)
        write(ring, value: 0.7, time: 10)

        let sample = reader.sample(at: 12)
        XCTAssertNotNil(sample)
        XCTAssertEqual(sample!.age, 2, accuracy: 0.001)
    }

    func testHasNewFramesOnlyReportsOnce() {
        let ring = SpectrumFrameRing(capacity: 8, bandCount: 4)
        let reader = SpectrumReader(ring: ring)
        XCTAssertFalse(reader.hasNewFrames())

        write(ring, value: 0.4, time: 1)
        XCTAssertTrue(reader.hasNewFrames())
        XCTAssertFalse(reader.hasNewFrames())
    }
}
