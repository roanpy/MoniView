@preconcurrency import AVFoundation
import AppKit
import Combine
import CoreImage
import Foundation

struct CaptureInputOption: Identifiable, Hashable {
    let id: String
    let name: String
}

struct CaptureFormatOption: Identifiable, Hashable {
    let id: Int
    let width: Int
    let height: Int
    let minimumFPS: Int
    let maximumFPS: Int
    let rates: [ClosedRange<Double>]
    var title: String { "\(width) × \(height)" }
    var fpsTitle: String { L10n.format("最高 %d FPS", maximumFPS) }
    func supportsFPS(_ fps: Int) -> Bool { supportsFrameRate(Double(fps)) }
    func supportsFrameRate(_ fps: Double) -> Bool {
        fps == 0 || rates.contains { $0.lowerBound - 0.01 <= fps && $0.upperBound + 0.01 >= fps }
    }
}

enum AspectMode: String, CaseIterable, Identifiable, Codable {
    case fit = "适应画面"
    case fill = "填满窗口"
    case stretch = "拉伸填满"
    var id: String { rawValue }
}

enum UpscaleTarget: String, CaseIterable, Identifiable, Codable {
    case native = "原始"
    case qhd = "2K"
    case uhd = "4K"
    case screen = "屏幕"
    var id: String { rawValue }
    /// Fixed long edge for fixed targets; nil for native (no scaling) and screen (resolved per display).
    var longEdge: Double? {
        switch self {
        case .native, .screen: return nil
        case .qhd: return 2560
        case .uhd: return 3840
        }
    }
    /// Resolves the processing long edge; the screen target adapts to the display's native pixel count.
    func resolvedLongEdge(screenLongEdge: Double?, sourceLongEdge: Double) -> Double {
        switch self {
        case .native: return sourceLongEdge
        case .qhd, .uhd: return longEdge ?? sourceLongEdge
        case .screen: return screenLongEdge ?? sourceLongEdge
        }
    }
}

enum UpscaleMethod: String, CaseIterable, Identifiable, Codable {
    case metalFX = "MetalFX"
    case lanczos = "Lanczos"
    case ai = "AI 超分"
    var id: String { rawValue }
}

struct PictureSettings: Equatable, Codable {
    var brightness = 0.0
    var contrast = 1.0
    var saturation = 1.0
    var sharpness = 0.0
    var vibrance = 0.0
    var lowLatency = true
    var enhancementEnabled = true
    var enhancementStrength = 0.35
    var upscaleTarget: UpscaleTarget = .native
    var upscaleMethod: UpscaleMethod = .metalFX
    var highlightRecovery = 0.0
    var colorParameters: [Double] { [brightness, contrast, saturation, vibrance, highlightRecovery] }
}

/// The renderer retains only the newest frame. Capture never waits for the GPU or SwiftUI.
final class LatestVideoFrame {
    private let lock = NSLock()
    private var frameHandler: (() -> Void)?
    private var buffer: CVPixelBuffer?
    private var sequence: UInt64 = 0
    private var captured = 0
    private var rendered = 0
    private var dropped = 0
    private var level: Float = 0
    private var receivedAt: UInt64 = 0
    private var processingMilliseconds = 0.0
    private var engine = "原始"
    private var enhancedSize: String?
    private var timings: [Double] = []
    private var gpuTimings: [Double] = []

    func put(_ pixelBuffer: CVPixelBuffer) {
        lock.lock()
        buffer = pixelBuffer
        receivedAt = DispatchTime.now().uptimeNanoseconds
        sequence &+= 1
        captured += 1
        let callback = frameHandler
        lock.unlock()
        callback?()
    }
    func setFrameHandler(_ handler: @escaping () -> Void) { lock.lock(); frameHandler = handler; lock.unlock() }
    func latest() -> (CVPixelBuffer, UInt64, UInt64)? {
        lock.lock(); defer { lock.unlock() }
        guard let buffer else { return nil }
        return (buffer, sequence, receivedAt)
    }
    func clear() {
        lock.lock(); defer { lock.unlock() }
        buffer = nil
        sequence &+= 1
        level = 0
    }
    func markRendered(receivedAt: UInt64, gpuMS: Double) {
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - receivedAt) / 1_000_000
        lock.lock(); rendered += 1; timings.append(milliseconds); gpuTimings.append(gpuMS); lock.unlock()
    }
    func setEngine(_ value: String) { lock.lock(); engine = value; lock.unlock() }
    func currentEngine() -> String { lock.lock(); defer { lock.unlock() }; return engine }
    func setEnhancedSize(_ value: String?) { lock.lock(); enhancedSize = value; lock.unlock() }
    func currentEnhancedSize() -> String? { lock.lock(); defer { lock.unlock() }; return enhancedSize }
    func processingTimes() -> (Double, Double, Double) {
        lock.lock(); defer { lock.unlock() }
        guard !timings.isEmpty else { return (processingMilliseconds, 0, 0) }
        processingMilliseconds = timings.reduce(0, +) / Double(timings.count)
        let sorted = timings.sorted()
        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        let gpu = gpuTimings.reduce(0, +) / Double(gpuTimings.count)
        timings.removeAll(keepingCapacity: true); gpuTimings.removeAll(keepingCapacity: true)
        return (processingMilliseconds, gpu, p95)
    }
    func markDropped() { lock.lock(); dropped += 1; lock.unlock() }
    func setLevel(_ value: Float) { lock.lock(); level = value; lock.unlock() }
    func statistics() -> (Int, Int, Int, Float) {
        lock.lock(); defer { lock.unlock() }
        let value = (captured, rendered, dropped, level)
        captured = 0; rendered = 0; dropped = 0
        return value
    }
}

final class CaptureManager: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    let frames = LatestVideoFrame()
    @Published private(set) var videoOptions: [CaptureInputOption] = []
    @Published private(set) var audioOptions: [CaptureInputOption] = []
    @Published private(set) var formatOptions: [CaptureFormatOption] = []
    @Published var selectedVideoID: String?
    @Published var selectedAudioID: String?
    @Published var selectedFormatID: Int?
    @Published var selectedFPS = 0
    @Published private(set) var frameRateOptions: [Double] = [0]
    @Published private(set) var selectedFrameRate = 0.0
    @Published var aspectMode: AspectMode = .fit { didSet { UserDefaults.standard.set(aspectMode.rawValue, forKey: "view.aspect") } }
    @Published var picture = PictureSettings() {
        didSet {
            if !applyingPreset && oldValue.colorParameters != picture.colorParameters { selectedColorPreset = nil }
            recorder.setPicture(recordIncludesPicture ? picture : nil)
            // Slider drags fire dozens of times per second; persist once the value settles.
            schedulePicturePersistence()
        }
    }
    @Published private(set) var selectedColorPreset: String? = "自然" {
        didSet { schedulePicturePersistence() }
    }
    @Published var recordIncludesPicture = true { didSet { UserDefaults.standard.set(recordIncludesPicture, forKey: "record.picture") } }
    @Published var showsStatusBar = true { didSet { UserDefaults.standard.set(showsStatusBar, forKey: "view.statusBar") } }
    private var applyingPreset = false
    private var picturePersistWork: DispatchWorkItem?
    @Published private(set) var deviceName = "未连接"
    @Published private(set) var resolution = "—"
    @Published private(set) var pixelFormat = "—"
    @Published private(set) var measuredFPS = 0
    @Published private(set) var renderedFPS = 0
    @Published private(set) var droppedFrames = 0
    @Published private(set) var processingMilliseconds = 0.0
    @Published private(set) var gpuMilliseconds = 0.0
    @Published private(set) var processingP95 = 0.0
    @Published private(set) var upscaleEngine = "原始"
    /// Actual size the enhancement stage produced for the latest frame; nil when no scaling ran.
    @Published private(set) var enhancedSize: String?
    @Published private(set) var isRunning = false
    @Published private(set) var isRecording = false
    @Published private(set) var recordingStartedAt: Date?
    private(set) var recordingError: String?
    @Published private(set) var recordingVideoDrops = 0
    @Published private(set) var recordingAudioDrops = 0
    @Published private(set) var statusMessage: String? {
        didSet { statusDismissal?.cancel(); statusDismissal = nil }
    }
    @Published private(set) var permissionDenied = false
    @Published private(set) var cameraPermissionPending = false
    @Published private(set) var audioVolume: Float = 0.8
    @Published private(set) var isMuted = false
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var audioStatus = "未连接音频"

    private let sessionQueue = DispatchQueue(label: "dev.moniview.capture", qos: .userInitiated)
    private let videoQueue = DispatchQueue(label: "dev.moniview.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "dev.moniview.audio", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let audioPreview = AVCaptureAudioPreviewOutput()
    private let recorder = CaptureRecorder()
    private var statsTimer: DispatchSourceTimer?
    private var displaySleepToken: NSObjectProtocol?
    /// Audio-callback queue only: last time the meter level was published to the UI.
    private var lastLevelPublish = 0.0
    /// Audio-callback queue only: loudest sample since the last publish.
    private var audioLevelPeak: Float = 0
    private var statusDismissal: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []
    // Session configuration state is accessed only on sessionQueue.
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var selectedDevice: AVCaptureDevice?
    private var requestedFrameRate = 0.0
    private var configuredFrameDuration = CMTime.invalid
    private var lastStatsTime = ProcessInfo.processInfo.systemUptime
    private var diagnosticTick = 0
    private var recordingFinished: (() -> Void)?
    private var discoveryRetryCount = 0
    private var discoveryRetryScheduled = false
    private var isSwitchingVideoDevice = false
    private var pendingAudioDeviceID: String?
    // Requests originate on main; queued work and its result both check this synchronized token.
    // Never hold its lock while configuring a device, starting a session or publishing UI state.
    private let videoConfiguration = ConfigurationRevision()

    override init() {
        super.init()
        let savedPreset = UserDefaults.standard.string(forKey: "view.colorPreset")
        if let data = UserDefaults.standard.data(forKey: "view.picture"), let saved = try? JSONDecoder().decode(PictureSettings.self, from: data) {
            applyingPreset = true; picture = saved; applyingPreset = false
            selectedColorPreset = savedPreset == "自定义" ? nil : (savedPreset ?? "自然")
        }
        if UserDefaults.standard.object(forKey: "record.picture") != nil { recordIncludesPicture = UserDefaults.standard.bool(forKey: "record.picture") }
        if UserDefaults.standard.object(forKey: "view.statusBar") != nil { showsStatusBar = UserDefaults.standard.bool(forKey: "view.statusBar") }
        if let raw = UserDefaults.standard.string(forKey: "view.aspect"), let saved = AspectMode(rawValue: raw) { aspectMode = saved }
        if UserDefaults.standard.object(forKey: "audio.volume") != nil { audioVolume = UserDefaults.standard.float(forKey: "audio.volume") }
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
        audioPreview.volume = audioVolume
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            if self.session.canAddOutput(self.videoOutput) { self.session.addOutput(self.videoOutput) }
            if self.session.canAddOutput(self.audioOutput) { self.session.addOutput(self.audioOutput) }
            if self.session.canAddOutput(self.audioPreview) { self.session.addOutput(self.audioPreview) }
            self.session.commitConfiguration()
        }
        // The Swift constant names changed in newer SDKs; the notification names are stable.
        for name in [Notification.Name("AVCaptureDeviceWasConnectedNotification"), Notification.Name("AVCaptureDeviceWasDisconnectedNotification")] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refreshDevices(force: false) })
        }
        observers.append(NotificationCenter.default.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: .main) { [weak self] note in
            guard let self else { return }
            if self.isRecording { self.stopRecording() }
            self.statusMessage = (note.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription ?? "采集发生错误，请重新连接设备。"
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            // Re-read authorization so granting access in System Settings takes effect without a relaunch.
            self?.refreshDevices(force: false)
        })
        startStatsTimer()
        requestInitialPermission()
    }

    deinit {
        statsTimer?.cancel()
        statusDismissal?.cancel()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private static func devices(_ media: AVMediaType) -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: media == .video ? [.external, .builtInWideAngleCamera] : [.microphone], mediaType: media, position: .unspecified).devices
    }

    func refreshDevices(force: Bool = true) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            permissionDenied = false
        case .notDetermined:
            cameraPermissionPending = true
            return
        default:
            permissionDenied = true
            return
        }
        let videos = Self.devices(.video)
        let audios = Self.devices(.audio)
        if !videos.isEmpty { discoveryRetryCount = 0 }
        else if !isRecording && !discoveryRetryScheduled && discoveryRetryCount < 5 {
            // UVC providers can finish initializing after the initial discovery snapshot.
            discoveryRetryCount += 1
            discoveryRetryScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self else { return }
                self.discoveryRetryScheduled = false
                if self.videoOptions.isEmpty && !self.isRecording && !self.permissionDenied { self.refreshDevices(force: false) }
            }
        }
        if isRecording {
            let videoDisconnected = !videos.contains(where: { $0.uniqueID == selectedVideoID })
            let audioDisconnected = selectedAudioID.map { id in !audios.contains(where: { $0.uniqueID == id }) } ?? false
            if videoDisconnected || audioDisconnected {
                stopRecording()
                statusMessage = videoDisconnected ? "视频设备断开，正在保存录制。" : "音频设备断开，正在保存录制。"
            } else if force { statusMessage = "停止录制后可更换设备。" }
            return
        }
        videoOptions = videos.map { CaptureInputOption(id: $0.uniqueID, name: $0.localizedName) }
        audioOptions = audios.map { CaptureInputOption(id: $0.uniqueID, name: $0.localizedName) }
        if let id = selectedAudioID, !audios.contains(where: { $0.uniqueID == id }) { selectAudioDevice(id: nil, persist: false) }
        if let id = selectedVideoID, videos.contains(where: { $0.uniqueID == id }) {
            if force { selectVideoDevice(id: id) }
            restoreSavedAudioIfNeeded(audios: audios)
            return
        }
        // Prefer a USB capture device over Continuity Camera.
        let preferredID = UserDefaults.standard.string(forKey: "device.lastVideo")
        selectVideoDevice(id: videos.first(where: { $0.uniqueID == preferredID })?.uniqueID ?? videos.first(where: { $0.transportType == 0x75736220 })?.uniqueID)
    }

    func selectVideoDevice(id: String?) {
        guard !isRecording else { statusMessage = "停止录制后可更换设备。"; return }
        let previouslyPaired = UserDefaults.standard.string(forKey: "audio.selection") == nil || audioOptions.first(where: { $0.id == selectedAudioID })?.name == deviceName
        selectedVideoID = id
        // Invalidate the previous device's format list immediately; its indices are not valid for the new device.
        formatOptions = []
        selectedFormatID = nil
        frameRateOptions = [0]
        selectedFrameRate = 0
        selectedFPS = 0
        isSwitchingVideoDevice = true
        let generation = videoConfiguration.advance()
        if let id { UserDefaults.standard.set(id, forKey: "device.lastVideo") }
        frames.clear()
        let device = Self.devices(.video).first { $0.uniqueID == id }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.videoConfiguration.isCurrent(generation) else { return }
            self.session.beginConfiguration()
            do {
                if let device {
                    if let old = self.videoInput { self.session.removeInput(old); self.videoInput = nil }
                    self.selectedDevice = nil
                    self.configuredFrameDuration = .invalid
                    let input = try AVCaptureDeviceInput(device: device)
                    guard self.session.canAddInput(input) else { throw CaptureFailure.message("无法连接视频设备。") }
                    self.session.addInput(input)
                    self.videoInput = input
                    self.selectedDevice = device
                    let options = Self.formatChoices(for: device)
                    let saved = UserDefaults.standard.dictionary(forKey: "device.format.\(device.uniqueID)")
                    let preferred = options.first { $0.width == saved?["width"] as? Int && $0.height == saved?["height"] as? Int }
                        ?? options.first { $0.width == 1920 && $0.height == 1080 && $0.supportsFPS(60) }
                        ?? options.first { $0.width == 1280 && $0.height == 720 && $0.supportsFPS(60) }
                        ?? options.first
                    let savedFPS = saved?["fps"] as? Double ?? 0
                    let desiredFPS = preferred?.supportsFrameRate(savedFPS) == true ? savedFPS : 0
                    self.requestedFrameRate = desiredFPS
                    if let preferred { try self.configureFormat(device, index: preferred.id, fps: desiredFPS) }
                    self.session.commitConfiguration()
                    self.configureConnectionTiming()
                    if !self.session.isRunning { self.session.startRunning() }
                    self.configureConnectionTiming()
                    let dim = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
                    DispatchQueue.main.async {
                        // A newer switch superseded this one; do not publish stale state.
                        guard self.videoConfiguration.isCurrent(generation) else { return }
                        self.deviceName = device.localizedName
                        self.resolution = "\(dim.width) × \(dim.height)"
                        self.pixelFormat = Self.fourCC(CMFormatDescriptionGetMediaSubType(device.activeFormat.formatDescription))
                        self.formatOptions = options
                        self.selectedFormatID = preferred?.id
                        self.selectedFPS = Int(desiredFPS.rounded())
                        self.selectedFrameRate = desiredFPS
                        self.frameRateOptions = Self.frameRates(for: device)
                        self.isSwitchingVideoDevice = false
                        self.statusMessage = nil
                        self.autoSelectAudio(for: device, replacePair: previouslyPaired)
                    }
                } else {
                    if let old = self.videoInput { self.session.removeInput(old); self.videoInput = nil }
                    self.selectedDevice = nil
                    self.configuredFrameDuration = .invalid
                    self.session.commitConfiguration()
                    self.session.stopRunning()
                    DispatchQueue.main.async {
                        guard self.videoConfiguration.isCurrent(generation) else { return }
                        self.deviceName = "未连接"; self.resolution = "—"; self.pixelFormat = "—"
                        self.formatOptions = []; self.selectedFormatID = nil
                        self.frameRateOptions = [0]; self.selectedFrameRate = 0; self.selectedFPS = 0
                        self.isSwitchingVideoDevice = false
                        self.isRunning = false
                        self.selectAudioDevice(id: nil, persist: false)
                    }
                }
            } catch {
                // Roll back to a consistent state: no video input, no stale device identity.
                if let old = self.videoInput { self.session.removeInput(old); self.videoInput = nil }
                self.selectedDevice = nil
                self.configuredFrameDuration = .invalid
                self.session.commitConfiguration()
                DispatchQueue.main.async {
                    guard self.videoConfiguration.isCurrent(generation) else { return }
                    self.deviceName = "未连接"; self.resolution = "—"; self.pixelFormat = "—"
                    self.formatOptions = []; self.selectedFormatID = nil
                    self.frameRateOptions = [0]; self.selectedFrameRate = 0; self.selectedFPS = 0
                    self.isSwitchingVideoDevice = false
                    self.isRunning = false
                    self.statusMessage = L10n.format("连接失败：%@", error.localizedDescription)
                }
            }
        }
    }

    /// Reconnect the user's saved audio input when it reappears while video stays connected.
    private func restoreSavedAudioIfNeeded(audios: [AVCaptureDevice]) {
        guard !isRecording, let saved = UserDefaults.standard.string(forKey: "audio.selection"), saved != "off" else { return }
        guard selectedAudioID != saved, audios.contains(where: { $0.uniqueID == saved }) else { return }
        selectAudioDevice(id: saved, persist: false)
    }

    private func autoSelectAudio(for device: AVCaptureDevice, replacePair: Bool) {
        // An explicit user choice wins: "off" stays off, a saved device is reselected when present.
        if let saved = UserDefaults.standard.string(forKey: "audio.selection") {
            if saved == "off" { selectAudioDevice(id: nil, persist: false) }
            else if Self.devices(.audio).contains(where: { $0.uniqueID == saved }) { selectAudioDevice(id: saved, persist: false) }
            return
        }
        guard replacePair || selectedAudioID == nil else { return }
        let audios = Self.devices(.audio)
        let matched = audios.first { $0.localizedName == device.localizedName }
            ?? audios.first { $0.transportType == 0x75736220 && ($0.localizedName.localizedCaseInsensitiveContains(device.localizedName) || device.localizedName.localizedCaseInsensitiveContains($0.localizedName)) }
        if let matched { selectAudioDevice(id: matched.uniqueID, persist: false) }
        else { selectAudioDevice(id: nil, persist: false); audioStatus = "未找到采集卡音频，请在设置中选择" }
    }

    /// Only the settings picker persists the choice; internal pairing and cleanup stay implicit.
    func selectAudioDevice(id: String?, persist: Bool = false) {
        guard !isRecording else { statusMessage = "停止录制后可更换音频。"; return }
        selectedAudioID = id
        if persist { UserDefaults.standard.set(id ?? "off", forKey: "audio.selection") }
        guard let id else { configureAudioInput(id: nil); return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: configureAudioInput(id: id)
        case .notDetermined:
            audioStatus = "等待麦克风权限"
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self, self.selectedAudioID == id else { return }
                    // Never reconfigure the session while a recording is in progress.
                    if granted { if self.isRecording { self.pendingAudioDeviceID = id } else { self.configureAudioInput(id: id) } }
                    else { self.audioStatus = "需要麦克风权限"; self.statusMessage = "请在系统设置 › 隐私与安全性 › 麦克风中允许 MoniView。" }
                }
            }
        default:
            audioStatus = "需要麦克风权限"
            statusMessage = "请在系统设置中允许 MoniView 访问麦克风，才能播放采集卡声音。"
        }
    }

    private func configureAudioInput(id: String?) {
        guard !isRecording else { pendingAudioDeviceID = id; return }
        let device = Self.devices(.audio).first { $0.uniqueID == id }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            if let old = self.audioInput { self.session.removeInput(old); self.audioInput = nil }
            do {
                if let device {
                    let input = try AVCaptureDeviceInput(device: device)
                    guard self.session.canAddInput(input) else { throw CaptureFailure.message("无法连接音频输入。") }
                    self.session.addInput(input); self.audioInput = input
                }
                // Adding an audio input may renegotiate video. Reassert the precise device timing.
                if let video = self.selectedDevice { try self.configureFormat(video, index: video.formats.firstIndex(of: video.activeFormat) ?? 0, fps: self.requestedFrameRate) }
                self.session.commitConfiguration()
                self.configureConnectionTiming()
                DispatchQueue.main.async {
                    self.audioStatus = device == nil ? "未连接音频" : "实时监听中"
                    if device == nil { self.audioLevel = 0 }
                    self.statusMessage = nil
                }
            } catch {
                self.session.commitConfiguration()
                self.configureConnectionTiming()
                DispatchQueue.main.async { self.audioStatus = "音频连接失败"; self.statusMessage = error.localizedDescription }
            }
        }
    }

    func setAudioVolume(_ volume: Float) {
        audioVolume = min(1, max(0, volume))
        UserDefaults.standard.set(audioVolume, forKey: "audio.volume")
        updateAudioVolume()
    }
    func setMuted(_ muted: Bool) { isMuted = muted; updateAudioVolume() }
    private func updateAudioVolume() {
        let volume = isMuted ? 0 : audioVolume
        sessionQueue.async { [weak self] in self?.audioPreview.volume = volume }
    }

    func selectFormat(id: Int?) {
        guard !isRecording else { statusMessage = "停止录制后可更改格式。"; return }
        guard let id else { return }
        let option = formatOptions.first { $0.id == id }
        applyFormat(index: id, fps: option?.supportsFrameRate(selectedFrameRate) == true ? selectedFrameRate : 0)
    }
    func selectFrameRate(_ fps: Int) { selectFrameRateValue(Double(fps)) }
    func selectFrameRateValue(_ fps: Double) {
        guard !isRecording else { statusMessage = "停止录制后可更改帧率。"; return }
        guard let selectedFormatID else { return }
        applyFormat(index: selectedFormatID, fps: fps)
    }
    private func applyFormat(index: Int, fps: Double) {
        let generation = videoConfiguration.advance()
        sessionQueue.async { [weak self] in
            guard let self, let device = self.selectedDevice else { return }
            guard self.videoConfiguration.isCurrent(generation) else { return }
            self.session.beginConfiguration()
            do {
                try self.configureFormat(device, index: index, fps: fps)
                self.session.commitConfiguration()
                self.configureConnectionTiming()
                self.requestedFrameRate = fps
                self.publishFormat(device: device, index: index, fps: fps, generation: generation)
            } catch {
                self.session.commitConfiguration()
                DispatchQueue.main.async {
                    guard self.videoConfiguration.isCurrent(generation) else { return }
                    self.statusMessage = error.localizedDescription
                }
            }
        }
    }

    private func publishFormat(device: AVCaptureDevice, index: Int, fps: Double, generation: UInt64) {
        let format = device.activeFormat
        let dim = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let options = Self.frameRates(for: device)
        let pixel = Self.fourCC(CMFormatDescriptionGetMediaSubType(format.formatDescription))
        UserDefaults.standard.set(["width": Int(dim.width), "height": Int(dim.height), "fps": fps], forKey: "device.format.\(device.uniqueID)")
        DispatchQueue.main.async {
            // Ignore a result that a newer switch already superseded.
            guard self.videoConfiguration.isCurrent(generation) else { return }
            self.selectedFormatID = self.formatOptions.first { $0.width == Int(dim.width) && $0.height == Int(dim.height) }?.id ?? index
            self.selectedFPS = Int(fps.rounded()); self.selectedFrameRate = fps
            self.frameRateOptions = options
            self.resolution = "\(dim.width) × \(dim.height)"; self.pixelFormat = pixel; self.statusMessage = nil
        }
    }
    private static func frameRates(for format: AVCaptureDevice.Format) -> [Double] {
        var values = Set<Double>()
        for range in format.videoSupportedFrameRateRanges {
            if abs(range.minFrameRate - range.maxFrameRate) < 0.01 {
                values.insert((range.maxFrameRate * 100).rounded() / 100)
            } else {
                for value in [24.0, 25, 29.97, 30, 50, 59.94, 60, 90, 120, range.minFrameRate, range.maxFrameRate] where value >= range.minFrameRate && value <= range.maxFrameRate {
                    values.insert((value * 100).rounded() / 100)
                }
            }
        }
        return [0] + values.sorted()
    }

    private static func frameRates(for device: AVCaptureDevice) -> [Double] {
        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let values = device.formats.filter {
            let size = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            return size.width == dimensions.width && size.height == dimensions.height
        }.flatMap { frameRates(for: $0) }
        return Set(values).sorted()
    }

    private func configureFormat(_ device: AVCaptureDevice, index: Int, fps: Double) throws {
        guard device.formats.indices.contains(index) else { throw CaptureFailure.message("格式已失效，请刷新设备。") }
        let selected = device.formats[index]
        let size = CMVideoFormatDescriptionGetDimensions(selected.formatDescription)
        let compatible = device.formats.filter {
            let dims = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            return dims.width == size.width && dims.height == size.height
        }
        let matches: (AVCaptureDevice.Format) -> Bool = { format in
            fps == 0 || format.videoSupportedFrameRateRanges.contains { $0.minFrameRate - 0.01 <= fps && $0.maxFrameRate + 0.01 >= fps }
        }
        let format = matches(selected) ? selected : compatible.first(where: matches) ?? selected
        let ranges = format.videoSupportedFrameRateRanges
        let target = fps == 0 ? (ranges.map(\.maxFrameRate).max() ?? 30) : fps
        guard let range = ranges.first(where: { $0.minFrameRate - 0.01 <= target && $0.maxFrameRate + 0.01 >= target })
            ?? (fps == 0 ? ranges.max(by: { $0.maxFrameRate < $1.maxFrameRate }) : nil) else {
            throw CaptureFailure.message(L10n.format("这个分辨率不支持 %.2f FPS，请选择其他格式。", fps))
        }
        // UVC rates are often 60.00024 / 30.00003, not exact integers. Use the advertised duration.
        let duration: CMTime
        if abs(range.maxFrameRate - target) < 0.01 { duration = range.minFrameDuration }
        else if abs(range.minFrameRate - target) < 0.01 { duration = range.maxFrameDuration }
        else { duration = CMTime(seconds: 1 / target, preferredTimescale: 1_000_000) }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.activeFormat = format
        let supported = videoOutput.availableVideoPixelFormatTypes
        let preferences: [OSType] = [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_32BGRA, kCVPixelFormatType_422YpCbCr8, kCVPixelFormatType_422YpCbCr8_yuvs]
        guard let outputType = preferences.first(where: { supported.contains($0) }) else {
            throw CaptureFailure.message("设备没有提供可用于预览的像素格式。")
        }
        // Request only the pixel format: explicit dimensions would force a scaling/conversion pass.
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: outputType]
        // Output negotiation may reset the device's interval. Apply timing afterwards.
        try Self.setDuration(duration, on: device)
        configuredFrameDuration = duration
    }

    private func configureConnectionTiming() {
        guard let device = selectedDevice, let connection = videoOutput.connection(with: .video) else { return }
        let duration = configuredFrameDuration.isValid ? configuredFrameDuration : device.activeVideoMinFrameDuration
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            try Self.setDuration(duration, on: device)
        } catch {
            DispatchQueue.main.async { self.statusMessage = error.localizedDescription }
            return
        }
        if connection.isVideoMinFrameDurationSupported { connection.videoMinFrameDuration = duration }
        if connection.isVideoMaxFrameDurationSupported { connection.videoMaxFrameDuration = duration }
    }

    private static func setDuration(_ duration: CMTime, on device: AVCaptureDevice) throws {
        let seconds = duration.seconds
        guard duration.isValid, seconds.isFinite, seconds > 0,
              device.activeFormat.videoSupportedFrameRateRanges.contains(where: {
                  seconds >= $0.minFrameDuration.seconds - 0.0000001 && seconds <= $0.maxFrameDuration.seconds + 0.0000001
              }) else { throw CaptureFailure.message("格式已失效，请刷新设备。") }
        if duration < device.activeVideoMinFrameDuration {
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
        } else {
            device.activeVideoMaxFrameDuration = duration
            device.activeVideoMinFrameDuration = duration
        }
    }

    func applyPreset(_ name: String) {
        var next = picture
        switch name {
        case "鲜艳": next.brightness = 0; next.contrast = 1.025; next.saturation = 1.07; next.vibrance = 0.08; next.highlightRecovery = 0.08
        case "电影": next.brightness = 0; next.contrast = 1.0; next.saturation = 0.96; next.vibrance = 0; next.highlightRecovery = 0.16
        default: next.brightness = 0; next.contrast = 1; next.saturation = 1; next.vibrance = 0; next.highlightRecovery = 0
        }
        applyingPreset = true
        picture = next
        selectedColorPreset = name
        applyingPreset = false
    }

    func startRecording(to url: URL) {
        guard isRunning, !isRecording else { return }
        isRecording = true
        recordingStartedAt = Date()
        recordingError = nil
        recordingVideoDrops = 0; recordingAudioDrops = 0
        statusMessage = "正在录制…"
        recorder.setPicture(recordIncludesPicture ? picture : nil)
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard let video = self.selectedDevice else {
                DispatchQueue.main.async {
                    self.isRecording = false; self.recordingStartedAt = nil; self.recordingError = L10n.text("视频设备已断开。")
                    self.statusMessage = L10n.format("录制失败：%@", self.recordingError!)
                    self.recordingFinished?(); self.recordingFinished = nil
                }
                return
            }
            let dims = CMVideoFormatDescriptionGetDimensions(video.activeFormat.formatDescription)
            let audioDesc = self.audioInput?.device.activeFormat.formatDescription
            let asbd = audioDesc.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
            let frameInterval = video.activeVideoMinFrameDuration.seconds
            // Devices without a valid frame duration would otherwise trap on Int(NaN).
            let recordingFPS = frameInterval.isFinite && frameInterval > 0 ? 1 / frameInterval : 60
            self.recorder.start(url: url, width: Int(dims.width), height: Int(dims.height), fps: recordingFPS, audio: asbd) { [weak self] error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    let drops = self.recorder.droppedSamples()
                    self.recordingVideoDrops = drops.video; self.recordingAudioDrops = drops.audio
                    self.isRecording = false
                    self.recordingStartedAt = nil
                    self.refreshDevices(force: false)
                    let warning = drops.video + drops.audio > 0 ? L10n.format(" · 录制丢弃视频 %d 帧 / 音频 %d 包", drops.video, drops.audio) : ""
                    self.recordingError = error?.localizedDescription
                    self.statusMessage = error.map { L10n.format("录制失败：%@", $0.localizedDescription) } ?? L10n.format("已保存到 %@%@", url.lastPathComponent, warning)
                    if error == nil && drops.video == 0 && drops.audio == 0 {
                        let dismiss = DispatchWorkItem { [weak self] in self?.statusMessage = nil }
                        self.statusDismissal = dismiss
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: dismiss)
                    }
                    // Apply an audio device change that was deferred to avoid reconfiguring a live recording.
                    if let pending = self.pendingAudioDeviceID {
                        self.pendingAudioDeviceID = nil
                        self.selectedAudioID = pending
                        self.configureAudioInput(id: pending)
                    }
                    let finished = self.recordingFinished; self.recordingFinished = nil; finished?()
                }
            }
        }
    }
    func stopRecording() { sessionQueue.async { [weak self] in self?.recorder.stop() } }

    /// AppKit delays process termination until MOV finalization completes.
    func finishRecordingBeforeExit(_ completion: @escaping () -> Void) {
        guard isRecording else { completion(); return }
        recordingFinished = completion
        stopRecording()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === videoOutput, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            frames.put(buffer)
            recorder.append(sampleBuffer, video: true)
        } else if output === audioOutput {
            let power = connection.audioChannels.map(\.averagePowerLevel).max() ?? -160
            let level = power <= -80 ? 0 : min(1, pow(10, power / 20))
            frames.setLevel(level)
            audioLevelPeak = max(audioLevelPeak, level)
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastLevelPublish >= 0.12 {
                lastLevelPublish = now
                let peak = audioLevelPeak
                audioLevelPeak = 0
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    // Instant attack, gentle decay so the meter reads like a real level meter.
                    self.audioLevel = max(peak, self.audioLevel * 0.75)
                }
            }
            recorder.append(sampleBuffer, video: false)
        }
    }
    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) { frames.markDropped() }

    private func requestInitialPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: refreshDevices()
        case .notDetermined:
            cameraPermissionPending = true
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.cameraPermissionPending = false
                    self?.permissionDenied = !granted
                    if granted { self?.refreshDevices() }
                }
            }
        default: permissionDenied = true
        }
    }
    private func startStatsTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.recorder.checkFailure()
            if self.isRecording {
                let drops = self.recorder.droppedSamples()
                self.recordingVideoDrops = drops.video; self.recordingAudioDrops = drops.audio
                if drops.video > 5 || drops.audio > 0 {
                    self.statusMessage = L10n.format("录制过载：视频丢帧 %d / 音频丢包 %d，可降低录制分辨率或关闭增强。", drops.video, drops.audio)
                }
            }
            let now = ProcessInfo.processInfo.systemUptime
            let elapsed = now - self.lastStatsTime
            self.lastStatsTime = now
            let stats = self.frames.statistics()
            self.measuredFPS = Int((Double(stats.0) / elapsed).rounded())
            self.renderedFPS = Int((Double(stats.1) / elapsed).rounded())
            self.droppedFrames = stats.2
            let times = self.frames.processingTimes()
            self.processingMilliseconds = times.0
            self.gpuMilliseconds = times.1
            self.processingP95 = times.2
            self.upscaleEngine = self.frames.currentEngine()
            self.enhancedSize = self.frames.currentEnhancedSize()
            self.isRunning = stats.0 > 0
            self.updatePowerAssertions()
            self.diagnosticTick += 1
            if self.diagnosticTick % 5 == 0, self.isRunning || self.isRecording { self.writeDiagnostics() }
        }
        timer.resume(); statsTimer = timer
    }
    private func schedulePicturePersistence() {
        picturePersistWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushPicturePersistence() }
        picturePersistWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Persist parameters and the preset name together so a quick quit never splits them.
    func flushPicturePersistence() {
        picturePersistWork?.cancel()
        picturePersistWork = nil
        if let data = try? JSONEncoder().encode(picture) { UserDefaults.standard.set(data, forKey: "view.picture") }
        UserDefaults.standard.set(selectedColorPreset ?? "自定义", forKey: "view.colorPreset")
    }

    /// Game and camera monitoring runs for long stretches without keyboard or mouse input;
    /// keep the display awake while a signal is being previewed.
    private func updatePowerAssertions() {
        if isRunning && displaySleepToken == nil {
            displaySleepToken = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .userInitiated], reason: "Live capture preview")
        } else if !isRunning, let token = displaySleepToken {
            ProcessInfo.processInfo.endActivity(token)
            displaySleepToken = nil
        }
    }
    private func writeDiagnostics() {
        var payload: [String: Any] = ["date": ISO8601DateFormatter().string(from: Date()), "device": deviceName, "resolution": resolution, "captureFPS": measuredFPS, "renderFPS": renderedFPS, "droppedFrames": droppedFrames, "pixelFormat": pixelFormat, "audioDevice": audioOptions.first { $0.id == selectedAudioID }?.name ?? "none", "audioLevel": audioLevel, "audioStatus": audioStatus, "muted": isMuted, "volume": audioVolume]
        if let (buffer, _, _) = frames.latest() {
            payload["bufferWidth"] = CVPixelBufferGetWidth(buffer)
            payload["bufferHeight"] = CVPixelBufferGetHeight(buffer)
            payload["bufferPixelFormat"] = Self.fourCC(CVPixelBufferGetPixelFormatType(buffer))
        }
        payload["softwareProcessingMS"] = processingMilliseconds
        payload["softwareP95MS"] = processingP95
        payload["gpuMS"] = gpuMilliseconds
        payload["lowLatency"] = picture.lowLatency
        payload["enhancementEnabled"] = picture.enhancementEnabled
        payload["enhancementTarget"] = picture.upscaleTarget.rawValue
        payload["upscaleEngine"] = upscaleEngine
        let snapshot = payload
        sessionQueue.async { [weak self] in
        guard let self else { return }
        var payload = snapshot
        if let device = self.selectedDevice {
            payload["configuredDeviceFPS"] = 1 / device.activeVideoMinFrameDuration.seconds
            payload["deviceMaxDuration"] = device.activeVideoMaxFrameDuration.seconds
        }
        if let connection = self.videoOutput.connection(with: .video) {
            payload["connectionMinDuration"] = connection.videoMinFrameDuration.seconds.isFinite ? connection.videoMinFrameDuration.seconds : 0
            payload["connectionMaxDuration"] = connection.videoMaxFrameDuration.seconds.isFinite ? connection.videoMaxFrameDuration.seconds : 0
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else { return }
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/MoniView", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent("diagnostics.json"), options: .atomic)
        }
    }
    private static func formatChoices(for device: AVCaptureDevice) -> [CaptureFormatOption] {
        var best: [String: CaptureFormatOption] = [:]
        for (index, format) in device.formats.enumerated() {
            let dim = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let ranges = format.videoSupportedFrameRateRanges
            guard dim.width > 0, dim.height > 0, !ranges.isEmpty else { continue }
            let option = CaptureFormatOption(id: index, width: Int(dim.width), height: Int(dim.height), minimumFPS: Int((ranges.map(\.minFrameRate).min() ?? 1).rounded()), maximumFPS: Int((ranges.map(\.maxFrameRate).max() ?? 30).rounded()), rates: ranges.map { $0.minFrameRate...$0.maxFrameRate })
            let key = "\(dim.width)x\(dim.height)"
            let nativeNV12 = CMFormatDescriptionGetMediaSubType(format.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            if let previous = best[key] {
                let preferNew = option.maximumFPS > previous.maximumFPS || (option.maximumFPS == previous.maximumFPS && nativeNV12)
                best[key] = CaptureFormatOption(id: preferNew ? option.id : previous.id, width: option.width, height: option.height,
                    minimumFPS: min(previous.minimumFPS, option.minimumFPS), maximumFPS: max(previous.maximumFPS, option.maximumFPS),
                    rates: previous.rates + option.rates)
            } else { best[key] = option }
        }
        return best.values.sorted { $0.width * $0.height > $1.width * $1.height }
    }
    private static func fourCC(_ value: FourCharCode) -> String {
        String(bytes: [UInt8((value >> 24) & 255), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)], encoding: .ascii) ?? "—"
    }
}

enum CaptureFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return L10n.text(text) }; return nil }
}
