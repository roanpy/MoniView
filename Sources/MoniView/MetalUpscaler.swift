import CoreImage
import Foundation
import Metal
import MetalFX

/// Main-thread-confined, small LRU used by MetalUpscaler. The factory runs only on a miss and failed creation
/// does not alter recency or the creation count.
final class MetalUpscalerResourceLRU<Key: Hashable, Value> {
    private let capacity: Int
    private var values: [Key: Value] = [:]
    private var leastToMostRecent: [Key] = []
    private(set) var creationCount = 0

    var count: Int { values.count }

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    func value(for key: Key, create: () -> Value?) -> Value? {
        if let value = values[key] {
            markRecentlyUsed(key)
            return value
        }
        guard let value = create() else { return nil }
        if values.count == capacity, let leastRecent = leastToMostRecent.first {
            values.removeValue(forKey: leastRecent)
            leastToMostRecent.removeFirst()
        }
        values[key] = value
        leastToMostRecent.append(key)
        creationCount += 1
        return value
    }

    func contains(_ key: Key) -> Bool {
        values[key] != nil
    }

    private func markRecentlyUsed(_ key: Key) {
        if let index = leastToMostRecent.firstIndex(of: key) {
            leastToMostRecent.remove(at: index)
        }
        leastToMostRecent.append(key)
    }
}

final class MetalUpscaler {
    private struct Key: Hashable {
        let sourceWidth: Int
        let sourceHeight: Int
        let outputWidth: Int
        let outputHeight: Int
    }

    /// A cache entry owns every resource configured for one size pair. Submitted command
    /// buffers retain the complete entry until completion, including after LRU eviction.
    private final class Entry {
        let scaler: MTLFXSpatialScaler
        let input: MTLTexture
        let output: MTLTexture

        init(scaler: MTLFXSpatialScaler, input: MTLTexture, output: MTLTexture) {
            self.scaler = scaler
            self.input = input
            self.output = output
        }
    }

    private let device: MTLDevice
    private let resources = MetalUpscalerResourceLRU<Key, Entry>(capacity: 2)
    private var retryAfterByKey: [Key: TimeInterval] = [:]
    private var nextRetryPrune = 0.0

    init?(device: MTLDevice) {
        guard MTLFXSpatialScalerDescriptor.supportsDevice(device) else { return nil }
        self.device = device
    }

    func upscale(_ image: CIImage, width: Int, height: Int, context: CIContext,
                 command: MTLCommandBuffer, colorSpace: CGColorSpace) -> CIImage? {
        dispatchPrecondition(condition: .onQueue(.main))
        let sourceWidth = Int(image.extent.width.rounded())
        let sourceHeight = Int(image.extent.height.rounded())
        guard width > sourceWidth, height > sourceHeight,
              width <= sourceWidth * 3, height <= sourceHeight * 3 else { return nil }

        let key = Key(sourceWidth: sourceWidth, sourceHeight: sourceHeight,
                      outputWidth: width, outputHeight: height)
        let now = ProcessInfo.processInfo.systemUptime
        // Failed size keys are checked exactly on access below. Prune other expired
        // failures periodically instead of rebuilding this dictionary on every frame.
        if now >= nextRetryPrune {
            retryAfterByKey = retryAfterByKey.filter { $0.value > now }
            nextRetryPrune = now + 1
        }
        if let retryAfter = retryAfterByKey[key], now < retryAfter { return nil }

        guard let entry = resources.value(for: key, create: { [device] in
            Self.makeEntry(key: key, device: device)
        }) else {
            retryAfterByKey[key] = now + 1
            return nil
        }
        retryAfterByKey.removeValue(forKey: key)

        // The command can outlive this call and its cache entry can be evicted meanwhile.
        command.addCompletedHandler { [entry] _ in
            withExtendedLifetime(entry) {}
        }

        context.render(image, to: entry.input, commandBuffer: command,
                       bounds: CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight),
                       colorSpace: colorSpace)
        entry.scaler.colorTexture = entry.input
        entry.scaler.outputTexture = entry.output
        entry.scaler.inputContentWidth = sourceWidth
        entry.scaler.inputContentHeight = sourceHeight
        entry.scaler.encode(commandBuffer: command)

        return CIImage(mtlTexture: entry.output, options: [.colorSpace: colorSpace])
    }

    private static func makeEntry(key: Key, device: MTLDevice) -> Entry? {
        let descriptor = MTLFXSpatialScalerDescriptor()
        descriptor.inputWidth = key.sourceWidth
        descriptor.inputHeight = key.sourceHeight
        descriptor.outputWidth = key.outputWidth
        descriptor.outputHeight = key.outputHeight
        descriptor.colorTextureFormat = .bgra8Unorm
        descriptor.outputTextureFormat = .bgra8Unorm
        descriptor.colorProcessingMode = .perceptual
        guard let scaler = descriptor.makeSpatialScaler(device: device) else { return nil }

        let inputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: key.sourceWidth, height: key.sourceHeight, mipmapped: false)
        inputDescriptor.storageMode = .private
        inputDescriptor.usage = scaler.colorTextureUsage.union([.shaderRead, .shaderWrite, .renderTarget])

        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: key.outputWidth, height: key.outputHeight, mipmapped: false)
        outputDescriptor.storageMode = .private
        outputDescriptor.usage = scaler.outputTextureUsage.union([.shaderRead, .shaderWrite, .renderTarget])

        guard let input = device.makeTexture(descriptor: inputDescriptor),
              let output = device.makeTexture(descriptor: outputDescriptor) else { return nil }
        return Entry(scaler: scaler, input: input, output: output)
    }

    #if MONIVIEW_METAL_UPSCALER_TESTING
    var testResourceCreationCount: Int { resources.creationCount }
    var testResourceCount: Int { resources.count }

    func testContainsResource(sourceWidth: Int, sourceHeight: Int,
                              outputWidth: Int, outputHeight: Int) -> Bool {
        resources.contains(Key(sourceWidth: sourceWidth, sourceHeight: sourceHeight,
                               outputWidth: outputWidth, outputHeight: outputHeight))
    }
    #endif
}
