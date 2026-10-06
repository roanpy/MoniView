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
