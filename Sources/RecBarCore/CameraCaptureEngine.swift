import Foundation
import AppKit
import AVFoundation
import CoreMedia
import CoreVideo

/// Captures camera video with AVFoundation and hands raw `CMSampleBuffer`s to the
/// controller. Buffers are delivered on a private serial queue, never the main thread.
///
/// This engine never captures audio: the microphone engine owns audio, and the
/// controller feeds the same audio buffers into the camera writer.
public final class CameraCaptureEngine: NSObject {
    public var onVideo: ((CMSampleBuffer) -> Void)?
    public var onError: ((Error) -> Void)?

    private let sampleQueue = DispatchQueue(label: "com.recbar.capture.camera", qos: .userInitiated)
    private let stateLock = NSLock()
    private var session: AVCaptureSession?
    private var output: AVCaptureVideoDataOutput?
    private var input: AVCaptureDeviceInput?
    private var runtimeErrorObserver: NSObjectProtocol?

    public override init() {
        super.init()
    }

    // MARK: - Devices

    public static func availableCameras() -> [CameraDeviceInfo] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        )

        var devices = discovery.devices
        if devices.isEmpty, let fallback = AVCaptureDevice.default(for: .video) {
            devices = [fallback]
        }

        let defaultID = AVCaptureDevice.default(for: .video)?.uniqueID
        var seen = Set<String>()
        var cameras: [CameraDeviceInfo] = []
        for device in devices {
            guard seen.insert(device.uniqueID).inserted else { continue }
            cameras.append(
                CameraDeviceInfo(
                    id: device.uniqueID,
                    name: device.localizedName,
                    isDefault: device.uniqueID == defaultID
                )
            )
        }
        return cameras
    }

    // MARK: - Permission

    public static func hasPermission() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    public static func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .video) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    public static func openCameraSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Lifecycle

    /// `width`, `height` and `frameRate` describe the encoder's target track, not the
    /// capture preset; the session uses `.hd1280x720` (or `.high`) and the writer scales.
    public func start(deviceID: String?, width: Int, height: Int, frameRate: Int, mirror: Bool) throws {
        stop()

        let device = try resolveDevice(deviceID: deviceID)

        let captureSession = AVCaptureSession()
        captureSession.beginConfiguration()

        captureSession.sessionPreset = captureSession.canSetSessionPreset(.hd1280x720) ? .hd1280x720 : .high

        let deviceInput: AVCaptureDeviceInput
        do {
            deviceInput = try AVCaptureDeviceInput(device: device)
        } catch {
            captureSession.commitConfiguration()
            throw RecBarError.captureFailed("Could not open \"\(device.localizedName)\": \(error.localizedDescription)")
        }

        guard captureSession.canAddInput(deviceInput) else {
            captureSession.commitConfiguration()
            throw RecBarError.captureFailed("The camera input could not be added to the capture session.")
        }
        captureSession.addInput(deviceInput)

        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: sampleQueue)

        guard captureSession.canAddOutput(videoOutput) else {
            captureSession.commitConfiguration()
            throw RecBarError.captureFailed("The camera output could not be added to the capture session.")
        }
        captureSession.addOutput(videoOutput)
        captureSession.commitConfiguration()

        if let connection = videoOutput.connection(with: .video), connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = mirror
        }

        let observer = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: captureSession,
            queue: nil
        ) { [weak self] notification in
            guard let self else { return }
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? Error
                ?? RecBarError.captureFailed("The camera capture session stopped unexpectedly.")
            self.onError?(error)
        }

        stateLock.lock()
        session = captureSession
        output = videoOutput
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
            guard let fallback = AVCaptureDevice.default(for: .video) else {
                throw RecBarError.noCamera
            }
            return fallback
        }

        guard let device = AVCaptureDevice(uniqueID: deviceID), device.hasMediaType(.video) else {
            throw RecBarError.noCamera
        }
        return device
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraCaptureEngine: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        onVideo?(sampleBuffer)
    }
}
