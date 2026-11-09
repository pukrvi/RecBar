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

        let controller = RecorderController()
        self.controller = controller

        let notifier = Notifier()
        self.notifier = notifier

        let statusMenu = StatusMenuController(controller: controller)
        self.statusMenu = statusMenu

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
}
