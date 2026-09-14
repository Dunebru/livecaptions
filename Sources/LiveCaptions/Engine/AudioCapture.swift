import AVFoundation
import ScreenCaptureKit

/// Audio source for captions: whatever the Mac is playing (via ScreenCaptureKit) or the microphone.
enum AudioSource: String, CaseIterable, Identifiable {
    case system = "System audio", microphone = "Microphone"
    var id: String { rawValue }
}

/// Delivers 48 kHz float PCM buffers from the chosen source.
final class AudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onError: ((String) -> Void)?

    private var stream: SCStream?
    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "livecaptions.audio")

    /// Test hook: when set, `start` streams this file in real time instead of capturing.
    var testFile: URL?
    private var fileTask: Task<Void, Never>?

    func start(source: AudioSource) async throws {
        if let f = testFile { startFile(f); return }
        switch source {
        case .system: try await startSystem()
        case .microphone: try startMicrophone()
        }
    }

    private func startFile(_ url: URL) {
        fileTask = Task.detached { [weak self] in
            guard let file = try? AVAudioFile(forReading: url) else { return }
            let format = file.processingFormat
            let chunk = AVAudioFrameCount(format.sampleRate / 10)   // 100 ms
            while !Task.isCancelled, file.framePosition < file.length {
                guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk), (try? file.read(into: buf, frameCount: chunk)) != nil, buf.frameLength > 0 else { break }
                self?.onBuffer?(buf)
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    func stop() async {
        fileTask?.cancel(); fileTask = nil
        if let s = stream { try? await s.stopCapture(); stream = nil }
        if engine.isRunning { engine.inputNode.removeTap(onBus: 0); engine.stop() }
    }

    // MARK: system audio (ScreenCaptureKit needs a video stream; we ask for the smallest one and drop it)

    private func startSystem() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { throw NSError(domain: "LiveCaptions", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display found."]) }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.width = 2; config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 3
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let desc = sampleBuffer.formatDescription,
              let asbd = desc.audioStreamBasicDescription else { return }
        let frames = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frames > 0, let format = AVAudioFormat(standardFormatWithSampleRate: asbd.mSampleRate, channels: asbd.mChannelsPerFrame),
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        pcm.frameLength = frames
        var blockBuffer: CMBlockBuffer?
        let list = pcm.mutableAudioBufferList
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: MemoryLayout<AudioBufferList>.size + (Int(asbd.mChannelsPerFrame) - 1) * MemoryLayout<AudioBuffer>.size, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &blockBuffer)
        guard status == noErr else { return }
        onBuffer?(pcm)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?(error.localizedDescription)
    }

    // MARK: microphone

    private func startMicrophone() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in self?.onBuffer?(buffer) }
        try engine.start()
    }
}
