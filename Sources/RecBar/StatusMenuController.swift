import AppKit
import RecBarCore
import SwiftUI

/// Owns the menu-bar status item and the visual popover panel. The status item
/// still shows the live recording timer; the panel itself is SwiftUI so the
/// controls and settings can be laid out as a grid instead of a long menu.
@MainActor
public final class StatusMenuController: NSObject {
    private let controller: RecorderController
    private let statusItem: NSStatusItem
    private let model: PanelModel
    private let popover = NSPopover()
    private let hostingController: NSHostingController<PanelView>

    /// Vector menu-bar artwork parsed once per state and appearance. `refresh()` runs
    /// every second while recording, so re-decoding the SVG on each tick would be wasteful.
    private var statusImages: [String: NSImage] = [:]
    /// System appearance changes while RecBar is idle would otherwise leave a stale
    /// black/white icon in the menu bar until the next recording tick.
    private var appearanceObservers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    /// Monitors installed only while the panel is open, so a click anywhere outside
    /// the panel dismisses it even when the click lands on the desktop or another
    /// app's menu-bar item instead of a normal window.
    private var panelEventMonitors: [Any] = []
    private var panelObservers: [NSObjectProtocol] = []

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
        // Variable length keeps the idle item as compact as every other menu-bar
        // icon. It grows only when the timer text appears while recording.
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let model = PanelModel(controller: controller)
        self.model = model
        self.hostingController = NSHostingController(rootView: PanelView(model: model))

        super.init()

        hostingController.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hostingController
        popover.behavior = .transient
        popover.animates = true
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.delegate = self

        statusItem.isVisible = true

        if let button = statusItem.button {
            button.imagePosition = .imageLeading
            button.imageScaling = .scaleProportionallyDown
            button.alignment = .left
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp])
        }

        // Starting a recording dismisses the panel, matching the menu-bar
        // behaviour users expect: pick your sources, hit Start, and get out of
        // the way. The status item's timer then carries the live state.
        model.onDismiss = { [weak self] in
            self?.closePanel()
        }

        observeAppearanceChanges()
        refresh()
    }

    deinit {
        for observer in appearanceObservers {
            observer.center.removeObserver(observer.token)
        }
        for monitor in panelEventMonitors {
            NSEvent.removeMonitor(monitor)
        }
        for observer in panelObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: Panel

    /// Opens the panel without a click. Used by the `--show-panel` diagnostic flag
    /// so the layout can be captured and reviewed in automated builds.
    public func showPanel() {
        guard let button = statusItem.button else { return }

        model.refresh()
        model.reloadDevices()
        hostingController.view.layoutSubtreeIfNeeded()
        let preferred = hostingController.preferredContentSize
        if preferred.width > 0, preferred.height > 0 {
            popover.contentSize = preferred
        }

        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        installDismissMonitors()
    }

    public func closePanel() {
        popover.performClose(nil)
    }

    // MARK: Dismissal

    /// `.transient` covers clicks on another app's window, but not every click on
    /// the desktop or the system menu bar. These monitors make outside clicks
    /// deterministic without touching clicks inside the panel or its native menus.
    private func installDismissMonitors() {
        removeDismissMonitors()

        if let global = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.closePanel() }
        } {
            panelEventMonitors.append(global)
        }

        let resign = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.closePanel() }
        }
        panelObservers.append(resign)
    }

    private func removeDismissMonitors() {
        for monitor in panelEventMonitors {
            NSEvent.removeMonitor(monitor)
        }
        panelEventMonitors.removeAll()

        for observer in panelObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        panelObservers.removeAll()
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPanel()
        }
    }

    // MARK: Status item

    /// Updates only the icon and timer text. Called once a second while recording.
    public func refresh() {
        updateStatusItem()
        if popover.isShown {
            model.refresh()
        }
    }

    private func updateStatusItem() {
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
}

// MARK: - NSPopoverDelegate

extension StatusMenuController: NSPopoverDelegate {
    public func popoverDidClose(_ notification: Notification) {
        removeDismissMonitors()
        model.hoveredControl = nil
    }
}
