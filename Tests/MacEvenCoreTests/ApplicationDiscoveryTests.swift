import Foundation
import Darwin
import MacEvenCore

final class BulkProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(done: Int, total: Int, name: String) { lock.withLock { storage.append("\(done)/\(total)/\(name)") } }
    var values: [String] { lock.withLock { storage } }
}

final class ApplicationDiscoveryTests {
    func testPreviewScopeSizesAndIsolation() throws {
        let fm = FileManager.default
        let raw = fm.temporaryDirectory.appendingPathComponent("MacEven-related-data-\(UUID())")
        try fm.createDirectory(at: raw, withIntermediateDirectories: true)
        let home = try canonicalFileURL(raw), apps = home.appendingPathComponent("Applications")
        defer { try? fm.removeItem(at: home) }
        let app = apps.appendingPathComponent("Lark.app"), id = "com.electron.lark"
        try makeTestApplication(app, id: id)
        try makeTestApplication(app.appendingPathComponent("Contents/Frameworks/Helper.app"), id: id + ".helper")
        let exact = home.appendingPathComponent("Library/Preferences/\(id).plist")
        let named = home.appendingPathComponent("Library/Application Support/LarkShell")
        let helper = home.appendingPathComponent("Library/Caches/\(id).helper")
        let shared = home.appendingPathComponent("Library/Group Containers/group.\(id)")
        let service = home.appendingPathComponent("Library/LaunchAgents/unrelated-filename.plist")
        for url in [named, helper, shared] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            try Data(repeating: 42, count: 8192).write(to: url.appendingPathComponent("fixture"))
        }
        try fm.linkItem(at: named.appendingPathComponent("fixture"), to: helper.appendingPathComponent("same-inode"))
        for url in [exact, service] { try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) }
        try Data([1]).write(to: exact)
        try PropertyListSerialization.data(fromPropertyList: ["ProgramArguments": [app.appendingPathComponent("Contents/MacOS/Test").path]], format: .xml, options: 0).write(to: service)
        let lookalike = home.appendingPathComponent("Library/Caches/\(id)ish")
        let unrelated = home.appendingPathComponent("Library/Application Support/Unrelated")
        try fm.createDirectory(at: lookalike, withIntermediateDirectories: true)
        try fm.createDirectory(at: unrelated, withIntermediateDirectories: true)
        let chineseApp = apps.appendingPathComponent("飞书.app")
        try makeTestApplication(chineseApp, id: "test.chinese")
        let chineseData = home.appendingPathComponent("Library/Application Support/飞书")
        try fm.createDirectory(at: chineseData, withIntermediateDirectories: true)
        let index = try DiskIndex(url: home.appendingPathComponent("index.sqlite"))
        let remover = ApplicationRemoval(index: index, home: home, roots: [apps])
        _ = try remover.scan(token: CancellationToken())
        let preview = try remover.inspectRelatedData(id: app.path, token: CancellationToken())
        let expectedSize = try [named.appendingPathComponent("fixture"), helper.appendingPathComponent("fixture"), shared.appendingPathComponent("fixture"), exact, service].reduce(Int64(0)) { try $0 + FileIdentity.read($1).allocated }
        guard Set(preview.items.map(\.url.path)) == Set([exact, named, helper, shared, service].map(\.path)),
              preview.items.first(where: { $0.url.path == exact.path })?.includedInRemoval == true,
              preview.items.first(where: { $0.url.path == helper.path })?.evidence.contains("内嵌程序") == true,
              preview.items.first(where: { $0.url.path == named.path })?.includedInRemoval == true,
              preview.items.filter({ ![exact.path, named.path].contains($0.url.path) }).allSatisfy({ !$0.includedInRemoval }),
              preview.items.allSatisfy({ $0.allocatedSize != nil && $0.issue == nil }),
              preview.allocatedSize == expectedSize else {
            throw MacEvenError("related data scope, ownership or sizes incorrect: \(preview)")
        }
        let before = try fm.contentsOfDirectory(at: home, includingPropertiesForKeys: [])
        for _ in 0..<3 { _ = try remover.inspectRelatedData(id: app.path, token: CancellationToken()) }
        guard Set(try fm.contentsOfDirectory(at: home, includingPropertiesForKeys: [])) == Set(before) else {
            throw MacEvenError("preview indices accumulated")
        }
        let plan = try remover.prepareDataRemoval(id: app.path, token: CancellationToken(), isRunning: { _ in false })
        guard Set(plan.paths.map(\.path)) == Set([exact, named].map(\.path)), fm.fileExists(atPath: app.path), fm.fileExists(atPath: named.path) else {
            throw MacEvenError("discovery expanded deletion or changed data")
        }
        let chinesePreview = try remover.inspectRelatedData(id: chineseApp.path, token: CancellationToken())
        guard chinesePreview.items.map(\.url.path) == [chineseData.path], chinesePreview.items[0].includedInRemoval == true else {
            throw MacEvenError("short non-Latin app names were excluded")
        }
        let link = home.appendingPathComponent("Library/Caches/LarkShell")
        try fm.createSymbolicLink(at: link, withDestinationURL: unrelated)
        chmod(helper.path, 0)
        let partial = try remover.inspectRelatedData(id: app.path, token: CancellationToken())
        chmod(helper.path, 0o700)
        guard partial.items.first(where: { $0.url.path == link.path })?.issue != nil,
              partial.items.first(where: { $0.url.path == link.path })?.allocatedSize == nil,
              partial.items.first(where: { $0.url.path == helper.path })?.issue != nil,
              partial.items.first(where: { $0.url.path == helper.path })?.allocatedSize == nil else {
            throw MacEvenError("unsafe or unreadable data reported as zero")
        }
        let cancelled = CancellationToken(); cancelled.cancel()
        var cancellationRefused = false
        do { _ = try remover.inspectRelatedData(id: app.path, token: cancelled) }
        catch { cancellationRefused = true }
        guard cancellationRefused else { throw MacEvenError("cancelled preview accepted") }
        guard remover.moveIncludingData(plan: plan, isRunning: { _ in true })[0].destination == nil else {
            throw MacEvenError("preview invalidated removal protection")
        }
    }

    func testBulkInspectionMatchesSingleAppAndSkips() throws {
        let fm = FileManager.default
        let raw = fm.temporaryDirectory.appendingPathComponent("MacEven-bulk-data-\(UUID())")
        try fm.createDirectory(at: raw, withIntermediateDirectories: true)
        let home = try canonicalFileURL(raw), apps = home.appendingPathComponent("Applications")
        defer { try? fm.removeItem(at: home) }
        let first = apps.appendingPathComponent("BulkOne.app"), firstID = "test.bulk.one"
        let second = apps.appendingPathComponent("BulkTwo.app"), secondID = "test.bulk.two"
        let protectedApp = apps.appendingPathComponent("Protected.app"), protectedID = "com.apple.test.protected"
        let broken = apps.appendingPathComponent("Broken.app")
        try makeTestApplication(first, id: firstID)
        try makeTestApplication(second, id: secondID)
        try makeTestApplication(protectedApp, id: protectedID)
        for (path, size) in [("Library/Caches/\(firstID)/data", 4096), ("Library/Application Support/BulkTwo/data", 8192),
            ("Library/Caches/BulkTwo/data", 16384), ("Library/Caches/protected.bulk", 2048)] {
            let url = home.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 9, count: size).write(to: url)
        }
        try fm.createDirectory(at: broken.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try Data("invalid plist".utf8).write(to: broken.appendingPathComponent("Contents/Info.plist"))
        let index = try DiskIndex(url: home.appendingPathComponent("index.sqlite"))
        let remover = ApplicationRemoval(index: index, home: home, roots: [apps])
        _ = try remover.scan(token: CancellationToken())
        let result = try remover.inspectAllRelatedData(token: CancellationToken())
        guard !result.cancelled, result.previews.count == 2, result.skipped.count == 2, result.warnings.isEmpty,
              result.skipped[protectedApp.path]?.contains("受保护") == true, result.skipped[broken.path]?.contains("标识") == true else {
            throw MacEvenError("bulk scope, skips or warnings incorrect: \(result.skipped)")
        }
        guard let firstPreview = result.previews.first(where: { $0.applicationID == first.path }),
              let secondPreview = result.previews.first(where: { $0.applicationID == second.path }) else {
            throw MacEvenError("bulk previews missing for both applications")
        }
        // 每个应用只拿到自己的数据，大小与将清理范围都统计完整。
        for preview in [firstPreview, secondPreview] {
            guard !preview.items.isEmpty, preview.items.allSatisfy({ $0.allocatedSize != nil && $0.issue == nil }),
                  preview.allocatedSize == preview.items.reduce(0, { $0 + ($1.allocatedSize ?? 0) }) else {
                throw MacEvenError("bulk preview sizes missing: \(preview.items)")
            }
        }
        let firstPaths = Set(firstPreview.items.map(\.url.path))
        let secondPaths = Set(secondPreview.items.map(\.url.path))
        guard firstPaths == Set([home.appendingPathComponent("Library/Caches/\(firstID)").path]) else {
            throw MacEvenError("first app scope wrong: \(firstPaths)")
        }
        guard secondPaths == Set([home.appendingPathComponent("Library/Application Support/BulkTwo").path,
            home.appendingPathComponent("Library/Caches/BulkTwo").path]) else {
            throw MacEvenError("second app scope wrong or cross-contaminated: \(secondPaths)")
        }
        guard !firstPaths.contains(where: { $0.contains("protected") || $0.contains("BulkTwo") }) else {
            throw MacEvenError("bulk inspection leaked other applications' data: \(firstPaths)")
        }
        // 逐应用检查必须给出同样的范围、大小与纳入判断。
        for (app, bulk) in [(first, firstPreview), (second, secondPreview)] {
            let single = try remover.inspectRelatedData(id: app.path, token: CancellationToken())
            guard single.items.map(\.url.path) == bulk.items.map(\.url.path),
                  single.items.map(\.allocatedSize) == bulk.items.map(\.allocatedSize),
                  single.items.map(\.includedInRemoval) == bulk.items.map(\.includedInRemoval) else {
                throw MacEvenError("bulk result diverged from single-app inspection: \(single.items.map(\.url.path)) / \(bulk.items.map(\.url.path))")
            }
        }
        // 再次批量检测使用新的目录清单，结果不变；临时统计索引不残留。
        let repeated = try remover.inspectAllRelatedData(token: CancellationToken())
        let describe = { (previews: [ApplicationDataPreview]) in previews.map { "\($0.applicationID)|\($0.items.map { "\($0.url.path):\($0.allocatedSize ?? -1)" }.joined(separator: ","))" } }
        guard describe(repeated.previews) == describe(result.previews) else {
            throw MacEvenError("repeated bulk inspection changed results")
        }
        guard try fm.contentsOfDirectory(atPath: home.path).allSatisfy({ !$0.hasPrefix("related-data-") }) else {
            throw MacEvenError("bulk inspection left temporary indexes behind")
        }
        // 进度按应用上报；在第一个应用后取消时返回部分结果且不抛错。
        let partial = CancellationToken(), log = BulkProgressLog()
        let cancelled = try remover.inspectAllRelatedData(token: partial) { progress in
            log.append(done: progress.done, total: progress.total, name: progress.applicationName)
            if progress.done == 1 { partial.cancel() }
        }
        let reported = log.values
        guard reported.count == 2, reported[0] == "0/2/", reported[1] == "1/2/BulkOne",
              cancelled.cancelled, cancelled.previews.count == 1 else {
            throw MacEvenError("bulk progress or cancellation incorrect: \(reported) cancelled=\(cancelled.cancelled) previews=\(cancelled.previews.count)")
        }
        let preCancelled = CancellationToken(); preCancelled.cancel()
        let immediate = try remover.inspectAllRelatedData(token: preCancelled)
        guard immediate.cancelled, immediate.previews.isEmpty, immediate.skipped.count == 2 else {
            throw MacEvenError("pre-cancelled bulk inspection returned results")
        }
        guard fm.fileExists(atPath: first.path), fm.fileExists(atPath: home.appendingPathComponent("Library/Caches/\(firstID)").path) else {
            throw MacEvenError("bulk inspection modified applications or data")
        }
    }
}
