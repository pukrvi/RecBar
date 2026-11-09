import AppKit
import Darwin
import RecBarCore

/// Thread-safe carrier for the self-test exit status.
final class ExitStatusBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Int32 = 1

    var value: Int32 {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }
}

// Diagnostic mode: reports the app's real TCC state when launched through
// LaunchServices (launching the bare binary from a shell would attribute the
// check to the shell instead of RecBar):
//   open -a /Applications/RecBar.app --args --permission-status
if CommandLine.arguments.contains("--permission-status") {
    let status: [String: Any] = [
        "screen": ScreenCaptureEngine.hasPermission(),
        "microphone": AudioCaptureEngine.hasPermission(),
        "camera": CameraCaptureEngine.hasPermission()
    ]
    if let data = try? JSONSerialization.data(withJSONObject: status, options: [.sortedKeys]) {
        try? data.write(to: URL(fileURLWithPath: "/tmp/recbar-permission-status.json"))
    }
    exit(status["screen"] as? Bool == true ? 0 : 2)
}

// Headless self-test mode (no permissions needed, no UI):
//   RecBar --selftest
//   RecBar --selftest-recovery
if CommandLine.arguments.contains("--selftest") || CommandLine.arguments.contains("--selftest-recovery") {
    let recoveryOnly = CommandLine.arguments.contains("--selftest-recovery")
    let semaphore = DispatchSemaphore(value: 0)
    let status = ExitStatusBox()
    Task {
        status.value = recoveryOnly ? await SelfTest.runRecovery() : await SelfTest.run()
        semaphore.signal()
    }
    semaphore.wait()
    exit(status.value)
}

// Top-level code always runs on the main thread, so this assertion is safe and
// lets us construct the @MainActor app delegate from the executable entry point.
MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    application.run()
}
