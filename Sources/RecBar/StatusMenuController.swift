import AppKit
import RecBarCore

/// Owns the menu-bar status item and builds the whole menu on demand.
@MainActor
public final class StatusMenuController: NSObject, NSMenuDelegate {
    private let controller: RecorderController
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var displays: [DisplayInfo] = []
    private var displayTask: Task<Void, Never>?
    /// Vector menu-bar artwork parsed once per state. `refresh()` runs every second
    /// while recording, so re-decoding the SVG on each tick would be wasteful.
    private var statusImages: [String: NSImage] = [:]

    // MARK: Setup

    public init(controller: RecorderController) {
        self.controller = controller
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        statusItem.isVisible = true

        if let button = statusItem.button {
            button.imagePosition = .imageLeading
            button.imageScaling = .scaleProportionallyDown
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        }

        refresh()
        refreshDisplays()
    }

    // MARK: Status item

    /// Updates only the icon and timer text. Called once a second while recording.
    public func refresh() {
        guard let button = statusItem.button else { return }

        switch controller.state {
        case .idle:
            button.image = statusImage("menubar-idle", fallbackSymbol: "record.circle")
            button.contentTintColor = nil
            button.title = ""
        case .recording:
            button.image = statusImage("menubar-recording", fallbackSymbol: "record.circle.fill")
            button.contentTintColor = .systemRed
            button.title = " " + Formatting.clock(controller.elapsed)
        case .paused:
            button.image = statusImage("menubar-paused", fallbackSymbol: "pause.circle.fill")
            button.contentTintColor = .systemOrange
            button.title = " " + Formatting.clock(controller.elapsed)
        case .merging:
            button.image = statusImage("menubar-exporting", fallbackSymbol: "arrow.triangle.2.circlepath")
            button.contentTintColor = nil
            let percent = Int((controller.mergeProgress * 100).rounded())
            button.title = " \(percent)%"
        case .starting, .stopping:
            button.image = statusImage("menubar-saving", fallbackSymbol: "arrow.triangle.2.circlepath")
            button.contentTintColor = nil
            button.title = ""
        case .recovering:
            button.image = statusImage("menubar-exporting", fallbackSymbol: "arrow.triangle.2.circlepath")
            button.contentTintColor = nil
            button.title = ""
        }
    }

    /// Loads the shipped vector menu-bar artwork as a template image so macOS tints
    /// it for light/dark menu bars. Falls back to an SF Symbol when running the bare
    /// binary, which has no bundle resources.
    private func statusImage(_ name: String, fallbackSymbol: String) -> NSImage? {
        if let cached = statusImages[name] {
            return cached
        }

        let image = Bundle.main.url(forResource: name, withExtension: "svg")
            .flatMap { NSImage(contentsOf: $0) }
            ?? NSImage(systemSymbolName: fallbackSymbol, accessibilityDescription: "RecBar")
        image?.isTemplate = true
        image?.size = NSSize(width: 18, height: 18)
        if let image {
            statusImages[name] = image
        }
        return image
    }

    // MARK: Menu construction

    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let state = controller.state
        let settings = controller.settings

        var headerParts = ["RecBar — \(state.displayName)"]
        if state == .recording || state == .paused {
            headerParts.append(Formatting.clock(controller.elapsed))
            headerParts.append(Formatting.bytes(controller.currentBytes))
        }
        if state == .merging {
            headerParts.append("\(Int((controller.mergeProgress * 100).rounded()))%")
        }
        if let free = controller.freeDiskBytes {
            headerParts.append("\(Formatting.bytes(free)) free")
        }
        menu.addItem(item(headerParts.joined(separator: " · "), nil, enabled: false))
        menu.addItem(.separator())

        // Start / stop
        switch state {
        case .idle:
            let start = item("Start Recording", #selector(startOrStop))
            start.keyEquivalent = "r"
            start.keyEquivalentModifierMask = [.command, .option, .control]
            menu.addItem(start)
        case .recording, .paused:
            let stop = item("Stop & Save Recording", #selector(startOrStop))
            stop.keyEquivalent = "r"
            stop.keyEquivalentModifierMask = [.command, .option, .control]
            menu.addItem(stop)
        default:
            menu.addItem(item("Finishing…", nil, enabled: false))
        }

        // Pause / resume
        switch state {
        case .recording:
            let pause = item("Pause Recording", #selector(pauseOrResume))
            pause.keyEquivalent = "p"
            pause.keyEquivalentModifierMask = [.command, .option, .control]
            menu.addItem(pause)
        case .paused:
            let resume = item("Resume Recording", #selector(pauseOrResume))
            resume.keyEquivalent = "p"
            resume.keyEquivalentModifierMask = [.command, .option, .control]
            menu.addItem(resume)
        default:
            menu.addItem(item("Pause Recording", nil, enabled: false))
        }

        menu.addItem(.separator())
        menu.addItem(submenuItem("Audio", audioMenu(settings: settings)))
        menu.addItem(submenuItem("Camera", cameraMenu(settings: settings)))
        menu.addItem(submenuItem("Capture Display", displayMenu(settings: settings)))
        menu.addItem(submenuItem("Quality", qualityMenu(settings: settings)))
        menu.addItem(submenuItem("Advanced", advancedMenu(settings: settings)))
        menu.addItem(.separator())

        menu.addItem(item("Open Recordings Folder", #selector(openRecordingsFolder)))

        let hasLast = controller.lastResult != nil
        menu.addItem(item("Open Last Recording", #selector(openLastRecording), enabled: hasLast))
        menu.addItem(item("Reveal Last Recording in Finder", #selector(revealLastRecording), enabled: hasLast))
        menu.addItem(item("Copy Last Recording Path", #selector(copyLastPath), enabled: hasLast))
        menu.addItem(.separator())

        let recoveryCount = controller.recoverableSessions.count
        let recoveryTitle = recoveryCount > 0
            ? "Recover Interrupted Recordings… (\(recoveryCount))"
            : "Recover Interrupted Recordings…"
        menu.addItem(item(recoveryTitle, #selector(recoverInterrupted), enabled: recoveryCount > 0))

        menu.addItem(.separator())
        let relaunch = item("Relaunch RecBar", #selector(relaunchApp))
        menu.addItem(relaunch)
        let quit = item("Quit RecBar", #selector(quit))
        quit.keyEquivalent = "q"
        quit.keyEquivalentModifierMask = [.command]
        menu.addItem(quit)
    }

    private func audioMenu(settings: RecorderSettings) -> NSMenu {
        let submenu = makeSubmenu()
        let microphones = AudioCaptureEngine.availableMicrophones()
        let selected = Set(settings.microphoneIDs)

        var summaryParts: [String] = []
        if settings.recordSystemAudio { summaryParts.append("system audio") }
        if selected.isEmpty {
            summaryParts.append("default microphone")
        } else {
            summaryParts.append("\(selected.count) microphone\(selected.count == 1 ? "" : "s")")
        }
        submenu.addItem(item("Recording: " + summaryParts.joined(separator: " + "), nil, enabled: false))
        submenu.addItem(.separator())

        let system = item("Record System Audio", #selector(toggleSystemAudio))
        system.state = settings.recordSystemAudio ? .on : .off
        submenu.addItem(system)

        submenu.addItem(.separator())
        submenu.addItem(item("Microphones — select any number", nil, enabled: false))

        let useDefault = item("System Default Microphone", #selector(useDefaultMicrophone))
        useDefault.state = settings.microphoneIDs.isEmpty ? .on : .off
        submenu.addItem(useDefault)

        if microphones.isEmpty {
            submenu.addItem(item("No microphones found", nil, enabled: false))
        } else {
            for device in microphones {
                let entry = item(device.name, #selector(toggleMicrophone(_:)), represented: device.id)
                entry.state = selected.contains(device.id) ? .on : .off
                submenu.addItem(entry)
            }
            submenu.addItem(.separator())
            let all = item("Record All Microphones", #selector(selectAllMicrophones))
            all.state = !microphones.isEmpty && selected.count == microphones.count ? .on : .off
            submenu.addItem(all)
        }

        submenu.addItem(.separator())
        submenu.addItem(item("Refresh Devices", #selector(refreshDevices)))
        return submenu
    }

    private func cameraMenu(settings: RecorderSettings) -> NSMenu {
        let submenu = makeSubmenu()

        let toggle = item("Record Camera", #selector(toggleRecordCamera))
        toggle.state = settings.recordCamera ? .on : .off
        submenu.addItem(toggle)
        submenu.addItem(.separator())

        let system = item(
            "System Default Camera",
            #selector(selectCamera(_:)),
            represented: NSNull(),
            enabled: settings.recordCamera
        )
        system.state = settings.cameraID == nil ? .on : .off
        submenu.addItem(system)

        let cameras = CameraCaptureEngine.availableCameras()
        if cameras.isEmpty {
            submenu.addItem(item("No cameras found", nil, enabled: false))
        } else {
            for device in cameras {
                let entry = item(
                    device.name,
                    #selector(selectCamera(_:)),
                    represented: device.id,
                    enabled: settings.recordCamera
                )
                entry.state = settings.cameraID == device.id ? .on : .off
                submenu.addItem(entry)
            }
        }

        submenu.addItem(.separator())
        submenu.addItem(item("Refresh Devices", #selector(refreshDevices)))
        return submenu
    }

    private func displayMenu(settings: RecorderSettings) -> NSMenu {
        let submenu = makeSubmenu()

        let main = item("Main Display", #selector(selectDisplay(_:)), represented: NSNull())
        main.state = settings.captureDisplayID == nil ? .on : .off
        submenu.addItem(main)

        if displays.isEmpty {
            submenu.addItem(item("No displays loaded", nil, enabled: false))
        } else {
            submenu.addItem(.separator())
            for display in displays {
                let title = "\(display.name) — \(display.width)×\(display.height)"
                let entry = item(
                    title,
                    #selector(selectDisplay(_:)),
                    represented: NSNumber(value: display.id)
                )
                entry.state = settings.captureDisplayID == display.id ? .on : .off
                submenu.addItem(entry)
            }
        }

        submenu.addItem(.separator())
        submenu.addItem(item("Refresh Displays", #selector(refreshDisplaysAction)))
        return submenu
    }

    private func qualityMenu(settings: RecorderSettings) -> NSMenu {
        let submenu = makeSubmenu()
        for preset in QualityPreset.allCases {
            let entry = item(preset.displayName, #selector(selectQuality(_:)), represented: preset.rawValue)
            entry.state = settings.quality == preset ? .on : .off
            submenu.addItem(entry)
        }
        return submenu
    }

    private func advancedMenu(settings: RecorderSettings) -> NSMenu {
        let submenu = makeSubmenu()

        let keep = item("Keep Segment Files", #selector(toggleKeepSegments))
        keep.state = settings.keepSegments ? .on : .off
        submenu.addItem(keep)

        let cursor = item("Show Cursor", #selector(toggleShowCursor))
        cursor.state = settings.showCursor ? .on : .off
        submenu.addItem(cursor)

        let login = item("Launch at Login", #selector(toggleLaunchAtLogin))
        login.state = settings.launchAtLogin ? .on : .off
        submenu.addItem(login)

        return submenu
    }

    // MARK: Item helpers

    private func item(
        _ title: String,
        _ action: Selector?,
        represented: Any? = nil,
        enabled: Bool = true
    ) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = action == nil ? nil : self
        entry.representedObject = represented
        entry.isEnabled = enabled
        return entry
    }

    private func submenuItem(_ title: String, _ submenu: NSMenu) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.submenu = submenu
        entry.isEnabled = true
        return entry
    }

    private func makeSubmenu() -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        return submenu
    }

    // MARK: Actions

    @objc private func startOrStop() {
        switch controller.state {
        case .idle:
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.controller.startRecording()
                } catch {
                    PermissionAlerts.show(error)
                }
            }
        case .recording, .paused:
            Task { [weak self] in
                guard let self else { return }
                do {
                    _ = try await self.controller.stopRecording()
                } catch {
                    PermissionAlerts.show(error)
                }
            }
        default:
            break
        }
    }

    @objc private func pauseOrResume() {
        switch controller.state {
        case .recording:
            Task { [weak self] in
                await self?.controller.pauseRecording()
            }
        case .paused:
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.controller.resumeRecording()
                } catch {
                    PermissionAlerts.show(error)
                }
            }
        default:
            break
        }
    }

    @objc private func toggleSystemAudio() {
        controller.updateSettings { $0.recordSystemAudio.toggle() }
    }

    @objc private func toggleMicrophone(_ sender: NSMenuItem) {
        guard let deviceID = sender.representedObject as? String else { return }
        controller.updateSettings { settings in
            if let index = settings.microphoneIDs.firstIndex(of: deviceID) {
                settings.microphoneIDs.remove(at: index)
            } else {
                settings.microphoneIDs.append(deviceID)
            }
        }
    }

    @objc private func useDefaultMicrophone() {
        controller.updateSettings { $0.microphoneIDs = [] }
    }

    @objc private func selectAllMicrophones() {
        let ids = AudioCaptureEngine.availableMicrophones().map(\.id)
        controller.updateSettings { $0.microphoneIDs = ids }
    }

    @objc private func toggleRecordCamera() {
        controller.updateSettings { $0.recordCamera.toggle() }
    }

    @objc private func selectCamera(_ sender: NSMenuItem) {
        let value: String? = sender.representedObject is NSNull
            ? nil
            : sender.representedObject as? String
        controller.updateSettings { $0.cameraID = value }
    }

    @objc private func selectDisplay(_ sender: NSMenuItem) {
        let value: UInt32?
        if let number = sender.representedObject as? NSNumber {
            value = number.uint32Value
        } else {
            value = nil
        }
        controller.updateSettings { $0.captureDisplayID = value }
    }

    @objc private func selectQuality(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let preset = QualityPreset(rawValue: raw) else { return }
        controller.updateSettings { $0.quality = preset }
    }

    @objc private func toggleKeepSegments() {
        controller.updateSettings { $0.keepSegments.toggle() }
    }

    @objc private func toggleShowCursor() {
        controller.updateSettings { $0.showCursor.toggle() }
    }

    @objc private func toggleLaunchAtLogin() {
        controller.updateSettings { $0.launchAtLogin.toggle() }
    }

    @objc private func refreshDevices() {
        // Devices are re-enumerated every time the menu opens; rebuilding the menu
        // while it is still tracking is unsupported, so just dismiss it.
        menu.cancelTracking()
    }

    @objc private func refreshDisplaysAction() {
        refreshDisplays()
        menu.cancelTracking()
    }

    @objc private func openRecordingsFolder() {
        controller.openRecordingsFolder()
    }

    @objc private func openLastRecording() {
        controller.openLastRecording()
    }

    @objc private func revealLastRecording() {
        controller.revealLastRecording()
    }

    @objc private func copyLastPath() {
        controller.copyLastRecordingPath()
    }

    @objc private func recoverInterrupted() {
        let count = controller.recoverableSessions.count
        guard count > 0 else { return }
        guard PermissionAlerts.confirmRecovery(count: count) else { return }
        Task { [weak self] in
            await self?.controller.recoverAllInterrupted()
        }
    }

    @objc private func relaunchApp() {
        if controller.isBusy {
            PermissionAlerts.showInfo(
                title: "RecBar",
                message: "Finish the current recording before relaunching."
            )
            return
        }
        AppRelauncher.relaunch()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: Displays

    public func refreshDisplays() {
        displayTask?.cancel()
        displayTask = Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await ScreenCaptureEngine.availableDisplays()
                guard !Task.isCancelled else { return }
                self.displays = loaded
                self.menu.update()
            } catch {
                NSLog("RecBar: could not load displays: %@", error.localizedDescription)
            }
        }
    }
}
