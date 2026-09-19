import Metal
import QuartzCore

/// GPU renderer for the visualizer strip.
///
/// One fullscreen triangle and one fragment shader draw the whole strip
/// procedurally from the band data, so per frame the CPU only copies a few
/// kilobytes of uniforms and encodes a single draw call. Nothing is
/// rasterized on the CPU and no bitmap is uploaded; the compositor receives a
/// GPU texture directly.
///
/// The shader is compiled from source at startup. There is no offline Metal
/// compiler in the Command Line Tools, and the compile takes a few
/// milliseconds once.
final class MetalRenderer {
    static let maxBandCount = 64
    static let historyLength = 12
    static let auroraBlobCount = 8
    static let maxSparks = 48

    // Float offsets into the data buffer. Must match the constants in the
    // shader source below.
    static let bandsOffset = 0
    static let peaksOffset = maxBandCount
    static let historyOffset = maxBandCount * 2
    static let auroraOffset = historyOffset + maxBandCount * historyLength
    static let sparksOffset = auroraOffset + auroraBlobCount
    static let sparkStride = 4
    static let dataFloatCount = sparksOffset + maxSparks * sparkStride

    /// Field order and types must match `Params` in the shader.
    struct Params {
        var baseR: Float = 1, baseG: Float = 1, baseB: Float = 1
        var haloR: Float = 0, haloG: Float = 0, haloB: Float = 0
        var width: Float = 0, height: Float = 0
        var fade: Float = 0
        var bass: Float = 0
        var time: Float = 0
        var style: Float = 0
        var bandCount: Float = 0
        var historyFilled: Float = 0
        var historyWriteIndex: Float = 0
        var sparkCount: Float = 0
        var isLightInk: Float = 0
    }

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState

    private static let inflightCount = 3
    private let paramsBuffers: [MTLBuffer]
    private let dataBuffers: [MTLBuffer]
    private let inflight = DispatchSemaphore(value: MetalRenderer.inflightCount)
    private var bufferIndex = 0

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw RendererError.noDevice
        }
        guard let queue = device.makeCommandQueue() else {
            throw RendererError.noCommandQueue
        }
        self.device = device
        self.queue = queue

        let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        guard let vertexFunction = library.makeFunction(name: "stripVertex"),
              let fragmentFunction = library.makeFunction(name: "stripFragment") else {
            throw RendererError.missingFunction
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

        var params: [MTLBuffer] = []
        var data: [MTLBuffer] = []
        for _ in 0..<Self.inflightCount {
            guard let p = device.makeBuffer(length: MemoryLayout<Params>.stride, options: .storageModeShared),
                  let d = device.makeBuffer(length: Self.dataFloatCount * MemoryLayout<Float>.stride, options: .storageModeShared)
            else { throw RendererError.bufferAllocation }
            params.append(p)
            data.append(d)
        }
        paramsBuffers = params
        dataBuffers = data
    }

    /// Encodes and presents one frame. `fillData` receives a pointer to
    /// `dataFloatCount` floats laid out per the offsets above.
    func render(
        to layer: CAMetalLayer,
        params: Params,
        fillData: (UnsafeMutablePointer<Float>) -> Void
    ) {
        inflight.wait()
        guard let drawable = layer.nextDrawable(),
              let commandBuffer = queue.makeCommandBuffer() else {
            inflight.signal()
            return
        }

        let index = bufferIndex
        bufferIndex = (bufferIndex + 1) % Self.inflightCount

        var params = params
        paramsBuffers[index].contents().copyMemory(from: &params, byteCount: MemoryLayout<Params>.stride)
        fillData(dataBuffers[index].contents().assumingMemoryBound(to: Float.self))

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            inflight.signal()
            return
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(paramsBuffers[index], offset: 0, index: 0)
        encoder.setFragmentBuffer(paramsBuffers[index], offset: 0, index: 0)
        encoder.setFragmentBuffer(dataBuffers[index], offset: 0, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        let inflight = self.inflight
        commandBuffer.addCompletedHandler { _ in inflight.signal() }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    enum RendererError: Error {
        case noDevice
        case noCommandQueue
        case missingFunction
        case bufferAllocation
    }

    // MARK: - Shader

    /// Everything is drawn in premultiplied alpha. Every element's alpha is
    /// multiplied by `fade`, matching the previous Core Graphics renderer
    /// which set the context alpha to the fade level.
    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Params {
        float baseR, baseG, baseB;
        float haloR, haloG, haloB;
        float width, height;
        float fade;
        float bass;
        float time;
        float style;
        float bandCount;
        float historyFilled;
        float historyWriteIndex;
        float sparkCount;
        float isLightInk;
    };

    constant int MAX_BANDS = 64;
    constant int HISTORY_LENGTH = 12;
    constant int BANDS_OFFSET = 0;
    constant int PEAKS_OFFSET = 64;
    constant int HISTORY_OFFSET = 128;
    constant int AURORA_OFFSET = 896;
    constant int SPARKS_OFFSET = 904;
    constant int SPARK_STRIDE = 4;
    constant int AURORA_BLOBS = 8;

    struct VertexOut {
        float4 position [[position]];
        float2 pixel;
    };

    vertex VertexOut stripVertex(uint vid [[vertex_id]], constant Params& P [[buffer(0)]]) {
        float2 ndc = float2(vid == 1 ? 3.0 : -1.0, vid == 2 ? 3.0 : -1.0);
        VertexOut out;
        out.position = float4(ndc, 0.0, 1.0);
        // y grows upward, like the AppKit view coordinates the layout uses.
        out.pixel = (ndc + 1.0) * 0.5 * float2(P.width, P.height);
        return out;
    }

    // Premultiplied source-over.
    static inline float4 over(float4 dst, float3 color, float alpha) {
        return float4(color * alpha, alpha) + dst * (1.0 - alpha);
    }

    // One-pixel antialiased edge from a signed distance.
    static inline float coverage(float distance) {
        return saturate(0.5 - distance);
    }

    static inline float ellipse(float2 p, float2 center, float2 radii) {
        float2 q = (p - center) / radii;
        float d = (length(q) - 1.0) * min(radii.x, radii.y);
        return coverage(d);
    }

    // Three-stop gradient, stops at 0, mid and 1.
    static inline float ramp3(float t, float a0, float a1, float a2, float mid) {
        return t < mid ? mix(a0, a1, t / mid) : mix(a1, a2, (t - mid) / (1.0 - mid));
    }

    // Smooth curve through the band points. The previous renderer used cubic
    // Beziers with horizontal tangents at every point, which is a smoothstep
    // between neighbours.
    static float curveY(float x, constant float* values, int count, float padding,
                        float width, float heightScale, float baseline) {
        float step = (width - 2.0 * padding) / float(max(1, count - 1));
        float u = (x - padding) / step;
        int i = clamp(int(floor(u)), 0, count - 2);
        float t = saturate(u - float(i));
        float s = t * t * (3.0 - 2.0 * t);
        return mix(values[i], values[i + 1], s) * heightScale + baseline;
    }

    static float4 bassGlow(float4 acc, float2 p, constant Params& P, float3 base) {
        float glowHeight = P.height * (0.4 + 0.5 * P.bass);
        if (p.y >= glowHeight) return acc;
        float g = ramp3(p.y / glowHeight, 1.0, 0.35, 0.0, 0.4);
        return over(acc, base, P.fade * (0.08 + 0.32 * P.bass) * g);
    }

    static float4 shadeWave(float2 p, constant Params& P, constant float* data,
                            float3 base, float3 halo) {
        float4 acc = bassGlow(float4(0.0), p, P, base);
        int count = int(P.bandCount);
        float W = P.width, H = P.height;
        float padding = 8.0;
        float x0 = padding, x1 = W - padding;
        float heightScale = H * 0.85, baseline = H * 0.05;
        constant float* bands = data + BANDS_OFFSET;
        constant float* peaks = data + PEAKS_OFFSET;

        // Gradient fill under the curve. Outside the band range the boundary
        // runs straight to the bottom corners.
        float boundary;
        if (p.x < x0) {
            boundary = mix(0.0, bands[0] * heightScale + baseline, p.x / x0);
        } else if (p.x > x1) {
            boundary = mix(bands[count - 1] * heightScale + baseline, 0.0, (p.x - x1) / padding);
        } else {
            boundary = curveY(p.x, bands, count, padding, W, heightScale, baseline);
        }
        float fillCoverage = coverage(p.y - boundary);
        if (fillCoverage > 0.0) {
            acc = over(acc, base, P.fade * mix(0.06, 0.30, p.y / H) * fillCoverage);
        }

        if (p.x < x0 || p.x > x1) return acc;

        float cy = curveY(p.x, bands, count, padding, W, heightScale, baseline);
        float ahead = curveY(min(p.x + 1.0, x1), bands, count, padding, W, heightScale, baseline);
        float behind = curveY(max(p.x - 1.0, x0), bands, count, padding, W, heightScale, baseline);
        float slope = (ahead - behind) * 0.5;
        float d = abs(p.y - cy) * rsqrt(1.0 + slope * slope);

        // Layered strokes stand in for a blur.
        float glow = 0.10 + 0.18 * P.bass;
        acc = over(acc, base, P.fade * glow * 0.5 * coverage(d - 3.5));
        acc = over(acc, base, P.fade * glow * coverage(d - 2.0));
        acc = over(acc, halo, P.fade * 0.22 * coverage(d - 1.5));
        acc = over(acc, base, P.fade * 0.75 * coverage(d - 0.75));

        // Dashed peak line: 2 on, 4 off.
        float py = curveY(p.x, peaks, count, padding, W, heightScale, baseline);
        float dash = fmod(p.x - x0, 6.0) < 2.0 ? 1.0 : 0.0;
        acc = over(acc, base, P.fade * 0.32 * dash * coverage(abs(p.y - py) - 0.5));
        return acc;
    }

    static float4 shadeDots(float2 p, constant Params& P, constant float* data,
                            float3 base, float3 halo) {
        float4 acc = bassGlow(float4(0.0), p, P, base);
        int count = int(P.bandCount);
        float H = P.height;
        float padding = 12.0;
        float step = (P.width - 2.0 * padding) / float(max(1, count - 1));
        float glowScale = 2.6 + 2.4 * P.bass;
        float maxReach = 5.5 * glowScale + 2.0;
        int reach = int(ceil(maxReach / step));
        int center = int(round((p.x - padding) / step));
        int historyFilled = int(P.historyFilled);
        int writeIndex = int(P.historyWriteIndex);

        for (int i = max(0, center - reach); i <= min(count - 1, center + reach); i++) {
            float x = padding + step * float(i);
            if (abs(p.x - x) > maxReach) continue;
            float m = data[BANDS_OFFSET + i];
            float y = m * (H * 0.78) + H * 0.06;
            float rx = 2.0 + m * 3.5;
            float ry = rx * (1.3 + 0.7 * m);
            float alpha = 0.4 + m * 0.6;

            for (int age = 1; age < historyFilled; age++) {
                int slot = (writeIndex - 1 - age + HISTORY_LENGTH * 2) % HISTORY_LENGTH;
                float past = data[HISTORY_OFFSET + slot * MAX_BANDS + i];
                float ghostY = past * (H * 0.78) + H * 0.06;
                if (abs(ghostY - y) <= 1.0) continue;
                float life = 1.0 - float(age) / float(historyFilled);
                float ghostAlpha = alpha * 0.35 * life * life;
                if (ghostAlpha <= 0.015) continue;
                float ghostRx = max(0.8, rx * (0.35 + 0.65 * life));
                acc = over(acc, base, P.fade * ghostAlpha
                           * ellipse(p, float2(x, ghostY), float2(ghostRx, ghostRx * 1.3)));
            }

            float peakY = data[PEAKS_OFFSET + i] * (H * 0.78) + H * 0.06;
            if (peakY - (y + ry) > 2.0) {
                float tick = coverage(max(abs(p.x - x) - rx, abs(p.y - peakY) - 0.5));
                acc = over(acc, base, P.fade * 0.5 * tick);
            }

            float glowRadius = rx * glowScale;
            float r = length(p - float2(x, y)) / glowRadius;
            if (r < 1.0) {
                float g = ramp3(r, 0.85, 0.25, 0.0, 0.35);
                acc = over(acc, base, P.fade * alpha * 0.55 * g);
            }

            acc = over(acc, halo, P.fade * alpha * 0.18 * ellipse(p, float2(x, y), float2(rx + 1.0, ry + 1.0)));
            acc = over(acc, base, P.fade * alpha * ellipse(p, float2(x, y), float2(rx, ry)));
        }
        return acc;
    }

    static float4 shadeAurora(float2 p, constant Params& P, constant float* data,
                              float3 base) {
        float4 acc = bassGlow(float4(0.0), p, P, base);
        float W = P.width, H = P.height;
        float spacing = W / float(AURORA_BLOBS);
        bool additive = P.isLightInk > 0.5;

        float4 blobs = float4(0.0);
        for (int b = 0; b < AURORA_BLOBS; b++) {
            float energy = data[AURORA_OFFSET + b];
            float phase = float(b) * 1.7;
            float speed = 0.25 + 0.05 * float(b % 3);
            float drift = sin(P.time * speed + phase) * spacing * 0.35;
            float2 center = float2(spacing * (float(b) + 0.5) + drift, H * 0.08 + energy * H * 0.3);
            float2 radii = float2(spacing * (0.75 + 0.5 * energy), H * (0.35 + 0.55 * energy));
            float r = length((p - center) / radii);
            if (r >= 1.0) continue;
            float a = P.fade * (0.12 + 0.5 * energy) * ramp3(r, 1.0, 0.35, 0.0, 0.45);
            if (additive) {
                blobs += float4(base * a, a);
            } else {
                blobs = over(blobs, base, a);
            }
        }
        if (additive) {
            acc = min(acc + blobs, 1.0);
        } else {
            acc = blobs + acc * (1.0 - blobs.a);
        }

        int sparkCount = int(P.sparkCount);
        for (int s = 0; s < sparkCount; s++) {
            constant float* spark = data + SPARKS_OFFSET + s * SPARK_STRIDE;
            float2 center = float2(spark[0], spark[1]);
            float size = spark[2];
            float alpha = spark[3];
            if (abs(p.x - center.x) > size + 1.0 || abs(p.y - center.y) > size + 1.0) continue;
            acc = over(acc, base, P.fade * alpha * ellipse(p, center, float2(size)));
        }
        return acc;
    }

    fragment float4 stripFragment(VertexOut in [[stage_in]],
                                  constant Params& P [[buffer(0)]],
                                  constant float* data [[buffer(1)]]) {
        float3 base = float3(P.baseR, P.baseG, P.baseB);
        float3 halo = float3(P.haloR, P.haloG, P.haloB);
        int style = int(P.style);
        if (style == 1) return shadeDots(in.pixel, P, data, base, halo);
        if (style == 2) return shadeAurora(in.pixel, P, data, base);
        return shadeWave(in.pixel, P, data, base, halo);
    }
    """
}
