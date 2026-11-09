import Foundation
import UserNotifications

/// Thin wrapper around UserNotifications. Notifications are a convenience only:
/// every failure here is logged and ignored so recording never depends on them.
public final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private let isBundled: Bool

    public override init() {
        isBundled = Bundle.main.bundleIdentifier != nil
        super.init()
        guard isBundled else { return }

        let center = UNUserNotificationCenter.current()
        // Without a delegate, macOS silently drops notifications while the app is
        // active — exactly when "Saved …" and low-disk warnings fire.
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                NSLog("RecBar: notification authorization failed: %@", error.localizedDescription)
            } else if !granted {
                NSLog("RecBar: notifications are disabled for this app")
            }
        }
    }

    public func post(title: String, body: String) {
        guard isBundled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = nil
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("RecBar: could not post notification: %@", error.localizedDescription)
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
