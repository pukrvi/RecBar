import AppKit
import Combine
import RecBarCore

/// Bridges the non-observable `RecorderController` into SwiftUI. Every mutation
/// goes through the controller, then the published snapshot is refreshed so the
/// panel always reflects the real recorder state rather than an optimistic copy.
@MainActor
final class PanelModel: ObservableObject {

    // MARK: Snapshot

    @Published private(set) var state: RecorderState
    @Published private(set) var elapsed: TimeInterval
    @Published private(set) var currentBytes: Int64
    @Published private(set) var mergeProgress: Double
    @Published private(set) var settings: RecorderSettings
    @Published private(set) var freeDiskBytes: Int64?
    @Published private(set) var hasLastRecording: Bool
    @Published private(set) var recoverableCount: Int

    /// Which control the pointer is over. Kept on the model because this Mac's
    /// Command Line Tools toolchain cannot expand SwiftUI's `@State` macro.
    @Published var hoveredControl: String?

    // MARK: Devices

    @Published private(set) var microphones: [AudioDeviceInfo] = []
    @Published private(set) var cameras: [CameraDeviceInfo] = []
    @Published private(set) var displays: [DisplayInfo] = []

    private let controller: RecorderController

    /// Called when the panel should close itself, e.g. after Start Recording.
    var onDismiss: (() -> Void)?

    init(controller: RecorderController) {
        self.controller = controller
        self.state = controller.state
        self.elapsed = controller.elapsed
        self.currentBytes = controller.currentBytes
        self.mergeProgress = controller.mergeProgress
        self.settings = controller.settings
        self.freeDiskBytes = controller.freeDiskBytes
        self.hasLastRecording = controller.lastResult != nil
        self.recoverableCount = controller.recoverableSessions.count
        refresh()
        reloadDevices()
    }

    // MARK: Refresh

    func refresh() {
        state = controller.state
        elapsed = controller.elapsed
        currentBytes = controller.currentBytes
        mergeProgress = controller.mergeProgress
        settings = controller.settings
        freeDiskBytes = controller.freeDiskBytes
        hasLastRecording = controller.lastResult != nil
        recoverableCount = controller.recoverableSessions.count
    }

    func reloadDevices() {
        microphones = AudioCaptureEngine.availableMicrophones()
        cameras = CameraCaptureEngine.availableCameras()
        Task { [weak self] in
            do {
                let loaded = try await ScreenCaptureEngine.availableDisplays()
                guard let self, !Task.isCancelled else { return }
                self.displays = loaded
            } catch {
                NSLog("RecBar: could not load displays for panel: %@", error.localizedDescription)
            }
        }
    }

    // MARK: Hover

    func setHover(_ hovering: Bool, on control: String) {
        if hovering {
            hoveredControl = control
        } else if hoveredControl == control {
            hoveredControl = nil
        }
    }

    func isHovered(_ control: String) -> Bool {
        hoveredControl == control
    }

    // MARK: Derived display values

    var audioSummary: String {
        let micCount = settings.microphoneIDs.count
        if settings.recordSystemAudio {
            if micCount == 0 { return "System + default mic" }
            return "System + \(micCount) mic\(micCount == 1 ? "" : "s")"
        }
        if micCount == 0 { return "Default microphone" }
        return "\(micCount) microphone\(micCount == 1 ? "" : "s")"
    }

    var cameraSummary: String {
        guard settings.recordCamera else { return "Off" }
        if let id = settings.cameraID,
           let camera = cameras.first(where: { $0.id == id }) {
            return camera.name
        }
        return "System Default"
    }

    var displaySummary: String {
        guard let display = currentDisplay else { return "Main Display" }
        if display.name.localizedCaseInsensitiveContains("built-in") {
            return "Built-in Display"
        }
        return display.name
    }

    var displayDetail: String? {
        guard let display = currentDisplay else { return nil }
        return "\(display.width)×\(display.height)"
    }

    private var currentDisplay: DisplayInfo? {
        displays.first(where: { $0.id == settings.captureDisplayID })
            ?? displays.first(where: { $0.isMain })
            ?? displays.first
    }

    var qualityDetail: String {
        switch settings.quality {
        case .compact1080p30: return "~1.5 GB/h"
        case .native30: return "~4 GB/h"
        case .native60: return "~9 GB/h"
        }
    }

    var statusSubtitle: String {
        switch state {
        case .idle:
            if let free = freeDiskBytes {
                return "\(Formatting.bytes(free)) free"
            }
            return "Waiting for a recording"
        case .starting:
            return "Preparing capture devices…"
        case .recording:
            return "\(Formatting.bytes(currentBytes)) written · \(audioSummary)"
        case .paused:
            return "\(Formatting.bytes(currentBytes)) written · paused"
        case .stopping:
            return "Finishing segments…"
        case .merging:
            return "Joining screen, camera, and audio tracks"
        case .recovering:
            return "Rebuilding interrupted recordings…"
        }
    }

    var statusLabel: String {
        switch state {
        case .idle: return "READY"
        case .starting: return "STARTING"
        case .recording: return "REC \(Formatting.clock(elapsed))"
        case .paused: return "PAUSED \(Formatting.clock(elapsed))"
        case .stopping: return "SAVING"
        case .merging: return "\(Int((mergeProgress * 100).rounded()))%"
        case .recovering: return "RECOVERING"
        }
    }

    // MARK: Primary actions

    func startOrStop() {
        switch controller.state {
        case .idle:
            // Collapse first: the user asked for Start to get the panel out of
            // the way, and the menu-bar timer takes over the live state.
            onDismiss?()
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.controller.startRecording()
                } catch {
                    PermissionAlerts.show(error)
                }
                self.refresh()
            }
        case .recording, .paused:
            Task { [weak self] in
                guard let self else { return }
                do {
                    _ = try await self.controller.stopRecording()
                } catch {
                    PermissionAlerts.show(error)
                }
                self.refresh()
            }
        default:
            break
        }
    }

    func pauseOrResume() {
        switch controller.state {
        case .recording:
            Task { [weak self] in
                await self?.controller.pauseRecording()
                self?.refresh()
            }
        case .paused:
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.controller.resumeRecording()
                } catch {
                    PermissionAlerts.show(error)
                }
                self.refresh()
            }
        default:
            break
        }
    }

    // MARK: Settings

    func toggleSystemAudio() {
        controller.updateSettings { $0.recordSystemAudio.toggle() }
        refresh()
    }

    func useDefaultMicrophone() {
        controller.updateSettings { $0.microphoneIDs = [] }
        refresh()
    }

    func toggleMicrophone(_ id: String) {
        controller.updateSettings { settings in
            if let index = settings.microphoneIDs.firstIndex(of: id) {
                settings.microphoneIDs.remove(at: index)
            } else {
                settings.microphoneIDs.append(id)
            }
        }
        refresh()
    }

    func selectAllMicrophones() {
        let ids = microphones.map(\.id)
        controller.updateSettings { $0.microphoneIDs = ids }
        refresh()
    }

    func toggleCamera() {
        controller.updateSettings { $0.recordCamera.toggle() }
        refresh()
    }

    func setCamera(_ id: String?) {
        controller.updateSettings { $0.cameraID = id }
        refresh()
    }

    func setDisplay(_ id: UInt32?) {
        controller.updateSettings { $0.captureDisplayID = id }
        refresh()
    }

    func setQuality(_ preset: QualityPreset) {
        controller.updateSettings { $0.quality = preset }
        refresh()
    }

    func toggleShowCursor() {
        controller.updateSettings { $0.showCursor.toggle() }
        refresh()
    }

    func toggleKeepSegments() {
        controller.updateSettings { $0.keepSegments.toggle() }
        refresh()
    }

    func toggleLaunchAtLogin() {
        controller.updateSettings { $0.launchAtLogin.toggle() }
        refresh()
    }

    // MARK: Quick actions

    func openRecordingsFolder() {
        controller.openRecordingsFolder()
    }

    func openLastRecording() {
        controller.openLastRecording()
    }

    func revealLastRecording() {
        controller.revealLastRecording()
    }

    func copyLastPath() {
        controller.copyLastRecordingPath()
    }

    func recoverInterrupted() {
        let count = controller.recoverableSessions.count
        guard count > 0 else { return }
        guard PermissionAlerts.confirmRecovery(count: count) else { return }
        Task { [weak self] in
            await self?.controller.recoverAllInterrupted()
            self?.refresh()
        }
    }

    func relaunch() {
        guard !controller.isBusy else {
            PermissionAlerts.showInfo(
                title: "RecBar",
                message: "Finish the current recording before relaunching."
            )
            return
        }
        AppRelauncher.relaunch()
    }

    func quit() {
        NSApp.terminate(nil)
    }

    func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }
}
