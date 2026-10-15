import AVFoundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo

struct RecordingOptions {
    var mic = false
    var systemAudio = true
    var fps = 30
    var quality = 1            // 0 low, 1 medium, 2 high
    var showsCursor = true
}

/// Owns the ScreenCaptureKit stream and the microphone session, and feeds `RecordingWriter`.
/// Not main-actor isolated: sample callbacks arrive on the writer's queue.
final class RecorderEngine: NSObject, SCStreamOutput, SCStreamDelegate,
                            AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private var writer: RecordingWriter?
    private var micSession: AVCaptureSession?

    /// Called on the main queue with a 0...1 microphone level.
    var onLevel: ((Float) -> Void)?
    /// Called on the main queue if the stream dies unexpectedly.
    var onFailure: ((Error) -> Void)?

    var outputURL: URL? { writer?.url }

    /// `sourceRect` (display-local points, top-left origin) crops a display filter; nil records the whole filter.
    func start(filter: SCContentFilter, width: Int, height: Int, sourceRect: CGRect?,
               url: URL, options: RecordingOptions) async throws {
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        if let sourceRect { config.sourceRect = sourceRect }
        config.scalesToFit = true
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.fps))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = options.showsCursor
        config.queueDepth = 3
        config.capturesAudio = options.systemAudio
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2

        let writer = try RecordingWriter(url: url, width: width, height: height, fps: options.fps,
                                         quality: options.quality,
                                         systemAudio: options.systemAudio, mic: options.mic)
        try writer.begin()
        self.writer = writer

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: writer.queue)
        if options.systemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: writer.queue)
        }
        if options.mic { try startMic(writer: writer) }
        self.stream = stream
        try await stream.startCapture()
    }

    private func startMic(writer: RecordingWriter) throws {
        guard let device = AVCaptureDevice.default(for: .audio) else {
            throw NSError(domain: "Snapper", code: 12,
                          userInfo: [NSLocalizedDescriptionKey: "No microphone was found."])
        }
        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw NSError(domain: "Snapper", code: 13,
                          userInfo: [NSLocalizedDescriptionKey: "The microphone could not be used."])
        }
        session.addInput(input)
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: writer.queue)
        guard session.canAddOutput(output) else {
            throw NSError(domain: "Snapper", code: 14,
                          userInfo: [NSLocalizedDescriptionKey: "The microphone output could not be created."])
        }
        session.addOutput(output)
        micSession = session
        session.startRunning()
    }

    func pause() { writer?.pause() }
    func resume() { writer?.resume() }

    func stop() async -> (URL?, Error?) {
        micSession?.stopRunning()
        micSession = nil
        if let stream { try? await stream.stopCapture() }
        stream = nil
        guard let writer else { return (nil, nil) }
        return await withCheckedContinuation { continuation in
            writer.finish { url, error in continuation.resume(returning: (url, error)) }
        }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .screen: writer?.appendVideo(sampleBuffer)
        case .audio: writer?.appendSystemAudio(sampleBuffer)
        default: break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { self.onFailure?(error) }
    }

    // MARK: - Microphone

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        writer?.appendMic(sampleBuffer)
        if let channel = connection.audioChannels.first {
            let db = channel.averagePowerLevel               // about -160...0
            let level = max(0, min(1, (db + 60) / 60))
            DispatchQueue.main.async { self.onLevel?(level) }
        }
    }
}
