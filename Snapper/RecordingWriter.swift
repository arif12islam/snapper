import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// Writes video + audio samples to an MP4.
///
/// Not fragmented: on current macOS, writing the second movie fragment fails (AVFoundation -11800 / -16341),
/// which cut every recording to its first fragment. A plain MP4 is written in one go when recording stops.
/// Every method that touches state runs on `queue`; the capture sources deliver on that same queue.
final class RecordingWriter: @unchecked Sendable {
    let queue = DispatchQueue(label: "com.example.snapper.recording-writer")

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private var systemAudioInput: AVAssetWriterInput?
    private var micInput: AVAssetWriterInput?
    private let frameDuration: CMTime

    private var sessionStarted = false
    private var startTime = CMTime.invalid
    private var paused = false
    private var waitingForVideoAfterResume = false
    private var timeOffset = CMTime.zero
    private var lastVideoPTS = CMTime.invalid     // in output timeline
    private(set) var failed = false
    private var failure: String?

    let url: URL

    init(url: URL, width: Int, height: Int, fps: Int, quality: Int = 1, systemAudio: Bool, mic: Bool) throws {
        self.url = url
        self.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = false

        let pixels = Double(width * height) * Double(fps) / 30.0
        let factor = [2.0, 4.0, 7.0][min(max(quality, 0), 2)]
        let bitrate = Int(min(max(pixels * factor, 1_500_000), 40_000_000))
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: fps
            ]
        ])
        videoInput.expectsMediaDataInRealTime = true
        writer.add(videoInput)

        func audioInput() -> AVAssetWriterInput {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000
            ])
            input.expectsMediaDataInRealTime = true
            return input
        }
        if systemAudio {
            let input = audioInput()
            writer.add(input)
            systemAudioInput = input
        }
        if mic {
            let input = audioInput()
            writer.add(input)
            micInput = input
        }
    }

    func begin() throws {
        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "Snapper", code: 10,
                                          userInfo: [NSLocalizedDescriptionKey: "Could not start writing the recording."])
        }
    }

    // MARK: - Pause / resume

    func pause() {
        queue.async { self.paused = true }
    }

    func resume() {
        queue.async {
            guard self.paused else { return }
            self.paused = false
            self.waitingForVideoAfterResume = true
        }
    }

    // MARK: - Appending (call on `queue`)

    func appendVideo(_ sample: CMSampleBuffer) {
        guard !failed, CMSampleBufferIsValid(sample), CMSampleBufferGetNumSamples(sample) > 0 else { return }
        // Only fully rendered frames carry pixels.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[String: Any]],
              let raw = attachments.first?[SCStreamFrameInfo.status.rawValue] as? Int,
              SCFrameStatus(rawValue: raw) == .complete else { return }
        if paused { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        if !sessionStarted {
            writer.startSession(atSourceTime: pts)
            sessionStarted = true
            startTime = pts
        }
        if waitingForVideoAfterResume {
            // Close the gap that the pause left, keeping one frame of spacing.
            if lastVideoPTS.isValid {
                let gap = CMTimeSubtract(CMTimeSubtract(pts, timeOffset), lastVideoPTS)
                let extra = CMTimeSubtract(gap, frameDuration)
                if extra > .zero { timeOffset = CMTimeAdd(timeOffset, extra) }
            }
            waitingForVideoAfterResume = false
        }
        guard writer.status == .writing, videoInput.isReadyForMoreMediaData, let out = retimed(sample) else { return }
        // A frame at or before the last one makes the writer fail for good, so drop it instead.
        let outPTS = CMSampleBufferGetPresentationTimeStamp(out)
        if lastVideoPTS.isValid, outPTS <= lastVideoPTS { return }
        if videoInput.append(out) {
            lastVideoPTS = outPTS
        } else {
            failed = true
            failure = "video append failed at \(String(format: "%.2f", CMTimeSubtract(outPTS, startTime).seconds)) s"
        }
    }

    func appendSystemAudio(_ sample: CMSampleBuffer) { appendAudio(sample, to: systemAudioInput) }
    func appendMic(_ sample: CMSampleBuffer) { appendAudio(sample, to: micInput) }

    /// Per audio track: where the last appended buffer ended, and the format the track started with.
    private var audioEnd: [ObjectIdentifier: CMTime] = [:]
    private var audioFormat: [ObjectIdentifier: (Float64, UInt32)] = [:]

    private func appendAudio(_ sample: CMSampleBuffer, to input: AVAssetWriterInput?) {
        guard !failed, sessionStarted, !paused, !waitingForVideoAfterResume, writer.status == .writing,
              let input, input.isReadyForMoreMediaData,
              CMSampleBufferIsValid(sample), CMSampleBufferGetNumSamples(sample) > 0 else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        if pts < startTime { return }
        let key = ObjectIdentifier(input)

        // A change of sample rate or channel count mid-recording (switching headphones, a Bluetooth device
        // dropping to call quality) makes the AAC encoder fail and the whole file with it: skip those buffers.
        if let desc = CMSampleBufferGetFormatDescription(sample),
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee {
            let format = (asbd.mSampleRate, asbd.mChannelsPerFrame)
            if let first = audioFormat[key] {
                if first.0 != format.0 || first.1 != format.1 { return }
            } else {
                audioFormat[key] = format
            }
        }
        guard let out = retimed(sample) else { return }
        // A buffer that starts before the previous one ended (overlapping system audio) is rejected by the
        // writer with -16341 and breaks the file: drop it.
        let outPTS = CMSampleBufferGetPresentationTimeStamp(out)
        if let end = audioEnd[key], CMTimeCompare(outPTS, CMTimeSubtract(end, CMTime(value: 1, timescale: 1000))) < 0 { return }
        let duration = CMSampleBufferGetDuration(out)
        audioEnd[key] = duration.isValid ? CMTimeAdd(outPTS, duration) : outPTS
        // A broken audio buffer should not take the video down with it: drop that track's sample and go on.
        if !input.append(out) {
            if writer.status == .failed {
                failed = true
                let fmt = audioFormat[key].map { "\(Int($0.0)) Hz, \($0.1) ch" } ?? "unknown format"
                failure = "audio append failed at \(String(format: "%.2f", CMTimeSubtract(outPTS, startTime).seconds)) s (\(input === micInput ? "mic" : "system audio"), \(fmt), \(CMSampleBufferGetNumSamples(out)) frames)"
            }
        }
    }

    private func retimed(_ sample: CMSampleBuffer) -> CMSampleBuffer? {
        if timeOffset == .zero { return sample }
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return sample }
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
        for i in 0..<timing.count {
            timing[i].presentationTimeStamp = CMTimeSubtract(timing[i].presentationTimeStamp, timeOffset)
            if timing[i].decodeTimeStamp.isValid {
                timing[i].decodeTimeStamp = CMTimeSubtract(timing[i].decodeTimeStamp, timeOffset)
            }
        }
        var copy: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample,
                                              sampleTimingEntryCount: count, sampleTimingArray: &timing,
                                              sampleBufferOut: &copy)
        return copy
    }

    // MARK: - Finish

    func finish(completion: @escaping (URL?, Error?) -> Void) {
        queue.async {
            guard self.sessionStarted else {
                self.writer.cancelWriting()
                completion(nil, NSError(domain: "Snapper", code: 11,
                                        userInfo: [NSLocalizedDescriptionKey: "No frames were recorded."]))
                return
            }
            self.videoInput.markAsFinished()
            self.systemAudioInput?.markAsFinished()
            self.micInput?.markAsFinished()
            self.writer.finishWriting {
                if self.writer.status == .completed {
                    completion(self.url, nil)
                } else {
                    var info: [String: Any] = [NSLocalizedDescriptionKey: "The recording could not be finished."]
                    if let e = self.writer.error { info[NSUnderlyingErrorKey] = e }
                    if let f = self.failure { info[NSLocalizedFailureReasonErrorKey] = f }
                    completion(nil, NSError(domain: "Snapper.Recording", code: 12, userInfo: info))
                }
            }
        }
    }
}
