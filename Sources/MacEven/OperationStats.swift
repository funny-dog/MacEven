import Foundation
import Combine
import MacEvenCore

@MainActor final class OperationStats: ObservableObject {
    @Published private(set) var movedItems: Int
    /// 已卸载：应用卸载来源中实际移到废纸篓的 .app 包数（0.28.0 起计）。
    @Published private(set) var uninstalledApps: Int
    /// 已扫描：各页开始的扫描次数，含之后取消的扫描（0.28.0 起计）。
    @Published private(set) var scans: Int
    private let defaults: UserDefaults
    private var previous: [String: Set<String>] = [:]
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        movedItems = max(0, defaults.integer(forKey: "status.movedItems"))
        uninstalledApps = max(0, defaults.integer(forKey: "status.uninstalledApps"))
        scans = max(0, defaults.integer(forKey: "status.scans"))
    }
    func record(_ results: [TrashResult], source: String) {
        guard !results.isEmpty else { return }
        let moved = results.filter { $0.destination != nil }
        let destinations = Set(moved.compactMap { $0.destination?.path })
        let fresh = destinations.subtracting(previous[source] ?? [])
        previous[source] = destinations
        movedItems = Self.adding(movedItems, fresh.count)
        defaults.set(movedItems, forKey: "status.movedItems")
        if source == "applications" {
            let apps = moved.filter { fresh.contains($0.destination!.path) && $0.path.hasSuffix(".app") }.count
            uninstalledApps = Self.adding(uninstalledApps, apps)
            defaults.set(uninstalledApps, forKey: "status.uninstalledApps")
        }
    }
    func recordScan() {
        scans = Self.adding(scans, 1)
        defaults.set(scans, forKey: "status.scans")
    }
    private static func adding(_ value: Int, _ count: Int) -> Int {
        let (total, overflow) = value.addingReportingOverflow(count)
        return overflow ? Int.max : total
    }
}
