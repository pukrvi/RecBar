import Foundation
import CoreMedia
import CoreVideo

/// Synthetic CMSampleBuffers for RecBar's `--selftest` mode: lets the recording
/// pipeline be exercised end to end without a real screen or microphone.
public enum SampleBufferFactory {

    /// A BGRA pixel buffer filled with deterministic vertical color bars that
    /// shift by one bar width per frame, wrapped as a 30 fps video sample buffer.
    public static func videoSampleBuffer(width: Int, height: Int, presentationTime: CMTime, frameIndex: Int) -> CMSampleBuffer? {
        guard width > 0, height > 0 else { return nil }

        var pixelBufferOut: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBufferOut
        )
        guard status == kCVReturnSuccess, let pixelBuffer = pixelBufferOut else {
            NSLog("RecBar SampleBufferFactory: CVPixelBufferCreate failed (%d)", status)
            return nil
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bars = Self.barColors
        let barWidth = max(1, width / bars.count)
        let shift = (frameIndex % bars.count + bars.count) % bars.count

        for row in 0..<height {
            let line = baseAddress.advanced(by: row * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for column in 0..<width {
                let bar = (column / barWidth + shift) % bars.count
                let color = bars[bar]
                line[column * 4 + 0] = color.blue
                line[column * 4 + 1] = color.green
                line[column * 4 + 2] = color.red
                line[column * 4 + 3] = 255 // opaque
            }
        }

        var formatOut: CMVideoFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatOut
        )
        guard formatStatus == noErr, let format = formatOut else {
            NSLog("RecBar SampleBufferFactory: CMVideoFormatDescriptionCreateForImageBuffer failed (%d)", formatStatus)
            return nil
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: CMTime.invalid
        )
        var sampleBufferOut: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBufferOut
        )
        guard sampleStatus == noErr, let sampleBuffer = sampleBufferOut else {
            NSLog("RecBar SampleBufferFactory: CMSampleBufferCreateReadyWithImageBuffer failed (%d)", sampleStatus)
            return nil
        }
        return sampleBuffer
    }

    /// Float32 interleaved LPCM carrying a 440 Hz sine wave. `phase` is in
    /// radians and is advanced by the caller between calls so successive
    /// buffers are phase-continuous.
    public static func audioSampleBuffer(sampleRate: Double, channels: Int, presentationTime: CMTime, frameCount: Int, phase: Double) -> CMSampleBuffer? {
        guard sampleRate > 0, channels > 0, frameCount > 0 else { return nil }

        let sampleCount = frameCount * channels
        let dataLength = sampleCount * MemoryLayout<Float32>.stride
        let samples = UnsafeMutablePointer<Float32>.allocate(capacity: sampleCount)
        defer { samples.deallocate() }

        let step = 2.0 * Double.pi * Self.toneFrequency / sampleRate
        var currentPhase = phase
        for frame in 0..<frameCount {
            let value = Float32(sin(currentPhase) * Self.amplitude)
            for channel in 0..<channels {
                samples[frame * channels + channel] = value
            }
            currentPhase += step
        }

        var blockBufferOut: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: dataLength,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataLength,
            flags: 0,
            blockBufferOut: &blockBufferOut
        )
        guard blockStatus == kCMBlockBufferNoErr, let blockBuffer = blockBufferOut else {
            NSLog("RecBar SampleBufferFactory: CMBlockBufferCreateWithMemoryBlock failed (%d)", blockStatus)
            return nil
        }
        let copyStatus = CMBlockBufferReplaceDataBytes(
            with: UnsafeRawPointer(samples),
            blockBuffer: blockBuffer,
            offsetIntoDestination: 0,
            dataLength: dataLength
        )
        guard copyStatus == kCMBlockBufferNoErr else {
            NSLog("RecBar SampleBufferFactory: CMBlockBufferReplaceDataBytes failed (%d)", copyStatus)
            return nil
        }

        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian,
            mBytesPerPacket: UInt32(channels * MemoryLayout<Float32>.stride),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(channels * MemoryLayout<Float32>.stride),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var formatOut: CMAudioFormatDescription?
        let formatStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatOut
        )
        guard formatStatus == noErr, let format = formatOut else {
            NSLog("RecBar SampleBufferFactory: CMAudioFormatDescriptionCreate failed (%d)", formatStatus)
            return nil
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: CMTime.invalid
        )
        var sampleBufferOut: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: format,
            sampleCount: frameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBufferOut
        )
        guard sampleStatus == noErr, let sampleBuffer = sampleBufferOut else {
            NSLog("RecBar SampleBufferFactory: CMSampleBufferCreateReady failed (%d)", sampleStatus)
            return nil
        }
        return sampleBuffer
    }

    // MARK: - Pattern constants

    private static let toneFrequency = 440.0
    private static let amplitude = 0.5

    private static var barColors: [(red: UInt8, green: UInt8, blue: UInt8)] {
        [
            (red: 235, green: 51, blue: 35),
            (red: 255, green: 140, blue: 0),
            (red: 255, green: 215, blue: 0),
            (red: 50, green: 205, blue: 50),
            (red: 0, green: 191, blue: 255),
            (red: 30, green: 60, blue: 150),
            (red: 155, green: 48, blue: 255),
            (red: 240, green: 240, blue: 240)
        ]
    }
}
