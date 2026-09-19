import BasslineCore
import Foundation

/// Render-side handle on a running analyzer: latency-compensated spectrum
/// lookup plus the activity signal the renderer uses to decide whether to draw
/// at all.
final class AudioEngine {
    private let analyzer: SpectrumAnalyzer
    private let reader: SpectrumReader
    private let latencyLock = NSLock()
    private var _outputLatency: Double = 0

    init(analyzer: SpectrumAnalyzer) {
        self.analyzer = analyzer
        reader = SpectrumReader(ring: analyzer.frames)
    }

    var bandCount: Int { reader.bandCount }

    var outputLatency: Double {
        get {
            latencyLock.lock()
            defer { latencyLock.unlock() }
            return _outputLatency
        }
        set {
            latencyLock.lock()
            _outputLatency = newValue
            latencyLock.unlock()
        }
    }

    /// True when the analyzer published at least one frame since the last call.
    /// When this is false and the visualizer has faded out, the renderer can
    /// stop entirely.
    func hasNewFrames() -> Bool { reader.hasNewFrames() }

    func sample(at presentationTime: Double, syncOffsetMs: Double) -> SpectrumReader.Sample? {
        let delay = outputLatency + syncOffsetMs / 1000
        return reader.sample(at: presentationTime - delay)
    }
}
