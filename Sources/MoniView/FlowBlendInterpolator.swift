// Frame analysis stays at quarter resolution, followed by one full-resolution warp pass.
// The 16-pixel sparse grid favors coherent, textured motion and keeps search work bounded.
// Three pyramid levels search to about 64 pixels; a search hitting that limit is marked low confidence.
// Confidence uses match residual, local texture, match uniqueness, neighborhood flow, and soft reverse agreement.
// Flat regions, repeated patterns, occlusions, and scene cuts remain ambiguous.
// Ambiguous pixels fall back to cross-dissolve, which can still show double edges.
// Motion boundaries can soften because a 16-pixel grid cannot represent every object contour.
// Quarter-resolution analysis refines motion to about one working pixel.
// Every input is color managed and resampled by Core Image directly into private working textures.
// This matches the native preview's YUV matrix, transfer function, chroma sampling and CI transforms.
// Working textures use sRGB and bottom-up rows, including the texture returned as a CIImage.
// prepare sets the actual working dimensions; source pixel buffers can be larger.
// Output is an MTL-backed CIImage, and every GPU pass is encoded on the caller's command buffer.
// Initialize one FlowBlendInterpolator per MTLDevice and reuse it across frame pairs.
// Call interpolate with the renderer's existing command buffer and blendFactor in [0, 1].
// Keep the returned CIImage and input resources alive on that command buffer through completion.

import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import Metal

/// Sparse, confidence-gated optical-flow interpolation encoded into the caller's command buffer.
/// The instance is reusable across sizes and supports multiple commands in flight.
final class FlowBlendInterpolator {
    private struct Size: Hashable {
        let width: Int
        let height: Int
    }

    private final class FrameResources {
        let size: Size
        let frame0: MTLTexture
        let frame1: MTLTexture
        let output: MTLTexture
        let previousLuma0: MTLTexture
        let previousLuma1: MTLTexture
        let previousLuma2: MTLTexture
        let currentLuma0: MTLTexture
        let currentLuma1: MTLTexture
        let currentLuma2: MTLTexture
        let forwardFlow: MTLTexture
        let backwardFlow: MTLTexture
        var inUse = true

        init?(device: MTLDevice, size: Size) {
            self.size = size
            let w4 = max(1, (size.width + 3) / 4)
            let h4 = max(1, (size.height + 3) / 4)
            let w8 = max(1, (w4 + 1) / 2)
            let h8 = max(1, (h4 + 1) / 2)
            let w16 = max(1, (w8 + 1) / 2)
            let h16 = max(1, (h8 + 1) / 2)

            func make(_ format: MTLPixelFormat, _ width: Int, _ height: Int, _ label: String) -> MTLTexture? {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format,
                                                                           width: width,
                                                                           height: height,
                                                                           mipmapped: false)
                descriptor.storageMode = .private
                descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
                let texture = device.makeTexture(descriptor: descriptor)
                texture?.label = "FlowBlend \(label) \(size.width)x\(size.height)"
                return texture
            }

            guard let frame0 = make(.bgra8Unorm, size.width, size.height, "frame0"),
                  let frame1 = make(.bgra8Unorm, size.width, size.height, "frame1"),
                  let output = make(.bgra8Unorm, size.width, size.height, "output"),
                  let previousLuma0 = make(.r16Float, w4, h4, "previous-luma-quarter"),
                  let previousLuma1 = make(.r16Float, w8, h8, "previous-luma-eighth"),
                  let previousLuma2 = make(.r16Float, w16, h16, "previous-luma-sixteenth"),
                  let currentLuma0 = make(.r16Float, w4, h4, "current-luma-quarter"),
                  let currentLuma1 = make(.r16Float, w8, h8, "current-luma-eighth"),
                  let currentLuma2 = make(.r16Float, w16, h16, "current-luma-sixteenth"),
                  let forwardFlow = make(.rgba16Float, w16, h16, "forward-flow"),
                  let backwardFlow = make(.rgba16Float, w16, h16, "backward-flow") else { return nil }
            self.frame0 = frame0
            self.frame1 = frame1
            self.output = output
            self.previousLuma0 = previousLuma0
            self.previousLuma1 = previousLuma1
            self.previousLuma2 = previousLuma2
            self.currentLuma0 = currentLuma0
            self.currentLuma1 = currentLuma1
            self.currentLuma2 = currentLuma2
            self.forwardFlow = forwardFlow
            self.backwardFlow = backwardFlow
        }
    }

    private let device: MTLDevice
    private let workingColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let buildLumaPipeline: MTLComputePipelineState
    private let downsamplePipeline: MTLComputePipelineState
    private let flowPipeline: MTLComputePipelineState
    private let warpPipeline: MTLComputePipelineState
    private let poolLock = NSLock()
    private var requestedSize: Size?
    private var resourcePool: [Size: [FrameResources]] = [:]

    private static let metalSource = #"""
        #include <metal_stdlib>
        using namespace metal;

        struct SearchResult {
            int2 displacement;
            float best;
            float second;
        };

        inline int2 bounded(int2 point, uint width, uint height) {
            return clamp(point, int2(0), int2(int(width) - 1, int(height) - 1));
        }

        inline float patchCost(texture2d<float, access::read> source,
                               texture2d<float, access::read> target,
                               int2 center,
                               int2 displacement) {
            float total = 0.0f;
            for (int y = -2; y <= 2; y += 2) {
                for (int x = -2; x <= 2; x += 2) {
                    int2 offset = int2(x, y);
                    float a = source.read(uint2(bounded(center + offset, source.get_width(), source.get_height()))).r;
                    float b = target.read(uint2(bounded(center + offset + displacement,
                                                          target.get_width(), target.get_height()))).r;
                    total += abs(a - b);
                }
            }
            return total / 9.0f;
        }

        inline float patchVariance(texture2d<float, access::read> source, int2 center) {
            float sum = 0.0f;
            float squareSum = 0.0f;
            for (int y = -2; y <= 2; y += 2) {
                for (int x = -2; x <= 2; x += 2) {
                    float value = source.read(uint2(bounded(center + int2(x, y),
                                                            source.get_width(), source.get_height()))).r;
                    sum += value;
                    squareSum += value * value;
                }
            }
            float mean = sum / 9.0f;
            return max(0.0f, squareSum / 9.0f - mean * mean);
        }

        inline SearchResult searchLevel(texture2d<float, access::read> source,
                                        texture2d<float, access::read> target,
                                        int2 center,
                                        int2 seed,
                                        int radius) {
            SearchResult result;
            result.displacement = seed;
            result.best = 1.0e10f;
            result.second = 1.0e10f;
            for (int y = -radius; y <= radius; ++y) {
                for (int x = -radius; x <= radius; ++x) {
                    int2 candidate = seed + int2(x, y);
                    float cost = patchCost(source, target, center, candidate);
                    // Equal-cost matches must favor the smallest displacement.
                    // Otherwise a static repeated pattern selects the first (negative)
                    // search offset and moves only on generated frames.
                    int candidateLength = candidate.x * candidate.x + candidate.y * candidate.y;
                    int bestLength = result.displacement.x * result.displacement.x
                                   + result.displacement.y * result.displacement.y;
                    if (cost < result.best || (cost == result.best && candidateLength < bestLength)) {
                        result.second = result.best;
                        result.best = cost;
                        result.displacement = candidate;
                    } else if (cost < result.second) {
                        result.second = cost;
                    }
                }
            }
            return result;
        }

        kernel void buildLuma4(texture2d<float, access::read> source [[texture(0)]],
                               texture2d<float, access::write> destination [[texture(1)]],
                               uint2 gid [[thread_position_in_grid]]) {
            if (gid.x >= destination.get_width() || gid.y >= destination.get_height()) return;
            float sum = 0.0f;
            for (uint y = 0; y < 4; ++y) {
                for (uint x = 0; x < 4; ++x) {
                    uint2 point = min(gid * 4 + uint2(x, y),
                                      uint2(source.get_width() - 1, source.get_height() - 1));
                    float3 rgb = source.read(point).rgb;
                    sum += dot(rgb, float3(0.2126f, 0.7152f, 0.0722f));
                }
            }
            destination.write(float4(sum / 16.0f, 0.0f, 0.0f, 1.0f), gid);
        }

        kernel void downsample2(texture2d<float, access::read> source [[texture(0)]],
                                texture2d<float, access::write> destination [[texture(1)]],
                                uint2 gid [[thread_position_in_grid]]) {
            if (gid.x >= destination.get_width() || gid.y >= destination.get_height()) return;
            uint2 maximum = uint2(source.get_width() - 1, source.get_height() - 1);
            uint2 point = gid * 2;
            float sum = source.read(min(point, maximum)).r
                      + source.read(min(point + uint2(1, 0), maximum)).r
                      + source.read(min(point + uint2(0, 1), maximum)).r
                      + source.read(min(point + uint2(1, 1), maximum)).r;
            destination.write(float4(sum * 0.25f, 0.0f, 0.0f, 1.0f), gid);
        }

        kernel void matchFlow(texture2d<float, access::read> source0 [[texture(0)]],
                              texture2d<float, access::read> target0 [[texture(1)]],
                              texture2d<float, access::read> source1 [[texture(2)]],
                              texture2d<float, access::read> target1 [[texture(3)]],
                              texture2d<float, access::read> source2 [[texture(4)]],
                              texture2d<float, access::read> target2 [[texture(5)]],
                              texture2d<float, access::write> flow [[texture(6)]],
                              uint2 gid [[thread_position_in_grid]]) {
            if (gid.x >= flow.get_width() || gid.y >= flow.get_height()) return;
            int2 cell = int2(gid);
            SearchResult coarse = searchLevel(source2, target2, cell, int2(0), 4);
            SearchResult middle = searchLevel(source1, target1, cell * 2 + 1,
                                               coarse.displacement * 2, 2);
            int2 fineCenter = cell * 4 + 2;
            SearchResult fine = searchLevel(source0, target0, fineCenter,
                                             middle.displacement * 2, 2);

            float left = patchCost(source0, target0, fineCenter,
                                   fine.displacement + int2(-1, 0));
            float right = patchCost(source0, target0, fineCenter,
                                    fine.displacement + int2(1, 0));
            float up = patchCost(source0, target0, fineCenter,
                                 fine.displacement + int2(0, -1));
            float down = patchCost(source0, target0, fineCenter,
                                   fine.displacement + int2(0, 1));
            float denominatorX = left - 2.0f * fine.best + right;
            float denominatorY = up - 2.0f * fine.best + down;
            // An exact integer match needs no parabolic correction. An asymmetric
            // neighborhood can otherwise invent subpixel movement on static frames.
            float subX = fine.best > 1.0e-6f && abs(denominatorX) > 1.0e-5f
                ? clamp(0.5f * (left - right) / denominatorX, -0.5f, 0.5f) : 0.0f;
            float subY = fine.best > 1.0e-6f && abs(denominatorY) > 1.0e-5f
                ? clamp(0.5f * (up - down) / denominatorY, -0.5f, 0.5f) : 0.0f;
            float variance = patchVariance(source0, fineCenter);
            float textureConfidence = smoothstep(0.00005f, 0.008f, variance);
            float uniqueness = smoothstep(0.0002f, 0.012f, max(0.0f, fine.second - fine.best));
            float residualConfidence = 1.0f - smoothstep(0.04f, 0.16f, fine.best);
            float rangeConfidence = (abs(coarse.displacement.x) < 4 && abs(coarse.displacement.y) < 4) ? 1.0f : 0.0f;
            float confidence = residualConfidence * max(textureConfidence, uniqueness) * rangeConfidence;
            float2 fullResolution = (float2(fine.displacement) + float2(subX, subY)) * 4.0f;
            flow.write(float4(fullResolution, confidence, fine.best), gid);
        }

        kernel void warpBlend(texture2d<float, access::sample> previous [[texture(0)]],
                              texture2d<float, access::sample> current [[texture(1)]],
                              texture2d<float, access::sample> forwardFlow [[texture(2)]],
                              texture2d<float, access::sample> backwardFlow [[texture(3)]],
                              texture2d<float, access::write> output [[texture(4)]],
                              constant float &blend [[buffer(0)]],
                              uint2 gid [[thread_position_in_grid]]) {
            if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
            constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
            float2 dimensions = float2(output.get_width(), output.get_height());
            float2 uv = (float2(gid) + 0.5f) / dimensions;
            float4 a = previous.sample(linearSampler, uv);
            float4 b = current.sample(linearSampler, uv);
            if (blend <= 0.0f) { output.write(a, gid); return; }
            if (blend >= 1.0f) { output.write(b, gid); return; }

            float4 forward = forwardFlow.sample(linearSampler, uv);
            float2 currentUV = uv + forward.xy * ((1.0f - blend) / dimensions);
            float4 backward = backwardFlow.sample(linearSampler, currentUV);
            float consistency = 1.0f - smoothstep(2.0f, 9.0f, length(forward.xy + backward.xy));

            float2 flowStep = 16.0f / dimensions;
            float2 flowRight = forwardFlow.sample(linearSampler, uv + float2(flowStep.x, 0.0f)).xy;
            float2 flowLeft = forwardFlow.sample(linearSampler, uv - float2(flowStep.x, 0.0f)).xy;
            float2 flowDown = forwardFlow.sample(linearSampler, uv + float2(0.0f, flowStep.y)).xy;
            float2 flowUp = forwardFlow.sample(linearSampler, uv - float2(0.0f, flowStep.y)).xy;
            float discontinuity = max(max(length(forward.xy - flowRight), length(forward.xy - flowLeft)),
                                      max(length(forward.xy - flowDown), length(forward.xy - flowUp)));
            float boundaryConfidence = 1.0f - smoothstep(10.0f, 30.0f, discontinuity);
            float confidence = forward.z * (0.75f + 0.25f * min(backward.z, consistency))
                             * (0.50f + 0.50f * boundaryConfidence);

            float2 previousUV = uv - forward.xy * (blend / dimensions);
            float4 warpedPrevious = previous.sample(linearSampler, previousUV);
            float4 warpedCurrent = current.sample(linearSampler, currentUV);
            float4 warped = mix(warpedPrevious, warpedCurrent, blend);
            output.write(mix(mix(a, b, blend), warped, confidence), gid);
        }
        """#

    init?(device: MTLDevice) {
        guard let library = try? device.makeLibrary(source: Self.metalSource, options: nil),
              let lumaFunction = library.makeFunction(name: "buildLuma4"),
              let downsampleFunction = library.makeFunction(name: "downsample2"),
              let flowFunction = library.makeFunction(name: "matchFlow"),
              let warpFunction = library.makeFunction(name: "warpBlend"),
              let buildLumaPipeline = try? device.makeComputePipelineState(function: lumaFunction),
              let downsamplePipeline = try? device.makeComputePipelineState(function: downsampleFunction),
              let flowPipeline = try? device.makeComputePipelineState(function: flowFunction),
              let warpPipeline = try? device.makeComputePipelineState(function: warpFunction) else { return nil }
        self.device = device
        self.buildLumaPipeline = buildLumaPipeline
        self.downsamplePipeline = downsamplePipeline
        self.flowPipeline = flowPipeline
        self.warpPipeline = warpPipeline
    }

    // Pipelines are built synchronously in init, so the engine is ready immediately.
    // prepare/stop match the renderer's engine protocol; resource pools release with ARC.
    var isReady: Bool { true }
    var onStateChange: (() -> Void)?
    func prepare(width: Int, height: Int) {
        poolLock.lock()
        requestedSize = width > 0 && height > 0 && width <= 8192 && height <= 8192
            ? Size(width: width, height: height) : nil
        // Completed resources at old sizes need not accumulate across rungs.
        resourcePool = resourcePool.filter { $0.key == requestedSize || $0.value.contains(where: \.inUse) }
        poolLock.unlock()
    }
    func stop() {
        poolLock.lock()
        requestedSize = nil
        resourcePool.removeAll()
        poolLock.unlock()
    }

    /// Engine-protocol entry point: 2x interpolation always blends at the temporal midpoint.
    func interpolate(previous: CIImage, current: CIImage, previousTime: CMTime, currentTime: CMTime,
                     context: CIContext, command: MTLCommandBuffer,
                     previousBuffer: CVPixelBuffer?, currentBuffer: CVPixelBuffer?,
                     fastInputResampling: Bool) -> CIImage? {
        interpolate(previous: previous, current: current, previousTime: previousTime,
                    currentTime: currentTime, context: context, command: command,
                    previousBuffer: previousBuffer, currentBuffer: currentBuffer,
                    fastInputResampling: fastInputResampling, blendFactor: 0.5)
    }

    /// Encodes one interpolated image on `command`; the caller owns command submission.
    /// `blendFactor` is 0 for previous and 1 for current. Pixel buffers may be 420v or BGRA.
    /// Output uses the prepared size, or the CIImage's size if prepare has not been called.
    func interpolate(previous: CIImage, current: CIImage, previousTime: CMTime, currentTime: CMTime,
                     context: CIContext, command: MTLCommandBuffer,
                     previousBuffer: CVPixelBuffer? = nil, currentBuffer: CVPixelBuffer? = nil,
                     fastInputResampling: Bool = false, blendFactor: Float = 0.5) -> CIImage? {
        guard previousTime.isNumeric, currentTime.isNumeric, currentTime > previousTime,
              blendFactor.isFinite, (0.0...1.0).contains(blendFactor) else { return nil }
        if let previousBuffer, let currentBuffer,
           CVPixelBufferGetWidth(previousBuffer) != CVPixelBufferGetWidth(currentBuffer) ||
           CVPixelBufferGetHeight(previousBuffer) != CVPixelBufferGetHeight(currentBuffer) {
            return nil
        }

        // CIImage is authoritative: a buffer may back a cropped, oriented or color-
        // overridden image. Reading its raw texture would silently discard that work.
        let previousExtent = previous.extent, currentExtent = current.extent
        guard previousExtent.minX.isFinite, previousExtent.minY.isFinite,
              currentExtent.minX.isFinite, currentExtent.minY.isFinite,
              previousExtent.width.isFinite, previousExtent.height.isFinite,
              currentExtent.width.isFinite, currentExtent.height.isFinite,
              previousExtent.width > 0, previousExtent.height > 0,
              currentExtent.width > 0, currentExtent.height > 0,
              abs(previousExtent.width - currentExtent.width) < 0.001,
              abs(previousExtent.height - currentExtent.height) < 0.001 else { return nil }
        poolLock.lock()
        let requested = requestedSize
        poolLock.unlock()
        guard requested != nil || (currentExtent.width <= 8192 && currentExtent.height <= 8192) else { return nil }
        let width = requested?.width ?? Int(currentExtent.width.rounded())
        let height = requested?.height ?? Int(currentExtent.height.rounded())
        guard width > 0, height > 0, width <= 8192, height <= 8192 else { return nil }
        let size = Size(width: width, height: height)
        guard let resources = takeResources(for: size) else { return nil }

        var renderTasks: [CIRenderTask] = []
        defer {
            command.addCompletedHandler { [weak self, resources, renderTasks,
                                           previousBuffer, currentBuffer, previous, current, context] _ in
                withExtendedLifetime((resources, renderTasks, previousBuffer, currentBuffer, previous, current, context)) {}
                self?.recycle(resources)
            }
        }
        guard let previousTask = render(previous, into: resources.frame0, size: size, context: context,
                                        command: command, fast: fastInputResampling) else { return nil }
        renderTasks.append(previousTask)
        guard let currentTask = render(current, into: resources.frame1, size: size, context: context,
                                       command: command, fast: fastInputResampling) else { return nil }
        renderTasks.append(currentTask)
        let previousTexture = resources.frame0
        let currentTexture = resources.frame1
        guard encodeLuma(source: previousTexture, luma0: resources.previousLuma0,
                         luma1: resources.previousLuma1, luma2: resources.previousLuma2,
                         command: command),
              encodeLuma(source: currentTexture, luma0: resources.currentLuma0,
                         luma1: resources.currentLuma1, luma2: resources.currentLuma2,
                         command: command),
              encodeFlow(source0: resources.previousLuma0, target0: resources.currentLuma0,
                         source1: resources.previousLuma1, target1: resources.currentLuma1,
                         source2: resources.previousLuma2, target2: resources.currentLuma2,
                         destination: resources.forwardFlow, command: command),
              encodeFlow(source0: resources.currentLuma0, target0: resources.previousLuma0,
                         source1: resources.currentLuma1, target1: resources.previousLuma1,
                         source2: resources.currentLuma2, target2: resources.previousLuma2,
                         destination: resources.backwardFlow, command: command),
              encodeWarp(previous: previousTexture, current: currentTexture, resources: resources,
                         blend: blendFactor, command: command) else { return nil }

        return CIImage(mtlTexture: resources.output, options: [.colorSpace: workingColorSpace])
    }

    private func render(_ image: CIImage, into texture: MTLTexture, size: Size,
                        context: CIContext, command: MTLCommandBuffer, fast: Bool) -> CIRenderTask? {
        let extent = image.extent
        guard extent.width.isFinite, extent.height.isFinite, extent.width > 0, extent.height > 0 else { return nil }
        var normalized = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        let sx = Double(size.width) / extent.width
        let sy = Double(size.height) / extent.height
        if abs(sx - 1.0) > 0.000001 || abs(sy - 1.0) > 0.000001 {
            if !fast, sx < 1.0 || sy < 1.0 {
                normalized = normalized.applyingFilter("CILanczosScaleTransform", parameters: [
                    kCIInputScaleKey: sy,
                    kCIInputAspectRatioKey: sx / sy
                ])
            } else {
                normalized = normalized.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            }
        }
        // CI reads CV/Metal-backed input directly on the GPU. Render straight to
        // working size; this engine allocates no source-size RGB staging texture
        // and performs no CPU readback.
        // Bottom-up rows match CIImage(mtlTexture:), unlike raw CV's top-down rows.
        let destination = CIRenderDestination(mtlTexture: texture, commandBuffer: command)
        destination.colorSpace = workingColorSpace
        destination.isFlipped = false
        return try? context.startTask(toRender: normalized,
                                     from: CGRect(x: 0, y: 0, width: size.width, height: size.height),
                                     to: destination, at: .zero)
    }

    private func encodeLuma(source: MTLTexture, luma0: MTLTexture, luma1: MTLTexture,
                            luma2: MTLTexture, command: MTLCommandBuffer) -> Bool {
        guard let lumaEncoder = command.makeComputeCommandEncoder() else { return false }
        lumaEncoder.setComputePipelineState(buildLumaPipeline)
        lumaEncoder.setTexture(source, index: 0)
        lumaEncoder.setTexture(luma0, index: 1)
        dispatch(lumaEncoder, width: luma0.width, height: luma0.height, pipeline: buildLumaPipeline)
        lumaEncoder.endEncoding()

        guard let firstDownsample = command.makeComputeCommandEncoder() else { return false }
        firstDownsample.setComputePipelineState(downsamplePipeline)
        firstDownsample.setTexture(luma0, index: 0)
        firstDownsample.setTexture(luma1, index: 1)
        dispatch(firstDownsample, width: luma1.width, height: luma1.height, pipeline: downsamplePipeline)
        firstDownsample.endEncoding()

        guard let secondDownsample = command.makeComputeCommandEncoder() else { return false }
        secondDownsample.setComputePipelineState(downsamplePipeline)
        secondDownsample.setTexture(luma1, index: 0)
        secondDownsample.setTexture(luma2, index: 1)
        dispatch(secondDownsample, width: luma2.width, height: luma2.height, pipeline: downsamplePipeline)
        secondDownsample.endEncoding()
        return true
    }

    private func encodeFlow(source0: MTLTexture, target0: MTLTexture,
                            source1: MTLTexture, target1: MTLTexture,
                            source2: MTLTexture, target2: MTLTexture,
                            destination: MTLTexture, command: MTLCommandBuffer) -> Bool {
        guard let encoder = command.makeComputeCommandEncoder() else { return false }
        encoder.setComputePipelineState(flowPipeline)
        encoder.setTexture(source0, index: 0)
        encoder.setTexture(target0, index: 1)
        encoder.setTexture(source1, index: 2)
        encoder.setTexture(target1, index: 3)
        encoder.setTexture(source2, index: 4)
        encoder.setTexture(target2, index: 5)
        encoder.setTexture(destination, index: 6)
        dispatch(encoder, width: destination.width, height: destination.height, pipeline: flowPipeline)
        encoder.endEncoding()
        return true
    }

    private func encodeWarp(previous: MTLTexture, current: MTLTexture,
                            resources: FrameResources, blend: Float,
                            command: MTLCommandBuffer) -> Bool {
        guard let encoder = command.makeComputeCommandEncoder() else { return false }
        encoder.setComputePipelineState(warpPipeline)
        encoder.setTexture(previous, index: 0)
        encoder.setTexture(current, index: 1)
        encoder.setTexture(resources.forwardFlow, index: 2)
        encoder.setTexture(resources.backwardFlow, index: 3)
        encoder.setTexture(resources.output, index: 4)
        var blendCopy = blend
        encoder.setBytes(&blendCopy, length: MemoryLayout<Float>.size, index: 0)
        dispatch(encoder, width: resources.size.width, height: resources.size.height, pipeline: warpPipeline)
        encoder.endEncoding()
        return true
    }

    private func dispatch(_ encoder: MTLComputeCommandEncoder, width: Int, height: Int,
                          pipeline: MTLComputePipelineState) {
        let threadWidth = max(1, pipeline.threadExecutionWidth)
        let threadHeight = max(1, min(8, pipeline.maxTotalThreadsPerThreadgroup / threadWidth))
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: threadWidth, height: threadHeight, depth: 1))
    }

    private func takeResources(for size: Size) -> FrameResources? {
        poolLock.lock()
        if let resources = resourcePool[size]?.first(where: { !$0.inUse }) {
            resources.inUse = true
            poolLock.unlock()
            return resources
        }
        poolLock.unlock()
        guard let resources = FrameResources(device: device, size: size) else { return nil }
        poolLock.lock()
        resourcePool[size, default: []].append(resources)
        poolLock.unlock()
        return resources
    }

    private func recycle(_ resources: FrameResources) {
        poolLock.lock()
        resources.inUse = false
        poolLock.unlock()
    }
}
