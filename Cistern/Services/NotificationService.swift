import Cocoa
import UserNotifications

class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                print("Notification authorization error: \(error)")
            }
        }
    }

    func sendBuildStarted(build: Build) {
        let content = UNMutableNotificationContent()
        content.title = "Build Started"
        content.body = "\(build.projectName) \u{2022} \(build.branch) \u{2022} \(build.workflowName)"
        content.sound = .default
        content.userInfo = ["url": build.webURL]

        let request = UNNotificationRequest(
            identifier: "build-\(build.projectSlug)-\(build.branch)-\(build.workflowName)-started",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }

    func sendBuildFinished(build: Build) {
        let content = UNMutableNotificationContent()

        switch build.status {
        case .success:
            content.title = "Build Succeeded"
        case .failed, .error, .failing:
            content.title = "Build Failed"
        case .canceled:
            content.title = "Build Canceled"
        default:
            content.title = "Build Finished"
        }

        content.body = "\(build.projectName) \u{2022} \(build.branch) \u{2022} \(build.workflowName) (\(build.durationString))"
        content.sound = .default
        content.userInfo = ["url": build.webURL]

        let request = UNNotificationRequest(
            identifier: "build-\(build.projectSlug)-\(build.branch)-\(build.workflowName)-finished",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // Handle notification click - open the build URL
        if let urlString = response.notification.request.content.userInfo["url"] as? String,
           let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
        completionHandler()
    }

    // Show notifications even when app is in foreground
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
