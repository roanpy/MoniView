@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import Foundation
import CoreImage
import Metal

/// Encoding runs away from the capture and render queues. Pending work is bounded.
private struct RetainedSample: @unchecked Sendable {
    // CMSampleBuffer is immutable while queued; retaining the wrapper preserves its lifetime.
    let buffer: CMSampleBuffer
}

final class CaptureRecorder {
    /// How this recording treats the video samples. Fixed at `start()` so a mid-recording
    /// shortage of processing resources can never silently change the color path.
    enum VideoMode {
        case source
        case processed(PictureSettings)
    }

    private let queue = DispatchQueue(label: "dev.moniview.record", qos: .userInitiated)
    private let pendingVideo = DispatchSemaphore(value: 3)
    private let lock = NSLock()
    private var accepting = false
    private var stopRequested = false
    // Audio ingress and writer backpressure share ONE bounded FIFO, protected by lock.
    // Retained media is capped at two seconds; this is not added monitoring latency.
    private var audioBacklog = DurationBoundedFIFO<RetainedSample>(maximumDuration: 2)
    private var audioDrainScheduled = false
    // `generation` is protected by lock and tags samples accepted for a writer.
    private var generation: UInt64 = 0
    private var droppedVideoSamples = 0
    private var droppedAudioSamples = 0
    // Writer state, including its generation, is confined to `queue`.
    private var writerGeneration: UInt64 = 0
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var startTime: CMTime?
    private var completion: ((Error?) -> Void)?
    private var videoCount = 0
    private var finishing = false
    private var finishWritingStarted = false
    private var audioDrainDeadline: TimeInterval?
    private var audioRetry: DispatchWorkItem?
    private var lastAudioTime: CMTime?
    private var picture: PictureSettings?
    private var mode: VideoMode = .source
    // Recording writes to a unique temporary file and is moved onto the user's URL only after
    // the writer finishes successfully, so an existing file is never truncated on failure.
    private var workingURL: URL?
    private var destinationURL: URL?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private let colorSpace = CGColorSpace(name: CGColorSpace.itur_709)!
    private let context: CIContext = {
        let options: [CIContextOption: Any] = [.cacheIntermediates: false, .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!]
        if let device = MTLCreateSystemDefaultDevice() { return CIContext(mtlDevice: device, options: options) }
        return CIContext(options: options)
    }()

    func setPicture(_ settings: PictureSettings?) { lock.lock(); picture = settings; lock.unlock() }

    func start(url: URL, width: Int, height: Int, fps: Double, audio: AudioStreamBasicDescription?, completion: @escaping (Error?) -> Void) {
        queue.async {
            guard self.writer == nil else { completion(CaptureFailure.message("录制仍在保存，请稍后再试。")); return }
            self.resetDroppedSamples()
            self.clearAudioBacklog()
            self.lastAudioTime = nil
            self.audioDrainDeadline = nil
            self.finishWritingStarted = false
            // Write beside the destination so the final move stays on one volume, and never
            // touch an existing file until the new recording has finished successfully.
            let destination = url
            let working = destination.deletingLastPathComponent()
                .appendingPathComponent(".moniview-\(UUID().uuidString).mov")
            do {
                let writer = try AVAssetWriter(outputURL: working, fileType: .mov)
                // Fragmented MOV keeps finished segments playable if the process dies mid-recording.
                writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 1)
                self.lock.lock()
                let pictureSnapshot = self.picture
                self.lock.unlock()
                let appliesPictureProcessing = pictureSnapshot != nil
                var videoSettings: [String: Any] = [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: width, AVVideoHeightKey: height,
                    AVVideoCompressionPropertiesKey: [
                        AVVideoAverageBitRateKey: max(8_000_000, Int(Double(width * height) * max(30, fps) * 0.15)),
                        AVVideoExpectedSourceFrameRateKey: Int(fps.rounded()),
                        AVVideoMaxKeyFrameIntervalDurationKey: 2,
                        AVVideoAllowFrameReorderingKey: false
                    ]
                ]
                if appliesPictureProcessing {
                    videoSettings[AVVideoColorPropertiesKey] = [
                        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
                    ]
                }
                guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
                    throw CaptureFailure.message("当前系统不支持请求的视频录制设置。")
                }
                let video = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
                video.expectsMediaDataInRealTime = true
                let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height, kCVPixelBufferMetalCompatibilityKey as String: true, kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
                guard writer.canAdd(video) else { throw CaptureFailure.message("无法创建视频编码器。") }
                var audioInput: AVAssetWriterInput?
                if let audio {
                    let audioSettings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: audio.mSampleRate, AVNumberOfChannelsKey: Int(audio.mChannelsPerFrame), AVEncoderBitRateKey: 192_000]
                    guard writer.canApply(outputSettings: audioSettings, forMediaType: .audio) else {
                        throw CaptureFailure.message("当前系统不支持请求的音频录制设置。")
                    }
                    let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                    input.expectsMediaDataInRealTime = true
                    guard writer.canAdd(input) else { throw CaptureFailure.message("无法创建音频编码器。") }
                    audioInput = input
                }
                writer.add(video)
                if let audioInput { writer.add(audioInput) }
                guard writer.startWriting() else { throw writer.error ?? CaptureFailure.message("无法开始录制。") }
                self.adaptor = adaptor
                self.mode = appliesPictureProcessing ? .processed(pictureSnapshot!) : .source
                self.workingURL = working
                self.destinationURL = destination
                self.writer = writer; self.videoInput = video; self.audioInput = audioInput
                self.startTime = nil; self.videoCount = 0; self.completion = completion
                self.writerGeneration = self.beginAccepting()
            } catch {
                self.clearAcceptingAfterStartFailure()
                self.clearAudioBacklog()
                try? FileManager.default.removeItem(at: working)
                completion(error)
            }
        }
    }

    func append(_ sample: CMSampleBuffer, video: Bool) {
        if !video { appendAudio(sample); return }
        lock.lock()
        guard accepting else { lock.unlock(); return }
        let sampleGeneration = generation
        guard pendingVideo.wait(timeout: .now()) == .success else {
            droppedVideoSamples += 1
            lock.unlock()
            return
        }
        let retained = RetainedSample(buffer: sample)
        queue.async {
            let sample = retained.buffer
            defer { self.pendingVideo.signal() }
            guard self.writerGeneration == sampleGeneration, let writer = self.writer else { return }
            guard writer.status == .writing else {
                if writer.status == .completed {
                    self.complete(nil, writer: writer, generation: sampleGeneration)
                } else {
                    self.fail(writer.error ?? CaptureFailure.message("录制写入状态已失效。"), writer: writer, generation: sampleGeneration)
                }
                return
            }
            defer { self.drainAudio(writer: writer, generation: sampleGeneration) }
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            guard time.isValid, time.seconds.isFinite else { self.recordDroppedSample(video: true); return }
            if self.startTime == nil {
                writer.startSession(atSourceTime: time)
                self.startTime = time
            }
            guard let start = self.startTime, time >= start else { return }
            guard let input = self.videoInput, input.isReadyForMoreMediaData else {
                self.recordDroppedSample(video: true)
                return
            }
            let appended: Bool
            switch self.mode {
            case .processed(let settings):
                // The processed path must never fall back to writing an unprocessed frame.
                guard let source = CMSampleBufferGetImageBuffer(sample), let adaptor = self.adaptor else {
                    self.fail(CaptureFailure.message("录制画面处理不可用。"), writer: writer, generation: sampleGeneration)
                    return
                }
                guard let pool = adaptor.pixelBufferPool else {
                    self.fail(CaptureFailure.message("录制画面缓冲池不可用。"), writer: writer, generation: sampleGeneration)
                    return
                }
                var destination: CVPixelBuffer?
                guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &destination) == kCVReturnSuccess, let destination else {
                    self.fail(CaptureFailure.message("无法分配录制画面缓冲。"), writer: writer, generation: sampleGeneration)
                    return
                }
                let image = VideoImageProcessor.recordedImage(source, settings: settings)
                self.context.render(image, to: destination, bounds: image.extent, colorSpace: self.colorSpace)
                appended = adaptor.append(destination, withPresentationTime: time)
            case .source:
                appended = input.append(sample)
            }
            if !appended { self.fail(writer.error ?? CaptureFailure.message("录制写入失败。"), writer: writer, generation: sampleGeneration) }
            else { self.videoCount += 1 }
        }
        lock.unlock()
    }

    private func appendAudio(_ sample: CMSampleBuffer) {
        let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        var duration = CMSampleBufferGetDuration(sample).seconds
        if !duration.isFinite || duration <= 0,
           let description = CMSampleBufferGetFormatDescription(sample),
           let format = CMAudioFormatDescriptionGetStreamBasicDescription(description) {
            duration = Double(CMSampleBufferGetNumSamples(sample)) / format.pointee.mSampleRate
        }
        lock.lock()
        defer { lock.unlock() }
        guard accepting else { return }
        droppedAudioSamples += audioBacklog.append(RetainedSample(buffer: sample), duration: duration, timestamp: time)
        guard !audioBacklog.isEmpty, !audioDrainScheduled else { return }
        let sampleGeneration = generation
        audioDrainScheduled = true
        // Coalesce ingress: at most one drain request waits behind video encoding.
        queue.async {
            self.lock.lock()
            guard self.generation == sampleGeneration else { self.lock.unlock(); return }
            self.audioDrainScheduled = false
            self.lock.unlock()
            guard self.writerGeneration == sampleGeneration, let writer = self.writer else { return }
            self.drainAudio(writer: writer, generation: sampleGeneration)
        }
    }

    /// Queue-only. Preserve source PTS; never let a new packet overtake buffered audio.
    private func drainAudio(writer: AVAssetWriter, generation: UInt64) {
        guard isCurrentWriter(writer, generation: generation), !finishWritingStarted else { return }
        guard writer.status == .writing else {
            fail(writer.error ?? CaptureFailure.message("录制写入状态已失效。"), writer: writer, generation: generation)
            return
        }
        guard let start = startTime else { return } // The first video establishes the common timebase.
        if let input = audioInput {
            var handled = 0
            // Yield to video work even if audio keeps arriving during the drain.
            while handled < 64 && input.isReadyForMoreMediaData {
                lock.lock()
                let retained = audioBacklog.popFirst()
                lock.unlock()
                guard let retained else { break }
                handled += 1
                let sample = retained.buffer
                let time = CMSampleBufferGetPresentationTimeStamp(sample)
                // Leading audio before the first video is preroll, not recording overload.
                guard time >= start else { continue }
                if let lastAudioTime, time <= lastAudioTime { recordDroppedSample(video: false); continue }
                guard input.append(sample) else {
                    fail(writer.error ?? CaptureFailure.message("录制写入失败。"), writer: writer, generation: generation)
                    return
                }
                lastAudioTime = time
            }
        } else { clearAudioBacklog() }
        lock.lock()
        if finishing, let deadline = audioDrainDeadline, ProcessInfo.processInfo.systemUptime >= deadline {
            // A stalled audio input must not keep tail draining indefinitely. Report the loss.
            droppedAudioSamples += audioBacklog.count
            audioBacklog.removeAll()
        }
        let hasAudio = !audioBacklog.isEmpty
        lock.unlock()
        if hasAudio { scheduleAudioRetry(writer: writer, generation: generation) }
        else {
            audioRetry?.cancel(); audioRetry = nil
            if finishing { finishWriting(writer: writer, generation: generation) }
        }
    }

    /// A retry exists only while buffered audio is waiting; no busy loop or capture/UI wait.
    private func scheduleAudioRetry(writer: AVAssetWriter, generation: UInt64) {
        guard audioRetry == nil else { return }
        let work = DispatchWorkItem { [weak self, weak writer] in
            guard let self, let writer, self.isCurrentWriter(writer, generation: generation) else { return }
            self.audioRetry = nil
            self.drainAudio(writer: writer, generation: generation)
        }
        audioRetry = work
        queue.asyncAfter(deadline: .now() + .milliseconds(10), execute: work)
    }

    private func clearAudioBacklog() {
        audioRetry?.cancel(); audioRetry = nil
        lock.lock()
        audioBacklog.removeAll()
        audioDrainScheduled = false
        lock.unlock()
    }

    /// Called periodically by CaptureManager so an asynchronous writer failure
    /// is reported even when capture has stopped delivering samples.
    func checkFailure() {
        queue.async {
            guard let writer = self.writer else { return }
            let generation = self.writerGeneration
            if writer.status == .failed || writer.status == .cancelled {
                self.fail(writer.error ?? CaptureFailure.message("录制失败或已取消。"), writer: writer, generation: generation)
            } else if writer.status == .completed {
                self.complete(nil, writer: writer, generation: generation)
            }
        }
    }

    /// Snapshot of samples omitted by bounded backpressure or writer input readiness.
    /// Reading does not clear the counters; they remain available through stop/save.
    func droppedSamples() -> (video: Int, audio: Int) {
        lock.lock(); defer { lock.unlock() }
        return (droppedVideoSamples, droppedAudioSamples)
    }

    func stop() {
        lock.lock()
        accepting = false
        stopRequested = true
        lock.unlock()
        queue.async {
            let generation = self.writerGeneration
            self.lock.lock(); self.accepting = false; self.lock.unlock()
            guard let writer = self.writer,
                  self.writerGeneration == generation,
                  !self.finishing else {
                if self.writer == nil { self.clearStopRequest() }
                return
            }
            self.finishing = true
            guard writer.status == .writing else {
                let error = writer.status == .completed ? nil : (writer.error ?? CaptureFailure.message("录制无法完成：writer 已停止。"))
                self.complete(error, writer: writer, generation: generation)
                return
            }
            guard self.videoCount > 0 else {
                self.fail(CaptureFailure.message("没有收到视频帧。"), writer: writer, generation: generation)
                return
            }
            self.videoInput?.markAsFinished()
            // This wall-clock deadline bounds tail draining, independently of the media budget.
            self.audioDrainDeadline = ProcessInfo.processInfo.systemUptime + 2
            self.drainAudio(writer: writer, generation: generation)
        }
    }

    private func finishWriting(writer: AVAssetWriter, generation: UInt64) {
        guard isCurrentWriter(writer, generation: generation), !finishWritingStarted else { return }
        finishWritingStarted = true
        audioInput?.markAsFinished()
        writer.finishWriting { [weak self] in
            guard let self else { return }
            self.queue.async { [weak self] in
                guard let self,
                      self.writerGeneration == generation,
                      let currentWriter = self.writer else { return }
                let error = currentWriter.status == .completed ? nil : currentWriter.error ?? CaptureFailure.message("录制保存失败。")
                self.complete(error, writer: currentWriter, generation: generation)
            }
        }
    }

    private func beginAccepting() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        generation &+= 1
        accepting = !stopRequested
        return generation
    }

    private func stopAccepting(generation expected: UInt64) {
        lock.lock(); defer { lock.unlock() }
        accepting = false
        if generation == expected { generation &+= 1 }
    }

    private func clearAcceptingAfterStartFailure() {
        lock.lock(); accepting = false; generation &+= 1; lock.unlock()
    }

    private func resetDroppedSamples() {
        lock.lock(); droppedVideoSamples = 0; droppedAudioSamples = 0; lock.unlock()
    }

    private func recordDroppedSample(video: Bool) {
        lock.lock()
        if video { droppedVideoSamples += 1 } else { droppedAudioSamples += 1 }
        lock.unlock()
    }

    private func clearStopRequest() {
        lock.lock(); stopRequested = false; accepting = false; lock.unlock()
    }

    private func isCurrentWriter(_ expectedWriter: AVAssetWriter, generation expectedGeneration: UInt64) -> Bool {
        guard writerGeneration == expectedGeneration, let writer else { return false }
        return writer === expectedWriter
    }

    private func fail(_ error: Error, writer expectedWriter: AVAssetWriter, generation expectedGeneration: UInt64) {
        guard isCurrentWriter(expectedWriter, generation: expectedGeneration) else { return }
        stopAccepting(generation: expectedGeneration)
        if expectedWriter.status == .writing { expectedWriter.cancelWriting() }
        complete(error, writer: expectedWriter, generation: expectedGeneration)
    }

    private func complete(_ error: Error?, writer expectedWriter: AVAssetWriter, generation expectedGeneration: UInt64) {
        guard isCurrentWriter(expectedWriter, generation: expectedGeneration) else { return }
        stopAccepting(generation: expectedGeneration)
        clearAudioBacklog()
        lastAudioTime = nil; audioDrainDeadline = nil; finishWritingStarted = false
        lock.lock(); stopRequested = false; lock.unlock()
        let callback = completion
        adaptor = nil
        writer = nil; videoInput = nil; audioInput = nil; completion = nil; startTime = nil
        finishing = false
        let working = workingURL
        let destination = destinationURL
        workingURL = nil; destinationURL = nil
        guard let working, let destination else { callback?(error); return }
        guard error == nil else {
            // Remove the partial file and leave any existing destination untouched.
            try? FileManager.default.removeItem(at: working)
            callback?(error)
            return
        }
        callback?(Self.commit(working: working, destination: destination))
    }

    /// Moves a finished recording onto the user's chosen URL, replacing an existing file only now.
    private static func commit(working: URL, destination: URL) -> Error? {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var commitError: Error?
        coordinator.coordinate(writingItemAt: destination, options: .forReplacing, error: &coordinationError) { url in
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    _ = try FileManager.default.replaceItemAt(url, withItemAt: working)
                } else {
                    try FileManager.default.moveItem(at: working, to: url)
                }
            } catch {
                commitError = error
            }
        }
        if let coordinationError { return coordinationError }
        if let commitError { return commitError }
        return nil
    }
}
