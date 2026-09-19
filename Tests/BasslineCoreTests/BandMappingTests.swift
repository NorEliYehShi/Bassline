import XCTest
@testable import BasslineCore

final class BandMappingTests: XCTestCase {
    func testBandCountMatchesRequest() {
        let mapping = BandMapping(bandCount: 48, binCount: 512, sampleRate: 48_000)
        XCTAssertEqual(mapping.bands.count, 48)
    }

    func testBandsAreMonotonicAndInRange() {
        let binCount = 512
        let mapping = BandMapping(bandCount: 48, binCount: binCount, sampleRate: 48_000)

        var previousLow: Int32 = 0
        for band in mapping.bands {
            if band.lowBin >= 0 {
                XCTAssertLessThanOrEqual(band.lowBin, band.highBin)
                XCTAssertGreaterThanOrEqual(band.lowBin, 1)
                XCTAssertLessThan(band.highBin, Int32(binCount))
                XCTAssertGreaterThanOrEqual(band.lowBin, previousLow)
                previousLow = band.lowBin
            } else {
                XCTAssertGreaterThanOrEqual(band.interpolationBin, 1)
                XCTAssertLessThanOrEqual(band.interpolationBin, Float(binCount - 2))
            }
        }
    }

    func testTiltRisesWithFrequency() {
        let mapping = BandMapping(bandCount: 48, binCount: 512, sampleRate: 48_000)
        let first = mapping.bands.first
        let last = mapping.bands.last
        XCTAssertNotNil(first)
        XCTAssertNotNil(last)
        XCTAssertGreaterThan(last!.tiltDB, first!.tiltDB)
        XCTAssertEqual(first!.tiltDB, 0, accuracy: 0.01)
    }

    func testLowSampleRateStaysWithinNyquist() {
        let binCount = 512
        let mapping = BandMapping(bandCount: 48, binCount: binCount, sampleRate: 8_000)
        for band in mapping.bands where band.lowBin >= 0 {
            XCTAssertLessThan(band.highBin, Int32(binCount))
        }
    }
}
