import CoreImage
import Foundation
import Metal
import MetalFX

/// Spatial MetalFX consumes only the current frame, so it adds no temporal frame queue.
final class MetalUpscaler {
    private let device: MTLDevice
    private var dimensions: [Int] = []
    private var retryAfterByDimensions: [[Int]: TimeInterval] = [:]
    private var scaler: MTLFXSpatialScaler?
    private var input: MTLTexture?
    private var output: MTLTexture?

    init?(device: MTLDevice) {
        guard MTLFXSpatialScalerDescriptor.supportsDevice(device) else { return nil }
        self.device = device
    }

    func upscale(_ image: CIImage, width: Int, height: Int, context: CIContext, command: MTLCommandBuffer, colorSpace: CGColorSpace) -> CIImage? {
        let sourceWidth = Int(image.extent.width.rounded())
        let sourceHeight = Int(image.extent.height.rounded())
        guard width > sourceWidth, height > sourceHeight, width <= sourceWidth * 3, height <= sourceHeight * 3 else { return nil }
        let key = [sourceWidth, sourceHeight, width, height]
        if key != dimensions {
            let now = ProcessInfo.processInfo.systemUptime
            retryAfterByDimensions = retryAfterByDimensions.filter { $0.value > now }
            if let retryAfter = retryAfterByDimensions[key], now < retryAfter { return nil }

            let descriptor = MTLFXSpatialScalerDescriptor()
            descriptor.inputWidth = sourceWidth; descriptor.inputHeight = sourceHeight
            descriptor.outputWidth = width; descriptor.outputHeight = height
            descriptor.colorTextureFormat = .bgra8Unorm
            descriptor.outputTextureFormat = .bgra8Unorm
            descriptor.colorProcessingMode = .perceptual
            guard let newScaler = descriptor.makeSpatialScaler(device: device) else {
                retryAfterByDimensions[key] = now + 1
                return nil
            }
            let inputDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: sourceWidth, height: sourceHeight, mipmapped: false)
            inputDescriptor.storageMode = .private
            inputDescriptor.usage = newScaler.colorTextureUsage.union([.shaderRead, .shaderWrite, .renderTarget])
            let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            outputDescriptor.storageMode = .private
            outputDescriptor.usage = newScaler.outputTextureUsage.union([.shaderRead, .shaderWrite, .renderTarget])
            guard let newInput = device.makeTexture(descriptor: inputDescriptor),
                  let newOutput = device.makeTexture(descriptor: outputDescriptor) else {
                retryAfterByDimensions[key] = now + 1
                return nil
            }
            scaler = newScaler
            input = newInput
            output = newOutput
            dimensions = key
            retryAfterByDimensions.removeValue(forKey: key)
        }
        guard let scaler, let input, let output else { return nil }
        context.render(image, to: input, commandBuffer: command, bounds: CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight), colorSpace: colorSpace)
        scaler.colorTexture = input; scaler.outputTexture = output
        scaler.inputContentWidth = sourceWidth; scaler.inputContentHeight = sourceHeight
        scaler.encode(commandBuffer: command)
        return CIImage(mtlTexture: output, options: [.colorSpace: colorSpace])
    }
}
