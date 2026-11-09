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
    /// Vector menu-bar artwork parsed once per state and appearance. `refresh()` runs
    /// every second while recording, so re-decoding the SVG on each tick would be wasteful.
    private var statusImages: [String: NSImage] = [:]
    /// System appearance changes while RecBar is idle would otherwise leave a stale
    /// black/white icon in the menu bar until the next recording tick.
    private var appearanceObservers: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    /// Menu-bar artwork is shipped in two explicit colours instead of relying on
    /// template tinting: a tinted template (or a tinted title) can render dark
    /// against a dark translucent or coloured menu bar. The variants are picked
    /// from the status item's effective appearance, which reflects the actual
    /// menu-bar style (Aqua on a light bar, Dark Aqua on a dark bar).
    private enum BarStyle {
        /// Black artwork and text for a light menu bar.
        case light
        /// White artwork and text for a dark menu bar.
        case dark

        var suffix: String { self == .dark ? "white" : "black" }
        var color: NSColor { self == .dark ? .white : .black }
    }

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

        observeAppearanceChanges()
        refresh()
        refreshDisplays()
    }

    deinit {
        for observer in appearanceObservers {
            observer.center.removeObserver(observer.token)
        }
    }

    // MARK: Status item

    /// Updates only the icon and timer text. Called once a second while recording.
    public func refresh() {
        guard let button = statusItem.button else { return }

        let style = currentBarStyle
        // The artwork and title carry explicit colours; any tint would override them.
        button.contentTintColor = nil

        switch controller.state {
        case .idle:
            button.image = statusImage(
                "menubar-idle-\(style.suffix)",
                fallbackSymbol: "record.circle"
            )
            setTitle("", style: style)
        case .recording:
            button.image = statusImage(
                "menubar-recording-\(style.suffix)",
                fallbackSymbol: "record.circle.fill"
            )
            setTitle(" " + Formatting.clock(controller.elapsed), style: style)
        case .paused:
            button.image = statusImage(
                "menubar-paused-\(style.suffix)",
                fallbackSymbol: "pause.circle.fill"
            )
            setTitle(" " + Formatting.clock(controller.elapsed), style: style)
        case .merging:
            button.image = statusImage(
                "menubar-exporting-\(style.suffix)",
                fallbackSymbol: "arrow.triangle.2.circlepath"
            )
            let percent = Int((controller.mergeProgress * 100).rounded())
            setTitle(" \(percent)%", style: style)
        case .starting, .stopping:
            button.image = statusImage(
                "menubar-saving-\(style.suffix)",
                fallbackSymbol: "arrow.triangle.2.circlepath"
            )
            setTitle("", style: style)
        case .recovering:
            button.image = statusImage(
                "menubar-exporting-\(style.suffix)",
                fallbackSymbol: "arrow.triangle.2.circlepath"
            )
            setTitle("", style: style)
        }
    }

    /// The menu bar can be dark even when the app is in light mode (and vice versa),
    /// so prefer the status button's appearance over the app-wide one.
    private var currentBarStyle: BarStyle {
        let appearance = statusItem.button?.effectiveAppearance ?? NSApp.effectiveAppearance
        return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }

    /// Uses an attributed title so the timer is explicitly white or black instead of
    /// inheriting the system's vibrant menu-bar tint.
    private func setTitle(_ text: String, style: BarStyle) {
        guard let button = statusItem.button else { return }
        guard !text.isEmpty else {
            button.attributedTitle = NSAttributedString(string: "")
            return
        }
        let font = button.font
            ?? NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        button.attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: style.color
            ]
        )
    }

    /// Loads the shipped black or white vector variant. Falls back to a template
    /// SF Symbol, which macOS tints correctly, when running the bare binary without
    /// bundle resources.
    private func statusImage(_ name: String, fallbackSymbol: String) -> NSImage? {
        if let cached = statusImages[name] {
            return cached
        }

        if let url = Bundle.main.url(forResource: name, withExtension: "svg"),
           let image = NSImage(contentsOf: url) {
            // Explicitly not a template: the SVG already contains the final colour.
            image.isTemplate = false
            image.size = NSSize(width: 18, height: 18)
            statusImages[name] = image
            return image
        }

        let symbol = NSImage(
            systemSymbolName: fallbackSymbol,
            accessibilityDescription: "RecBar"
        )
        symbol?.size = NSSize(width: 18, height: 18)
        return symbol
    }

    /// Refreshes the icon when macOS switches between light and dark appearance, or
    /// when accessibility display options change the menu-bar appearance.
    private func observeAppearanceChanges() {
        let theme = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        appearanceObservers.append((DistributedNotificationCenter.default(), theme))

        let accessibility = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        appearanceObservers.append((NSWorkspace.shared.notificationCenter, accessibility))

        // Catches appearance changes that happened while the app was inactive.
        let active = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        appearanceObservers.append((NotificationCenter.default, active))
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
