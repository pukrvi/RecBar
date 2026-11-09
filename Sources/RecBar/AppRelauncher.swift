import AppKit

/// Relaunches the app as a fresh process. macOS only applies a newly granted
/// Screen Recording permission to a process started after the grant, so the
/// permission alert offers this instead of leaving the user stuck.
public enum AppRelauncher {
    public static func relaunch() {
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app" else {
            // Running the bare binary from SwiftPM: there is no bundle to reopen.
            NSApp.terminate(nil)
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                if error == nil {
                    NSApp.terminate(nil)
                } else {
                    NSApp.activate(ignoringOtherApps: true)
                    let alert = NSAlert()
                    alert.messageText = "RecBar could not relaunch"
                    alert.informativeText = error?.localizedDescription ?? "Quit RecBar and open it again from Applications."
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }
    }
}
