import AppKit
import UserNotifications

/// Plan-limit threshold alerts, shown only inside the app (the "À traiter" card); never macOS notifications.
final class LimitAlerts {
    static let shared = LimitAlerts()

    /// Clears anything earlier versions left in Notification Center; the app no longer posts there.
    func setUp() {
        let center = UNUserNotificationCenter.current()
        center.removeAllDeliveredNotifications()
        center.removeAllPendingNotificationRequests()
    }

    static var threshold: Double { UserDefaults.standard.double(forKey: "alertThreshold") }

    func evaluate(_ plan: PlanUsage?) {
        guard let plan else { return }
        DispatchQueue.main.async { AttentionCenter.shared.observeLimits(plan, threshold: Self.threshold) }
    }
}
