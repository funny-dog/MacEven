import Foundation
import Darwin

public struct InstalledApplication: Identifiable, Sendable, Equatable {
    public var id: String { url.path }
    public let url: URL
    public let bundleIdentifier: String
    public let name: String
    public let allocatedSize: Int64?
    public let logicalSize: Int64?
    public let cachePaths: [URL]
    public let blockedReason: String?
}

public struct ApplicationDataPlan: Sendable, Equatable {
    public let id: UUID
    public let applicationID: String
    public let paths: [URL]
    public let allocatedSize: Int64
    public let retainedReasons: [String]
    let candidatePaths: [URL]
}

public struct ApplicationScanResult: Sendable {
    public let applications: [InstalledApplication]
    public let incomplete: Bool
    public let errors: [String]
}

/// 批量关联数据检测的进度：每完成一个应用上报一次，便于界面逐个填充大小。
public struct ApplicationDataBulkProgress: Sendable {
    public let done: Int
    public let total: Int
    public let applicationName: String
    /// 刚完成应用的数据概况；跳过或失败时为 nil。
    public let preview: ApplicationDataPreview?

    public init(done: Int, total: Int, applicationName: String, preview: ApplicationDataPreview?) {
        self.done = done; self.total = total; self.applicationName = applicationName; self.preview = preview
    }
}

public struct ApplicationDataBulkResult: Sendable {
    public let previews: [ApplicationDataPreview]
    /// 未检测的应用及原因：受保护、标识无法识别、大小未统计或该应用检测失败。
    public let skipped: [String: String]
    public let cancelled: Bool
    /// 整批去重后的访问问题与扫描限制，最多 100 条。
    public let warnings: [String]

    public init(previews: [ApplicationDataPreview], skipped: [String: String], cancelled: Bool, warnings: [String]) {
        self.previews = previews; self.skipped = skipped; self.cancelled = cancelled; self.warnings = warnings
    }
}

// The caller's serial queue owns this session and its SQLite index.
public final class ApplicationRemoval {
    private struct Record {
        let url: URL
        let identifier: String
        let name: String
        let ancestors: [(URL, FileIdentity)]
        var rootID: Int64?
        var issue: String?
    }
    private let index: DiskIndex
    private let home: URL
    private let roots: [URL]
    private var records: [Record] = []
    private var invalid = false
    private struct DataRecord {
        let url: URL
        let rootID: Int64
        let ancestors: [(URL, FileIdentity)]
    }
    // 按应用分别保存，支持批量彻底卸载时同时冻结多份计划。
    private var dataRecords: [String: [DataRecord]] = [:]
    private var dataPlans: [String: ApplicationDataPlan] = [:]
    private let protection: ProtectionStore

    public init(index: DiskIndex, home: URL = FileManager.default.homeDirectoryForCurrentUser, roots: [URL]? = nil, protection: ProtectionStore = .shared) {
        self.index = index; self.home = (try? canonicalFileURL(home)) ?? home; self.protection = protection
        self.roots = roots ?? [URL(fileURLWithPath: "/Applications"), self.home.appendingPathComponent("Applications")]
    }

    private func ancestry(_ path: URL, forRemoval: Bool = true) throws -> [(URL, FileIdentity)] {
        guard !path.pathComponents.contains(".."), !path.pathComponents.contains("."), path.pathExtension.lowercased() == "app",
            let root = roots.first(where: { path.path.hasPrefix($0.path + "/") }),
            try canonicalFileURL(root).path == root.path else { throw MacEvenError(localized("应用不在允许的实际应用目录内。")) }
        try validateHomePath(path, home: root)
        var current = root
        var parents = [(root, try FileIdentity.read(root))]
        for component in path.path.dropFirst(root.path.count + 1).split(separator: "/").dropLast() {
            guard !component.hasPrefix("."), !component.lowercased().hasSuffix(".app") else { throw MacEvenError(localized("隐藏目录及嵌套应用包受保护。")) }
            current.appendPathComponent(String(component)); parents.append((current, try FileIdentity.read(current)))
        }
        if forRemoval {
            let own = Bundle.main.bundleURL.resolvingSymlinksInPath().path
            guard path.path != own, !own.hasPrefix(path.path + "/"), !index.url.path.hasPrefix(path.path + "/") else { throw MacEvenError(localized("MacEven 自身及索引受保护。")) }
        }
        return parents
    }

    private func bundleInfo(_ path: URL) throws -> [String: Any]? {
        let infoURL = path.appendingPathComponent("Contents/Info.plist")
        try validateHomePath(infoURL, home: path)
        let info = try FileIdentity.read(infoURL)
        guard info.isRegular, info.size <= 1024 * 1024 else { throw MacEvenError(localized("应用信息无效或超过 1 MiB。")) }
        let handle = try FileHandle(forReadingFrom: infoURL)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 1024 * 1024 + 1) ?? Data()
        guard data.count <= 1024 * 1024 else { throw MacEvenError(localized("应用信息超过 1 MiB。")) }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    private func metadata(_ path: URL) throws -> (String, String) {
        guard let plist = try bundleInfo(path),
            plist["CFBundlePackageType"] as? String == "APPL", let id = plist["CFBundleIdentifier"] as? String,
            validCacheIdentifier(id) else { throw MacEvenError(localized("无法精确识别应用标识，仅供查看。")) }
        let name = (plist["CFBundleDisplayName"] as? String) ?? (plist["CFBundleName"] as? String) ?? path.deletingPathExtension().lastPathComponent
        return (id, String(name.prefix(512)))
    }

    public func scan(token: CancellationToken, progress: @Sendable (ScanProgress) -> Void = { _ in }) throws -> ApplicationScanResult {
        try index.reset(); records = []; invalid = false; dataRecords = [:]; dataPlans = [:]
        var errors: [String] = []; var incomplete = false; var visited = 0; var seen = Set<String>()
        func note(_ text: String) { incomplete = true; if errors.count < 100 { errors.append(String(text.prefix(1000))) } }
        for root in roots {
            if token.isCancelled { break }
            do {
                let identity = try FileIdentity.read(root)
                guard identity.isDirectory, !identity.isSymlink, try canonicalFileURL(root).path == root.path else { throw MacEvenError(localized("应用目录不是实际目录：\(root.path)")) }
                guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [], options: [.skipsPackageDescendants, .skipsHiddenFiles], errorHandler: { _, error in note(error.localizedDescription); return !token.isCancelled }) else { throw MacEvenError(localized("无法枚举应用目录：\(root.path)")) }
                while !token.isCancelled, let path = autoreleasepool(invoking: { enumerator.nextObject() as? URL }) {
                    visited += 1
                    if visited > 16384 || records.count >= 2048 { note(localized("应用发现达到上限，请缩小应用目录范围。")); break }
                    let info: FileIdentity
                    do { info = try FileIdentity.read(path) } catch { note(error.localizedDescription); continue }
                    if info.isSymlink || info.device != identity.device { if info.isDirectory { enumerator.skipDescendants() }; continue }
                    guard info.isDirectory, path.pathExtension.lowercased() == "app" else { continue }
                    enumerator.skipDescendants()
                    guard seen.insert(path.path).inserted else { continue }
                    var record = Record(url: path, identifier: "", name: String(path.deletingPathExtension().lastPathComponent.prefix(512)), ancestors: [])
                    do {
                        let parents = try ancestry(path, forRemoval: false)
                        record = Record(url: path, identifier: "", name: record.name, ancestors: parents)
                        let (id, name) = try metadata(path)
                        record = Record(url: path, identifier: id, name: name, ancestors: parents)
                        _ = try ancestry(path)
                        if id.lowercased().hasPrefix("com.apple.") || id.lowercased().hasPrefix("local.maceven") { record.issue = localized("系统和 MacEven 自身应用受保护。") }
                    } catch { record.issue = error.localizedDescription }
                    records.append(record)
                }
            } catch {
                let failure = error as NSError
                if failure.domain != NSPOSIXErrorDomain || failure.code != Int(ENOENT) { note(error.localizedDescription) }
            }
            if visited > 16384 || records.count >= 2048 { break }
        }
        let start = Date(); var scanned = 0; var allocated: Int64 = 0; var logical: Int64 = 0
        // 只读大小统计不依赖卸载许可，但必须通过实际目录与祖先路径检查。
        let pending = records.indices.filter { !records[$0].ancestors.isEmpty }, total = pending.count
        func snapshot(_ done: Int, path: String) -> ScanProgress {
            ScanProgress(visited: scanned, logicalSize: logical, allocatedSize: allocated, currentPath: path,
                elapsed: Date().timeIntervalSince(start), errors: 0).units(done, of: total)
        }
        for (offset, n) in pending.enumerated() {
            if token.isCancelled { break }
            progress(snapshot(offset, path: records[n].url.path))
            let previousScanned = scanned, previousAllocated = allocated, previousLogical = logical
            do {
                let summary = try Scanner.scan(root: records[n].url, index: index, token: token, resetIndex: false, requireCompleteTraversal: true) { value in
                    progress(ScanProgress(visited: previousScanned + value.visited, logicalSize: previousLogical + value.logicalSize,
                        allocatedSize: previousAllocated + value.allocatedSize, currentPath: value.currentPath, elapsed: Date().timeIntervalSince(start), errors: value.errors).units(offset, of: total))
                }
                records[n].rootID = summary.rootID; scanned += summary.visited
                if let entry = try index.entry(id: summary.rootID) { allocated += entry.allocatedSize; logical += entry.logicalSize }
                if summary.cancelled || summary.errors > 0 {
                    records[n].issue = localized("应用包扫描不完整，请重新扫描。"); incomplete = true
                    errors.append(contentsOf: summary.errorExamples.prefix(max(0, 100 - errors.count)))
                }
            } catch { records[n].issue = error.localizedDescription; note(error.localizedDescription) }
        }
        if !token.isCancelled { progress(snapshot(total, path: roots.first?.path ?? "")) }
        if token.isCancelled { incomplete = true }
        if incomplete { for n in records.indices { records[n].issue = records[n].issue ?? localized("应用范围或扫描不完整，请解决访问问题后重新扫描。") } }
        return ApplicationScanResult(applications: try refresh(isRunning: { _ in false }), incomplete: incomplete, errors: errors)
    }

    public func refresh(isRunning: (InstalledApplication) -> Bool) throws -> [InstalledApplication] {
        var values: [InstalledApplication] = []
        for record in records {
            let entry = try record.rootID.flatMap { try index.entry(id: $0) }
            if record.rootID != nil && entry == nil { continue }
            var reason = invalid ? localized("索引失效，请重新扫描。") : record.issue
            if reason == nil { do { _ = try ancestry(record.url) } catch { reason = error.localizedDescription } }
            if reason == nil, !record.identifier.isEmpty { reason = protection.reason(forBundleIdentifier: record.identifier) }
            if reason == nil { reason = protection.reason(for: record.url) }
            var caches: [URL] = []
            if validCacheIdentifier(record.identifier) {
                for relative in ["Library/Caches/\(record.identifier)", "Library/Containers/\(record.identifier)/Data/Library/Caches"] {
                    let path = home.appendingPathComponent(relative)
                    if (try? validateHomePath(path, home: home)) != nil, (try? FileIdentity.read(path).isDirectory) == true { caches.append(path) }
                }
            }
            func value(_ reason: String?) -> InstalledApplication {
                InstalledApplication(url: record.url, bundleIdentifier: record.identifier, name: record.name,
                    allocatedSize: entry?.allocatedSize, logicalSize: entry?.logicalSize, cachePaths: caches, blockedReason: reason)
            }
            if reason == nil && isRunning(value(nil)) { reason = localized("应用正在运行，请退出后重新检查。") }
            values.append(value(reason))
        }
        return values.sorted { ($0.allocatedSize ?? -1) == ($1.allocatedSize ?? -1) ? $0.id < $1.id : ($0.allocatedSize ?? -1) > ($1.allocatedSize ?? -1) }
    }

    private func dataCandidates(identifier: String, warnings: inout [String]) throws -> [URL] {
        guard validCacheIdentifier(identifier), !identifier.lowercased().hasPrefix("com.apple."),
            !identifier.lowercased().hasPrefix("local.maceven") else { throw MacEvenError(localized("应用标识受保护。")) }
        let relatives = ["Library/Caches/\(identifier)", "Library/Application Support/\(identifier)",
            "Library/Preferences/\(identifier).plist", "Library/Containers/\(identifier)",
            "Library/Saved Application State/\(identifier).savedState", "Library/Logs/\(identifier)",
            "Library/HTTPStorages/\(identifier)", "Library/HTTPStorages/\(identifier).binarycookies",
            "Library/WebKit/\(identifier)", "Library/Application Scripts/\(identifier)"]
        var candidates = relatives.map { home.appendingPathComponent($0) }
        let byHost = home.appendingPathComponent("Library/Preferences/ByHost")
        do {
            try validateHomePath(byHost, home: home)
            var enumerationError: String?
            guard let enumerator = FileManager.default.enumerator(at: byHost, includingPropertiesForKeys: [],
                options: [.skipsSubdirectoryDescendants], errorHandler: { _, error in enumerationError = error.localizedDescription; return false }) else { throw MacEvenError(localized("无法检查主机偏好设置。")) }
            var count = 0
            while let url = enumerator.nextObject() as? URL {
                count += 1
                guard count <= 16384 else { throw MacEvenError(localized("主机偏好设置过多，无法完整检查。")) }
                let name = url.lastPathComponent, prefix = identifier + "."
                if name.hasPrefix(prefix), name.hasSuffix(".plist"),
                    UUID(uuidString: String(name.dropFirst(prefix.count).dropLast(6))) != nil { candidates.append(url) }
            }
            if let enumerationError { throw MacEvenError(enumerationError) }
        } catch {
            let failure = error as NSError
            if failure.domain != NSPOSIXErrorDomain || failure.code != Int(ENOENT) { warnings.append(localized("ByHost 偏好设置保留：") + error.localizedDescription) }
        }
        return candidates.filter { url in
            do {
                _ = try FileIdentity.read(url)
                return true
            } catch {
                let failure = error as NSError
                if failure.domain == NSPOSIXErrorDomain && failure.code == Int(ENOENT) { return false }
                warnings.append(url.path + "：" + error.localizedDescription)
                return true
            }
        }.sorted { $0.path < $1.path }
    }

    private func removalCandidates(_ app: InstalledApplication, token: CancellationToken) throws -> ([URL], [String]) {
        var warnings: [String] = []
        let exact = try dataCandidates(identifier: app.bundleIdentifier, warnings: &warnings)
        let (candidates, issues) = try ApplicationDataDiscovery.discover(app: app, home: home, exact: exact, token: token)
        return (candidates.filter(\.included).map(\.url), warnings + issues)
    }

    private func dataAncestry(_ url: URL) throws -> [(URL, FileIdentity)] {
        try validateHomePath(url, home: home)
        var current = home, values = [(home, try FileIdentity.read(home))]
        for part in url.path.dropFirst(home.path.count + 1).split(separator: "/").dropLast() {
            current.appendPathComponent(String(part)); values.append((current, try FileIdentity.read(current)))
        }
        return values
    }

    /// 关联数据检查的准入规则：与逐应用检查共用，系统应用、MacEven 自身与无法识别的标识一律不检测。
    private func dataInspectionProtection(_ app: InstalledApplication) -> String? {
        guard validCacheIdentifier(app.bundleIdentifier) else { return localized("无法精确识别应用标识，无法检测关联数据。") }
        if app.bundleIdentifier.lowercased().hasPrefix("com.apple.") { return localized("系统应用的数据受保护，无法检测关联数据。") }
        if app.bundleIdentifier.lowercased().hasPrefix("local.maceven") { return localized("MacEven 自身受保护，无法检测关联数据。") }
        return nil
    }

    /// 单个应用的关联数据统计；逐应用检查与批量检测共用，保证同一个应用两处数字一致。
    private func relatedDataPreview(app: InstalledApplication, scratch: DiskIndex, token: CancellationToken,
                                    cache: ApplicationDataListingCache?) throws -> ApplicationDataPreview {
        var warnings: [String] = []
        let exact: [URL]
        do { exact = try dataCandidates(identifier: app.bundleIdentifier, warnings: &warnings) }
        catch { exact = []; warnings.append(error.localizedDescription) }
        let (candidates, discoveryWarnings) = try ApplicationDataDiscovery.discover(app: app, home: home, exact: exact, token: token, cache: cache)
        warnings += discoveryWarnings
        var items: [ApplicationRelatedData] = []
        for candidate in candidates {
            if token.isCancelled { throw MacEvenError(localized("关联数据扫描已取消。")) }
            var size: Int64?, issue: String?
            let protectedReason = protection.reason(for: candidate.url).map { localized("\($0)，卸载时保留。") }
            do {
                let boundary = candidate.url.path.hasPrefix(home.path + "/") ? home : URL(fileURLWithPath: "/Library")
                try validateHomePath(candidate.url, home: boundary)
                for protected in [index.url.path, Bundle.main.bundleURL.resolvingSymlinksInPath().path] {
                    guard candidate.url.path != protected, !protected.hasPrefix(candidate.url.path + "/"), !candidate.url.path.hasPrefix(protected + "/") else { throw MacEvenError(localized("MacEven 自身及索引受保护。")) }
                }
                let identity = try FileIdentity.read(candidate.url)
                if identity.isDirectory {
                    let summary = try Scanner.scan(root: candidate.url, index: scratch, token: token, resetIndex: false, requireCompleteTraversal: true)
                    guard !summary.cancelled, summary.errors == 0 else { throw MacEvenError(localized("未完整统计：\(summary.errorExamples.first ?? candidate.url.path)")) }
                    size = try scratch.entry(id: summary.rootID)?.allocatedSize
                } else { size = identity.allocated }
            } catch { issue = error.localizedDescription }
            issue = issue ?? protectedReason
            items.append(ApplicationRelatedData(url: candidate.url, category: candidate.category, evidence: candidate.evidence,
                includedInRemoval: candidate.included && issue == nil, allocatedSize: size, issue: issue))
        }
        if token.isCancelled { throw MacEvenError(localized("关联数据扫描已取消。")) }
        return ApplicationDataPreview(applicationID: app.id, items: items, warnings: warnings)
    }

    public func inspectRelatedData(id: String, token: CancellationToken) throws -> ApplicationDataPreview {
        guard !invalid, let app = try refresh(isRunning: { _ in false }).first(where: { $0.id == id }) else { throw MacEvenError(localized("该应用无法检查关联数据。")) }
        if let reason = dataInspectionProtection(app) { throw MacEvenError(reason) }
        let scratchURL = index.url.deletingLastPathComponent().appendingPathComponent("related-data-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: scratchURL); try? FileManager.default.removeItem(atPath: scratchURL.path + "-journal") }
        let scratch = try DiskIndex(url: scratchURL)
        defer { scratch.close() }
        return try relatedDataPreview(app: app, scratch: scratch, token: token, cache: nil)
    }

    /// 一次性检测所有可检查应用的关联数据：只读、可取消；跳过或失败的应用不影响其他应用。
    /// 目录清单与 plist 解析在整批中共享，大小统计复用同一个临时索引并逐个应用清空。
    public func inspectAllRelatedData(token: CancellationToken,
                                      progress: @Sendable (ApplicationDataBulkProgress) -> Void = { _ in }) throws -> ApplicationDataBulkResult {
        guard !invalid else { throw MacEvenError(localized("应用索引已失效，请重新扫描。")) }
        let apps = try refresh(isRunning: { _ in false })
        var candidates: [InstalledApplication] = [], skipped: [String: String] = [:]
        for app in apps {
            if let reason = dataInspectionProtection(app) { skipped[app.id] = reason }
            else if app.allocatedSize == nil { skipped[app.id] = localized("应用包大小未统计，仅按本体大小参与排序。") }
            else { candidates.append(app) }
        }
        progress(ApplicationDataBulkProgress(done: 0, total: candidates.count, applicationName: "", preview: nil))
        guard !candidates.isEmpty else { return ApplicationDataBulkResult(previews: [], skipped: skipped, cancelled: false, warnings: []) }
        let scratchURL = index.url.deletingLastPathComponent().appendingPathComponent("related-data-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: scratchURL); try? FileManager.default.removeItem(atPath: scratchURL.path + "-journal") }
        let scratch = try DiskIndex(url: scratchURL)
        defer { scratch.close() }
        let cache = ApplicationDataListingCache()
        var previews: [ApplicationDataPreview] = [], warnings: [String] = [], cancelled = false
        for (offset, app) in candidates.enumerated() {
            if token.isCancelled { cancelled = true; break }
            var preview: ApplicationDataPreview?
            do {
                try scratch.reset()
                let value = try relatedDataPreview(app: app, scratch: scratch, token: token, cache: cache)
                preview = value
                previews.append(value)
                for warning in value.warnings where warnings.count < 100 && !warnings.contains(warning) { warnings.append(warning) }
            } catch {
                if token.isCancelled { cancelled = true } else { skipped[app.id] = error.localizedDescription }
            }
            progress(ApplicationDataBulkProgress(done: offset + 1, total: candidates.count, applicationName: app.name, preview: preview))
            if cancelled { break }
        }
        return ApplicationDataBulkResult(previews: previews, skipped: skipped, cancelled: cancelled, warnings: warnings)
    }

    private func validateExclusiveApplication(_ app: InstalledApplication) throws {
        var visited = 0
        let ownInfo = try bundleInfo(app.url)
        let ownNames = Set(([app.name, app.url.deletingPathExtension().lastPathComponent]
            + ["CFBundleName", "CFBundleDisplayName"].compactMap { ownInfo?[$0] as? String }).map { $0.lowercased() })
        for root in roots {
            do { _ = try FileIdentity.read(root) }
            catch {
                let failure = error as NSError
                if failure.domain == NSPOSIXErrorDomain && failure.code == Int(ENOENT) { continue }
                throw error
            }
            do {
                guard try canonicalFileURL(root).path == root.path else { throw MacEvenError(localized("应用目录已变化。")) }
                var enumerationError: String?
                guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [],
                    options: [.skipsPackageDescendants, .skipsHiddenFiles], errorHandler: { _, error in enumerationError = error.localizedDescription; return false }) else {
                    throw MacEvenError(localized("无法检查其他应用副本。"))
                }
                while let url = enumerator.nextObject() as? URL {
                    visited += 1
                    guard visited <= 16384 else { throw MacEvenError(localized("应用副本检查达到上限。")) }
                    let identity = try FileIdentity.read(url)
                    if identity.isSymlink { continue }
                    guard identity.isDirectory, url.pathExtension.lowercased() == "app" else { continue }
                    enumerator.skipDescendants()
                    if url.path == app.url.path { continue }
                    // Copy discovery reads protected bundles; only removal must reject them.
                    _ = try ancestry(url, forRemoval: false)
                    let info: [String: Any]?
                    do { info = try bundleInfo(url) }
                    catch {
                        let failure = error as NSError
                        if failure.domain == NSPOSIXErrorDomain && failure.code == Int(ENOENT) { continue }
                        throw error
                    }
                    if let identifier = info?["CFBundleIdentifier"] as? String, validCacheIdentifier(identifier), identifier == app.bundleIdentifier {
                        throw MacEvenError(localized("发现同标识的其他应用副本，数据可能共享；请使用仅删除 App。"))
                    }
                    let names = [url.deletingPathExtension().lastPathComponent]
                        + ["CFBundleName", "CFBundleDisplayName"].compactMap { info?[$0] as? String }
                    guard names.allSatisfy({ !ownNames.contains($0.lowercased()) }) else { throw MacEvenError(localized("发现同名的其他应用，关联数据可能共享，已保留。")) }
                }
                if let enumerationError { throw MacEvenError(enumerationError) }
            }
        }
    }

    public func prepareDataRemoval(id: String, token: CancellationToken, isRunning: (InstalledApplication) -> Bool) throws -> ApplicationDataPlan {
        dataPlans[id] = nil
        for record in dataRecords[id] ?? [] { try index.removeSubtree(id: record.rootID) }
        dataRecords[id] = []
        guard let app = try refresh(isRunning: isRunning).first(where: { $0.id == id }), app.blockedReason == nil else {
            throw MacEvenError(localized("该应用不可卸载，请重新检查。"))
        }
        let (candidates, warnings) = try removalCandidates(app, token: token)
        var retained = warnings
        var exclusive = true
        do { try validateExclusiveApplication(app) }
        catch { exclusive = false; retained.append(localized("关联数据保留：") + error.localizedDescription) }
        var size: Int64 = 0
        for url in exclusive ? candidates : [] {
            guard !token.isCancelled else { throw MacEvenError(localized("关联数据扫描已取消。")) }
            do {
                if let reason = protection.reason(for: url) { throw MacEvenError(reason) }
                for protected in [index.url.path, Bundle.main.bundleURL.resolvingSymlinksInPath().path] {
                    guard url.path != protected, !protected.hasPrefix(url.path + "/"), !url.path.hasPrefix(protected + "/") else { throw MacEvenError(localized("MacEven 自身及索引受保护。")) }
                }
                let parents = try dataAncestry(url), identity = try FileIdentity.read(url)
                let rootID: Int64
                if identity.isDirectory {
                    let summary = try Scanner.scan(root: url, index: index, token: token, resetIndex: false, requireCompleteTraversal: true)
                    guard !summary.cancelled, summary.errors == 0 else {
                        try index.removeSubtree(id: summary.rootID)
                        throw MacEvenError(localized("关联数据扫描不完整，已保留。"))
                    }
                    rootID = summary.rootID
                } else {
                    rootID = try index.insert(parent: 0, url: url, identity: identity).id
                }
                dataRecords[id, default: []].append(DataRecord(url: url, rootID: rootID, ancestors: parents))
                size += try index.entry(id: rootID)?.allocatedSize ?? 0
            } catch {
                if token.isCancelled { throw error }
                retained.append(url.path + "：" + error.localizedDescription)
            }
        }
        guard !token.isCancelled else { throw MacEvenError(localized("关联数据扫描已取消。")) }
        let plan = ApplicationDataPlan(id: UUID(), applicationID: id, paths: (dataRecords[id] ?? []).map(\.url), allocatedSize: size, retainedReasons: retained, candidatePaths: candidates)
        dataPlans[id] = plan
        return plan
    }

    private func validateData(_ record: DataRecord) throws {
        let current = try dataAncestry(record.url)
        guard current.count == record.ancestors.count, zip(current, record.ancestors).allSatisfy({ a, b in
            a.0 == b.0 && a.1.device == b.1.device && a.1.inode == b.1.inode && a.1.mode == b.1.mode
        }) else { throw MacEvenError(localized("数据祖先目录已被替换，请重新扫描。")) }
        try index.validateSubtree(id: record.rootID)
    }

    public func rescanDataAfterQuit(plan: ApplicationDataPlan, token: CancellationToken, isRunning: (InstalledApplication) -> Bool) throws -> ApplicationDataPlan {
        guard !invalid, plan == dataPlans[plan.applicationID],
            let app = try refresh(isRunning: isRunning).first(where: { $0.id == plan.applicationID }), app.blockedReason == nil,
            try removalCandidates(app, token: token).0 == plan.candidatePaths else { throw MacEvenError(localized("应用未退出或关联数据范围已变化，请重新确认。")) }
        do {
            var size: Int64 = 0
            for offset in (dataRecords[plan.applicationID] ?? []).indices {
                let record = dataRecords[plan.applicationID]![offset]
                let current = try dataAncestry(record.url)
                guard current.count == record.ancestors.count, zip(current, record.ancestors).allSatisfy({ a, b in
                    a.0 == b.0 && a.1.device == b.1.device && a.1.inode == b.1.inode && a.1.mode == b.1.mode
                }) else { throw MacEvenError(localized("关联数据祖先目录已替换，内容已保留。")) }
                let root = try index.rescanAfterApplicationQuit(id: record.rootID, token: token)
                dataRecords[plan.applicationID]![offset] = DataRecord(url: record.url, rootID: root, ancestors: record.ancestors)
                size += try index.entry(id: root)?.allocatedSize ?? 0
            }
            let refreshed = ApplicationDataPlan(id: UUID(), applicationID: plan.applicationID, paths: plan.paths, allocatedSize: size, retainedReasons: plan.retainedReasons, candidatePaths: plan.candidatePaths)
            dataPlans[plan.applicationID] = refreshed
            return refreshed
        } catch { dataPlans[plan.applicationID] = nil; throw error }
    }

    public func moveIncludingData(plan: ApplicationDataPlan, isRunning: (InstalledApplication) -> Bool) -> [TrashResult] {
        defer { dataPlans[plan.applicationID] = nil }
        let planRecords = dataRecords[plan.applicationID] ?? []
        do {
            guard !invalid, plan == dataPlans[plan.applicationID],
                let app = try refresh(isRunning: isRunning).first(where: { $0.id == plan.applicationID }), app.blockedReason == nil else { throw MacEvenError(localized("卸载确认已失效，请重新检查。")) }
            if !plan.paths.isEmpty { try validateExclusiveApplication(app) }
            guard try removalCandidates(app, token: CancellationToken()).0 == plan.candidatePaths else { throw MacEvenError(localized("关联数据范围已变化，请重新确认。")) }
            for record in planRecords { try validateData(record) }
            let movedApp = move(id: plan.applicationID, isRunning: isRunning)
            var results = [movedApp]
            guard movedApp.destination != nil, movedApp.error == nil else { return results }
            for record in planRecords {
                var destination: NSURL?
                var size: Int64?
                do {
                    try validateData(record)
                    guard !isRunning(app) else { throw MacEvenError(localized("应用重新启动，余下数据已保留。")) }
                    if let reason = protection.reason(for: record.url) { throw MacEvenError(localized("\(reason)，余下数据已保留。")) }
                    size = try index.entry(id: record.rootID)?.allocatedSize
                    try FileManager.default.trashItem(at: record.url, resultingItemURL: &destination)
                    do { try index.removeSubtree(id: record.rootID) }
                    catch { invalid = true; throw MacEvenError(localized("已移到废纸篓，但索引同步失败：\(error.localizedDescription)。请重新扫描。")) }
                    results.append(TrashResult(id: record.rootID, path: record.url.path, destination: destination as URL?, error: nil, allocatedSize: size))
                } catch {
                    results.append(TrashResult(id: record.rootID, path: record.url.path, destination: destination as URL?, error: error.localizedDescription, allocatedSize: size))
                    if invalid || isRunning(app) { break }
                }
            }
            return results
        } catch { return [TrashResult(id: 0, path: plan.applicationID, destination: nil, error: error.localizedDescription)] }
    }

    public func move(id: String, isRunning: (InstalledApplication) -> Bool) -> TrashResult {
        var destination: NSURL?
        var rootID: Int64 = 0
        var size: Int64?
        do {
            guard !invalid, let record = records.first(where: { $0.url.path == id }), record.issue == nil, let root = record.rootID,
                let app = try refresh(isRunning: isRunning).first(where: { $0.id == id }), app.blockedReason == nil else { throw MacEvenError(localized("该应用不可卸载，请退出并重新检查或重新扫描。")) }
            rootID = root
            let actual = try ancestry(record.url)
            guard actual.count == record.ancestors.count, zip(actual, record.ancestors).allSatisfy({ a, b in
                a.0 == b.0 && a.1.device == b.1.device && a.1.inode == b.1.inode && a.1.mode == b.1.mode
            }) else { throw MacEvenError(localized("应用祖先目录已被替换，请重新扫描。")) }
            try index.validateSubtree(id: root)
            guard !isRunning(app) else { throw MacEvenError(localized("应用重新启动，应用包已保留。")) }
            size = try index.entry(id: root)?.allocatedSize
            try FileManager.default.trashItem(at: record.url, resultingItemURL: &destination)
            do { try index.removeSubtree(id: root) }
            catch { invalid = true; throw MacEvenError(localized("已移到废纸篓，但索引同步失败：\(error.localizedDescription)。请重新扫描。")) }
            return TrashResult(id: root, path: id, destination: destination as URL?, error: nil, allocatedSize: size)
        } catch { return TrashResult(id: rootID, path: id, destination: destination as URL?, error: error.localizedDescription, allocatedSize: size) }
    }
}
