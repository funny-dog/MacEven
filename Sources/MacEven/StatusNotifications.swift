import Combine
import Foundation
import UserNotifications
import MacEvenCore

@MainActor final class StatusNotifications: ObservableObject {
    @Published private(set) var enabled: Bool
    @Published private(set) var message: String?
    private let defaults: UserDefaults
    private var previousCamera = false
    private var previousMicrophone = false
    private var lowDevices: Set<String> = []
    private var generation = 0
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults; enabled = defaults.bool(forKey: "status.notifications")
    }
    func setEnabled(_ value: Bool) {
        generation += 1; let request = generation
        if !value { enabled = false; defaults.set(false, forKey: "status.notifications"); return }
        Task {
            do {
                let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                guard request == generation else { return }
                enabled = granted; defaults.set(granted, forKey: "status.notifications")
                message = granted ? nil : localized("系统未允许通知，请到系统设置 → 通知 → MacEven 查看。")
            } catch { if request == generation { message = error.localizedDescription } }
        }
    }
    func updatePrivacy(camera: Bool?, microphone: Bool?) {
        if enabled, camera == true, !previousCamera { send(id: "camera", body: localized("检测到摄像头被其他应用使用；系统接口未提供应用归属。")) }
        if enabled, microphone == true, !previousMicrophone { send(id: "microphone", body: localized("检测到麦克风被其他应用使用；系统接口未提供应用归属。")) }
        if let camera { previousCamera = camera }
        if let microphone { previousMicrophone = microphone }
    }
    func updateHardware(_ hardware: HardwareSnapshot) {
        var current: Set<String> = []
        for device in hardware.bluetoothAccessories.prefix(128) {
            let values = [device.batteryPercent, device.leftBatteryPercent, device.rightBatteryPercent, device.caseBatteryPercent].compactMap { $0 }
            if values.contains(where: { $0 <= 20 }) {
                current.insert(device.id)
                if enabled, !lowDevices.contains(device.id) { send(id: "accessory-\(device.id)", body: localized("\(device.name) 有电量读数低于或等于 20%。")) }
            }
        }
        if let percent = hardware.battery.currentCapacityPercent, percent <= 20, hardware.battery.isACConnected == false {
            current.insert("internal-battery")
            if enabled, !lowDevices.contains("internal-battery") { send(id: "internal-battery", body: localized("内置电池仅剩 \(percent)% 电量。")) }
        }
        // A missing device does not prove recharge; avoid repeated alerts after a short disconnect.
        lowDevices.formUnion(current)
        for device in hardware.bluetoothAccessories {
            let values = [device.batteryPercent, device.leftBatteryPercent, device.rightBatteryPercent, device.caseBatteryPercent].compactMap { $0 }
            if !values.isEmpty, values.allSatisfy({ $0 > 25 }) { lowDevices.remove(device.id) }
        }
        if hardware.battery.currentCapacityPercent.map({ $0 > 25 }) == true { lowDevices.remove("internal-battery") }
        if lowDevices.count > 256 { lowDevices = current }
    }
    private func send(id: String, body: String) {
        let content = UNMutableNotificationContent(); content.title = "MacEven"; content.body = body
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        Task { do { try await UNUserNotificationCenter.current().add(request) } catch { message = localized("通知发送失败：\(error.localizedDescription)") } }
    }
}
