import Foundation

/// Precomputed mapping from FFT bins to log-spaced display bands.
///
/// Built once per sample rate on the main thread and read from the audio
/// thread, so band mapping itself costs no allocation and no `pow` calls.
public struct BandMapping {
    public struct Band {
        public var lowBin: Int32
        public var highBin: Int32
        /// Fractional bin used when the band is narrower than one FFT bin.
        public var interpolationBin: Float
        /// Spectral tilt in dB, compensating for the natural roll-off of music.
        public var tiltDB: Float

        public init(lowBin: Int32, highBin: Int32, interpolationBin: Float, tiltDB: Float) {
            self.lowBin = lowBin
            self.highBin = highBin
            self.interpolationBin = interpolationBin
            self.tiltDB = tiltDB
        }
    }

    public let bands: [Band]
    public let sampleRate: Double

    public static let minFrequency: Double = 40
    public static let maxFrequency: Double = 18_000
    /// dB added per octave above `minFrequency` so highs stay visible.
    ///
    /// Music rolls off at roughly 3 dB per octave, so compensating by the full
    /// amount flattens the spectrum completely: the right side of the strip
    /// then moves as much as the middle. Correcting only part of the roll-off
    /// keeps highs visible while preserving the natural falling shape.
    public static let tiltPerOctaveDB: Float = 1.2

    public init(bandCount: Int, binCount: Int, sampleRate: Double) {
        precondition(bandCount > 0 && binCount > 1 && sampleRate > 0)
        self.sampleRate = sampleRate

        let nyquist = sampleRate / 2
        let maxFrequency = min(nyquist * 0.98, Self.maxFrequency)
        let logMin = log2(Self.minFrequency)
        let logMax = log2(max(maxFrequency, Self.minFrequency * 2))
        let binWidth = nyquist / Double(binCount)

        var result = [Band]()
        result.reserveCapacity(bandCount)

        for index in 0..<bandCount {
            let lowFrequency = pow(2, logMin + (logMax - logMin) * Double(index) / Double(bandCount))
            let highFrequency = pow(2, logMin + (logMax - logMin) * Double(index + 1) / Double(bandCount))
            let lowBinF = lowFrequency / binWidth
            let highBinF = highFrequency / binWidth
            let tilt = Float(log2(max(lowFrequency, Self.minFrequency) / Self.minFrequency)) * Self.tiltPerOctaveDB

            if highBinF - lowBinF >= 1 {
                let low = max(1, Int(lowBinF.rounded(.down)))
                let high = min(binCount - 1, max(low, Int(highBinF.rounded(.down))))
                result.append(Band(lowBin: Int32(low), highBin: Int32(high), interpolationBin: -1, tiltDB: tilt))
            } else {
                let center = min(Double(binCount - 2), max(1, (lowBinF + highBinF) / 2))
                result.append(Band(lowBin: -1, highBin: -1, interpolationBin: Float(center), tiltDB: tilt))
            }
        }

        bands = result
    }
}
