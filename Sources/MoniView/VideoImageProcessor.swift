import CoreImage

/// Shared color math keeps preview and recording consistent. Scaling remains preview-specific.
enum VideoImageProcessor {
    /// Enhancement sharpening shared by recording and native-size preview, and it is
    /// applied inside the same command the midpoint uses, so its cost lands on the
    /// interpolation budget. 0.22 was invisible at the default strength; pushing it to
    /// 0.30 cost enough GPU that a 30 FPS source stopped reaching 60. This is the
    /// visible-but-affordable point; raise it only if the budget has room to spare.
    static let enhancementSharpening = 0.26
    /// Resampling softens edges, so a scaled preview compensates a little more.
    static let scaledPreviewSharpening = 0.36

    static func color(_ image: CIImage, settings: PictureSettings) -> CIImage {
        var result = image
        if settings.brightness != 0 || settings.contrast != 1 || settings.saturation != 1 {
            result = result.applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: settings.brightness, kCIInputContrastKey: settings.contrast, kCIInputSaturationKey: settings.saturation])
        }
        if settings.vibrance != 0 { result = result.applyingFilter("CIVibrance", parameters: [kCIInputAmountKey: settings.vibrance]) }
        if settings.highlightRecovery > 0 {
            result = result.applyingFilter("CIHighlightShadowAdjust", parameters: ["inputHighlightAmount": 1 - settings.highlightRecovery, "inputShadowAmount": 0])
        }
        return result
    }
    static func recordedImage(_ buffer: CVPixelBuffer, settings: PictureSettings) -> CIImage {
        let source = CIImage(cvPixelBuffer: buffer)
        var result = color(source, settings: settings)
        let sharpness = settings.sharpness + (settings.enhancementEnabled ? settings.enhancementStrength * enhancementSharpening : 0)
        if sharpness > 0.001 { result = result.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: sharpness]) }
        return result.cropped(to: source.extent)
    }
}
