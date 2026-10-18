import Foundation
import MacEvenCore

@main struct OperationStatsChecks {
    @MainActor static func main() {
        // 域名会登记到 MACEVEN_TEST_DEFAULTS_LOG，进程退出后由 check-status.sh 删除残留 plist。
        let (defaults, name) = makeTestDefaults(prefix: "MacEven.stats.tests")
        defer { defaults.removePersistentDomain(forName: name) }
        let stats = OperationStats(defaults: defaults)
        let moved = TrashResult(id: 1, path: "/test/a", destination: URL(fileURLWithPath: "/trash/a"), error: "索引同步失败")
        let failed = TrashResult(id: 2, path: "/test/b", destination: nil, error: "保留")
        stats.record([moved, failed], source: "disk")
        precondition(stats.movedItems == 1, "count must reflect actual moves even when index update failed")
        stats.record([moved, failed], source: "disk")
        precondition(stats.movedItems == 1, "republication counted same operation twice")
        stats.record([], source: "disk")
        stats.record([TrashResult(id: 3, path: "/test/c", destination: URL(fileURLWithPath: "/trash/c"), error: nil)], source: "cache")
        precondition(OperationStats(defaults: defaults).movedItems == 2, "statistics lost after recreation")
        let app = TrashResult(id: 4, path: "/Applications/A.app", destination: URL(fileURLWithPath: "/trash/A.app"), error: nil)
        let data = TrashResult(id: 5, path: "/Users/t/Library/Caches/a", destination: URL(fileURLWithPath: "/trash/a-cache"), error: nil)
        let kept = TrashResult(id: 6, path: "/Applications/B.app", destination: nil, error: "运行中")
        stats.record([app, data, kept], source: "applications")
        stats.record([app, data, kept], source: "applications")
        stats.record([TrashResult(id: 7, path: "/x/C.app", destination: URL(fileURLWithPath: "/trash/C.app"), error: nil)], source: "disk")
        precondition(stats.uninstalledApps == 1 && stats.movedItems == 5, "uninstall count must include only moved app bundles from application removal")
        stats.recordScan(); stats.recordScan()
        let reloaded = OperationStats(defaults: defaults)
        precondition(reloaded.uninstalledApps == 1 && reloaded.scans == 2, "running totals lost after recreation")
        print("PASS: uninstalled app and scan running totals")
        print("PASS: actual moved-path statistics, partial failure, duplicate delivery, persistent count")
    }
}
