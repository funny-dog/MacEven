import Foundation
import Darwin

public enum ProtectionKind: String, Codable, Sendable {
    case path
    case bundleIdentifier
}

public struct ProtectionEntry: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let kind: ProtectionKind
    public let value: String
    public let resolvedPath: String?
    public let added: Date
}

// 用户保护列表：只增加限制，不放开任何既有保护。文件无法读取时失败即关闭。
public final class ProtectionStore: @unchecked Sendable {
    public static let maxEntries = 500
    public static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/MacEven/protection.json")
    public static let shared = ProtectionStore(url: defaultURL)

    private struct Document: Codable {
        var version: Int
        var entries: [ProtectionEntry]
    }
    private struct Stamp: Equatable {
        let device: Int64, inode: Int64, size: Int64, modified: Int64, changed: Int64
    }
    public let url: URL
    private let lock = NSLock()
    private var cachedStamp: Stamp??
    private var cached: Result<[ProtectionEntry], MacEvenError> = .success([])

    public init(url: URL) { self.url = url }

    public func entries() throws -> [ProtectionEntry] {
        try lock.withLock { try loadLocked().get() }
    }

    public func reason(for target: URL) -> String? {
        let entries: [ProtectionEntry]
        switch lock.withLock({ loadLocked() }) {
        case .failure(let error): return localized("保护列表无法读取，为安全起见暂停清理：\(error.message)")
        case .success(let values): entries = values
        }
        let path = target.path.lowercased()
        let components = target.pathComponents
        let libraryTail: [String] = components.firstIndex(where: { $0.lowercased() == "library" }).map { components[($0 + 1)...].map { $0.lowercased() } } ?? []
        if entries.contains(where: { $0.kind == .bundleIdentifier }) {
            // 目标是应用包或位于应用包内时，按包内声明的标识核对（例如磁盘分析里删除 ~/Applications/Foo.app）。
            var bundle = URL(fileURLWithPath: "/")
            for component in components.dropFirst() {
                bundle.appendPathComponent(component)
                guard component.lowercased().hasSuffix(".app") else { continue }
                switch Self.bundleIdentifier(of: bundle) {
                case .success(let identifier?): if let reason = Self.match(identifier, entries) { return reason }
                case .success(nil): continue
                case .failure(let error): return localized("无法核对应用标识，为安全起见保留：\(error.message)")
                }
            }
        }
        for entry in entries {
            switch entry.kind {
            case .path:
                for candidate in [entry.value, entry.resolvedPath].compactMap({ $0?.lowercased() }) where Self.overlaps(path, candidate) {
                    return localized("已在保护列表中：\(entry.value)")
                }
            case .bundleIdentifier:
                let id = entry.value.lowercased()
                if libraryTail.contains(where: { $0 == id || $0.hasPrefix(id + ".") }) { return localized("已在保护列表中：\(entry.value)") }
            }
        }
        return nil
    }

    public func reason(forBundleIdentifier identifier: String) -> String? {
        switch lock.withLock({ loadLocked() }) {
        case .failure(let error): return localized("保护列表无法读取，为安全起见暂停清理：\(error.message)")
        case .success(let entries): return Self.match(identifier, entries)
        }
    }

    private static func match(_ identifier: String, _ entries: [ProtectionEntry]) -> String? {
        let value = identifier.lowercased()
        for entry in entries where entry.kind == .bundleIdentifier {
            let id = entry.value.lowercased()
            if value == id || value.hasPrefix(id + ".") { return localized("已在保护列表中：\(entry.value)") }
        }
        return nil
    }

    /// 没有 Info.plist 视为普通目录；存在但无法读取时返回失败，由调用方保守拒绝。
    private static func bundleIdentifier(of bundle: URL) -> Result<String?, MacEvenError> {
        let plist = bundle.appendingPathComponent("Contents/Info.plist")
        do {
            let info = try FileIdentity.read(plist)
            guard info.isRegular, info.size <= 1024 * 1024 else { return .failure(MacEvenError(localized("应用信息无效：\(plist.path)"))) }
            let data = try Data(contentsOf: plist)
            guard let values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return .failure(MacEvenError(localized("应用信息格式无效：\(plist.path)"))) }
            return .success(values["CFBundleIdentifier"] as? String)
        } catch {
            let failure = error as NSError
            if failure.domain == NSPOSIXErrorDomain && (failure.code == Int(ENOENT) || failure.code == Int(ENOTDIR)) { return .success(nil) }
            return .failure(MacEvenError(error.localizedDescription))
        }
    }

    @discardableResult
    public func addPath(_ target: URL) throws -> ProtectionEntry {
        guard target.isFileURL, target.path.hasPrefix("/"), !target.pathComponents.contains(".."), !target.pathComponents.contains(".") else {
            throw MacEvenError(localized("请选择实际的文件或文件夹路径。"))
        }
        // 不做 standardizedFileURL：它会把 /private/var 改写为 /var，与扫描得到的实际写法不一致。
        let value = target.path
        let resolved = (try? canonicalFileURL(target))?.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let homeResolved = (try? canonicalFileURL(FileManager.default.homeDirectoryForCurrentUser))?.path
        for candidate in [value, resolved].compactMap({ $0 }) where candidate == "/" || candidate == home || candidate == homeResolved {
            throw MacEvenError(localized("保护范围过大：不能保护根目录或整个主目录。"))
        }
        return try mutate { entries in
            if let existing = entries.first(where: { $0.kind == .path && $0.value.lowercased() == value.lowercased() }) { return existing }
            let entry = ProtectionEntry(id: UUID(), kind: .path, value: value, resolvedPath: resolved == value ? nil : resolved, added: Date())
            entries.append(entry)
            return entry
        }
    }

    @discardableResult
    public func addBundleIdentifier(_ raw: String) throws -> ProtectionEntry {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validIdentifier(value) else { throw MacEvenError(localized("应用标识格式无效，例如 com.example.app。")) }
        return try mutate { entries in
            if let existing = entries.first(where: { $0.kind == .bundleIdentifier && $0.value.lowercased() == value.lowercased() }) { return existing }
            let entry = ProtectionEntry(id: UUID(), kind: .bundleIdentifier, value: value, resolvedPath: nil, added: Date())
            entries.append(entry)
            return entry
        }
    }

    public func remove(id: UUID) throws {
        _ = try mutate { entries in entries.removeAll { $0.id == id } }
    }

    // 无法读取时把原文件改名备份，再从空列表开始。
    public func reset() throws {
        try lock.withLock {
            if (try? FileIdentity.read(url)) != nil {
                let backup = url.deletingLastPathComponent().appendingPathComponent("protection-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).json.bak")
                try FileManager.default.moveItem(at: url, to: backup)
            }
            cachedStamp = nil
            try writeLocked([])
        }
    }

    static func validIdentifier(_ value: String) -> Bool {
        validCacheIdentifier(value) && value.contains(".") && !value.hasPrefix(".") && !value.hasSuffix(".") && !value.contains("..")
    }

    static func overlaps(_ rawPath: String, _ rawProtected: String) -> Bool {
        // 手工编辑的列表可能带尾部斜杠；去掉后再比较，避免子路径漏保护。
        func trimmed(_ value: String) -> String {
            var value = value
            while value.count > 1 && value.hasSuffix("/") { value.removeLast() }
            return value
        }
        let path = trimmed(rawPath), protected = trimmed(rawProtected)
        return path == protected || path.hasPrefix(protected + "/") || protected.hasPrefix(path + "/")
    }

    private func mutate<T>(_ body: (inout [ProtectionEntry]) throws -> T) throws -> T {
        try lock.withLock {
            var entries = try loadLocked().get()
            let value = try body(&entries)
            guard entries.count <= Self.maxEntries else { throw MacEvenError(localized("保护列表最多 \(Self.maxEntries) 条。")) }
            try writeLocked(entries)
            return value
        }
    }

    private func writeLocked(_ entries: [ProtectionEntry]) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard !(try FileIdentity.read(directory)).isSymlink else { throw MacEvenError(localized("保护列表目录不能是符号链接。")) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(Document(version: 1, entries: entries)).write(to: url, options: .atomic)
        cachedStamp = nil
    }

    private func loadLocked() -> Result<[ProtectionEntry], MacEvenError> {
        let stamp: Stamp?
        do {
            let info = try FileIdentity.read(url)
            guard info.isRegular else {
                cachedStamp = nil
                cached = .failure(MacEvenError(localized("\(url.path) 不是普通文件。")))
                return cached
            }
            stamp = Stamp(device: info.device, inode: info.inode, size: info.size, modified: info.modified, changed: info.changed)
        } catch {
            let failure = error as NSError
            guard failure.domain == NSPOSIXErrorDomain && failure.code == Int(ENOENT) else {
                cachedStamp = nil
                cached = .failure(MacEvenError(error.localizedDescription))
                return cached
            }
            stamp = nil
        }
        if let cachedStamp, cachedStamp == stamp { return cached }
        cachedStamp = stamp
        guard let stamp else { cached = .success([]); return cached }
        do {
            guard stamp.size <= 1024 * 1024 else { throw MacEvenError(localized("文件超过 1 MiB。")) }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let document = try decoder.decode(Document.self, from: Data(contentsOf: url))
            guard document.version == 1 else { throw MacEvenError(localized("不认识的版本 \(document.version)。")) }
            guard document.entries.count <= Self.maxEntries else { throw MacEvenError(localized("条目超过 \(Self.maxEntries) 条。")) }
            for entry in document.entries {
                switch entry.kind {
                case .path: guard entry.value.hasPrefix("/"), entry.value.contains(where: { $0 != "/" }) else { throw MacEvenError(localized("路径条目无效：\(entry.value)")) }
                case .bundleIdentifier: guard Self.validIdentifier(entry.value) else { throw MacEvenError(localized("应用标识条目无效：\(entry.value)")) }
                }
            }
            cached = .success(document.entries)
        } catch let error as MacEvenError {
            cached = .failure(error)
        } catch {
            cached = .failure(MacEvenError(localized("格式无效：\(error.localizedDescription)")))
        }
        return cached
    }
}
