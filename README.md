<div align="center">

# MoniView

**A native, lightweight UVC / HDMI capture card monitor for macOS.**

Live preview, audio monitoring, recording, color tools, and MetalFX spatial scaling, built on SwiftUI, AVFoundation, Metal, and Core Image with no third-party runtime dependencies.

**English · [简体中文](README.zh-CN.md)**

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-111827?logo=apple)
![Swift 5.9+](https://img.shields.io/badge/Swift-5.9%2B-f05138?logo=swift&logoColor=white)
[![License: MIT](https://img.shields.io/badge/license-MIT-16a34a.svg)](LICENSE)

</div>

> **Status: early preview (0.2.0).** MoniView is a local developer build with ad-hoc signing. It is not notarized and is not on the Mac App Store. It targets macOS 14 or later. The interface follows the system language: English or Simplified Chinese.

MoniView turns a USB (UVC) capture card into a low-latency monitor window for an HDMI source: a camera, a console, or any other HDMI output.

## What it does

- Enumerates the formats the device actually reports, including discrete steps and fractional rates such as 29.97 and 59.94 FPS.
- Keeps the preview low-latency: only the newest frame is retained, and capture, GPU rendering, audio, and video encoding run on separate queues with at most one GPU frame in flight.
- Monitors the capture card's audio input in real time with a level meter.
- Records H.264 video with AAC audio to a `.mov` file.
- Adjusts color and sharpening: brightness, contrast, saturation, vibrance, and highlight recovery.
- Scales the preview on the GPU with MetalFX, with a Lanczos compatibility fallback.
- Writes a diagnostics snapshot on the local machine only.

## Screenshots

![MoniView live preview window](docs/images/moniview-window.png)

![MoniView capture settings](docs/images/moniview-controls.png)

These screenshots show the actual app connected to a Jemdo Video capture card. On-screen values depend on the connected device and are not performance benchmarks.

## Build and run

```sh
swift build -c release
./Scripts/build-app.sh
open build/MoniView.app
```

Only the Swift toolchain is needed; the Xcode Command Line Tools are enough and no Xcode project or full IDE is required. `Scripts/build-app.sh` wraps the SwiftPM release binary into `build/MoniView.app` with `Resources/MoniView.icns`, the bundled `PrivacyInfo.xcprivacy`, and an ad-hoc signature.

On first launch, grant camera and microphone access; the capture card's audio input also uses the microphone permission. MoniView auto-selects the USB video device and a matching audio input, and other inputs can be chosen in settings.

The bottom buttons are Record, Info, Quality, Color, and Settings. A click on the image closes the open panel.

The brief status line shows the device name, the actual buffer resolution, and the measured FPS. In window mode it sits centered along the top; in full screen it moves to the top left. The detailed info card opens at the top right, and while it is open the brief line is hidden and restored when the card closes. Turn the brief line off with **显示设备状态** (Show device status) in settings.

**画面比例** (Aspect) sets how the image fills the window: **适应画面** (fit) shows the whole image, **填满窗口** (fill) keeps the ratio and crops the overflow, and **拉伸填满** (stretch) fills the window and may distort the ratio.

Shortcuts: `⌘R` record/stop, `⌘M` mute monitoring, `⌘I` show or hide the info card, `⌘,` open settings, `⌃⌘F` or a double-click on the image to toggle native full screen, and `Esc` to close a panel or leave full screen. In full screen, the buttons and cursor hide after three seconds of inactivity and reappear on movement.

## Preview and frame rate

MoniView sets both the device and the video connection frame duration, so a device configured for 60 FPS is not left with a connection still running at 20. When the resolution changes and the current frame rate is not supported, it uses the highest rate the new format offers.

The info card reports the actual buffer size, capture and render frame rates, audio level, and software processing time. That time spans the video callback through GPU completion; it does not include HDMI device, capture card, or display scan-out latency.

When the window is minimized or fully occluded by another window, preview rendering pauses while capture, recording, and audio monitoring continue.

See [performance notes](docs/PERFORMANCE.md) for the pipeline, observed device samples, and measurement limits.

## GPU spatial scaling is not AI

MetalFX is a spatial upscaler that needs no multi-frame history, so it cannot create detail the capture signal never contained. This version has no AI model and no frame interpolation.

- **MetalFX** uses the system spatial upscaler on supported GPUs.
- **Lanczos** is the compatibility path, used automatically when the device does not support MetalFX or the requested scale exceeds its current limits.
- Targets are original, 2K (long edge 2560), and 4K (long edge 3840). Those sizes are stated at 16:9; other aspect ratios are measured by their long edge and keep their own ratio.

In low latency mode the target is an upper bound on the processing size: frames are processed at the actual display size, so 2K and 4K can resolve to the same processing size. The info card shows the pixel size this frame was actually processed at.

In low latency mode the target is an upper bound: frames are processed at the actual display size, not always the full target. With vsync off this can cause tearing; turn low latency off to process at the full target size.

These options affect the live preview only.

## Recording

By default a recording includes the selected color adjustments and sharpening at the original resolution. It does not include GPU scaling or the on-screen UI. Because sharpening is applied at the source resolution while the preview may sharpen after MetalFX or Lanczos scaling, a recording is not a pixel-for-pixel copy of the scaled preview. Turn off **录制预览色彩和锐化** (Record color and sharpening) in settings to save the untouched source instead. H.264 encoding uses the system encoder through AVFoundation, which may be a hardware or software encoder; a hardware encoder is not guaranteed. Audio (when present) is AAC, and the container is `.mov`.

## Measured device limits

On the development machine, a Jemdo Video USB capture device exposed a highest capture format of 1920×1080 at about 60 FPS, and no 4K capture entry was present. HDMI input or passthrough capability and the USB capture output capability can differ; follow the formats the device actually reports. Other capture cards still need to be verified on their own hardware.

This is what one device reported under test, not a general performance claim.

## Privacy

Camera and microphone access are required: the camera permission reads the UVC capture card, and the microphone permission reads the capture card's audio input for monitoring and recording. MoniView runs entirely on the local machine, collects nothing, and sends nothing to any external service. The app bundles a privacy manifest (`PrivacyInfo.xcprivacy`) that declares no tracking and no collected data. Recordings are written to the file you choose in the save panel, and the diagnostics snapshot is written to `~/Library/Logs/MoniView/diagnostics.json`; both stay local. Capture card serial numbers, device identifiers, and diagnostic logs can be personally identifying, so do not attach them to public issues. See [docs/PRIVACY.md](docs/PRIVACY.md) for the full statement.

## Platform and roadmap

MoniView is macOS only today. It is built as an ad-hoc signed local app, not a notarized or Mac App Store build, so the current artifact is not Store-submittable; see [docs/APP_STORE.md](docs/APP_STORE.md) for the distribution checklist and the remaining gaps. An iPad version would need a separate UIKit touch target, audio playback adaptation, and its own signing; a Mac `.app` cannot be installed on iPad. The iOS version is not part of this repository, and later versions may be closed source. Existing releases keep the license they shipped with.

## References

Reference material for the capture and rendering approach. No third-party code was copied. OBS Studio is licensed GPL-2.0-or-later; its source was reviewed for design ideas, but no code was copied.

- Apple: [Technical Note TN2445 — Handling Frame Drops with AVCaptureVideoDataOutput](https://developer.apple.com/library/archive/technotes/tn2445/_index.html)
- Apple: [CAMetalLayer](https://developer.apple.com/documentation/QuartzCore/CAMetalLayer) and [nextDrawable()](https://developer.apple.com/documentation/QuartzCore/CAMetalLayer/nextDrawable())
- OBS Studio: [mac-avcapture plugin](https://github.com/obsproject/obs-studio/tree/master/plugins/mac-avcapture) (GPL-2.0-or-later)

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for build and privacy ground rules, and [CHANGELOG.md](CHANGELOG.md) for release history. A build-only workflow is available for manual runs; it is not triggered on push or pull request.

## License

MIT. See [LICENSE](LICENSE).
