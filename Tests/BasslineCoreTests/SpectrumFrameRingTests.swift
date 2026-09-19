import XCTest
@testable import BasslineCore

final class SpectrumFrameRingTests: XCTestCase {
    private func makeBands(_ value: Float, count: Int) -> [Float] {
        [Float](repeating: value, count: count)
    }

    func testEmptyRingReturnsNil() {
        let ring = SpectrumFrameRing(capacity: 4, bandCount: 3)
        var destination = [Float](repeating: 0, count: 3)
        XCTAssertNil(ring.read(age: 0, into: &destination))
    }

    func testReadsBackNewestFrame() {
        let ring = SpectrumFrameRing(capacity: 4, bandCount: 3)
        let bands = makeBands(0.5, count: 3)
        bands.withUnsafeBufferPointer { ring.write(bands: $0.baseAddress!, time: 12, level: 0.25) }

        var destination = [Float](repeating: 0, count: 3)
        let result = ring.read(age: 0, into: &destination)
        XCTAssertEqual(result?.time, 12)
        XCTAssertEqual(result?.level, 0.25)
        XCTAssertEqual(destination, bands)
    }

    func testAgeWalksBackwardsInTime() {
        let ring = SpectrumFrameRing(capacity: 8, bandCount: 2)
        for index in 0..<5 {
            let bands = makeBands(Float(index), count: 2)
            bands.withUnsafeBufferPointer {
                ring.write(bands: $0.baseAddress!, time: Double(index), level: Float(index))
            }
        }

        var destination = [Float](repeating: 0, count: 2)
        XCTAssertEqual(ring.read(age: 0, into: &destination)?.time, 4)
        XCTAssertEqual(ring.read(age: 2, into: &destination)?.time, 2)
        XCTAssertEqual(destination, [2, 2])
    }

    func testOverwrittenFramesAreNotReturned() {
        let ring = SpectrumFrameRing(capacity: 4, bandCount: 1)
        for index in 0..<10 {
            let bands = makeBands(Float(index), count: 1)
            bands.withUnsafeBufferPointer {
                ring.write(bands: $0.baseAddress!, time: Double(index), level: 0)
            }
        }

        var destination = [Float](repeating: 0, count: 1)
        XCTAssertEqual(ring.read(age: 0, into: &destination)?.time, 9)
        XCTAssertNil(ring.read(age: 4, into: &destination))
        XCTAssertEqual(ring.writtenFrameCount, 10)
    }

    func testConcurrentWriterAndReaderNeverTear() {
        let bandCount = 32
        let ring = SpectrumFrameRing(capacity: 16, bandCount: bandCount)
        let iterations = 20_000
        let finished = expectation(description: "writer finished")

        DispatchQueue.global().async {
            for index in 0..<iterations {
                let value = Float(index % 100)
                let bands = [Float](repeating: value, count: bandCount)
                bands.withUnsafeBufferPointer {
                    ring.write(bands: $0.baseAddress!, time: Double(index), level: value)
                }
            }
            finished.fulfill()
        }

        var destination = [Float](repeating: 0, count: bandCount)
        var reads = 0
        while reads < iterations {
            if let result = ring.read(age: 0, into: &destination) {
                // Every band in a frame is written with the same value, so any
                // mismatch means a torn read slipped through.
                XCTAssertTrue(destination.allSatisfy { $0 == destination[0] })
                XCTAssertEqual(destination[0], result.level)
            }
            reads += 1
        }

        wait(for: [finished], timeout: 30)
    }
}
