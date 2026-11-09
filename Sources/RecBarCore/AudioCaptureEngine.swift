import Foundation
import AppKit
import AVFoundation
import CoreMedia

/// Captures microphone audio with AVFoundation and hands raw `CMSampleBuffer`s to the
/// controller. Buffers are delivered on a private serial queue, never the main thread.
public final class AudioCaptureEngine: NSObject {
    public var onAudio: ((CMSampleBuffer) -> Void)?
    public var onError: ((Error) -> Void)?

    private let sampleQueue = DispatchQueue(label: "com.recbar.capture.audio", qos: .userInitiated)
    private let stateLock = NSLock()
    private var session: AVCaptureSession?
    private var output: AVCaptureAudioDataOutput?
    private var input: AVCaptureDeviceInput?
    private var runtimeErrorObserver: NSObjectProtocol?

    public override init() {
        super.init()
    }

    // MARK: - Devices

    public static func availableMicrophones() -> [AudioDeviceInfo] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )

        var devices = discovery.devices
        if devices.isEmpty, let fallback = AVCaptureDevice.default(for: .audio) {
            devices = [fallback]
        }

        let defaultID = AVCaptureDevice.default(for: .audio)?.uniqueID
        var seen = Set<String>()
        var microphones: [AudioDeviceInfo] = []
        for device in devices {
            guard seen.insert(device.uniqueID).inserted else { continue }
            microphones.append(
                AudioDeviceInfo(
                    id: device.uniqueID,
                    name: device.localizedName,
                    isDefault: device.uniqueID == defaultID
                )
            )
        }
        return microphones
    }

    // MARK: - Permission

    public static func hasPermission() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    public static func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    public static func openMicrophoneSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Lifecycle

    public func start(deviceID: String?, sampleRate: Double, channels: Int) throws {
        stop()

        let device = try resolveDevice(deviceID: deviceID)

        let captureSession = AVCaptureSession()
        captureSession.beginConfiguration()

        let deviceInput: AVCaptureDeviceInput
        do {
            deviceInput = try AVCaptureDeviceInput(device: device)
        } catch {
            captureSession.commitConfiguration()
            throw RecBarError.captureFailed("Could not open \"\(device.localizedName)\": \(error.localizedDescription)")
        }

        guard captureSession.canAddInput(deviceInput) else {
            captureSession.commitConfiguration()
            throw RecBarError.captureFailed("The microphone input could not be added to the capture session.")
        }
        captureSession.addInput(deviceInput)

        let audioOutput = AVCaptureAudioDataOutput()
        audioOutput.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: max(1, channels),
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        audioOutput.setSampleBufferDelegate(self, queue: sampleQueue)

        guard captureSession.canAddOutput(audioOutput) else {
            captureSession.commitConfiguration()
            throw RecBarError.captureFailed("The microphone output could not be added to the capture session.")
        }
        captureSession.addOutput(audioOutput)
        captureSession.commitConfiguration()

        let observer = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: captureSession,
            queue: nil
        ) { [weak self] notification in
            guard let self else { return }
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? Error
                ?? RecBarError.captureFailed("The microphone capture session stopped unexpectedly.")
            self.onError?(error)
        }

        stateLock.lock()
        session = captureSession
        output = audioOutput
        input = deviceInput
        runtimeErrorObserver = observer
        stateLock.unlock()

        captureSession.startRunning()
    }

    public func stop() {
        stateLock.lock()
        let runningSession = session
        let runningOutput = output
        let observer = runtimeErrorObserver
        session = nil
        output = nil
        input = nil
        runtimeErrorObserver = nil
        stateLock.unlock()

        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        runningOutput?.setSampleBufferDelegate(nil, queue: nil)
        if let runningSession, runningSession.isRunning {
            runningSession.stopRunning()
        }
    }

    // MARK: - Helpers

    private func resolveDevice(deviceID: String?) throws -> AVCaptureDevice {
        guard let deviceID, !deviceID.isEmpty else {
            guard let fallback = AVCaptureDevice.default(for: .audio) else {
                throw RecBarError.noMicrophone
            }
            return fallback
        }

        guard let device = AVCaptureDevice(uniqueID: deviceID), device.hasMediaType(.audio) else {
            throw RecBarError.noMicrophone
        }
        return device
    }
}

// MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

extension AudioCaptureEngine: AVCaptureAudioDataOutputSampleBufferDelegate {
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        onAudio?(sampleBuffer)
    }
}
