import Accelerate
import Foundation

/// Real-time spectrum analyzer.
///
/// `process` runs on the Core Audio IO thread. Every buffer it needs is
/// allocated once in `init`, so the hot path performs no allocation, no
/// locking and no logging. Results are published through a lock-free ring.
public final class SpectrumAnalyzer: @unchecked Sendable {
    public static let bandCount = 48
    public static let silenceThreshold: Float = 0.0007

    private static let fftSize = 1024
    private static let hopSize = 512
    private static let frameCapacity = 128
    private static let log2n = vDSP_Length(10)

    /// Display window, relative to the slow gain reference.
    ///
    /// A wide window (the -68 dB used previously) lifts every quiet band well
    /// above zero, so the whole strip sits high and its shape flattens into a
    /// near-straight line. -45 dB keeps quiet bands near the baseline and
    /// leaves room for peaks to stand out.
    private static let floorDB: Float = -45
    private static let headroomDB: Float = 0

    /// Shapes the 0...1 band height. Above 1 this pushes mid-level bands down
    /// while leaving strong ones near full height, restoring the visible
    /// difference between the loud and quiet parts of the spectrum.
    private static let displayGamma: Float = 1.8

    public let frames: SpectrumFrameRing

    private let fftSetup: vDSP_DFT_Setup?
    private let window: UnsafeMutablePointer<Float>
    private let ring: UnsafeMutablePointer<Float>
    private let mono: UnsafeMutablePointer<Float>
    private let frameBuffer: UnsafeMutablePointer<Float>
    private let windowed: UnsafeMutablePointer<Float>
    private let realPart: UnsafeMutablePointer<Float>
    private let imagPart: UnsafeMutablePointer<Float>
    private let magnitudes: UnsafeMutablePointer<Float>
    private let rawBands: UnsafeMutablePointer<Float>
    private let smoothedBands: UnsafeMutablePointer<Float>

    private let monoCapacity: Int
    private var ringWriteIndex = 0
    private var ringFilled = 0
    private var samplesSinceHop = 0

    /// Slow automatic gain so quiet passages stay visible without flattening
    /// dynamics the way per-frame normalization does.
    private var gainReferenceDB: Float = -18
    private let attackCoefficient: Float = 0.38
    private let decayCoefficient: Float = 0.055

    /// Bin/band table held as raw memory so the audio thread never touches a
    /// Swift array (which would mean retain/release on the hot path).
    private let mapping: UnsafeMutablePointer<BandMapping.Band>
    private var mappingSampleRate: Double
    private var unityGain: Float = 1

    public init(maxFrameCount: Int = 4096, initialSampleRate: Double = 48_000) {
        let n = Self.fftSize
        let halfN = n / 2

        frames = SpectrumFrameRing(capacity: Self.frameCapacity, bandCount: Self.bandCount)
        fftSetup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(n), .FORWARD)

        window = .allocate(capacity: n)
        window.initialize(repeating: 0, count: n)
        vDSP_hann_window(window, vDSP_Length(n), Int32(vDSP_HANN_NORM))

        ring = Self.makeBuffer(n)
        monoCapacity = max(maxFrameCount, 4096)
        mono = Self.makeBuffer(monoCapacity)
        frameBuffer = Self.makeBuffer(n)
        windowed = Self.makeBuffer(n)
        realPart = Self.makeBuffer(halfN)
        imagPart = Self.makeBuffer(halfN)
        magnitudes = Self.makeBuffer(halfN)
        rawBands = Self.makeBuffer(Self.bandCount)
        smoothedBands = Self.makeBuffer(Self.bandCount)

        mapping = .allocate(capacity: Self.bandCount)
        mapping.initialize(repeating: BandMapping.Band(lowBin: -1, highBin: -1, interpolationBin: 1, tiltDB: 0), count: Self.bandCount)
        mappingSampleRate = initialSampleRate
        Self.fill(mapping, sampleRate: initialSampleRate, binCount: halfN)
    }

    private static func fill(_ destination: UnsafeMutablePointer<BandMapping.Band>, sampleRate: Double, binCount: Int) {
        let table = BandMapping(bandCount: bandCount, binCount: binCount, sampleRate: sampleRate)
        for index in 0..<bandCount {
            destination[index] = table.bands[index]
        }
    }

    deinit {
        if let fftSetup { vDSP_DFT_DestroySetup(fftSetup) }
        for buffer in [window, ring, mono, frameBuffer, windowed, realPart, imagPart, magnitudes, rawBands, smoothedBands] {
            buffer.deallocate()
        }
        mapping.deinitialize(count: Self.bandCount)
        mapping.deallocate()
    }

    private static func makeBuffer(_ count: Int) -> UnsafeMutablePointer<Float> {
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: count)
        buffer.initialize(repeating: 0, count: count)
        return buffer
    }

    /// Rebuilds the bin/band mapping. Call from a non-realtime thread only.
    public func updateSampleRate(_ sampleRate: Double) {
        guard sampleRate > 0, abs(sampleRate - mappingSampleRate) > 1 else { return }
        Self.fill(mapping, sampleRate: sampleRate, binCount: Self.fftSize / 2)
        mappingSampleRate = sampleRate
    }

    public var currentSampleRate: Double { mappingSampleRate }

    // MARK: - Audio thread

    /// Consumes one interleaved audio buffer. Real-time safe.
    public func process(
        buffer: UnsafePointer<Float>,
        frameCount: Int,
        channelCount: Int,
        sampleRate: Double,
        hostTime: Double
    ) {
        guard frameCount > 0, channelCount > 0, frameCount <= monoCapacity else { return }

        downmix(buffer: buffer, frameCount: frameCount, channelCount: channelCount)

        let n = Self.fftSize
        let mask = n - 1
        var index = 0
        while index < frameCount {
            // `samplesSinceHop` is always reset the moment it reaches the hop
            // size below, so this is never zero. The guard is kept because a
            // zero-length chunk here would spin the audio thread forever.
            let chunk = min(Self.hopSize - samplesSinceHop, frameCount - index)
            guard chunk > 0 else { break }

            let contiguous = min(chunk, n - ringWriteIndex)
            (ring + ringWriteIndex).update(from: mono + index, count: contiguous)
            if contiguous < chunk {
                ring.update(from: mono + index + contiguous, count: chunk - contiguous)
            }

            ringWriteIndex = (ringWriteIndex + chunk) & mask
            ringFilled = min(n, ringFilled + chunk)
            samplesSinceHop += chunk
            index += chunk

            // The counter must be reset whenever a full hop has been consumed,
            // even while the ring is still filling up. Resetting only when the
            // FFT actually runs leaves it pinned at the hop size, which makes
            // the chunk above zero and the loop never terminates.
            if samplesSinceHop >= Self.hopSize {
                samplesSinceHop = 0
                if ringFilled == n {
                    let centerOffset = Double(index - n / 2) / sampleRate
                    analyze(time: hostTime + centerOffset)
                }
            }
        }
    }

    private func downmix(buffer: UnsafePointer<Float>, frameCount: Int, channelCount: Int) {
        if channelCount == 1 {
            mono.update(from: buffer, count: frameCount)
            return
        }
        // Distinct source and destination pointers: no aliasing, no exclusivity
        // violation, unlike passing the same array as both operands.
        vDSP_vsmul(buffer, vDSP_Stride(channelCount), &unityGain, mono, 1, vDSP_Length(frameCount))
        for channel in 1..<channelCount {
            vDSP_vadd(mono, 1, buffer + channel, vDSP_Stride(channelCount), mono, 1, vDSP_Length(frameCount))
        }
        var scale = 1 / Float(channelCount)
        vDSP_vsmul(mono, 1, &scale, mono, 1, vDSP_Length(frameCount))
    }

    private func analyze(time: Double) {
        guard let fftSetup else { return }
        let n = Self.fftSize
        let halfN = n / 2

        let oldest = ringWriteIndex
        let tail = n - oldest
        frameBuffer.update(from: ring + oldest, count: tail)
        (frameBuffer + tail).update(from: ring, count: oldest)

        var rms: Float = 0
        vDSP_rmsqv(frameBuffer, 1, &rms, vDSP_Length(n))

        guard rms > Self.silenceThreshold * 0.25 else {
            decayToSilence(time: time, rms: rms)
            return
        }

        vDSP_vmul(frameBuffer, 1, window, 1, windowed, 1, vDSP_Length(n))

        var split = DSPSplitComplex(realp: realPart, imagp: imagPart)
        windowed.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { complex in
            vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(halfN))
        }
        vDSP_DFT_Execute(fftSetup, realPart, imagPart, realPart, imagPart)
        vDSP_zvmags(&split, 1, magnitudes, 1, vDSP_Length(halfN))

        // vDSP_zvmags returns squared magnitude; scale to amplitude^2 of the
        // original signal so the dB conversion below is meaningful.
        var scale = Float(1) / Float(n * n)
        vDSP_vsmul(magnitudes, 1, &scale, magnitudes, 1, vDSP_Length(halfN))

        mapBands()
        updateGainReference()
        publish(time: time, rms: rms)
    }

    private func mapBands() {
        let reference = gainReferenceDB
        let span = Self.headroomDB - Self.floorDB

        for index in 0..<Self.bandCount {
            let band = mapping[index]
            var power: Float

            if band.lowBin >= 0 {
                let low = Int(band.lowBin)
                let high = Int(band.highBin)
                var sum: Float = 0
                vDSP_sve(magnitudes + low, 1, &sum, vDSP_Length(high - low + 1))
                power = sum / Float(high - low + 1)
            } else {
                let center = band.interpolationBin
                let i0 = Int(center)
                let fraction = center - Float(i0)
                power = magnitudes[i0] + fraction * (magnitudes[i0 + 1] - magnitudes[i0])
            }

            // Power to dB, plus spectral tilt, referenced to the slow AGC.
            let db = 10 * log10f(max(power, 1e-12)) + band.tiltDB - reference
            let normalized = min(1, max(0, (db - Self.floorDB) / span))
            // Gamma keeps strong bands tall while pushing mid-level ones back
            // down, so the strip keeps a visible shape instead of flattening.
            rawBands[index] = powf(normalized, Self.displayGamma)
        }
    }

    private func updateGainReference() {
        var peak: Float = 0
        vDSP_maxv(magnitudes, 1, &peak, vDSP_Length(Self.fftSize / 2))
        let peakDB = 10 * log10f(max(peak, 1e-12))
        // Rise quickly to loud material, fall back slowly so a quiet passage
        // does not get boosted to full scale within a beat.
        let coefficient: Float = peakDB > gainReferenceDB ? 0.05 : 0.0015
        gainReferenceDB += coefficient * (peakDB - gainReferenceDB)
        gainReferenceDB = max(-60, min(0, gainReferenceDB))
    }

    private func decayToSilence(time: Double, rms: Float) {
        for index in 0..<Self.bandCount {
            smoothedBands[index] -= decayCoefficient * smoothedBands[index]
        }
        frames.write(bands: smoothedBands, time: time, level: rms)
    }

    private func publish(time: Double, rms: Float) {
        for index in 0..<Self.bandCount {
            let target = rawBands[index]
            let current = smoothedBands[index]
            let coefficient = target > current ? attackCoefficient : decayCoefficient
            smoothedBands[index] = current + coefficient * (target - current)
        }
        frames.write(bands: smoothedBands, time: time, level: rms)
    }
}
