import Foundation
import CoreImage
import Metal

// Native GPU smoke test of the production path. Synthetic colors cannot prove
// perceptual improvement on games, or compatibility with other Macs/capture cards.
guard AIUpscalerSupport.isSupported, let gpu = MTLCreateSystemDefaultDevice(),
      let queue = gpu.makeCommandQueue(),
      let factor = AIUpscaler.scaleFactor(for: 1280, sourceHeight: 720, requested: 1.5) else {
    print("SKIP: runtime does not support 720p AI scaling")
    exit(2)
}
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CIContext(mtlDevice: gpu, options: [.workingColorSpace: space, .cacheIntermediates: false])
let scaler = AIUpscaler(device: gpu)
let width = Int(1280 * factor), height = Int(720 * factor)
let colors: [(Float, Float, Float)] = [(1,0,0), (0,1,0), (0,0,1), (0.5,0.5,0.5)]
var image = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 1280, height: 720))
for (i, color) in colors.enumerated() {
    let rect = CGRect(x: (i % 2) * 640, y: (i / 2) * 360, width: 640, height: 360)
    image = CIImage(color: CIColor(red: CGFloat(color.0), green: CGFloat(color.1), blue: CGFloat(color.2)))
        .cropped(to: rect).composited(over: image)
}
// Also verify a nonzero input origin is normalized without changing orientation.
image = image.transformed(by: CGAffineTransform(translationX: 12, y: 24))
var pass = 0
let deadline = ProcessInfo.processInfo.systemUptime + 30
func renderWhenReady() {
    guard ProcessInfo.processInfo.systemUptime < deadline else { fatalError("AI warmup timed out") }
    scaler.prepare(sourceWidth: 1280, sourceHeight: 720, factor: factor, colorSpace: space)
    guard scaler.isReady else {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: renderWhenReady)
        return
    }
    let command = queue.makeCommandBuffer()!
    guard let scaled = scaler.upscale(image, context: ctx, command: command, colorSpace: space) else { fatalError("AI encode failed") }
    precondition(Int(scaled.extent.width) == width && Int(scaled.extent.height) == height)
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
    descriptor.storageMode = .shared
    descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
    let output = gpu.makeTexture(descriptor: descriptor)!
    ctx.render(scaled, to: output, commandBuffer: command, bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: space)
    command.addCompletedHandler { completed in
        precondition(completed.status == .completed, "GPU error: \(String(describing: completed.error))")
        var samples: [[UInt8]] = []
        for i in 0..<4 {
            var rgba = [UInt8](repeating: 0, count: 4)
            output.getBytes(&rgba, bytesPerRow: 4, from: MTLRegionMake2D(width * (i % 2 == 0 ? 1 : 3) / 4, height * (i < 2 ? 1 : 3) / 4, 1, 1), mipmapLevel: 0)
            samples.append(rgba)
        }
        for (index, sample) in samples.enumerated() {
            for channel in 0..<3 {
                let expected = Double(channel == 0 ? colors[index].0 : channel == 1 ? colors[index].1 : colors[index].2) * 255
                precondition(abs(Double(sample[channel]) - expected) <= 8, "Color/orientation mismatch: \(samples)")
            }
            precondition(sample[3] == 255)
        }
        DispatchQueue.main.async {
            pass += 1
            print("PASS AI \(width)x\(height), color/orientation, cycle \(pass): \(samples)")
            if pass == 3 { scaler.stop(); exit(0) }
            renderWhenReady()
        }
    }
    command.commit()
    // Retiring while the GPU is in flight must not free its resources early.
    scaler.stop()
}
DispatchQueue.main.async {
    scaler.prepare(sourceWidth: 1280, sourceHeight: 720, factor: factor, colorSpace: space)
    scaler.stop() // Invalidate a pending warmup before publication.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
        precondition(!scaler.isReady, "Obsolete warmup was published")
        renderWhenReady()
    }
}
dispatchMain()
