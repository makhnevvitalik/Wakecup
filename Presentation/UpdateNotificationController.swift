import AppKit
import Combine
import UserNotifications

@MainActor
final class UpdateNotificationController: NSObject, UNUserNotificationCenterDelegate {
    private nonisolated static let identifier = "wakecup.update"
    private static let notifiedVersionKey = "lastNotifiedUpdateVersion"
    private var startupCheck: AnyCancellable?

    func checkAtLaunch(using checker: UpdateChecker) {
        UNUserNotificationCenter.current().delegate = self
        startupCheck = checker.$state
            .compactMap { state -> UpdateCheckResult? in
                guard case let .finished(result) = state else { return nil }
                return result
            }
            .first()
            .sink { [weak self] result in
                guard case let .updateAvailable(tag, _) = result else { return }
                Task { await self?.notify(version: tag) }
            }
        checker.check()
    }

    private func notify(version: String) async {
        let defaults = UserDefaults.standard
        if let previous = defaults.string(forKey: Self.notifiedVersionKey),
           AppVersion(previous) == AppVersion(version) { return }

        let center = UNUserNotificationCenter.current()
        var settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            guard (try? await center.requestAuthorization(options: [.alert])) == true else { return }
            settings = await center.notificationSettings()
        }
        let showsAlert = settings.alertSetting == .enabled && settings.alertStyle != .none
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional,
              showsAlert || settings.notificationCenterSetting == .enabled else { return }

        let content = UNMutableNotificationContent()
        content.title = localized("Wakecup update available")
        content.body = localizedFormat("%@ is available.", version)
        do {
            try await center.add(UNNotificationRequest(identifier: Self.identifier, content: content, trigger: nil))
            defaults.set(version, forKey: Self.notifiedVersionKey)
        } catch {
            NSLog("Wakecup update notification unavailable: %@", error.localizedDescription)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                             willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                             didReceive response: UNNotificationResponse) async {
        guard response.notification.request.identifier == Self.identifier,
              response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        await MainActor.run { _ = NSWorkspace.shared.open(UpdateChecker.latestReleaseURL) }
    }
}
