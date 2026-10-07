import CoreFoundation
import CoreVideo
import Darwin
import Foundation
import ImageIO

/// Exact CPU comparison for two already-retained video frames.
///
/// This type deliberately keeps no frame history. Callers own the lifetime of both
/// pixel buffers and decide whether an identical interpolation pair should be skipped.
enum VideoFrameDuplicateDetector {
    /// Returns true only when dimensions, pixel format, image-interpretation attachments,
    /// and every active pixel byte match exactly. Row padding is ignored.
    /// A capture device can resend one picture with a handful of bytes changed by its own
    /// encoding noise. Exact comparison reads that as new content, which inflates the
    /// measured content rate: a 30 FPS game in a 60 Hz signal measured 40 to 45 FPS on
    /// this hardware. Cadence measurement therefore allows a small fraction of differing
    /// bytes, while the inference-skip decision keeps using the exact comparison so it
    /// never treats genuinely different pictures as repeats.
    static func areEquivalentForCadence(_ previous: CVPixelBuffer, _ current: CVPixelBuffer,
                                        allowedDifference: Double = 0.002) -> Bool {
        // Same format allow-list as the exact path. The difference counter assumes two-plane
        // 420 or packed BGRA, so an unexpected layout must be refused rather than measured:
        // a three-plane format would have its chroma rows read past their true length.
        let format = CVPixelBufferGetPixelFormatType(previous)
        let isBiPlanar420 = format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
            format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        let isBGRA = format == kCVPixelFormatType_32BGRA
        guard isBiPlanar420 || isBGRA else { return false }
        guard ObjectIdentifier(previous as AnyObject) != ObjectIdentifier(current as AnyObject),
              CVPixelBufferGetWidth(previous) == CVPixelBufferGetWidth(current),
              CVPixelBufferGetHeight(previous) == CVPixelBufferGetHeight(current),
              CVPixelBufferGetPixelFormatType(previous) == CVPixelBufferGetPixelFormatType(current),
              attachmentsMatch(previous, current) else { return false }
        guard CVPixelBufferLockBaseAddress(previous, .readOnly) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(previous, .readOnly) }
        guard CVPixelBufferLockBaseAddress(current, .readOnly) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(current, .readOnly) }
        let total = planeByteCount(previous)
        guard total > 0 else { return false }
        let differing = differingByteCount(previous, current)
        return Double(differing) <= Double(total) * allowedDifference
    }

    /// Total compared byte count across the planes an exact comparison would visit.
    private static func planeByteCount(_ buffer: CVPixelBuffer) -> Int {
        var total = 0
        if CVPixelBufferGetPlaneCount(buffer) == 0 {
            total = CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer)
        } else {
            for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
                total += CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane)
            }
        }
        return total
    }

    /// Bytes that differ, counted on the same rows the exact comparison inspects.
    private static func differingByteCount(_ first: CVPixelBuffer, _ second: CVPixelBuffer) -> Int {
        var differing = 0
        if CVPixelBufferGetPlaneCount(first) == 0 {
            guard let a = CVPixelBufferGetBaseAddress(first), let b = CVPixelBufferGetBaseAddress(second) else { return .max }
            differing += countDifferences(a, CVPixelBufferGetBytesPerRow(first),
                                          b, CVPixelBufferGetBytesPerRow(second),
                                          rowBytes: CVPixelBufferGetWidth(first) * 4,
                                          rowCount: CVPixelBufferGetHeight(first))
        } else {
            for plane in 0..<CVPixelBufferGetPlaneCount(first) {
                guard let a = CVPixelBufferGetBaseAddressOfPlane(first, plane),
                      let b = CVPixelBufferGetBaseAddressOfPlane(second, plane) else { return .max }
                let bytesPerSample = plane == 0 ? 1 : 2
                differing += countDifferences(a, CVPixelBufferGetBytesPerRowOfPlane(first, plane),
                                              b, CVPixelBufferGetBytesPerRowOfPlane(second, plane),
                                              rowBytes: CVPixelBufferGetWidthOfPlane(first, plane) * bytesPerSample,
                                              rowCount: CVPixelBufferGetHeightOfPlane(first, plane))
            }
        }
        return differing
    }

    private static func countDifferences(
        _ firstBase: UnsafeMutableRawPointer, _ firstStride: Int,
        _ secondBase: UnsafeMutableRawPointer, _ secondStride: Int,
        rowBytes: Int, rowCount: Int
    ) -> Int {
        guard rowBytes > 0, rowCount > 0, firstStride >= rowBytes, secondStride >= rowBytes else { return .max }
        let first = firstBase.assumingMemoryBound(to: UInt8.self)
        let second = secondBase.assumingMemoryBound(to: UInt8.self)
        var differing = 0
        for row in 0..<rowCount {
            let a = first + row * firstStride
            let b = second + row * secondStride
            // Rows of a duplicate are usually byte-identical, so let memcmp settle them at
            // memory speed and only count bytes on the rare row that actually differs.
            if memcmp(a, b, rowBytes) == 0 { continue }
            for index in 0..<rowBytes where a[index] != b[index] { differing += 1 }
        }
        return differing
    }

    static func areIdentical(_ previous: CVPixelBuffer, _ current: CVPixelBuffer) -> Bool {
        // A shared reference could be mutable through another alias; do not infer that
        // its contents stayed unchanged between capture and comparison.
        guard ObjectIdentifier(previous as AnyObject) != ObjectIdentifier(current as AnyObject),
              CVPixelBufferGetWidth(previous) == CVPixelBufferGetWidth(current),
              CVPixelBufferGetHeight(previous) == CVPixelBufferGetHeight(current),
              CVPixelBufferGetPixelFormatType(previous) == CVPixelBufferGetPixelFormatType(current),
              attachmentsMatch(previous, current) else { return false }

        let format = CVPixelBufferGetPixelFormatType(previous)
        let isBiPlanar420 = format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
            format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        let isBGRA = format == kCVPixelFormatType_32BGRA
        guard isBiPlanar420 || isBGRA,
              CVPixelBufferLockBaseAddress(previous, .readOnly) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(previous, .readOnly) }
        guard CVPixelBufferLockBaseAddress(current, .readOnly) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(current, .readOnly) }

        if isBiPlanar420 {
            return biPlanar420PixelsMatch(previous, current)
        }
        return bgraPixelsMatch(previous, current)
    }

    private static func attachmentsMatch(_ first: CVPixelBuffer, _ second: CVPixelBuffer) -> Bool {
        for key in imageInterpretationAttachmentKeys {
            let firstValue = CVBufferCopyAttachment(first, key, nil)
            let secondValue = CVBufferCopyAttachment(second, key, nil)
            switch (firstValue, secondValue) {
            case (nil, nil):
                continue
            case let (firstValue?, secondValue?):
                guard CFEqual(firstValue, secondValue) else { return false }
            default:
                return false
            }
        }
        return true
    }

    /// Only attachments that can change how pixel values are interpreted belong in
    /// duplicate identity. Per-frame metadata and timestamps intentionally do not.
    private static let imageInterpretationAttachmentKeys: [CFString] = [
        kCVImageBufferYCbCrMatrixKey,
        kCVImageBufferColorPrimariesKey,
        kCVImageBufferTransferFunctionKey,
        kCVImageBufferGammaLevelKey,
        kCVImageBufferCGColorSpaceKey,
        kCVImageBufferChromaLocationTopFieldKey,
        kCVImageBufferChromaLocationBottomFieldKey,
        kCVImageBufferCleanApertureKey,
        kCVImageBufferPixelAspectRatioKey,
        kCVImageBufferFieldCountKey,
        kCVImageBufferFieldDetailKey,
        kCGImagePropertyOrientation
    ]

    private static func biPlanar420PixelsMatch(_ first: CVPixelBuffer, _ second: CVPixelBuffer) -> Bool {
        guard CVPixelBufferGetPlaneCount(first) == 2,
              CVPixelBufferGetPlaneCount(second) == 2 else { return false }

        let width = CVPixelBufferGetWidth(first)
        let height = CVPixelBufferGetHeight(first)
        let expectedWidths = [width, width / 2 + width % 2]
        let expectedHeights = [height, height / 2 + height % 2]

        for plane in 0..<2 {
            let firstWidth = CVPixelBufferGetWidthOfPlane(first, plane)
            let secondWidth = CVPixelBufferGetWidthOfPlane(second, plane)
            let firstHeight = CVPixelBufferGetHeightOfPlane(first, plane)
            let secondHeight = CVPixelBufferGetHeightOfPlane(second, plane)
            guard firstWidth == expectedWidths[plane], secondWidth == expectedWidths[plane],
                  firstHeight == expectedHeights[plane], secondHeight == expectedHeights[plane] else { return false }

            let bytesPerSample = plane == 0 ? 1 : 2 // UV is interleaved CbCr.
            guard let rowBytes = multipliedWithoutOverflow(firstWidth, bytesPerSample),
                  let firstBase = CVPixelBufferGetBaseAddressOfPlane(first, plane),
                  let secondBase = CVPixelBufferGetBaseAddressOfPlane(second, plane),
                  rowsMatch(firstBase, firstStride: CVPixelBufferGetBytesPerRowOfPlane(first, plane),
                            secondBase, secondStride: CVPixelBufferGetBytesPerRowOfPlane(second, plane),
                            rowBytes: rowBytes, rowCount: firstHeight) else { return false }
        }
        return true
    }

    private static func bgraPixelsMatch(_ first: CVPixelBuffer, _ second: CVPixelBuffer) -> Bool {
        guard CVPixelBufferGetPlaneCount(first) == 0,
              CVPixelBufferGetPlaneCount(second) == 0,
              let rowBytes = multipliedWithoutOverflow(CVPixelBufferGetWidth(first), 4),
              let firstBase = CVPixelBufferGetBaseAddress(first),
              let secondBase = CVPixelBufferGetBaseAddress(second) else { return false }

        return rowsMatch(firstBase, firstStride: CVPixelBufferGetBytesPerRow(first),
                         secondBase, secondStride: CVPixelBufferGetBytesPerRow(second),
                         rowBytes: rowBytes, rowCount: CVPixelBufferGetHeight(first))
    }

    private static func rowsMatch(
        _ firstBase: UnsafeMutableRawPointer,
        firstStride: Int,
        _ secondBase: UnsafeMutableRawPointer,
        secondStride: Int,
        rowBytes: Int,
        rowCount: Int
    ) -> Bool {
        guard rowBytes > 0, rowCount > 0,
              firstStride >= rowBytes, secondStride >= rowBytes,
              firstStride.multipliedReportingOverflow(by: rowCount - 1).overflow == false,
              secondStride.multipliedReportingOverflow(by: rowCount - 1).overflow == false else { return false }

        let first = UnsafeRawPointer(firstBase)
        let second = UnsafeRawPointer(secondBase)
        for row in 0..<rowCount {
            if memcmp(first.advanced(by: row * firstStride),
                      second.advanced(by: row * secondStride), rowBytes) != 0 {
                return false
            }
        }
        return true
    }

    private static func multipliedWithoutOverflow(_ value: Int, _ multiplier: Int) -> Int? {
        let (result, overflow) = value.multipliedReportingOverflow(by: multiplier)
        return overflow || result <= 0 ? nil : result
    }
}
