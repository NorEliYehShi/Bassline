import AppKit
import BasslineCore
import Foundation
import QuartzCore

/// Visualizer view. Owns the per-frame state (bands, peaks, history, sparks,
/// fade) and hands it to `MetalRenderer`, which draws the whole strip on the
/// GPU in a single fragment shader.
///
/// Designed for low, predictable power draw:
/// - nothing is rasterized on the CPU and no bitmap is uploaded per frame; the
///   compositor receives a GPU texture directly
/// - no allocation in the frame path: band history, peaks and sparks live in
///   fixed-size storage
/// - the display link is stopped entirely once the visualizer has faded out,
///   so a paused track costs nothing
/// - 30 fps at 1x backing scale: the strip is soft-edged and smoothed, so
///   neither 60 fps nor Retina resolution is visible on it
/// - a frame is only rendered when something visible changed; a sustained
///   note or a quiet passage costs no draw and no compositor work
final class WaveView: NSView {
    /// Called when the renderer becomes fully idle, so the controller can hide
    /// the window and drop it out of the compositor.
    var onIdle: (() -> Void)?

    var engine: AudioEngine? {
        didSet {
            bandCount = engine?.bandCount ?? SpectrumAnalyzer.bandCount
            resetState()
        }
    }

    var style: VisualizerStyle = .wave {
        didSet {
            sparkCount = 0
            needsRender = true
        }
    }
    var tint: VisualizerTint = .auto {
        didSet {
            ink = nil
            needsRender = true
        }
    }
    var backdropLuminance: CGFloat? {
        didSet {
            ink = nil
            needsRender = true
        }
    }
    /// Caps the frame rate at 20 fps instead of 30.
    var lowPowerMode = false {
        didSet {
            guard lowPowerMode != oldValue else { return }
            applyFrameRateRange()
        }
    }

    private static let maxBandCount = MetalRenderer.maxBandCount
    private static let historyLength = MetalRenderer.historyLength
    private static let maxSparks = MetalRenderer.maxSparks
    private static let auroraBlobCount = MetalRenderer.auroraBlobCount
    private static let idleGraceSeconds: CFTimeInterval = 1.5

    private var bandCount = SpectrumAnalyzer.bandCount

    // Flat fixed-size storage: no per-frame array allocation.
    private var bands = [Float](repeating: 0, count: maxBandCount)
    private var peaks = [Float](repeating: 0, count: maxBandCount)
    private var peakHold = [CGFloat](repeating: 0, count: maxBandCount)
    private var history = [Float](repeating: 0, count: maxBandCount * historyLength)
    private var historyWriteIndex = 0
    private var historyFilled = 0
    private var auroraEnergy = [Float](repeating: 0, count: auroraBlobCount)
    private var previousBlobEnergy = [Float](repeating: 0, count: auroraBlobCount)

    private struct Spark {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var vx: CGFloat = 0
        var vy: CGFloat = 0
        var age: CGFloat = 0
        var lifetime: CGFloat = 1
        var size: CGFloat = 1
    }
    private var sparks = [Spark](repeating: Spark(), count: maxSparks)
    private var sparkCount = 0

    private var bass: Float = 0
    private var fadeAlpha: CGFloat = 0
    // Per second, so the fade looks the same at any frame rate.
    private let fadeInSpeed: CGFloat = 6
    private let fadeOutSpeed: CGFloat = 1.8

    // State as of the last frame that was actually rendered. A new frame is
    // drawn only when the current state differs from this by more than
    // `redrawThreshold`.
    private var drawnBands = [Float](repeating: 0, count: maxBandCount)
    private var drawnPeaks = [Float](repeating: 0, count: maxBandCount)
    private var drawnBass: Float = 0
    private var drawnFadeAlpha: CGFloat = 0
    private var needsRender = false
    /// In normalized band height; well under one pixel at any strip height.
    private static let redrawThreshold: Float = 0.005

    private var displayLink: CADisplayLink?
    private var lastFrameTime: CFTimeInterval = CACurrentMediaTime()
    private var silentSince: CFTimeInterval?

    private let peakHoldSeconds: CGFloat = 0.17
    /// Normalized height per second.
    private let peakGravity: Float = 0.5

    private let renderer: MetalRenderer?
    private var metalLayer: CAMetalLayer? { layer as? CAMetalLayer }

    private struct Ink {
        let base: SIMD3<Float>
        let halo: SIMD3<Float>
        let isLight: Bool
    }
    private var ink: Ink?

    override var isFlipped: Bool { false }
    override var isOpaque: Bool { false }

    override init(frame: NSRect) {
        do {
            renderer = try MetalRenderer()
        } catch {
            renderer = nil
            log.error("Metal renderer unavailable: \(String(describing: error), privacy: .public)")
        }
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        updateDrawableSize()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.device = renderer?.device
        layer.pixelFormat = .bgra8Unorm
        layer.isOpaque = false
        layer.framebufferOnly = true
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.contentsScale = 1
        return layer
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
        needsRender = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        // AppKit resets the scale to the display's; keep 1x. The visualizer is
        // soft-edged, so 1x is visually almost identical to Retina and cuts the
        // shaded pixel count by 4.
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        guard let metalLayer else { return }
        metalLayer.contentsScale = 1
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        metalLayer.drawableSize = size
    }

    // MARK: - Display link

    var isRunning: Bool { displayLink != nil }

    func startDisplayLink() {
        guard displayLink == nil, window != nil else { return }
        let link = displayLink(target: self, selector: #selector(displayLinkFired))
        applyFrameRateRange(to: link)
        link.add(to: .main, forMode: .common)
        displayLink = link
        lastFrameTime = CACurrentMediaTime()
        silentSince = nil
    }

    func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    private func applyFrameRateRange(to link: CADisplayLink? = nil) {
        guard let target = link ?? displayLink else { return }
        // The analyzer publishes ~94 frames/s and the bands are smoothed, so
        // 30 fps is indistinguishable from 60 on a spectrum strip. Every frame
        // saved is a GPU pass and a compositor pass.
        target.preferredFrameRateRange = lowPowerMode
            ? CAFrameRateRange(minimum: 15, maximum: 20, preferred: 20)
            : CAFrameRateRange(minimum: 24, maximum: 30, preferred: 30)
    }

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        update(presentationTime: link.targetTimestamp)
    }

    private func resetState() {
        for index in 0..<Self.maxBandCount {
            bands[index] = 0
            peaks[index] = 0
            peakHold[index] = 0
        }
        for index in 0..<history.count { history[index] = 0 }
        historyWriteIndex = 0
        historyFilled = 0
        sparkCount = 0
        bass = 0
    }

    // MARK: - Per-frame update

    private func update(presentationTime: CFTimeInterval) {
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(0.05, max(0.0001, now - lastFrameTime)))
        lastFrameTime = now

        var isSilent = true
        var hasFreshData = false

        if let engine {
            hasFreshData = engine.hasNewFrames()
            if let sample = engine.sample(
                at: presentationTime,
                syncOffsetMs: Settings.shared.syncOffsetMs
            ) {
                for index in 0..<bandCount {
                    bands[index] = sample.bands[index]
                }
                isSilent = sample.age > 0.5 || sample.level < SpectrumAnalyzer.silenceThreshold
            }
        }

        if isSilent {
            fadeAlpha = max(0, fadeAlpha - fadeOutSpeed * dt)
        } else {
            fadeAlpha = min(1, fadeAlpha + fadeInSpeed * dt)
            silentSince = nil
        }

        // Fully faded out and the producer stopped: shut the renderer down
        // instead of running a full-width GPU pass forever.
        if fadeAlpha <= 0.001 && !hasFreshData {
            let start = silentSince ?? now
            silentSince = start
            if now - start > Self.idleGraceSeconds {
                stopDisplayLink()
                onIdle?()
                return
            }
        }

        guard fadeAlpha > 0.001 else { return }

        appendHistory()
        updatePeaks(dt: dt)
        updateBass()
        if style == .aurora {
            updateAurora(dt: dt)
        }

        guard needsRender || hasVisibleChange() else { return }
        needsRender = false
        recordDrawnState()
        render()
    }

    private func hasVisibleChange() -> Bool {
        // Aurora blobs drift with wall-clock time, so every frame differs.
        if style == .aurora { return true }
        if abs(fadeAlpha - drawnFadeAlpha) > 0.002 { return true }
        if abs(bass - drawnBass) > Self.redrawThreshold { return true }
        for index in 0..<bandCount {
            if abs(bands[index] - drawnBands[index]) > Self.redrawThreshold
                || abs(peaks[index] - drawnPeaks[index]) > Self.redrawThreshold {
                return true
            }
        }
        return false
    }

    private func recordDrawnState() {
        for index in 0..<bandCount {
            drawnBands[index] = bands[index]
            drawnPeaks[index] = peaks[index]
        }
        drawnBass = bass
        drawnFadeAlpha = fadeAlpha
    }

    private func appendHistory() {
        let offset = historyWriteIndex * Self.maxBandCount
        for index in 0..<bandCount {
            history[offset + index] = bands[index]
        }
        historyWriteIndex = (historyWriteIndex + 1) % Self.historyLength
        historyFilled = min(Self.historyLength, historyFilled + 1)
    }

    private func updatePeaks(dt: CGFloat) {
        let fall = peakGravity * Float(dt)
        for index in 0..<bandCount {
            if bands[index] >= peaks[index] {
                peaks[index] = bands[index]
                peakHold[index] = peakHoldSeconds
            } else if peakHold[index] > 0 {
                peakHold[index] -= dt
            } else {
                peaks[index] = max(bands[index], peaks[index] - fall)
            }
        }
    }

    private func updateBass() {
        let count = min(6, bandCount)
        var sum: Float = 0
        for index in 0..<count { sum += bands[index] }
        let target = sum / Float(count)
        bass += (target > bass ? 0.5 : 0.1) * (target - bass)
    }

    private func updateAurora(dt: CGFloat) {
        let blobCount = Self.auroraBlobCount
        let bandsPerBlob = bandCount / blobCount
        guard bandsPerBlob > 0 else { return }

        let height = bounds.height
        let spacing = bounds.width / CGFloat(blobCount)

        for blob in 0..<blobCount {
            var sum: Float = 0
            for index in (blob * bandsPerBlob)..<((blob + 1) * bandsPerBlob) {
                sum += bands[index]
            }
            let target = sum / Float(bandsPerBlob)
            let previous = auroraEnergy[blob]
            auroraEnergy[blob] += (target > previous ? 0.3 : 0.06) * (target - previous)

            let isOnset = target - previousBlobEnergy[blob] > 0.18
            previousBlobEnergy[blob] = target

            if isOnset, fadeAlpha > 0.5, sparkCount < Self.maxSparks - 2 {
                let centerX = spacing * (CGFloat(blob) + 0.5)
                for _ in 0..<2 where sparkCount < Self.maxSparks {
                    sparks[sparkCount] = Spark(
                        x: centerX + CGFloat.random(in: -spacing * 0.4...spacing * 0.4),
                        y: height * 0.08 + CGFloat(target) * height * 0.3,
                        vx: CGFloat.random(in: -6...6),
                        vy: CGFloat.random(in: 18...40),
                        age: 0,
                        lifetime: CGFloat.random(in: 0.8...1.6),
                        size: CGFloat.random(in: 0.9...2.0)
                    )
                    sparkCount += 1
                }
            }
        }

        var index = 0
        while index < sparkCount {
            sparks[index].age += dt
            sparks[index].x += sparks[index].vx * dt
            sparks[index].y += sparks[index].vy * dt
            sparks[index].vy *= 1 - 0.6 * dt

            if sparks[index].age >= sparks[index].lifetime || sparks[index].y > height {
                sparks[index] = sparks[sparkCount - 1]
                sparkCount -= 1
            } else {
                index += 1
            }
        }
    }

    // MARK: - Rendering

    private func currentInk() -> Ink {
        if let ink { return ink }
        let color = tint.resolvedColor(appearance: effectiveAppearance, backdropLuminance: backdropLuminance)
        let srgb = color.usingColorSpace(.sRGB) ?? color
        let base = SIMD3<Float>(Float(srgb.redComponent), Float(srgb.greenComponent), Float(srgb.blueComponent))
        let luminance = 0.2126 * base.x + 0.7152 * base.y + 0.0722 * base.z
        let isLight = luminance > 0.5
        let created = Ink(base: base, halo: isLight ? SIMD3<Float>(0, 0, 0) : SIMD3<Float>(1, 1, 1), isLight: isLight)
        ink = created
        return created
    }

    private static let styleIndex: [VisualizerStyle: Float] = [.wave: 0, .dots: 1, .aurora: 2]
    /// Common period of the aurora drift sines (speeds are multiples of 0.05),
    /// so wrapping the time keeps it exact in a 32-bit float.
    private static let auroraTimePeriod = 2 * Double.pi / 0.05

    private func render() {
        guard let renderer, let metalLayer, bounds.width > 0, bounds.height > 0 else { return }
        let ink = currentInk()

        var params = MetalRenderer.Params()
        params.baseR = ink.base.x
        params.baseG = ink.base.y
        params.baseB = ink.base.z
        params.haloR = ink.halo.x
        params.haloG = ink.halo.y
        params.haloB = ink.halo.z
        params.width = Float(bounds.width)
        params.height = Float(bounds.height)
        params.fade = Float(fadeAlpha)
        params.bass = bass
        params.time = Float(CACurrentMediaTime().truncatingRemainder(dividingBy: Self.auroraTimePeriod))
        params.style = Self.styleIndex[style] ?? 0
        params.bandCount = Float(bandCount)
        params.historyFilled = Float(historyFilled)
        params.historyWriteIndex = Float(historyWriteIndex)
        params.sparkCount = Float(sparkCount)
        params.isLightInk = ink.isLight ? 1 : 0

        renderer.render(to: metalLayer, params: params) { data in
            bands.withUnsafeBufferPointer {
                (data + MetalRenderer.bandsOffset).update(from: $0.baseAddress!, count: Self.maxBandCount)
            }
            peaks.withUnsafeBufferPointer {
                (data + MetalRenderer.peaksOffset).update(from: $0.baseAddress!, count: Self.maxBandCount)
            }
            history.withUnsafeBufferPointer {
                (data + MetalRenderer.historyOffset).update(from: $0.baseAddress!, count: history.count)
            }
            auroraEnergy.withUnsafeBufferPointer {
                (data + MetalRenderer.auroraOffset).update(from: $0.baseAddress!, count: Self.auroraBlobCount)
            }
            for index in 0..<sparkCount {
                let spark = sparks[index]
                let life = 1 - spark.age / spark.lifetime
                let alpha = 0.9 * life * life
                let base = data + MetalRenderer.sparksOffset + index * MetalRenderer.sparkStride
                base[0] = Float(spark.x)
                base[1] = Float(spark.y)
                base[2] = Float(spark.size)
                base[3] = alpha > 0.02 ? Float(alpha) : 0
            }
        }
    }
}
