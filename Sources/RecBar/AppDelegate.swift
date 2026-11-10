import AppKit
import Carbon.HIToolbox
import RecBarCore

/// Owns the recorder, the status-bar menu, the global hot keys, and notifications.
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {

    private var controller: RecorderController!
    private var statusMenu: StatusMenuController!
    private var hotKeys: HotKeyManager?
    private var notifier: Notifier?
    private var didPromptRecovery = false
    /// Set when we return `.terminateLater`. Any further terminate request must be
    /// refused, otherwise a second ⌘Q can kill the app mid-finalize.
    private var isTerminating = false

    // MARK: Launch

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Ask the system for Screen Recording at most once in the app's lifetime.
        // Every later start uses the alert + Relaunch flow instead of re-prompting.
        ScreenCaptureEngine.requestPermissionOnceOnFirstLaunch()
        installMainMenu()

        let controller = RecorderController()
        self.controller = controller

        let notifier = Notifier()
        self.notifier = notifier

        let statusMenu = StatusMenuController(controller: controller)
        self.statusMenu = statusMenu

        // Diagnostic hook for automated layout checks: open the panel once at launch.
        if CommandLine.arguments.contains("--show-panel") {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 600_000_000)
                self?.statusMenu.showPanel()
            }
        }

        controller.onStateChanged = { [weak statusMenu] in statusMenu?.refresh() }
        controller.onTick = { [weak statusMenu] in statusMenu?.refresh() }
        controller.onNotice = { [weak notifier] message in
            notifier?.post(title: "RecBar", body: message)
        }
        controller.onError = { error in
            PermissionAlerts.show(error)
        }

        let hotKeys = HotKeyManager()
        self.hotKeys = hotKeys

        // ⌃⌥⌘R — toggle start/stop.
        hotKeys.register(
            id: 1,
            keyCode: UInt32(kVK_ANSI_R),
            modifiers: UInt32(controlKey) | UInt32(optionKey) | UInt32(cmdKey)
        ) { [weak self] in
            Task { @MainActor in
                guard let self, !self.isTerminating else { return }
                do {
                    if self.controller.isRecording || self.controller.isPaused {
                        _ = try await self.controller.stopRecording()
                    } else {
                        try await self.controller.startRecording()
                    }
                } catch {
                    PermissionAlerts.show(error)
                }
            }
        }

        // ⌃⌥⌘P — pause / resume.
        hotKeys.register(
            id: 2,
            keyCode: UInt32(kVK_ANSI_P),
            modifiers: UInt32(controlKey) | UInt32(optionKey) | UInt32(cmdKey)
        ) { [weak self] in
            Task { @MainActor in
                guard let self, !self.isTerminating else { return }
                if self.controller.isRecording {
                    await self.controller.pauseRecording()
                } else if self.controller.isPaused {
                    do {
                        try await self.controller.resumeRecording()
                    } catch {
                        PermissionAlerts.show(error)
                    }
                }
            }
        }

        controller.refreshRecoverableSessions()

        // Offer to recover interrupted recordings shortly after launch.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self, !self.didPromptRecovery else { return }
            guard !self.controller.recoverableSessions.isEmpty else { return }
            self.didPromptRecovery = true
            if PermissionAlerts.confirmRecovery(count: self.controller.recoverableSessions.count) {
                await self.controller.recoverAllInterrupted()
            }
        }
    }

    // MARK: Termination

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A quit that is already saving must never be pre-empted by a second ⌘Q.
        if isTerminating {
            return .terminateCancel
        }

        switch controller.state {
        case .merging, .recovering, .starting, .stopping:
            PermissionAlerts.showInfo(
                title: "RecBar",
                message: "RecBar is still finishing a file. Try again in a moment."
            )
            return .terminateCancel
        case .recording, .paused:
            if !PermissionAlerts.confirmQuitWhileRecording() {
                return .terminateCancel
            }
            isTerminating = true
            Task { [weak self] in
                guard let self else {
                    NSApp.reply(toApplicationShouldTerminate: true)
                    return
                }
                do {
                    _ = try await self.controller.stopRecording()
                } catch {
                    // Best effort; the segment files stay recoverable either way.
                }
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        default:
            return .terminateNow
        }
    }

    // MARK: Main menu

    /// RecBar is an accessory app with no Dock icon, but a minimal main menu keeps
    /// ⌘Q, ⌘H, About, and the standard text-editing shortcuts working while the
    /// panel or an alert is focused.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        let about = NSMenuItem(
            title: "About RecBar",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        about.target = NSApp
        appMenu.addItem(about)
        appMenu.addItem(.separator())

        let hide = NSMenuItem(
            title: "Hide RecBar",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        hide.target = NSApp
        appMenu.addItem(hide)

        let hideOthers = NSMenuItem(
            title: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        hideOthers.target = NSApp
        appMenu.addItem(hideOthers)

        let showAll = NSMenuItem(
            title: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        showAll.target = NSApp
        appMenu.addItem(showAll)
        appMenu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit RecBar",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quit.target = NSApp
        appMenu.addItem(quit)
        appMenuItem.submenu = appMenu

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }
}
