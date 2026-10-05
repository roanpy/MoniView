import Combine
import CoreImage
import CoreVideo
import Foundation
import Metal

/// No AppKit/UI dependency: frame processing and file writing can be reused by an iPad shell.
/// The caller admits one export at a time. All expensive work stays off capture and render queues.
final class FrameExporter: ObservableObject {
    private struct Frame: @unchecked Sendable { let buffer: CVPixelBuffer }
    private let queue = DispatchQueue(label: "dev.moniview.snapshot", qos: .userInitiated)
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    // Created and used only on queue; reuse the context instead of rebuilding it per snapshot.
    private lazy var context: CIContext = {
        let options: [CIContextOption: Any] = [.cacheIntermediates: false, .workingColorSpace: colorSpace]
        if let device = MTLCreateSystemDefaultDevice() { return CIContext(mtlDevice: device, options: options) }
        return CIContext(options: options)
    }()

    func png(buffer: CVPixelBuffer, settings: PictureSettings, completion: @escaping (Result<Data, Error>) -> Void) {
        let frame = Frame(buffer: buffer)
        queue.async {
            let result: Result<Data, Error> = autoreleasepool {
                let image = VideoImageProcessor.recordedImage(frame.buffer, settings: settings)
                guard let data = self.context.pngRepresentation(of: image, format: .RGBA8, colorSpace: self.colorSpace, options: [:]) else {
                    return .failure(CaptureFailure.message("无法生成 PNG 图像。"))
                }
                return .success(data)
            }
            // Only PNG data survives into the save panel; never pin a capture buffer while choosing a path.
            DispatchQueue.main.async { completion(result) }
        }
    }

    func write(_ data: Data, to destination: URL, completion: @escaping (Error?) -> Void) {
        queue.async {
            let accessed = destination.startAccessingSecurityScopedResource()
            defer { if accessed { destination.stopAccessingSecurityScopedResource() } }
            var coordinationError: NSError?
            var writeError: Error?
            NSFileCoordinator().coordinate(writingItemAt: destination, options: .forReplacing, error: &coordinationError) { url in
                do { try data.write(to: url, options: .atomic) }
                catch { writeError = error }
            }
            let error: Error? = coordinationError ?? writeError
            DispatchQueue.main.async { completion(error) }
        }
    }
}
