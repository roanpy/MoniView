import AppKit
import CoreVideo
import SwiftUI
import UniformTypeIdentifiers

private enum PanelKind: String, Hashable {
    case information
    case clarity
    case color
    case settings
}

struct MainView: View {
    @EnvironmentObject private var capture: CaptureManager
    @State private var activePanel: PanelKind?
    @State private var showInformation = false
    @State private var expandedInformation = false
    @State private var isFullscreen = false
    @State private var fullscreenControlsVisible = true
    @State private var controlsHideWorkItem: DispatchWorkItem?

    var body: some View {
        ZStack {
            if isFullscreen {
                Color.black.ignoresSafeArea()
            } else {
                LinearGradient(
                    colors: [Color(hex: 0x272321), Color(hex: 0x191817), Color(hex: 0x211e1a)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
            }

            VStack(spacing: 0) {
                if !isFullscreen {
                    header
                        .padding(.horizontal, 18)
                        .padding(.top, 9)
                        .padding(.bottom, 7)
                }

                previewArea
                    .padding(.horizontal, isFullscreen ? 0 : 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .ignoresSafeArea(edges: isFullscreen ? .all : [])

            quickControls
                .padding(.bottom, isFullscreen ? 26 : 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .opacity(!isFullscreen || fullscreenControlsVisible ? 1 : 0)
                .allowsHitTesting(!isFullscreen || fullscreenControlsVisible)
                .animation(.easeInOut(duration: 0.2), value: fullscreenControlsVisible)
        }
        .overlay(alignment: .bottom) {
            if let activePanel {
                panelContent(activePanel)
                    .padding(16)
                    .frame(width: activePanel == .settings ? 365 : 330)
                    .background(Color(hex: 0x24201c).opacity(0.92), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 0.7))
                    .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
                    .padding(.bottom, isFullscreen ? 98 : 82)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeOut(duration: 0.18), value: activePanel)
        .background(Color(hex: 0x1d1b19))
        .background {
            WindowFullscreenObserver(isFullscreen: $isFullscreen)
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            if case .active = phase {
                revealFullscreenControls()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: fullscreenControlsVisible)
        .onChange(of: isFullscreen) { _, enteredFullscreen in
            controlsHideWorkItem?.cancel()
            if enteredFullscreen {
                fullscreenControlsVisible = true
                scheduleFullscreenControlsHide()
            } else {
                fullscreenControlsVisible = true
                NSCursor.setHiddenUntilMouseMoves(false)
            }
        }
        .onChange(of: activePanel) { _, panel in
            if panel != nil { revealFullscreenControls() }
            else if isFullscreen { scheduleFullscreenControlsHide() }
        }
        .overlay {
            VStack {
                Button("静音") { capture.setMuted(!capture.isMuted) }.keyboardShortcut("m", modifiers: [.command, .shift])
                Button("画面信息") { showInformation.toggle() }.keyboardShortcut("i", modifiers: [.command])
                Button("设置") { activePanel = activePanel == .settings ? nil : .settings }.keyboardShortcut(",", modifiers: [.command])
            }.hidden().accessibilityHidden(true)
        }
        .onExitCommand {
            if activePanel != nil { activePanel = nil }
            else if isFullscreen { NSApp.keyWindow?.toggleFullScreen(nil) }
        }
        .onDisappear {
            controlsHideWorkItem?.cancel()
            NSCursor.setHiddenUntilMouseMoves(false)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LinearGradient(colors: [Color(hex: 0xf5a13a), Color(hex: 0xc56a13)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 30, height: 30)
                Image(systemName: "viewfinder")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x201915))
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("MoniView")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(hex: 0xf4eee7))
            }

            Spacer()

            Button {
                NSApp.keyWindow?.toggleFullScreen(nil)
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(hex: 0xd2c9c0))
                    .frame(width: 30, height: 30)
                    .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .help("进入全屏 · ⌃⌘F")
            .accessibilityLabel("进入全屏")
        }
        .overlay {
            if capture.isRunning && capture.showsStatusBar && !showInformation {
                sourceSummary
                    .frame(maxWidth: 420)
                    .allowsHitTesting(false)
            }
        }
    }

    private var sourceSummary: some View {
        HStack(spacing: 7) {
            Circle().fill(Color(hex: 0x5fd69a)).frame(width: 6, height: 6)
            Text(L10n.text(capture.deviceName)).lineLimit(1).truncationMode(.middle)
            Text("·")
            Text(actualBufferResolution).fixedSize()
            Text("·")
            Text("\(capture.measuredFPS) FPS").fixedSize()
            if capture.picture.enhancementEnabled {
                Text("·")
                Text(enhancementSummary)
                    .fixedSize()
                    .foregroundStyle(Color(hex: 0xec8718))
            }
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .foregroundStyle(Color(hex: 0xe6ddd4))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.black.opacity(isFullscreen ? 0.56 : 0.22), in: Capsule())
    }

    private var enhancementSummary: String {
        if let enhancedSize = capture.enhancedSize {
            return "\(capture.upscaleEngine) \(enhancedSize)"
        }
        return L10n.text("增强")
    }

    private var previewArea: some View {
        ZStack {
            if isFullscreen {
                Color.black
            } else {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(hex: 0x100f10))
            }

            // Keep the preview alive across signal drops and fullscreen transitions so the GPU
            // pipeline is never rebuilt; overlays communicate state instead.
            PreviewLayerView(capture: capture)
                .clipShape(RoundedRectangle(cornerRadius: isFullscreen ? 0 : 17, style: .continuous))
                .padding(isFullscreen ? 0 : 3)
            if !capture.isRunning { waitingForInput }

            VStack {
                HStack(alignment: .top) {
                    if isFullscreen && capture.isRunning && capture.showsStatusBar && !showInformation {
                        sourceSummary
                        .transition(.opacity)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 8) {
                        if capture.isRecording {
                            HStack(spacing: 7) {
                                Circle().fill(Color(hex: 0xff5c46)).frame(width: 7, height: 7)
                                Text("REC")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                if let started = capture.recordingStartedAt {
                                    Text(started, style: .timer)
                                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                                        .monospacedDigit()
                                }
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 8)
                            .background(Color(hex: 0x9e2d20).opacity(0.92), in: Capsule())
                        }
                        if showInformation {
                            informationPanel
                        }
                    }
                }
                Spacer()
                if let message = capture.statusMessage, message != "正在录制…" {
                    HStack(spacing: 8) {
                        Image(systemName: capture.isRecording ? "record.circle" : "info.circle")
                        Text(L10n.text(message)).lineLimit(1)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(hex: 0xf5e5d5))
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(Color.black.opacity(0.72), in: Capsule())
                    .padding(.bottom, 14)
                }
            }
            .padding(isFullscreen ? 20 : 18)
        }
        .overlay {
            if !isFullscreen {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color(hex: 0x65584c).opacity(0.64), lineWidth: 1)
            }
        }
        .shadow(color: .black.opacity(isFullscreen ? 0 : 0.24), radius: isFullscreen ? 0 : 22, y: isFullscreen ? 0 : 12)
        .onTapGesture(count: 2) { NSApp.keyWindow?.toggleFullScreen(nil) }
        .onTapGesture { activePanel = nil; revealFullscreenControls() }
        .accessibilityElement(children: .contain)
    }

    private var waitingForInput: some View {
        VStack(spacing: 13) {
            ZStack {
                Circle().fill(Color(hex: 0xe98921).opacity(0.13)).frame(width: 74, height: 74)
                Image(systemName: capture.permissionDenied ? "video.slash" : "cable.connector")
                    .font(.system(size: 29, weight: .light))
                    .foregroundStyle(Color(hex: 0xf1a447))
            }
            Text(L10n.text(capture.cameraPermissionPending ? "等待摄像头权限" : (capture.permissionDenied ? "需要摄像头权限" : (capture.videoOptions.isEmpty ? "连接 HDMI 采集卡" : (capture.selectedVideoID != nil ? "等待视频信号" : "选择视频输入")))))
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(hex: 0xf2eae2))
            Text(L10n.text(capture.cameraPermissionPending ? "请在系统权限弹窗中允许访问摄像头。" : capture.permissionDenied
                 ? "请在系统设置 › 隐私与安全性 › 摄像头中允许 MoniView。"
                 : (capture.selectedVideoID != nil && !capture.videoOptions.isEmpty
                    ? "采集卡已连接，请确认信号源已开机并输出画面。"
                    : "将采集卡接入 Mac，再把 Switch 或其他 HDMI 设备连接到采集卡。")))
                .font(.system(size: 12))
                .foregroundStyle(Color(hex: 0x9c938b))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if capture.permissionDenied {
                Button("打开系统设置") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(AmberActionButtonStyle())
                .padding(.top, 3)
            } else if !capture.videoOptions.isEmpty {
                Picker("视频输入", selection: Binding(
                    get: { capture.selectedVideoID },
                    set: { capture.selectVideoDevice(id: $0) }
                )) {
                    ForEach(capture.videoOptions) { option in
                        Text(option.name).tag(Optional(option.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 280)
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Cover the last presented frame so a dropped signal never shows a stale image.
        .background((isFullscreen ? Color.black : Color(hex: 0x100f10)).opacity(0.94))
    }

    private var quickControls: some View {
        HStack(spacing: 6) {
            Button(action: toggleRecording) {
                DockButtonFace(icon: capture.isRecording ? "stop.fill" : "record.circle", active: capture.isRecording, primary: true, recording: capture.isRecording)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(!capture.isRunning && !capture.isRecording)
            .opacity(capture.isRunning || capture.isRecording ? 1 : 0.55)
            .help(L10n.text(capture.isRecording ? "停止录制" : "录制画面"))
            .accessibilityLabel(L10n.text(capture.isRecording ? "停止录制" : "录制画面"))

            Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 26).padding(.horizontal, 4)
            panelButton(.information, icon: "waveform.path.ecg", label: "画面信息")
            panelButton(.clarity, icon: "sparkles.tv", label: "画质增强")
            panelButton(.color, icon: "circle.lefthalf.filled", label: "色彩调节")
            panelButton(.settings, icon: "gearshape", label: "设置")
        }
        .padding(7)
        .background(Color(hex: 0x211c18).opacity(0.94), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(LinearGradient(colors: [.white.opacity(0.2), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom), lineWidth: 0.7))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
    }

    @ViewBuilder
    private func panelButton(_ kind: PanelKind, icon: String, label: String) -> some View {
        let selected = kind == .information ? showInformation : activePanel == kind
        let button = Button {
            if kind == .information { showInformation.toggle() }
            else { activePanel = activePanel == kind ? nil : kind }
            revealFullscreenControls()
        } label: {
            DockButtonFace(icon: icon, active: selected)
        }
        .buttonStyle(.plain)
        .help(L10n.text(label))
        .accessibilityLabel(L10n.text(label))

        button
    }

    @ViewBuilder
    private func panelContent(_ kind: PanelKind) -> some View {
        switch kind {
        case .information:
            informationPanel
        case .clarity:
            clarityPanel
        case .color:
            colorPanel
        case .settings:
            settingsPanel
        }
    }

    private var informationPanel: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Circle().fill(capture.isRunning ? Color(hex: 0x5fd69a) : .gray).frame(width: 5, height: 5)
                Text(L10n.text(capture.deviceName)).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
                Button { expandedInformation.toggle() } label: {
                    Image(systemName: expandedInformation ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .semibold))
                }.buttonStyle(.plain).help("展开诊断数据").accessibilityLabel("展开诊断数据")
                Button { showInformation = false } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                }.buttonStyle(.plain).help("关闭画面信息").accessibilityLabel("关闭画面信息")
            }
            HStack(spacing: 17) {
                informationMetric("采集", value: "\(capture.measuredFPS)")
                informationMetric("渲染", value: "\(capture.renderedFPS)")
                informationMetric("丢帧", value: "\(capture.droppedFrames)")
                Spacer(minLength: 0)
            }
            HStack {
                Text(actualBufferResolution)
                Spacer(minLength: 0)
                Text(capture.pixelFormat)
            }.font(.system(size: 10, design: .monospaced)).foregroundStyle(Color(hex: 0xb5aaa0))
            HStack {
                Text(L10n.text(capture.upscaleEngine) + (capture.picture.upscaleTarget == .native ? "" : " · " + L10n.text(capture.picture.upscaleTarget.rawValue)))
                Spacer(minLength: 0)
                Text(String(format: "GPU %.1f ms", capture.gpuMilliseconds))
            }.font(.system(size: 9, design: .monospaced)).foregroundStyle(Color(hex: 0xaaa199))
            if let enhancedSize = capture.enhancedSize {
                Text(L10n.format("实际处理 %@ · 目标上限 %@", enhancedSize, L10n.text(capture.picture.upscaleTarget.rawValue)))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Color(hex: 0xaaa199))
            }
            if expandedInformation {
                Text(L10n.format("回调→GPU %.1f ms · P95 %.1f", capture.processingMilliseconds, capture.processingP95))
                Text(L10n.format("等待/CPU %.1f ms", max(0, capture.processingMilliseconds - capture.gpuMilliseconds)))
                Text(L10n.text(capture.picture.lowLatency ? "低延迟 · 按显示尺寸处理" : "按完整目标尺寸处理"))
                if capture.isRecording || capture.recordingVideoDrops + capture.recordingAudioDrops > 0 {
                    Text(L10n.format("录制丢弃 · 视频 %d / 音频 %d", capture.recordingVideoDrops, capture.recordingAudioDrops))
                }
            }
            HStack(spacing: 6) {
                Button { capture.setMuted(!capture.isMuted) } label: {
                    Image(systemName: capture.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill").foregroundStyle(Color(hex: 0xe9a24d))
                }.buttonStyle(.plain).help("静音监听 · ⌘⇧M")
                Text(L10n.text(capture.isMuted ? "静音" : capture.audioStatus)).lineLimit(1)
                Spacer(minLength: 0)
                ProgressView(value: audioLevelValue).tint(Color(hex: 0xec8718)).frame(width: 35)
            }.font(.system(size: 9))
        }
        .font(.system(size: 9, design: .monospaced))
        .foregroundStyle(Color(hex: 0xe5dcd3))
        .padding(10)
        .frame(width: 218, alignment: .leading)
        .background(Color.black.opacity(0.84), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.1), lineWidth: 0.7))
    }

    private func informationMetric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L10n.text(title))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Color(hex: 0x98908a))
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color(hex: 0xf2eae2))
        }
    }

    private var actualBufferResolution: String {
        guard let (buffer, _, _) = capture.frames.latest() else { return "—" }
        return "\(CVPixelBufferGetWidth(buffer)) × \(CVPixelBufferGetHeight(buffer))"
    }

    private func upscaleTargetTitle(_ target: UpscaleTarget) -> String {
        switch target {
        case .native: return "原始输入"
        case .qhd: return "2K · 2560 px 宽"
        case .uhd: return "4K · 3840 px 宽"
        case .screen: return "匹配屏幕"
        }
    }

    private var clarityPanel: some View {
        VStack(alignment: .leading, spacing: 15) {
            panelHeading("画质增强", subtitle: "实时预览处理", icon: "sparkles.tv")
            VStack(alignment: .leading, spacing: 12) {
                settingsToggle("低延迟模式", isOn: $capture.picture.lowLatency)
                Text("按实际显示尺寸处理，优先保持实时帧率；目标是放大上限。")
                    .font(.system(size: 10)).foregroundStyle(Color(hex: 0x98908a))
                settingsToggle("启用画质增强", isOn: $capture.picture.enhancementEnabled)
                Divider().overlay(Color.white.opacity(0.06))
                labeledSlider("增强强度", value: $capture.picture.enhancementStrength, range: 0...1, format: "%.2f")
                labeledPicker("放大方式", selection: $capture.picture.upscaleMethod,
                    choices: UpscaleMethod.allCases.filter { $0 != .ai || AIUpscalerSupport.isSupported }.map { PickerChoice(value: $0, title: L10n.text($0.rawValue)) })
                    .disabled(!capture.picture.enhancementEnabled)
                labeledPicker("放大目标", selection: $capture.picture.upscaleTarget,
                    choices: UpscaleTarget.allCases.map { PickerChoice(value: $0, title: L10n.text(upscaleTargetTitle($0))) })
                    .disabled(!capture.picture.enhancementEnabled)
                Text("MetalFX 在支持的 GPU 上进行空间放大；否则使用 Lanczos。匹配屏幕按当前显示器的物理像素放大，全屏时与屏幕像素一一对应。不改变采集卡输入分辨率。")
                    .font(.system(size: 10))
                    .foregroundStyle(Color(hex: 0x98908a))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(13)
            .background(Color.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var recordingFreezesColor: Bool { capture.isRecording && capture.recordIncludesPicture }

    private var colorPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            panelHeading("色彩调节", subtitle: L10n.format("当前：%@ · %@", L10n.text(capture.selectedColorPreset ?? "自定义"), L10n.text(capture.recordIncludesPicture ? "预览与录制" : "仅预览")), icon: "circle.lefthalf.filled")
            HStack(spacing: 7) {
                presetButton("自然")
                presetButton("鲜艳")
                presetButton("电影")
            }
            .padding(4)
            .background(Color.black.opacity(0.2), in: Capsule())
            .disabled(recordingFreezesColor)
            VStack(spacing: 13) {
                labeledSlider("高光恢复", value: $capture.picture.highlightRecovery, range: 0...0.5, format: "%.2f")
                labeledSlider("亮度", value: $capture.picture.brightness, range: -0.5...0.5, format: "%+.2f")
                labeledSlider("对比度", value: $capture.picture.contrast, range: 0.5...1.5, format: "%.2f")
                labeledSlider("饱和度", value: $capture.picture.saturation, range: 0...2, format: "%.2f")
                labeledSlider("鲜艳度", value: $capture.picture.vibrance, range: -1...1, format: "%+.2f")
            }
            .padding(13)
            .background(Color.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
            .disabled(recordingFreezesColor)
            if recordingFreezesColor {
                Text("本次录制使用开始时的设置")
                    .font(.system(size: 10))
                    .foregroundStyle(Color(hex: 0x98908a))
            }
        }
    }

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                panelHeading("采集设置", subtitle: "按采集卡支持的格式显示", icon: "gearshape")
                Button {
                    capture.refreshDevices()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(hex: 0xe9a24d))
                        .frame(width: 30, height: 30)
                        .background(Color.white.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)
                .help("刷新采集设备")
            }

            VStack(alignment: .leading, spacing: 11) {
                labeledPicker("视频设备", fieldWidth: 195,
                    selection: Binding(get: { capture.selectedVideoID }, set: { capture.selectVideoDevice(id: $0) }),
                    choices: capture.videoOptions.map { PickerChoice(value: Optional($0.id), title: $0.name) })
                    .disabled(capture.isRecording)
                labeledPicker("音频输入", fieldWidth: 195,
                    selection: Binding(get: { capture.selectedAudioID }, set: { capture.selectAudioDevice(id: $0, persist: true) }),
                    choices: [PickerChoice(value: Optional<String>.none, title: L10n.text("关闭音频输入"))] + capture.audioOptions.map { PickerChoice(value: Optional($0.id), title: $0.name) })
                    .disabled(capture.isRecording)

                audioMonitoringControls

                labeledPicker("分辨率", fieldWidth: 195,
                    selection: Binding(get: { capture.selectedFormatID }, set: { capture.selectFormat(id: $0) }),
                    choices: capture.formatOptions.map { PickerChoice(value: Optional($0.id), title: $0.title) })
                    .disabled(capture.isRecording || capture.formatOptions.isEmpty)

                HStack {
                    Text("帧率")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color(hex: 0xc8bfb7))
                    Spacer()
                    HStack(spacing: 2) {
                        fpsButton(0, title: "自动")
                        fpsButton(30, title: "30")
                        fpsButton(60, title: "60")
                    }
                    .padding(3)
                    .background(Color.black.opacity(0.28), in: Capsule())
                }

                labeledPicker("帧率档位", fieldWidth: 195,
                    selection: Binding(get: { capture.selectedFrameRate }, set: { capture.selectFrameRateValue($0) }),
                    choices: capture.frameRateOptions.map { PickerChoice(value: $0, title: $0 == 0 ? L10n.text("自动") : String(format: "%.2f FPS", $0)) })
                    .disabled(capture.isRecording || capture.formatOptions.isEmpty)
                labeledPicker("画面比例", fieldWidth: 195, selection: $capture.aspectMode,
                    choices: AspectMode.allCases.map { PickerChoice(value: $0, title: L10n.text($0.rawValue)) })
                Text(L10n.text(capture.aspectMode == .stretch ? "铺满窗口，画面比例可能变形。" : (capture.aspectMode == .fill ? "保持比例，裁切超出窗口的部分。" : "保持比例，完整显示画面。")))
                    .font(.system(size: 10))
                    .foregroundStyle(Color(hex: 0x98908a))
            }
            .padding(12)
            .background(Color.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))

            VStack(spacing: 14) {
                settingsToggle("录制预览色彩和锐化", isOn: $capture.recordIncludesPicture)
                    .disabled(capture.isRecording)
                settingsToggle("显示设备状态", isOn: $capture.showsStatusBar)
            }
            .padding(.horizontal, 12)
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                Text("分辨率和帧率受采集卡硬件限制。")
            }
            .font(.system(size: 10))
            .foregroundStyle(Color(hex: 0x98908a))
        }
    }

    private var audioMonitoringControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().overlay(Color.white.opacity(0.06))

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("声音监听")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(hex: 0xe6ddd4))
                    Text(L10n.text(capture.audioStatus))
                        .font(.system(size: 10))
                        .foregroundStyle(Color(hex: 0x98908a))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Text("\(Int(capture.audioVolume * 100))%")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color(hex: 0xc8bfb7))
            }

            Slider(value: Binding(
                get: { Double(capture.audioVolume) },
                set: { capture.setAudioVolume(Float($0)) }
            ), in: 0...1)
            .tint(Color(hex: 0xec8718))
            .accessibilityLabel(L10n.text("声音监听"))
            .accessibilityValue("\(Int(capture.audioVolume * 100))%")

            HStack(spacing: 8) {
                Toggle(isOn: Binding(
                    get: { capture.isMuted },
                    set: { capture.setMuted($0) }
                )) {
                    Text("静音监听")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color(hex: 0xc8bfb7))
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                Spacer(minLength: 4)
                Text("电平")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color(hex: 0x98908a))
                ProgressView(value: audioLevelValue)
                    .progressViewStyle(.linear)
                    .tint(Color(hex: 0xec8718))
                    .frame(width: 54)
                    .accessibilityLabel(L10n.text("电平"))
                    .accessibilityValue("\(Int(audioLevelValue * 100))%")
                Text("\(Int(audioLevelValue * 100))%")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color(hex: 0xaaa199))
            }
        }
        .padding(.vertical, 2)
    }

    private func panelHeading(_ title: String, subtitle: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color(hex: 0xf1a13a))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.text(title)).font(.system(size: 15, weight: .semibold))
                Text(L10n.text(subtitle)).font(.system(size: 10)).foregroundStyle(Color(hex: 0x98908a))
            }
            Spacer()
        }
        .foregroundStyle(Color(hex: 0xf3ece5))
    }

    private func labeledSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, format: String) -> some View {
        HStack(spacing: 9) {
            Text(L10n.text(title))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color(hex: 0xc8bfb7))
                .frame(width: Locale.preferredLanguages.first?.hasPrefix("zh") == true ? 58 : 96, alignment: .leading)
            Text(String(format: format, value.wrappedValue))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color(hex: 0xaaa199))
                .frame(width: 42, alignment: .trailing)
            Slider(value: value, in: range)
                .tint(Color(hex: 0xec8718))
                .accessibilityLabel(L10n.text(title))
                .accessibilityValue(String(format: format, value.wrappedValue))
        }
    }

    private func settingsToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 8) {
            Text(L10n.text(title))
                .font(.system(size: 11))
            Spacer(minLength: 8)
            Toggle(L10n.text(title), isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .fixedSize()
        }
    }

    private func labeledPicker<Selection: Hashable>(
        _ title: String,
        fieldWidth: CGFloat = 170,
        selection: Binding<Selection>,
        choices: [PickerChoice<Selection>]
    ) -> some View {
        HStack(spacing: 8) {
            Text(L10n.text(title))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color(hex: 0xc8bfb7))
                .frame(maxWidth: .infinity, alignment: .leading)
            AlignedPicker(title: title, choices: choices, selection: selection)
                .frame(width: fieldWidth, height: 27)
        }
    }

    private func presetButton(_ title: String) -> some View {
        let selected = capture.selectedColorPreset == title
        return Button {
            capture.applyPreset(title)
        } label: {
            Text(L10n.text(title))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(selected ? Color(hex: 0x2d1b0b) : Color(hex: 0xf2e9df))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(selected ? Color(hex: 0xf2a340) : Color.white.opacity(0.055), in: Capsule())
                .overlay(Capsule().stroke(selected ? Color(hex: 0xffc36a) : Color.clear, lineWidth: 0.7))
        }
        .buttonStyle(.plain)
        .accessibilityValue(L10n.text(selected ? "已选中" : "未选中"))
    }

    private func fpsButton(_ fps: Int, title: String) -> some View {
        let selected = capture.selectedFPS == fps
        let option = capture.formatOptions.first(where: { $0.id == capture.selectedFormatID })
        let isSupported = fps == 0 || (option?.supportsFPS(fps) ?? false)

        return Button {
            capture.selectFrameRate(fps)
        } label: {
            Text(L10n.text(title))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isSupported ? Color(hex: 0xf1e9e1) : Color(hex: 0x6d6660))
                .frame(minWidth: 40)
                .padding(.vertical, 6)
                .background(selected ? Color(hex: 0x635850) : .clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isSupported || capture.isRecording)
    }

    private var audioLevelValue: Double {
        min(max(Double(capture.audioLevel), 0), 1)
    }

    private func revealFullscreenControls() {
        guard isFullscreen else { return }
        fullscreenControlsVisible = true
        scheduleFullscreenControlsHide()
    }

    private func scheduleFullscreenControlsHide() {
        controlsHideWorkItem?.cancel()
        let workItem = DispatchWorkItem {
            if let activePanel, activePanel != .information {
                fullscreenControlsVisible = true
                return
            }
            fullscreenControlsVisible = false
            if isFullscreen { NSCursor.setHiddenUntilMouseMoves(true) }
        }
        controlsHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: workItem)
    }

    private func toggleRecording() {
        if capture.isRecording {
            capture.stopRecording()
            return
        }

        let panel = NSSavePanel()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        panel.nameFieldStringValue = "MoniView-\(formatter.string(from: .now)).mov"
        panel.allowedContentTypes = [.quickTimeMovie]
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            capture.startRecording(to: url)
        }
    }
}

private struct WindowFullscreenObserver: NSViewRepresentable {
    @Binding var isFullscreen: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { [weak view] in
            context.coordinator.attach(to: view?.window, binding: $isFullscreen)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.attach(to: nsView.window, binding: $isFullscreen)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator {
        private weak var window: NSWindow?
        private var observers: [NSObjectProtocol] = []
        private var binding: Binding<Bool>?

        func attach(to window: NSWindow?, binding: Binding<Bool>) {
            guard let window else {
                self.binding = binding
                return
            }

            self.binding = binding
            guard self.window !== window else { return }

            detach()
            self.window = window
            self.binding = binding
            binding.wrappedValue = window.styleMask.contains(.fullScreen)

            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                    self?.binding?.wrappedValue = true
                },
                center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                    self?.binding?.wrappedValue = false
                }
            ]
        }

        func detach() {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
            window = nil
            binding = nil
        }

        deinit {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
        }
    }
}

private struct DockButtonFace: View {
    let icon: String
    var active = false
    var primary = false
    var recording = false
    @State private var hovered = false

    private var illuminated: Bool { active }
    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 20, weight: .medium))
            .foregroundStyle(illuminated ? Color(hex: 0x35200c) : (primary ? Color(hex: 0xffd88a) : Color(hex: 0xf3ae56)))
            .frame(width: 52, height: 48)
            .background(
                LinearGradient(colors: recording
                    ? [Color(hex: 0xffbe49), Color(hex: 0xe49422)]
                    : illuminated ? [Color(hex: 0xf4a137), Color(hex: 0xcd721c)]
                    : primary ? [Color(hex: 0xd29a48).opacity(hovered ? 0.3 : 0.18), Color(hex: 0xd29a48).opacity(0.08)]
                    : [Color.white.opacity(hovered ? 0.12 : 0.055), Color.white.opacity(hovered ? 0.065 : 0.025)],
                    startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 15, style: .continuous)
            )
            .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(Color.white.opacity(illuminated ? 0.22 : (hovered ? 0.16 : 0.06)), lineWidth: 0.7))
            .shadow(color: Color(hex: 0xd97c25).opacity(illuminated ? 0.15 : 0), radius: 7, y: 2)
            .scaleEffect(hovered ? 1.035 : 1)
            .animation(.easeOut(duration: 0.15), value: hovered)
            .animation(.easeOut(duration: 0.15), value: active)
            .onHover { hovered = $0 }
    }
}

private struct AmberActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color(hex: 0x26190f))
            .padding(.horizontal, 15)
            .padding(.vertical, 9)
            .background(Color(hex: 0xef982c), in: Capsule())
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}

private extension Color {
    init(hex: UInt) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255,
            opacity: 1
        )
    }
}
