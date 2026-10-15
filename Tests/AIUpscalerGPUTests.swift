import Foundation
import CoreImage
import Metal
import VideoToolbox

// Exercise the production pipeline on a real GPU. Synthetic colors establish
// output, orientation and resource lifetimes, not perceptual quality on games.
#if compiler(>=6.2) && !MONIVIEW_DISABLE_AI
@available(macOS 26.0, *)
private final class GPURecoveryTests {
    private struct Configuration {
        let width: Int
        let height: Int
        let factor: Float
        var label: String { "\(width)x\(height) @ \(factor)x" }
    }
    private let gpu: MTLDevice
    private let queue: MTLCommandQueue
    private let space = CGColorSpace(name: CGColorSpace.sRGB)!
    private let context: CIContext
    private let scaler: AIUpscaler
    private var configurations: [Configuration] = []
    private var configurationIndex = 0
    private var step = 0
    private var inFlight = false
    private var watchdog: DispatchWorkItem?
    private var budgetFailures: [String] = []
    private let steps = [
        "stop during warmup -> one same-size prepare",
        "stop ready session -> one same-size prepare",
        "stop before GPU commit -> same-size recovery",
        "stop after GPU commit -> same-size recovery",
        "reuse recovered session"
    ]
    private let colors: [(Float, Float, Float)] = [(1, 0, 0), (0, 1, 0), (0, 0, 1), (0.5, 0.5, 0.5)]

    init(gpu: MTLDevice, queue: MTLCommandQueue) {
        self.gpu = gpu
        self.queue = queue
        context = CIContext(mtlDevice: gpu, options: [.workingColorSpace: space, .cacheIntermediates: false])
        scaler = AIUpscaler(device: gpu)
    }

    private func fail(_ message: String) -> Never {
        print("FAIL: \(message)")
        exit(1)
    }

    func run() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !scaler.isReady, !scaler.isPreparing, !scaler.preparationFailed else { fail("Incorrect initial preparation state") }
        print("GPU: \(gpu.name); OS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        let minimum = VTLowLatencySuperResolutionScalerConfiguration.minimumDimensions.map { "\($0.width)x\($0.height)" } ?? "none"
        let maximum = VTLowLatencySuperResolutionScalerConfiguration.maximumDimensions.map { "\($0.width)x\($0.height)" } ?? "none"
        print("SDK dimensions: min=\(minimum), max=\(maximum)")
        enumerateFactors(width: 1920, height: 1080)
        enumerateFactors(width: 1280, height: 720)
        for (width, height, requested) in [(0, 720, 2.0), (1280, 0, 2.0), (-1280, 720, 2.0),
                                           (1279, 720, 2.0), (1280, 719, 2.0), (1280, 720, Double.nan),
                                           (1280, 720, Double.infinity), (1280, 720, -1.0)] {
            if AIUpscaler.scaleFactor(for: width, sourceHeight: height, requested: requested) != nil {
                fail("Invalid dimensions or budget accepted: \(width)x\(height), \(requested)")
            }
        }
        guard !configurations.isEmpty else {
            if !budgetFailures.isEmpty { fail(budgetFailures.joined(separator: "; ")) }
            print("SKIP: neither 1080p nor 720p has a supported AI factor; no GPU recovery was tested")
            exit(2)
        }
        checkPreparationFailure()
    }

    private func checkPreparationFailure() {
        let timeout = DispatchWorkItem { [weak self] in self?.fail("No preparation-failure state notification") }
        watchdog = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timeout)
        scaler.onStateChange = { [weak self] in
            guard let self else { return }
            guard scaler.preparationFailed, !scaler.isReady, !scaler.isPreparing else {
                fail("Rejected preparation did not publish the failure state")
            }
            watchdog?.cancel()
            scaler.stop()
            guard !scaler.preparationFailed, !scaler.isReady, !scaler.isPreparing else { fail("stop did not clear a preparation failure") }
            print("PASS STATUS: rejected factor -> failure callback -> stop clears failure")
            // Observe readiness only. Repeated prepare calls would hide a lost
            // request behind an obsolete warmup when capture is paused.
            scaler.onStateChange = { [weak self] in self?.renderWhenReady() }
            startConfiguration()
        }
        let current = configurations[0]
        // Fail through the production preparation guard, without asking VT to
        // initialize an unsupported native configuration or simulating a model error.
        scaler.prepare(sourceWidth: current.width, sourceHeight: current.height, factor: 1, colorSpace: space)
        guard scaler.isPreparing, !scaler.preparationFailed, !scaler.isReady else { fail("Incorrect in-progress preparation state") }
    }

    private func enumerateFactors(width: Int, height: Int) {
        let supported = VTLowLatencySuperResolutionScalerConfiguration.supportedScaleFactors(frameWidth: width, frameHeight: height)
            .filter { $0.isFinite && $0 > 1 }.sorted()
        print("FACTORS \(width)x\(height): \(supported)")
        let requests: [(String, Double)] = [
            ("native", 1), ("1.2x", 1.2), ("1.5x", 1.5), ("2x", 2),
            ("4K long edge", 3840 / Double(width)),
            ("2300px / low-latency visible cap", 2300 / Double(width)),
            ("3024px screen target", 3024 / Double(width))
        ]
        for (label, requested) in requests {
            let expected = supported.filter { Double($0) <= requested }.max()
            let selected = AIUpscaler.scaleFactor(for: width, sourceHeight: height, requested: requested)
            guard selected == expected else { fail("\(width)x\(height) \(label): expected \(String(describing: expected)), got \(String(describing: selected))") }
            let output = selected.map { "\(Int(Float(width) * $0))x\(Int(Float(height) * $0))" } ?? "spatial fallback (no AI factor fits)"
            print("  \(label): requested=\(requested), selected=\(String(describing: selected)), output=\(output)")
        }
        for factor in supported {
            // A request immediately below a native factor must not round up to it.
            let cap = Double(factor).nextDown
            if let selected = AIUpscaler.scaleFactor(for: width, sourceHeight: height, requested: cap), Double(selected) > cap {
                let message = "\(width)x\(height) selected \(selected)x above requested cap \(cap)"
                budgetFailures.append(message)
                print("FAIL BUDGET: \(message)")
            }
            configurations.append(Configuration(width: width, height: height, factor: factor))
        }
    }

    private func startConfiguration() {
        step = 0
        inFlight = false
        scaler.stop()
        armWatchdog()
        prepareOnce()
        guard scaler.isPreparing, !scaler.preparationFailed else { fail("New warmup did not clear the previous failure state") }
        scaler.stop() // Both calls occur before the warmup can publish on main.
        scaler.stop() // stop is idempotent.
        guard !scaler.isReady else { fail("Stopped warmup remained ready") }
        prepareOnce()
    }

    private func prepareOnce() {
        let current = configurations[configurationIndex]
        scaler.prepare(sourceWidth: current.width, sourceHeight: current.height, factor: current.factor, colorSpace: space)
    }

    private func armWatchdog() {
        watchdog?.cancel()
        let current = configurations[configurationIndex]
        let label = steps[step]
        let work = DispatchWorkItem { [weak self] in
            self?.fail("\(current.label): timed out waiting for \(label); prepare must recover without another capture frame")
        }
        watchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: work)
    }

    private func renderWhenReady() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !inFlight, scaler.isReady else { return }
        guard !scaler.isPreparing, !scaler.preparationFailed else { fail("Ready scaler still reports preparation/failure") }
        inFlight = true
        let current = configurations[configurationIndex]
        let width = Int(Float(current.width) * current.factor)
        let height = Int(Float(current.height) * current.factor)
        var image = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: current.width, height: current.height))
        for (index, color) in colors.enumerated() {
            let rect = CGRect(x: (index % 2) * current.width / 2, y: (index / 2) * current.height / 2,
                              width: current.width / 2, height: current.height / 2)
            image = CIImage(color: CIColor(red: CGFloat(color.0), green: CGFloat(color.1), blue: CGFloat(color.2)))
                .cropped(to: rect).composited(over: image)
        }
        image = image.transformed(by: CGAffineTransform(translationX: 12, y: 24))
        guard let command = queue.makeCommandBuffer(),
              let scaled = scaler.upscale(image, context: context, command: command, colorSpace: space) else {
            fail("\(current.label): AI encode failed at \(steps[step])")
        }
        guard scaled.extent.origin == .zero, Int(scaled.extent.width) == width, Int(scaled.extent.height) == height else {
            fail("\(current.label): incorrect output extent \(scaled.extent)")
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
        guard let output = gpu.makeTexture(descriptor: descriptor) else { fail("Output texture allocation failed") }
        context.render(scaled, to: output, commandBuffer: command, bounds: scaled.extent, colorSpace: space)
        let submittedStep = step
        command.addCompletedHandler { [self] completed in
            guard completed.status == .completed else { fail("GPU error: \(String(describing: completed.error))") }
            var samples: [[UInt8]] = []
            for index in 0..<4 {
                var rgba = [UInt8](repeating: 0, count: 4)
                output.getBytes(&rgba, bytesPerRow: 4,
                                from: MTLRegionMake2D(width * (index % 2 == 0 ? 1 : 3) / 4, height * (index < 2 ? 1 : 3) / 4, 1, 1),
                                mipmapLevel: 0)
                samples.append(rgba)
            }
            for (index, sample) in samples.enumerated() {
                let color = colors[index]
                let expected = [color.0, color.1, color.2].map { Double($0) * 255 }
                guard (0..<3).allSatisfy({ abs(Double(sample[$0]) - expected[$0]) <= 8 }), sample[3] == 255 else {
                    fail("\(current.label): color/orientation mismatch: \(samples)")
                }
            }
            DispatchQueue.main.async { [self] in
                watchdog?.cancel()
                inFlight = false
                print("PASS GPU \(current.label) -> \(width)x\(height): \(steps[submittedStep]); samples=\(samples)")
                advance(after: submittedStep)
            }
        }
        if submittedStep == 1 {
            // Resources must survive retirement even before the buffer is committed.
            scaler.stop()
            guard !scaler.isReady else { fail("Stopped session remained ready before GPU commit") }
            prepareOnce()
        }
        command.commit()
        if submittedStep == 2 {
            scaler.stop()
            guard !scaler.isReady else { fail("Stopped session remained ready after GPU commit") }
            prepareOnce()
        }
    }

    private func advance(after submittedStep: Int) {
        step = submittedStep + 1
        if step == steps.count {
            scaler.stop()
            configurationIndex += 1
            if configurationIndex == configurations.count {
                if !budgetFailures.isEmpty { fail(budgetFailures.joined(separator: "; ")) }
                print("PASS: SDK factor enumeration, requested caps, and \(configurations.count * steps.count) real GPU recovery/render checks")
                exit(0)
            }
            startConfiguration()
            return
        }
        armWatchdog()
        if step == 1 {
            scaler.stop()
            guard !scaler.isReady else { fail("Stopped completed session remained ready") }
            prepareOnce()
        }
        renderWhenReady() // Readiness may have arrived while the previous command ran.
    }
}

if #available(macOS 26.0, *), AIUpscalerSupport.isSupported {
    guard let gpu = MTLCreateSystemDefaultDevice(), let queue = gpu.makeCommandQueue() else {
        print("SKIP: no Metal GPU/queue; no GPU recovery was tested")
        exit(2)
    }
    let tests = GPURecoveryTests(gpu: gpu, queue: queue)
    DispatchQueue.main.async { tests.run() }
    dispatchMain()
}
#else
if #available(macOS 26.0, *), let gpu = MTLCreateSystemDefaultDevice() {
    let stub = AIUpscaler(device: gpu)
    guard !stub.isReady, !stub.isPreparing, !stub.preparationFailed,
          AIUpscaler.scaleFactor(for: 1280, sourceHeight: 720, requested: 2) == nil else {
        print("FAIL: unavailable-AI stub reports active preparation/scaling")
        exit(1)
    }
    print("Stub readiness/preparation/failure properties verified; actual AI GPU test remains skipped")
}
#endif
print("SKIP: AI scaler is unavailable with this SDK/runtime; no GPU recovery was tested")
exit(2)
