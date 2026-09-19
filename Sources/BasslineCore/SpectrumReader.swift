import Foundation

/// Render-side view over a `SpectrumFrameRing`.
///
/// Owns its own scratch buffers so reading a latency-compensated frame costs
/// no allocation per display refresh.
public final class SpectrumReader {
    public let bandCount: Int

    private let ring: SpectrumFrameRing
    private let older: UnsafeMutablePointer<Float>
    private let newer: UnsafeMutablePointer<Float>
    private let output: UnsafeMutablePointer<Float>
    private var lastConsumedFrameCount: UInt64 = 0

    public init(ring: SpectrumFrameRing) {
        self.ring = ring
        bandCount = ring.bandCount
        older = Self.makeBuffer(bandCount)
        newer = Self.makeBuffer(bandCount)
        output = Self.makeBuffer(bandCount)
    }

    deinit {
        older.deallocate()
        newer.deallocate()
        output.deallocate()
    }

    private static func makeBuffer(_ count: Int) -> UnsafeMutablePointer<Float> {
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: count)
        buffer.initialize(repeating: 0, count: count)
        return buffer
    }

    /// True when the producer published at least one frame since the last call.
    /// Used to skip redrawing when nothing changed.
    public func hasNewFrames() -> Bool {
        let written = ring.writtenFrameCount
        guard written != lastConsumedFrameCount else { return false }
        lastConsumedFrameCount = written
        return true
    }

    public struct Sample {
        public let bands: UnsafePointer<Float>
        public let level: Float
        public let age: Double
    }

    /// Returns the spectrum as it should look at `time`, interpolating between
    /// the two frames around it. `nil` when no usable frame exists yet.
    public func sample(at time: Double) -> Sample? {
        guard let newest = ring.read(age: 0, into: newer) else { return nil }

        if newest.time <= time {
            output.update(from: newer, count: bandCount)
            return Sample(bands: UnsafePointer(output), level: newest.level, age: time - newest.time)
        }

        var newerTime = newest.time
        var newerLevel = newest.level

        for age in 1..<ring.capacity {
            guard let candidate = ring.read(age: age, into: older) else { break }
            if candidate.time <= time {
                let span = newerTime - candidate.time
                let t = span > 0 ? Float((time - candidate.time) / span) : 0
                for index in 0..<bandCount {
                    let base = older[index]
                    output[index] = base + t * (newer[index] - base)
                }
                let level = candidate.level + t * (newerLevel - candidate.level)
                return Sample(bands: UnsafePointer(output), level: level, age: 0)
            }
            newer.update(from: older, count: bandCount)
            newerTime = candidate.time
            newerLevel = candidate.level
        }

        output.update(from: newer, count: bandCount)
        return Sample(bands: UnsafePointer(output), level: newerLevel, age: time - newerTime)
    }
}
