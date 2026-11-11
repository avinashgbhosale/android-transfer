import Foundation
import UserNotifications

final class TransferNotifications: ObservableObject {
    static let shared = TransferNotifications()
    @Published private(set) var enabled: Bool
    private let defaultsKey = "transferNotificationsEnabled"

    private init() {
        enabled = UserDefaults.standard.bool(forKey: defaultsKey)
    }

    func toggle() {
        if enabled {
            UserDefaults.standard.set(false, forKey: defaultsKey)
            enabled = false
            return
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async {
                UserDefaults.standard.set(granted, forKey: self.defaultsKey)
                self.enabled = granted
            }
        }
    }

    func send(title: String, body: String) {
        guard UserDefaults.standard.bool(forKey: defaultsKey) else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
