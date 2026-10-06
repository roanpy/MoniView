import CoreGraphics
import CoreImage
import Foundation
import Metal
import MetalFX

private func fail(_ message: String) -> Never {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
}

private func skip(_ message: String) -> Never {
    print("SKIP: \(message)")
    exit(2)
}

private final class CompletionState {
    private let lock = NSLock()
    private var storedError: String?
    private var storedPixels: [UInt8]?

    func recordError(_ message: String) {
        lock.lock()
        storedError = storedError ?? message
        lock.unlock()
    }

    func recordPixels(_ pixels: [UInt8]) {
        lock.lock()
        storedPixels = pixels
        lock.unlock()
    }

    func result() -> (String?, [UInt8]?) {
        lock.lock()
        defer { lock.unlock() }
        return (storedError, storedPixels)
    }
}

@main
private struct MetalUpscalerLRUTests {
    private struct SizeKey: Hashable {
        let sourceWidth: Int
        let sourceHeight: Int
        let outputWidth: Int
        let outputHeight: Int
    }

    static func main() {
        switch CommandLine.arguments.dropFirst().first ?? "--gpu" {
        case "--cache-only":
            runCreationCountTest()
        case "--gpu":
            runNativeMetalTest()
        default:
            fail("expected --cache-only or --gpu")
        }
    }

    private static func runCreationCountTest() {
        let lru = MetalUpscalerResourceLRU<String, Int>(capacity: 2)
        var factoryCount = 0

        for index in 0..<20 {
            let key = index.isMultiple(of: 2) ? "A" : "B"
            guard lru.value(for: key, create: {
                factoryCount += 1
                return factoryCount
            }) != nil else {
                fail("cache factory unexpectedly returned nil for key \(key)")
            }
        }

        guard factoryCount == 2, lru.creationCount == 2, lru.count == 2 else {
            fail("alternating 2-key access created \(factoryCount) resources; expected 2")
        }
        _ = lru.value(for: "C", create: {
            factoryCount += 1
            return factoryCount
        })
        guard factoryCount == 3, lru.creationCount == 3,
              !lru.contains("A"), lru.contains("B"), lru.contains("C") else {
            fail("third key did not evict the least-recently-used key A")
        }
        print("PASS compile-only creationCount test: 20 alternating accesses create 2; key C evicts A")
    }

    private static func runNativeMetalTest() {
        guard let device = MTLCreateSystemDefaultDevice(),
              MTLFXSpatialScalerDescriptor.supportsDevice(device),
              let upscaler = MetalUpscaler(device: device),
              let queue = device.makeCommandQueue() else {
            skip("no Metal device with MetalFX spatial scaler support")
        }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CIContext(mtlDevice: device, options: [
            .workingColorSpace: colorSpace,
            .cacheIntermediates: false
        ])
        let a = SizeKey(sourceWidth: 320, sourceHeight: 180, outputWidth: 640, outputHeight: 360)
        let b = SizeKey(sourceWidth: 480, sourceHeight: 270, outputWidth: 960, outputHeight: 540)
        let c = SizeKey(sourceWidth: 640, sourceHeight: 360, outputWidth: 1280, outputHeight: 720)

        // Exercise real MetalFX entries while serializing completion so the same key's
        // scratch textures are not concurrently written during this cache-count check.
        for index in 0..<20 {
            let key = index.isMultiple(of: 2) ? a : b
            guard let command = queue.makeCommandBuffer() else { fail("could not create Metal command buffer") }
            let image = inputImage(for: key, color: index.isMultiple(of: 2) ? .red : .green)
            guard let output = upscaler.upscale(image, width: key.outputWidth, height: key.outputHeight,
                                                context: context, command: command, colorSpace: colorSpace) else {
                fail("MetalFX resource creation failed for alternating key \(index.isMultiple(of: 2) ? "A" : "B")")
            }
            withExtendedLifetime(output) {}
            command.commit()
            command.waitUntilCompleted()
            guard command.status == .completed else {
                fail("Metal command failed during the 20-key access sequence: \(String(describing: command.error))")
            }
        }
        guard upscaler.testResourceCreationCount == 2, upscaler.testResourceCount == 2,
              upscaler.testContainsResource(sourceWidth: a.sourceWidth, sourceHeight: a.sourceHeight,
                                            outputWidth: a.outputWidth, outputHeight: a.outputHeight),
              upscaler.testContainsResource(sourceWidth: b.sourceWidth, sourceHeight: b.sourceHeight,
                                            outputWidth: b.outputWidth, outputHeight: b.outputHeight) else {
            fail("MetalUpscaler did not reuse exactly two entries across 20 alternating calls")
        }
        print("PASS native MetalFX: 20 alternating calls created exactly two resources")

        guard let event = device.makeSharedEvent(),
              let first = queue.makeCommandBuffer(),
              let second = queue.makeCommandBuffer(),
              let third = queue.makeCommandBuffer(),
              let readback = makeReadbackTexture(device: device, width: a.outputWidth, height: a.outputHeight) else {
            fail("could not allocate resources for pending-eviction readback")
        }
        event.signaledValue = 0
        first.encodeWaitForEvent(event, value: 1)

        let completionState = CompletionState()
        let completed = DispatchGroup()

        let firstImage = inputImage(for: a, color: CIColor(red: 0.92, green: 0.08, blue: 0.04))
        guard let firstOutput = upscaler.upscale(firstImage, width: a.outputWidth, height: a.outputHeight,
                                                 context: context, command: first, colorSpace: colorSpace) else {
            fail("could not encode pending key A")
        }
        context.render(firstOutput, to: readback, commandBuffer: first,
                       bounds: CGRect(x: 0, y: 0, width: a.outputWidth, height: a.outputHeight),
                       colorSpace: colorSpace)
        completed.enter()
        first.addCompletedHandler { command in
            if command.status == .completed {
                completionState.recordPixels(readPixels(readback, width: a.outputWidth, height: a.outputHeight))
            } else {
                completionState.recordError("pending key A failed: \(String(describing: command.error))")
            }
            completed.leave()
        }
        first.commit()

        // Touch B after A so A is least-recently-used, then key C evicts A while its
        // first command is blocked on the shared event and has not completed.
        guard let secondOutput = upscaler.upscale(inputImage(for: b, color: .green),
                                                   width: b.outputWidth, height: b.outputHeight,
                                                   context: context, command: second, colorSpace: colorSpace),
              let thirdOutput = upscaler.upscale(inputImage(for: c, color: .blue),
                                                  width: c.outputWidth, height: c.outputHeight,
                                                  context: context, command: third, colorSpace: colorSpace) else {
            fail("could not encode keys B and C during pending eviction")
        }
        withExtendedLifetime((secondOutput, thirdOutput)) {}
        for command in [second, third] {
            completed.enter()
            command.addCompletedHandler { buffer in
                if buffer.status != .completed {
                    completionState.recordError("queued Metal command failed: \(String(describing: buffer.error))")
                }
                completed.leave()
            }
            command.commit()
        }

        guard first.status != .completed,
              upscaler.testResourceCreationCount == 3, upscaler.testResourceCount == 2,
              !upscaler.testContainsResource(sourceWidth: a.sourceWidth, sourceHeight: a.sourceHeight,
                                             outputWidth: a.outputWidth, outputHeight: a.outputHeight),
              upscaler.testContainsResource(sourceWidth: b.sourceWidth, sourceHeight: b.sourceHeight,
                                           outputWidth: b.outputWidth, outputHeight: b.outputHeight),
              upscaler.testContainsResource(sourceWidth: c.sourceWidth, sourceHeight: c.sourceHeight,
                                           outputWidth: c.outputWidth, outputHeight: c.outputHeight) else {
            fail("key C did not evict pending key A while retaining exactly B and C")
        }

        event.signaledValue = 1
        guard completed.wait(timeout: .now() + 60) == .success else {
            fail("Metal commands did not complete after releasing the shared event")
        }
        let (error, pixels) = completionState.result()
        if let error { fail(error) }
        guard let pixels else { fail("pending key A produced no readback") }
        let center = ((a.outputHeight / 2) * a.outputWidth + a.outputWidth / 2) * 4
        let red = Int(pixels[center]), green = Int(pixels[center + 1]), blue = Int(pixels[center + 2])
        guard red > 120, red > green + 70, red > blue + 70 else {
            fail("evicted pending key A read back unexpected RGB (\(red), \(green), \(blue))")
        }
        print("PASS pending evicted resource remained alive; key A readback RGB (\(red), \(green), \(blue))")
    }

    private static func inputImage(for key: SizeKey, color: CIColor) -> CIImage {
        CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: key.sourceWidth, height: key.sourceHeight))
    }

    private static func makeReadbackTexture(device: MTLDevice, width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
        return device.makeTexture(descriptor: descriptor)
    }

    private static func readPixels(_ texture: MTLTexture, width: Int, height: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            texture.getBytes(bytes.baseAddress!, bytesPerRow: width * 4,
                             from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return pixels
    }
}
