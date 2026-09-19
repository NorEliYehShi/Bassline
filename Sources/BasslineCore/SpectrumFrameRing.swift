import CBasslineAtomics
import Foundation

/// Single-producer / single-consumer ring of spectrum frames.
///
/// The producer is the Core Audio IO thread: every write is wait-free and
/// performs no allocation, no locking and no ObjC/Swift runtime calls.
/// The consumer is the render thread, which reads with a seqlock so a frame
/// that is being overwritten mid-read is detected and skipped instead of
/// returning torn data.
public final class SpectrumFrameRing {
    public let capacity: Int
    public let bandCount: Int

    private let bands: UnsafeMutablePointer<Float>
    private let times: UnsafeMutablePointer<Double>
    private let levels: UnsafeMutablePointer<Float>
    private let sequences: UnsafeMutablePointer<UInt64>
    private let writeCounter: UnsafeMutablePointer<UInt64>

    public init(capacity: Int, bandCount: Int) {
        precondition(capacity > 0 && bandCount > 0)
        self.capacity = capacity
        self.bandCount = bandCount

        bands = .allocate(capacity: capacity * bandCount)
        bands.initialize(repeating: 0, count: capacity * bandCount)
        times = .allocate(capacity: capacity)
        times.initialize(repeating: 0, count: capacity)
        levels = .allocate(capacity: capacity)
        levels.initialize(repeating: 0, count: capacity)
        sequences = .allocate(capacity: capacity)
        sequences.initialize(repeating: 0, count: capacity)
        writeCounter = .allocate(capacity: 1)
        writeCounter.initialize(to: 0)
    }

    deinit {
        bands.deinitialize(count: capacity * bandCount)
        bands.deallocate()
        times.deinitialize(count: capacity)
        times.deallocate()
        levels.deinitialize(count: capacity)
        levels.deallocate()
        sequences.deinitialize(count: capacity)
        sequences.deallocate()
        writeCounter.deinitialize(count: 1)
        writeCounter.deallocate()
    }

    /// Total number of frames written since creation.
    public var writtenFrameCount: UInt64 {
        bsl_load_acquire_u64(writeCounter)
    }

    // MARK: - Producer (audio thread)

    /// Publishes one frame. Real-time safe: no allocation, no locks.
    public func write(bands source: UnsafePointer<Float>, time: Double, level: Float) {
        let written = bsl_load_relaxed_u64(writeCounter)
        let slot = Int(written % UInt64(capacity))

        let seq = bsl_load_relaxed_u64(sequences + slot)
        bsl_store_release_u64(sequences + slot, seq | 1)

        (bands + slot * bandCount).update(from: source, count: bandCount)
        times[slot] = time
        levels[slot] = level

        bsl_store_release_u64(sequences + slot, (seq | 1) + 1)
        bsl_store_release_u64(writeCounter, written &+ 1)
    }

    // MARK: - Consumer (render thread)

    /// Reads one slot, counting back from the newest frame.
    /// `age` 0 is the newest frame. Returns false if the slot is empty or was
    /// being rewritten during the copy.
    public func read(age: Int, into destination: UnsafeMutablePointer<Float>) -> (time: Double, level: Float)? {
        let written = bsl_load_acquire_u64(writeCounter)
        guard written > UInt64(age) else { return nil }

        let index = written &- UInt64(age) &- 1
        guard written &- index <= UInt64(capacity) else { return nil }
        let slot = Int(index % UInt64(capacity))

        let seqBefore = bsl_load_acquire_u64(sequences + slot)
        guard seqBefore & 1 == 0, seqBefore != 0 else { return nil }

        destination.update(from: bands + slot * bandCount, count: bandCount)
        let time = times[slot]
        let level = levels[slot]

        let seqAfter = bsl_load_acquire_u64(sequences + slot)
        guard seqAfter == seqBefore else { return nil }

        return (time, level)
    }
}
