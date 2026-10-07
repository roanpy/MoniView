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
    @State private var panelContentHeight: CGFloat = 560
    private let iconButtonHitTarget: CGFloat = 32
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
            GeometryReader { geometry in
                if let activePanel {
                    let bottom = isFullscreen ? 98.0 : 82.0
                    ScrollView {
                        panelContent(activePanel)
                            .padding(16)
                            .fixedSize(horizontal: false, vertical: true)
                            // A stable identity per panel: without it SwiftUI reuses one view
                            // across a panel switch, so the outgoing panel's content and layout
                            // briefly render behind the incoming one.
                            .id(activePanel)
                            .onGeometryChange(for: CGFloat.self) { content in
                                content.size.height
                            } action: { height in
                                if height > 0 { panelContentHeight = height }
                            }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .scrollIndicators(.hidden)
                    // One width for every panel: switching between them no longer makes the
                    // card jump size and reflow its controls.
                    .frame(width: 365)
                    // Let a panel use whatever vertical room the window actually has. The
                    // previous fixed 560pt cap for the enhancement panel forced a scrollbar
                    // on a normal-size window even with every section collapsed.
                    .frame(height: min(panelContentHeight, max(120, geometry.size.height - bottom - 12)))
                    .background(Color(hex: 0x24201c).opacity(0.92), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 0.7))
                    .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
                    .padding(.bottom, bottom)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
        }
        // A new panel must not inherit the previous panel measured height: the frame
        // would be the wrong size for one layout pass, which is what made a scrollbar
        // flash on every switch.
        .onChange(of: activePanel) { _, _ in panelContentHeight = 0 }
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
                    .frame(width: iconButtonHitTarget, height: iconButtonHitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("进入全屏 · ⌃⌘F")
            .accessibilityLabel("进入全屏")
        }
        .overlay {
            if capture.isRunning && capture.showsStatusBar && !showInformation {
                sourceSummary
                    .frame(maxWidth: 900)
                    .allowsHitTesting(false)
            }
        }
    }

    private var sourceSummary: some View {
        HStack(spacing: 7) {
            Circle().fill(Color(hex: 0x5fd69a)).frame(width: 6, height: 6)
            Text(L10n.text(capture.deviceName)).lineLimit(1).truncationMode(.middle).frame(maxWidth: 132)
            Text("·")
            Text(actualBufferResolution).fixedSize()
            Text("·")
            Text(L10n.format("采集 %d FPS", capture.measuredFPS)).fixedSize()
            if capture.picture.enhancementEnabled && capture.showsEngineStatus {
                Text("·")
                Text(enhancementSummary)
                    .fixedSize()
                    .foregroundStyle(Color(hex: 0xec8718))
            }
            if capture.showsEngineStatus && capture.picture.frameInterpolation != .off {
                Text("·")
                Text(interpolationSummary)
                    .help(L10n.text("显示最近有效插帧配对；实际呈现见输出帧率。"))
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

    private var interpolationSummary: String {
        if let activity = capture.interpolationActivity {
            let basis = activity.basisFPS
            return L10n.format("插帧 %d→%d · 输出 %d FPS（生成 %d）",
                               Int(basis.rounded()), Int((basis * activity.multiplier).rounded()),
                               capture.outputFPS, capture.generatedFPS)
        }
        return L10n.format("插帧待运行 · 输出 %d FPS（生成 %d）", capture.outputFPS, capture.generatedFPS)
    }

    private var enhancementSummary: String {
        if let enhancedSize = capture.enhancedSize {
            return "\(L10n.text(capture.upscaleEngine)) \(enhancedSize)"
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
                .id(capture.previewRevision)
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
        // A window source never involves the camera or an HDMI capture card, so the
        // device wording would be misleading; describe that source instead.
        let isWindow = capture.sourceKind == .macWindow
        return VStack(spacing: 13) {
            ZStack {
                Circle().fill(Color(hex: 0xe98921).opacity(0.13)).frame(width: 74, height: 74)
                Image(systemName: isWindow ? "macwindow" : (capture.permissionDenied ? "video.slash" : "cable.connector"))
                    .font(.system(size: 29, weight: .light))
                    .foregroundStyle(Color(hex: 0xf1a447))
            }
            Text(L10n.text(isWindow
                ? (capture.selectedMacWindowID == nil ? "选择要显示的窗口" : "等待窗口画面")
                : (capture.cameraPermissionPending ? "等待摄像头权限" : (capture.permissionDenied ? "需要摄像头权限" : (capture.videoOptions.isEmpty ? "连接 HDMI 采集卡" : (capture.selectedVideoID != nil ? "等待视频信号" : "选择视频输入"))))))
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(hex: 0xf2eae2))
            Text(L10n.text(isWindow
                 ? (capture.macWindowStatus ?? "在设置 › 采集设置 中选择一个窗口；首次使用需允许屏幕录制。")
                 : capture.cameraPermissionPending ? "请在系统权限弹窗中允许访问摄像头。" : capture.permissionDenied
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
                    Image(systemName: expandedInformation ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: iconButtonHitTarget, height: iconButtonHitTarget)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .help(L10n.text(expandedInformation ? "收起诊断数据" : "展开诊断数据"))
                    .accessibilityLabel(L10n.text(expandedInformation ? "收起诊断数据" : "展开诊断数据"))
                Button { showInformation = false } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: iconButtonHitTarget, height: iconButtonHitTarget)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).help("关闭画面信息").accessibilityLabel("关闭画面信息")
            }
            HStack(spacing: 17) {
                informationMetric("采集", value: "\(capture.measuredFPS)")
                informationMetric("渲染", value: "\(capture.renderedFPS)")
                informationMetric("采集丢帧", value: "\(capture.droppedFrames)")
                Spacer(minLength: 0)
            }
            HStack {
                Text(actualBufferResolution)
                Spacer(minLength: 0)
                Text(actualBufferPixelFormat)
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
            if let contentFPS = capture.detectedContentFPS {
                Text(L10n.format("实际约 %d 帧", Int(contentFPS.rounded())))
            }
            if capture.picture.frameInterpolation != .off {
                Text(interpolationSummary + " · " + L10n.text(capture.interpolationStatus))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Color(hex: 0xaaa199))
            }
            if capture.picture.frameInterpolation != .off, capture.interpolationBudgetMS > 0 {
                Text(L10n.format("插帧预算 %.0f%% · %.1f ms", capture.interpolationCostMS / capture.interpolationBudgetMS * 100, capture.interpolationCostMS))
                    .font(.system(size: 9, design: .monospaced))
            }
            if expandedInformation {
                if capture.presentationIntervalP95MS > 0 {
                    Text(L10n.format("呈现间隔 P95 %.1f ms", capture.presentationIntervalP95MS))
                }
                if capture.picture.skipsExactDuplicateInterpolation {
                    Text(L10n.format("跳过重复插帧 %d 对/秒", capture.skippedDuplicatePairsPerSecond))
                }
                Text(L10n.format("回调→GPU %.1f ms · P95 %.1f", capture.processingMilliseconds, capture.processingP95))
                Text(L10n.format("等待/CPU %.1f ms", max(0, capture.processingMilliseconds - capture.gpuMilliseconds)))
                Text(L10n.text(capture.picture.lowLatency ? "低延迟 · 按显示尺寸处理" : "按完整目标尺寸处理"))
                if capture.isRecording || capture.recordingVideoDrops + capture.recordingAudioDrops > 0 {
                    Text(L10n.format("录制丢弃 · 视频 %d / 音频 %d", capture.recordingVideoDrops, capture.recordingAudioDrops))
                }
            }
            HStack(spacing: 6) {
                Button { capture.setMuted(!capture.isMuted) } label: {
                    Image(systemName: capture.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .foregroundStyle(Color(hex: 0xe9a24d))
                        .frame(width: iconButtonHitTarget, height: iconButtonHitTarget)
                        .contentShape(Rectangle())
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

    private var actualBufferPixelFormat: String {
        guard let (buffer, _, _) = capture.frames.latest() else { return "—" }
        let value = CVPixelBufferGetPixelFormatType(buffer)
        return String(bytes: [UInt8((value >> 24) & 255), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)], encoding: .ascii) ?? "—"
    }

    private func upscaleTargetTitle(_ target: UpscaleTarget) -> String {
        switch target {
        case .native: return "原始输入"
        case .fullHD: return "1080p · 长边 1920 px"
        case .qhd: return "2K · 长边 2560 px"
        case .uhd: return "4K · 长边 3840 px"
        case .screen: return "匹配屏幕"
        }
    }

    /// Preset caption for the resolved configuration. A capability fallback (Flow in
    /// place of the quality tier, or no engine at all) must not be described as the
    /// combination the preset would have applied.
    private var qualityPresetSummary: String {
        guard let name = capture.selectedQualityPreset else { return "已自定义：下列选项可继续调整。" }
        let engine = capture.picture.frameInterpolation
        switch name {
        case "原生增强":
            return "原生帧率 · 匹配屏幕 · 增强 1.00；开启插帧可继续微调。"
        case "流畅优先":
            switch engine {
            case .flowBlend: return "原始尺寸 · 光流插帧 · 跟随内容 · 增强 0.55"
            case .quality: return "原始尺寸 · 高档插帧 · 跟随内容 · 增强 0.55"
            case .off: return "原始尺寸 · 插帧不可用，已关闭 · 增强 0.55"
            default: return "原始尺寸 · 可用插帧 · 跟随内容 · 增强 0.55"
            }
        default:
            switch engine {
            case .quality: return "匹配屏幕 · 高档插帧 · 跟随内容 · 增强 0.80"
            case .flowBlend: return "匹配屏幕 · 光流插帧（回退）· 跟随内容 · 增强 0.80"
            case .off: return "匹配屏幕 · 插帧不可用，已关闭 · 增强 0.80"
            default: return "匹配屏幕 · 可用插帧 · 跟随内容 · 增强 0.80"
            }
        }
    }

    private var clarityPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            panelHeading("画质增强", subtitle: "实时预览处理", icon: "sparkles.tv")
            // Presets first: picking one is the whole flow for most sessions.
            HStack(spacing: 7) {
                ForEach(CaptureManager.qualityPresets, id: \.name) { preset in
                    qualityPresetButton(preset.name)
                }
            }
            .padding(4)
            .background(Color.black.opacity(0.2), in: Capsule())
            Text(L10n.text(qualityPresetSummary))
                .font(.system(size: 10))
                .foregroundStyle(Color(hex: 0x98908a))
            VStack(alignment: .leading, spacing: 9) {
                settingsToggle("启用画质增强", isOn: $capture.picture.enhancementEnabled)
                settingsToggle("平滑插帧", isOn: Binding(
                    get: { capture.picture.frameInterpolation != .off },
                    set: { enabled in
                        if enabled, !FrameInterpolatorSupport.isSupported(capture.picture.preferredInterpolationQuality ?? .balanced),
                           let fallback = availableInterpolationQualities.first {
                            capture.picture.preferredInterpolationQuality = fallback
                        }
                        capture.picture.setInterpolationEnabled(enabled)
                    }))
                    .disabled(capture.picture.frameInterpolation == .off && (!capture.picture.enhancementEnabled || availableInterpolationQualities.isEmpty))
                    .help(L10n.text("按内容节奏生成中间帧，自动选择 2× 或支持的 3×；实际输出受屏幕刷新率与处理耗时限制。"))
                qualityAdvancedSettings
                if capture.picture.frameInterpolation != .off {
                    interpolationReadout
                }
                if capture.picture.frameInterpolation != .off || availableInterpolationQualities.isEmpty {
                    Text(L10n.text(FrameInterpolatorSupport.isSupported(capture.picture.frameInterpolation) ? capture.interpolationStatus : "插帧不可用"))
                        .font(.system(size: 10)).foregroundStyle(Color(hex: 0x98908a))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if recordingFreezesColor {
                    Text("本次录制使用开始时的设置")
                        .font(.system(size: 10)).foregroundStyle(Color(hex: 0x98908a))
                }
            }
            .padding(12)
            .background(Color.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    /// Enhancement settings shown directly under the presets: presets set the starting
    /// point, and every individual control stays visible for finer tuning.
    private var qualityAdvancedSettings: some View {
        VStack(alignment: .leading, spacing: 9) {
            Divider().overlay(Color.white.opacity(0.06))

            settingsToggle("低延迟模式", isOn: $capture.picture.lowLatency)
                .help(L10n.text("按实际显示尺寸处理，优先保持实时帧率；目标是放大上限。"))
            labeledSlider("增强强度", value: $capture.picture.enhancementStrength, range: 0...1, format: "%.2f")
            labeledPicker("放大方式", selection: Binding(
                get: { capture.picture.upscaleMethod.availableMethod(aiSupported: AIUpscalerSupport.isSupported && capture.picture.frameInterpolation == .off) },
                set: { capture.picture.upscaleMethod = $0 }),
                choices: UpscaleMethod.allCases.filter { $0 != .ai || (AIUpscalerSupport.isSupported && capture.picture.frameInterpolation == .off) }.map { PickerChoice(value: $0, title: L10n.text($0.rawValue)) })
                .disabled(!capture.picture.enhancementEnabled)
            labeledPicker("放大目标", selection: $capture.picture.upscaleTarget,
                choices: UpscaleTarget.allCases.map { PickerChoice(value: $0, title: L10n.text(upscaleTargetTitle($0))) })
                .disabled(!capture.picture.enhancementEnabled)
                .help(L10n.text("支持时可选 AI 超分，否则回退空间放大。匹配屏幕使用当前显示器的绘制像素尺寸，不保证与面板物理像素一一对应。不会改变采集输入分辨率。"))
            if capture.picture.frameInterpolation != .off, capture.picture.upscaleMethod == .ai {
                Text("AI 超分暂停，关闭插帧后恢复")
                    .font(.system(size: 10)).foregroundStyle(Color(hex: 0x98908a))
            } else if capture.picture.upscaleMethod == .ai, !capture.aiUpscaleStatus.isEmpty {
                Text(L10n.text(capture.aiUpscaleStatus))
                    .font(.system(size: 10)).foregroundStyle(Color(hex: 0x98908a))
            }
            Divider().overlay(Color.white.opacity(0.06))
            // With interpolation off this control has no value to show, so it states that
            // and greys out instead of presenting an empty box that still looks operable.
            labeledPicker("插帧质量", selection: Binding(
                get: { capture.picture.frameInterpolation },
                set: { capture.picture.frameInterpolation = $0; capture.picture.preferredInterpolationQuality = $0 }),
                choices: interpolationQualityChoices)
                .disabled(!capture.picture.enhancementEnabled || capture.picture.frameInterpolation == .off)
                .help(L10n.text(capture.picture.frameInterpolation == .off
                    ? "插帧已关闭；打开「平滑插帧」后可选择质量档位。"
                    : "低档自适应降低中间帧分辨率；中、高档保持各自上限；光流 Beta 为自研引擎。"))
            if capture.picture.frameInterpolation == .off {
                Text(L10n.text("插帧关闭：以下质量与高级选项不生效。"))
                    .font(.system(size: 10))
                    .foregroundStyle(Color(hex: 0x98908a))
                    .fixedSize(horizontal: false, vertical: true)
            }
            // These only mean something while interpolation is on. Leaving them
            // operable with interpolation off let the force flag stay set on its own,
            // which then looked like the app ignoring performance limits.
            settingsToggle("强制尝试插帧", isOn: $capture.picture.forceFrameInterpolation)
                .disabled(capture.picture.frameInterpolation == .off)
                .help(L10n.text("忽略性能预算，保留所选质量；仍受屏幕刷新率、有效输入和呈现期限限制。可能增加延迟与卡顿。"))
            settingsToggle("跟随内容帧率", isOn: $capture.picture.skipsExactDuplicateInterpolation)
                .disabled(capture.picture.frameInterpolation == .off)
                .help(L10n.text("开启按不同内容画面的时间插帧，关闭按采集节奏插帧；不改变采集档位。"))
        }
    }

    private var availableInterpolationQualities: [FrameInterpolationMode] {
        FrameInterpolationMode.allCases.filter { $0 != .off && FrameInterpolatorSupport.isSupported($0) }
    }

    private var interpolationQualityChoices: [PickerChoice<FrameInterpolationMode>] {
        let current = capture.picture.frameInterpolation
        var choices = availableInterpolationQualities.map { PickerChoice(value: $0, title: L10n.text($0.title)) }
        if current == .off {
            choices.insert(PickerChoice(value: .off, title: L10n.text("插帧关闭")), at: 0)
        } else if !availableInterpolationQualities.contains(current) {
            choices.insert(PickerChoice(value: current, title: L10n.text(current.title) + " · " + L10n.text("插帧不可用")), at: 0)
        }
        return choices
    }

    /// Live interpolation readout, shown only while interpolation is on.
    private var interpolationReadout: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().overlay(Color.white.opacity(0.06))
            HStack {
                if let activity = capture.interpolationActivity {
                    let basisFPS = activity.basisFPS
                    let multiplierLabel = String(format: "%.0f×", activity.multiplier)
                    Text(L10n.format(capture.picture.skipsExactDuplicateInterpolation
                                     ? "内容配对 %d FPS · %@ 目标 %d" : "采集 %d FPS · %@ 目标 %d",
                                     Int(basisFPS.rounded()), multiplierLabel, Int((basisFPS * activity.multiplier).rounded())))
                } else {
                    // The capture signal rate is not the content rate: a 30 FPS game in a
                    // 60 Hz signal can only reach 60, so an undetected cadence must not
                    // claim the signal's doubled rate as the target.
                    Text(L10n.format("目标取决于内容帧率 · 屏幕 %.0f Hz", capture.displayMaximumFPS))
                }
                Spacer(minLength: 4)
                Button {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") { NSWorkspace.shared.open(url) }
                } label: {
                    Image(systemName: "display")
                        .frame(width: iconButtonHitTarget, height: iconButtonHitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.link).help("显示器设置…")
            }.font(.system(size: 10, design: .monospaced)).foregroundStyle(Color(hex: 0x98908a))
            Text(L10n.format("输出 %d FPS（生成 %d）", capture.outputFPS, capture.generatedFPS))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Color(hex: 0xe9a24d))
            if capture.interpolationBudgetMS > 0 {
                Text(L10n.format("插帧预算 %.0f%% · %.1f ms", capture.interpolationCostMS / capture.interpolationBudgetMS * 100, capture.interpolationCostMS))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(capture.interpolationCostMS > capture.interpolationBudgetMS ? Color.orange : Color(hex: 0x98908a))
                    .help(L10n.text("处理预算不是整机 GPU 占用率；详细尺寸与呈现统计见画面信息。"))
            }
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
            // This panel exists to adjust colour, so its sliders stay on the surface
            // under the presets; hiding them here would hide the point of the panel.
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

    /// One refresh action covers both sources: devices always, and the window list
    /// whenever the Mac-window source is selected.
    private var sourceRefreshButton: some View {
        Button {
            capture.refreshDevices()
            capture.refreshMacWindows()
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(hex: 0xe9a24d))
                .frame(width: 30, height: 30)
                .background(Color.white.opacity(0.06), in: Circle())
                .frame(width: iconButtonHitTarget, height: iconButtonHitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L10n.text("刷新来源"))
    }

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                panelHeading("采集设置", subtitle: "按采集卡支持的格式显示", icon: "gearshape")
                sourceRefreshButton
            }

            VStack(alignment: .leading, spacing: 11) {
                labeledPicker("画面来源", fieldWidth: 195,
                    selection: $capture.sourceKind,
                    choices: CaptureSourceKind.allCases.map { PickerChoice(value: $0, title: L10n.text($0.rawValue)) })
                    .disabled(capture.isRecording)
                if capture.sourceKind == .macWindow {
                    HStack(alignment: .center, spacing: 8) {
                        labeledPicker("Mac 窗口", fieldWidth: 195,
                            selection: Binding(get: { capture.selectedMacWindowID }, set: { capture.selectedMacWindowID = $0 }),
                            choices: capture.macWindowOptions.map { PickerChoice(value: Optional($0.id), title: $0.displayTitle) })
                            .disabled(capture.isRecording || capture.macWindowOptions.isEmpty)
                        sourceRefreshButton
                    }
                    if let status = capture.macWindowStatus {
                        Text(L10n.text(status))
                            .font(.system(size: 10))
                            .foregroundStyle(Color(hex: 0x98908a))
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(L10n.text("捕获本机窗口，勾选系统录屏授权后生效。只显示窗口内容，不影响原程序。"))
                            .font(.system(size: 10))
                            .foregroundStyle(Color(hex: 0x98908a))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                // A window source has no capture-device controls to show; hiding them
                // keeps the panel honest instead of leaving dead pickers behind.
                if capture.sourceKind == .device {
                    labeledPicker("视频设备", fieldWidth: 195,
                        selection: Binding(get: { capture.selectedVideoID }, set: { capture.selectVideoDevice(id: $0) }),
                        choices: capture.videoOptions.map { PickerChoice(value: Optional($0.id), title: $0.name) })
                        .disabled(capture.isRecording)
                }

                if capture.sourceKind == .device {
                labeledPicker("分辨率", fieldWidth: 195,
                    selection: Binding(get: { capture.selectedFormatID }, set: { capture.selectFormat(id: $0) }),
                    choices: capture.formatOptions.map { PickerChoice(value: Optional($0.id), title: $0.title) })
                    .disabled(capture.isRecording || capture.formatOptions.isEmpty)

                HStack(spacing: 8) {
                    Text(L10n.text("帧率"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color(hex: 0xc8bfb7))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 5) {
                        HStack(spacing: 1) {
                            fpsButton(0, title: "自动")
                            ForEach(quickFrameRates, id: \.self) { fps in
                                fpsButton(fps, title: CaptureFrameRatePolicy.shortcutTitle(fps))
                            }
                        }
                        .padding(3)
                        .background(Color.black.opacity(0.28), in: Capsule())
                        Text(capture.detectedContentFPS.map {
                            L10n.format("实际约 %d 帧", Int($0.rounded()))
                        } ?? L10n.text("实际待测"))
                            .font(.system(size: 9))
                            .foregroundStyle(Color(hex: 0x98908a))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .frame(width: 195, alignment: .leading)
                }

                // The shortcut row above is the everyday control; this picker carries every
                // advertised value, including fractional rates and high-rate modes, so nothing
                // becomes unreachable. Interpolation's content-follow switch lives in
                // the enhancement panel, so this row only changes hardware sampling.
                HStack(alignment: .center, spacing: 8) {
                    Text(L10n.text("完整帧率"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color(hex: 0xc8bfb7))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    AlignedPicker(title: "完整帧率",
                        choices: capture.frameRateOptions.map { PickerChoice(value: $0, title: $0 == 0 ? L10n.text("自动") : String(format: "%.2f FPS", $0)) },
                        selection: Binding(get: { capture.selectedFrameRate }, set: { capture.selectFrameRateValue($0) }))
                        .frame(width: 195, height: 27)
                        .disabled(capture.isRecording || capture.formatOptions.isEmpty)
                        .help(L10n.text("采集档位决定采样上限。识别变化的内容帧率，建议保留 60 帧采集；插帧的跟随开关不会改变采集档位。"))
                }
                labeledPicker("画面比例", fieldWidth: 195, selection: $capture.aspectMode,
                    choices: AspectMode.allCases.map { PickerChoice(value: $0, title: L10n.text($0.rawValue)) })
                Text(L10n.text(capture.aspectMode == .stretch ? "铺满窗口，画面比例可能变形。" : (capture.aspectMode == .fill ? "保持比例，裁切超出窗口的部分。" : "保持比例，完整显示画面。")))
                    .font(.system(size: 10))
                    .foregroundStyle(Color(hex: 0x98908a))
                }
            }
            .padding(12)
            .background(Color.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))

            // Audio stays on the surface: it is adjusted while using the app, not during
            // first-time setup. Recording and status display are set once, so they stay
            // reachable behind one disclosure.
            VStack(alignment: .leading, spacing: 14) {
                labeledPicker("音频输入", fieldWidth: 195,
                    selection: Binding(get: { capture.selectedAudioID }, set: { capture.selectAudioDevice(id: $0, persist: true) }),
                    choices: [PickerChoice(value: Optional<String>.none, title: L10n.text("关闭音频输入"))] + capture.audioOptions.map { PickerChoice(value: Optional($0.id), title: $0.name) })
                    .disabled(capture.isRecording)
                audioMonitoringControls
            }
            .padding(12)
            .background(Color.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))

            DisclosureGroup {
                VStack(spacing: 14) {
                    settingsToggle("录制预览色彩和锐化", isOn: $capture.recordIncludesPicture)
                        .disabled(capture.isRecording)
                    settingsToggle("显示设备状态", isOn: $capture.showsStatusBar)
                    settingsToggle("显示增强状态", isOn: $capture.showsEngineStatus)
                }
                .padding(.top, 8)
            } label: {
                Text(L10n.text("录制与状态"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(hex: 0xd9cfc6))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .padding(.vertical, 5)
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

            // Status, volume and mute read as one row: the title and level meter share
            // the line, and the slider sits under a compact mute switch.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("声音监听")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(hex: 0xe6ddd4))
                Text(L10n.text(capture.audioStatus))
                    .font(.system(size: 10))
                    .foregroundStyle(Color(hex: 0x98908a))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text("\(Int(capture.audioVolume * 100))%")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color(hex: 0xc8bfb7))
            }

            HStack(spacing: 8) {
                Toggle(isOn: Binding(
                    get: { capture.isMuted },
                    set: { capture.setMuted($0) }
                )) {
                    Text("静音")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color(hex: 0xc8bfb7))
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .fixedSize()

                Slider(value: Binding(
                    get: { Double(capture.audioVolume) },
                    set: { capture.setAudioVolume(Float($0)) }
                ), in: 0...1)
                .tint(Color(hex: 0xec8718))
                .accessibilityLabel(L10n.text("声音监听"))
                .accessibilityValue("\(Int(capture.audioVolume * 100))%")

                Text("电平")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color(hex: 0x98908a))
                    .fixedSize()
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
                .frame(width: Bundle.main.preferredLocalizations.first?.hasPrefix("zh") == true ? 58 : 96, alignment: .leading)
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
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(selected ? Color(hex: 0xf2a340) : Color.white.opacity(0.055), in: Capsule())
                .overlay(Capsule().stroke(selected ? Color(hex: 0xffc36a) : Color.clear, lineWidth: 0.7))
        }
        .buttonStyle(.plain)
        .accessibilityValue(L10n.text(selected ? "已选中" : "未选中"))
    }

    /// Quality presets use the same visual language as the colour presets, so the
    /// panel reads as "pick a starting point, then fine-tune if you want".
    private func qualityPresetButton(_ title: String) -> some View {
        let selected = capture.selectedQualityPreset == title
        return Button {
            capture.applyQualityPreset(title)
        } label: {
            Text(L10n.text(title))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(selected ? Color(hex: 0x2d1b0b) : Color(hex: 0xf2e9df))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(selected ? Color(hex: 0xf2a340) : Color.white.opacity(0.055), in: Capsule())
                .overlay(Capsule().stroke(selected ? Color(hex: 0xffc36a) : Color.clear, lineWidth: 0.7))
        }
        .buttonStyle(.plain)
        .accessibilityValue(L10n.text(selected ? "已选中" : "未选中"))
    }

    private var quickFrameRates: [Double] {
        let rates = CaptureFrameRatePolicy.shortcuts(supportedRates: capture.frameRateOptions,
                                                     selectedRate: capture.selectedFrameRate, limit: 4)
        // Fractional labels need more space; keep three shortcuts alongside the content
        // reading rather than rounding away their precision or hiding the current choice.
        return rates.contains(where: { CaptureFrameRatePolicy.shortcutTitle($0).count > 3 })
            ? CaptureFrameRatePolicy.shortcuts(supportedRates: capture.frameRateOptions,
                                                selectedRate: capture.selectedFrameRate, limit: 3)
            : rates
    }

    private func fpsButton(_ fps: Double, title: String) -> some View {
        let selected = abs(capture.selectedFrameRate - fps) < 0.001
        // Same-resolution pixel formats can advertise different frame rates;
        // configureFormat selects the compatible variant when needed.
        let isSupported = capture.frameRateOptions.contains { abs($0 - fps) < 0.001 }

        return Button {
            capture.selectFrameRateValue(fps)
        } label: {
            Text(L10n.text(title))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isSupported ? Color(hex: 0xf1e9e1) : Color(hex: 0x6d6660))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(minWidth: fps == 0 ? 32 : (quickFrameRates.count == 4 ? 25 : 28))
                .padding(.horizontal, title.count > 3 ? 2 : 0)
                .padding(.vertical, 7)
                .background(selected ? Color(hex: 0x635850) : .clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isSupported || capture.isRecording || capture.formatOptions.isEmpty)
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
