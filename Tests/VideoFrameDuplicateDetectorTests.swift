import CoreVideo
import Darwin
import Foundation
import ImageIO

@main
struct VideoFrameDuplicateDetectorTests {
    private static let alignment = 64
    private static var checks = 0

    private static let formats: [(name: String, type: OSType)] = [
        ("420v", kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        ("420f", kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
        ("32BGRA", kCVPixelFormatType_32BGRA)
    ]

    static func main() throws {
        setbuf(stdout, nil)
        print("Running pixel equality cases")
        testIdenticalAndChangedPixels()
        testCadenceTolerance()
        print("Running padding cases")
        testPaddingIsIgnored()
        print("Running format/dimension cases")
        testFormatAndDimensionsMustMatch()
        print("Running attachment cases")
        testAttachmentsMustMatch()
        print("Running CPU benchmarks")
        print("Benchmark conditions: swiftc -O; 3 warmups then 100 measured calls per case; repeated 420v buffers compare every active Y and UV byte; CPU thread clock includes readOnly locks and comparison, and repeated-buffer cache effects are machine-specific.")
        benchmark420VideoRange(width: 1920, height: 1080)
        benchmark420VideoRange(width: 3840, height: 2160)
        print("VideoFrameDuplicateDetector: \(checks) correctness checks passed.")
        print("These CPU timings do not measure image quality, end-to-end latency, or GPU performance.")
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            fflush(stderr)
            fatalError("FAIL: \(message)")
        }
        checks += 1
    }

    private static func makeBuffer(width: Int, height: Int, format: OSType) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferBytesPerRowAlignmentKey as String: alignment] as CFDictionary
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, attributes, &buffer)
        precondition(status == kCVReturnSuccess, "CVPixelBufferCreate failed for \(width)x\(height), format \(format): \(status)")
        return buffer!
    }

    private static func activeRowBytes(_ buffer: CVPixelBuffer, plane: Int) -> Int {
        if CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA {
            return CVPixelBufferGetWidth(buffer) * 4
        }
        return CVPixelBufferGetWidthOfPlane(buffer, plane) * (plane == 0 ? 1 : 2)
    }

    private static func withWriteLock(_ buffer: CVPixelBuffer, _ body: () -> Void) {
        precondition(CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess, "pixel buffer write lock failed")
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        body()
    }

    /// Fills active bytes deterministically and padding separately so tests can prove
    /// that comparison is independent of allocator row padding.
    private static func fill(_ buffer: CVPixelBuffer, seed: Int = 17, padding: UInt8 = 0) {
        withWriteLock(buffer) {
            let isBGRA = CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA
            let planeCount = isBGRA ? 1 : CVPixelBufferGetPlaneCount(buffer)
            for plane in 0..<planeCount {
                let rows = isBGRA ? CVPixelBufferGetHeight(buffer) : CVPixelBufferGetHeightOfPlane(buffer, plane)
                let stride = isBGRA ? CVPixelBufferGetBytesPerRow(buffer) : CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
                let rowBytes = activeRowBytes(buffer, plane: plane)
                let base = isBGRA ? CVPixelBufferGetBaseAddress(buffer) : CVPixelBufferGetBaseAddressOfPlane(buffer, plane)
                guard let base, stride >= rowBytes else { preconditionFailure("invalid test pixel-buffer layout") }
                for row in 0..<rows {
                    let destination = base.advanced(by: row * stride)
                    memset(destination, Int32(padding), stride)
                    for byte in 0..<rowBytes {
                        let value = seed &+ plane &* 53 &+ row &* 29 &+ byte &* 7
                        destination.storeBytes(of: UInt8(truncatingIfNeeded: value), toByteOffset: byte, as: UInt8.self)
                    }
                }
            }
        }
    }

    private static func writeByte(_ buffer: CVPixelBuffer, plane: Int, row: Int, offset: Int, value: UInt8) {
        withWriteLock(buffer) {
            let isBGRA = CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA
            let base = isBGRA ? CVPixelBufferGetBaseAddress(buffer) : CVPixelBufferGetBaseAddressOfPlane(buffer, plane)
            let stride = isBGRA ? CVPixelBufferGetBytesPerRow(buffer) : CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            let rows = isBGRA ? CVPixelBufferGetHeight(buffer) : CVPixelBufferGetHeightOfPlane(buffer, plane)
            precondition(row >= 0 && row < rows && offset >= 0 && offset < activeRowBytes(buffer, plane: plane))
            base!.storeBytes(of: value, toByteOffset: row * stride + offset, as: UInt8.self)
        }
    }

    private static func activeBytesArePadded(_ buffer: CVPixelBuffer) -> Bool {
        let isBGRA = CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA
        let planes = isBGRA ? 1 : CVPixelBufferGetPlaneCount(buffer)
        return (0..<planes).contains { plane in
            let stride = isBGRA ? CVPixelBufferGetBytesPerRow(buffer) : CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            return stride > activeRowBytes(buffer, plane: plane)
        }
    }

    /// The cadence judge tolerates a few differing bytes because a capture device resends one
    /// picture with its own encoding noise. These cases pin the boundary: noise reads as a
    /// repeat, real movement does not.
    private static func testCadenceTolerance() {
        for format in formats {
            let previous = makeBuffer(width: 64, height: 48, format: format.type)
            fill(previous, seed: 91, padding: 0x11)

            // Exact copies are equivalent.
            let copy = makeBuffer(width: 64, height: 48, format: format.type)
            fill(copy, seed: 91, padding: 0x11)
            check(VideoFrameDuplicateDetector.areEquivalentForCadence(previous, copy),
                  "identical buffers are equivalent: \(format.name)")

            // A handful of bytes is within tolerance and counts as a repeat.
            let noisy = makeBuffer(width: 64, height: 48, format: format.type)
            fill(noisy, seed: 91, padding: 0x11)
            for offset in stride(from: 4, to: 40, by: 4) {
                writeByte(noisy, plane: 0, row: 5, offset: offset, value: 200)
            }
            check(VideoFrameDuplicateDetector.areEquivalentForCadence(previous, noisy),
                  "a few differing bytes stay equivalent: \(format.name)")

            // The exact judge must still reject that same pair.
            check(!VideoFrameDuplicateDetector.areIdentical(previous, noisy),
                  "the exact judge rejects the noisy copy: \(format.name)")

            // A genuinely different picture is far outside tolerance.
            let different = makeBuffer(width: 64, height: 48, format: format.type)
            fill(different, seed: 12, padding: 0x11)
            check(!VideoFrameDuplicateDetector.areEquivalentForCadence(previous, different),
                  "different content is not equivalent: \(format.name)")

            // Zero tolerance degenerates to exactness.
            check(!VideoFrameDuplicateDetector.areEquivalentForCadence(previous, noisy, allowedDifference: 0),
                  "zero tolerance rejects any difference: \(format.name)")
            check(VideoFrameDuplicateDetector.areEquivalentForCadence(previous, copy, allowedDifference: 0),
                  "zero tolerance still accepts identical buffers: \(format.name)")
        }
    }

    private static func testIdenticalAndChangedPixels() {
        for format in formats {
            let previous = makeBuffer(width: 12, height: 8, format: format.type)
            let current = makeBuffer(width: 12, height: 8, format: format.type)
            fill(previous, seed: 71, padding: 0x11)
            fill(current, seed: 71, padding: 0xEE)
            check(VideoFrameDuplicateDetector.areIdentical(previous, current), "identical active pixels differ only in padding: \(format.name)")
            check(!VideoFrameDuplicateDetector.areIdentical(previous, previous), "same mutable reference is conservatively rejected: \(format.name)")

            let changed = makeBuffer(width: 12, height: 8, format: format.type)
            fill(changed, seed: 71)
            let firstPlane = 0
            let changedOffset = format.type == kCVPixelFormatType_32BGRA ? 4 * 4 : 4
            let original = UInt8(truncatingIfNeeded: 71 &+ 3 &* 29 &+ changedOffset &* 7)
            writeByte(changed, plane: firstPlane, row: 3, offset: changedOffset, value: original &+ 1)
            check(!VideoFrameDuplicateDetector.areIdentical(previous, changed), "one-byte pixel change is not duplicate: \(format.name)")

            if format.type != kCVPixelFormatType_32BGRA {
                let uvChanged = makeBuffer(width: 12, height: 8, format: format.type)
                fill(uvChanged, seed: 71)
                let uvOriginal = UInt8(truncatingIfNeeded: 71 &+ 53 &+ 2 &* 29)
                writeByte(uvChanged, plane: 1, row: 2, offset: 2, value: uvOriginal &+ 1)
                check(!VideoFrameDuplicateDetector.areIdentical(previous, uvChanged), "one-byte interleaved UV change is not duplicate: \(format.name)")

                let moved = makeBuffer(width: 12, height: 8, format: format.type)
                fill(previous, seed: 19)
                fill(moved, seed: 19)
                writeByte(previous, plane: 0, row: 4, offset: 4, value: 220)
                writeByte(moved, plane: 0, row: 4, offset: 5, value: 220)
                check(!VideoFrameDuplicateDetector.areIdentical(previous, moved), "one-sample luma movement is not duplicate: \(format.name)")
            }
        }
    }

    private static func testPaddingIsIgnored() {
        for format in formats {
            let first = makeBuffer(width: 9, height: 7, format: format.type)
            let second = makeBuffer(width: 9, height: 7, format: format.type)
            fill(first, seed: 101, padding: 0xA5)
            fill(second, seed: 101, padding: 0x5A)
            check(activeBytesArePadded(first) && activeBytesArePadded(second), "allocator supplied row padding for \(format.name) fixture")
            check(VideoFrameDuplicateDetector.areIdentical(first, second), "padding bytes are ignored: \(format.name)")
        }
    }

    private static func testFormatAndDimensionsMustMatch() {
        let video = makeBuffer(width: 12, height: 8, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        let full = makeBuffer(width: 12, height: 8, format: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        fill(video, seed: 23); fill(full, seed: 23)
        check(!VideoFrameDuplicateDetector.areIdentical(video, full), "video-range and full-range 420 formats differ")

        let smaller = makeBuffer(width: 10, height: 8, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        fill(smaller, seed: 23)
        check(!VideoFrameDuplicateDetector.areIdentical(video, smaller), "different dimensions are rejected")

    }

    private static func set709Attachments(_ buffer: CVPixelBuffer, orientation: UInt32 = 1) {
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCGImagePropertyOrientation, NSNumber(value: orientation), .shouldPropagate)
    }

    private static func setNonImageFrameMetadata(_ buffer: CVPixelBuffer, frameLabel: String, timestamp: Int64) {
        CVBufferSetAttachment(buffer, "com.moniview.tests.frame-label" as CFString,
                              frameLabel as CFString, .shouldPropagate)
        let movieTime = [
            kCVBufferTimeValueKey as String: NSNumber(value: timestamp),
            kCVBufferTimeScaleKey as String: NSNumber(value: 60_000)
        ] as CFDictionary
        CVBufferSetAttachment(buffer, kCVBufferMovieTimeKey, movieTime, .shouldNotPropagate)
    }

    private static func testAttachmentsMustMatch() {
        let baseline = makeBuffer(width: 12, height: 8, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        let equalMetadata = makeBuffer(width: 12, height: 8, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        fill(baseline, seed: 37); fill(equalMetadata, seed: 37)
        set709Attachments(baseline); set709Attachments(equalMetadata)
        check(VideoFrameDuplicateDetector.areIdentical(baseline, equalMetadata), "matching Rec.709 and orientation attachments are accepted")

        let differentColor = makeBuffer(width: 12, height: 8, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        fill(differentColor, seed: 37)
        set709Attachments(differentColor)
        CVBufferSetAttachment(differentColor, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate)
        check(!VideoFrameDuplicateDetector.areIdentical(baseline, differentColor), "different YCbCr matrix attachment is rejected")

        let differentOrientation = makeBuffer(width: 12, height: 8, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        fill(differentOrientation, seed: 37); set709Attachments(differentOrientation, orientation: 6)
        check(!VideoFrameDuplicateDetector.areIdentical(baseline, differentOrientation), "different orientation attachment is rejected")

        let perFrameMetadataDiffers = makeBuffer(width: 12, height: 8, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        fill(perFrameMetadataDiffers, seed: 37); set709Attachments(perFrameMetadataDiffers)
        setNonImageFrameMetadata(baseline, frameLabel: "captured-frame-1", timestamp: 1_000)
        setNonImageFrameMetadata(perFrameMetadataDiffers, frameLabel: "captured-frame-2", timestamp: 2_000)
        check(VideoFrameDuplicateDetector.areIdentical(baseline, perFrameMetadataDiffers), "custom frame metadata and timestamp differences do not affect image identity")
    }

    private static func setLastActiveByte(_ buffer: CVPixelBuffer, value: UInt8) {
        let plane = 1
        withWriteLock(buffer) {
            let rowCount = CVPixelBufferGetHeightOfPlane(buffer, plane)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            let finalRow = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!.advanced(by: (rowCount - 1) * stride)
            let finalActiveByte = activeRowBytes(buffer, plane: plane) - 1
            finalRow.storeBytes(of: value, toByteOffset: finalActiveByte, as: UInt8.self)
        }
    }

    private static func lastActiveByte(_ buffer: CVPixelBuffer) -> UInt8 {
        let plane = 1
        precondition(CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess,
                     "benchmark buffer read lock failed")
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let finalRow = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!
            .advanced(by: (CVPixelBufferGetHeightOfPlane(buffer, plane) - 1) * CVPixelBufferGetBytesPerRowOfPlane(buffer, plane))
        return finalRow.load(fromByteOffset: activeRowBytes(buffer, plane: plane) - 1, as: UInt8.self)
    }

    private static func threadCPUClock() -> Double {
        var time = timespec()
        let status = clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
        precondition(status == 0, "clock_gettime(CLOCK_THREAD_CPUTIME_ID) failed: \(errno)")
        return Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000
    }

    private static func runBenchmark(_ name: String, first: CVPixelBuffer, second: CVPixelBuffer, expected: Bool) {
        for _ in 0..<3 {
            check(VideoFrameDuplicateDetector.areIdentical(first, second) == expected, "benchmark warmup: \(name)")
        }
        let iterations = 100
        var matches = 0
        let start = threadCPUClock()
        for _ in 0..<iterations {
            if VideoFrameDuplicateDetector.areIdentical(first, second) { matches += 1 }
        }
        let elapsed = threadCPUClock() - start
        let expectedMatches = expected ? iterations : 0
        check(matches == expectedMatches, "benchmark result consistency: \(name)")
        print(String(format: "BENCH %@ n=%d CPU=%.3f ms avg=%.1f µs/call", name, iterations, elapsed * 1000, elapsed * 1_000_000 / Double(iterations)))
    }

    private static func benchmark420VideoRange(width: Int, height: Int) {
        let first = makeBuffer(width: width, height: height, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        let second = makeBuffer(width: width, height: height, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        fill(first, seed: 61, padding: 0xA1)
        fill(second, seed: 61, padding: 0xB2)
        let label = "420v \(width)x\(height)"
        runBenchmark("\(label) exact-identical", first: first, second: second, expected: true)

        let lastByte = lastActiveByte(second)
        setLastActiveByte(second, value: lastByte ^ 1)
        runBenchmark("\(label) worst-last-byte", first: first, second: second, expected: false)
    }
}
