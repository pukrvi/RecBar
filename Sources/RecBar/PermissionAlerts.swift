import AppKit
import RecBarCore

/// Modal alerts shown from the menu bar. Every call activates the app first so the
/// alert is visible even though RecBar has no Dock icon and usually no windows.
@MainActor
public enum PermissionAlerts {

    public static func show(_ error: Error) {
        activate()

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "RecBar"

        var message = error.localizedDescription
        if let suggestion = (error as? LocalizedError)?.recoverySuggestion,
           !suggestion.isEmpty {
            message += "\n\n" + suggestion
        }

        var openSettings: (() -> Void)?
        var offerRelaunch = false
        if let recBarError = error as? RecBarError {
            switch recBarError {
            case .screenPermissionDenied:
                message += "\n\nEnable RecBar under System Settings → Privacy & Security → Screen & System Audio Recording, then relaunch RecBar so macOS applies the grant. You only need to do this once."
                openSettings = { ScreenCaptureEngine.openScreenRecordingSettings() }
                offerRelaunch = true
            case .microphonePermissionDenied:
                openSettings = { AudioCaptureEngine.openMicrophoneSettings() }
            case .cameraPermissionDenied:
                openSettings = { CameraCaptureEngine.openCameraSettings() }
            default:
                break
            }
        }

        alert.informativeText = message

        if let openSettings, offerRelaunch {
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "Relaunch RecBar")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                openSettings()
            case .alertSecondButtonReturn:
                AppRelauncher.relaunch()
            default:
                break
            }
        } else if let openSettings {
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "OK")
            if alert.runModal() == .alertFirstButtonReturn {
                openSettings()
            }
        } else {
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    public static func confirmRecovery(count: Int) -> Bool {
        activate()
        let alert = NSAlert()
        alert.messageText = "Recover interrupted recordings?"
        let noun = count == 1 ? "recording" : "recordings"
        alert.informativeText = "RecBar found \(count) \(noun) that were interrupted. Recover them now?"
        alert.addButton(withTitle: "Recover")
        alert.addButton(withTitle: "Later")
        return alert.runModal() == .alertFirstButtonReturn
    }

    public static func confirmQuitWhileRecording() -> Bool {
        activate()
        let alert = NSAlert()
        alert.messageText = "RecBar is still recording"
        alert.informativeText = "Stop the recording and save it before quitting?"
        alert.addButton(withTitle: "Stop & Save")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    public static func showInfo(title: String, message: String) {
        activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static func activate() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
