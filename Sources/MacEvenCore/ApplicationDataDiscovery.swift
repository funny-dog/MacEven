import Foundation
import Darwin
import Security

public struct ApplicationRelatedData: Identifiable, Sendable, Equatable {
    public var id: String { url.path }
    public let url: URL
    public let category: String
    public let evidence: String
    public let includedInRemoval: Bool
    public let allocatedSize: Int64?
    public let issue: String?
}

public struct ApplicationDataPreview: Sendable, Equatable {
    public let applicationID: String
    public let items: [ApplicationRelatedData]
    public let warnings: [String]
    public var allocatedSize: Int64 { items.reduce(0) { $0 + ($1.allocatedSize ?? 0) } }
    public var includedSize: Int64 { items.reduce(0) { $0 + ($1.includedInRemoval ? ($1.allocatedSize ?? 0) : 0) } }
    public var retainedSize: Int64 { allocatedSize - includedSize }
    public var unmeasuredCount: Int { items.filter { $0.allocatedSize == nil }.count }
}

/// 一次批量检测共享的目录清单与 plist 解析；由调用方在单一线程上串行使用。
final class ApplicationDataListingCache: @unchecked Sendable {
    private var listings: [String: [URL]] = [:]
    private var plists: [String: [String: Any]?] = [:]

    func entries(_ root: URL, boundary: URL, token: CancellationToken, note: @escaping (String) -> Void) -> [URL] {
        let key = "entries\u{1}\(root.path)\u{1}\(boundary.path)"
        if let cached = listings[key] { return cached }
        let value = ApplicationDataDiscovery.entries(root, boundary: boundary, token: token, note: note)
        if !token.isCancelled { listings[key] = value }
        return value
    }

    func homeEntries(_ home: URL, token: CancellationToken, note: @escaping (String) -> Void) -> [URL] {
        let key = "home\u{1}\(home.path)"
        if let cached = listings[key] { return cached }
        let value = ApplicationDataDiscovery.homeEntries(home, token: token, note: note)
        if !token.isCancelled { listings[key] = value }
        return value
    }

    func plist(_ url: URL, root: URL) -> [String: Any]? {
        let key = "plist\u{1}\(url.path)\u{1}\(root.path)"
        if let cached = plists[key] { return cached }
        let value = try? ApplicationDataDiscovery.plist(url, root: root)
        plists[key] = value
        return value
    }
}

// 精确标识与产品目录进入确认范围；前缀、共享组和后台服务仅供查看。
enum ApplicationDataDiscovery {
    struct Candidate {
        let url: URL
        let category: String
        let evidence: String
        let included: Bool
    }
    static let directories = ["Application Support", "Caches", "Preferences", "Containers", "Group Containers",
        "Saved Application State", "Logs", "HTTPStorages", "WebKit", "Application Scripts", "Cookies", "Autosave Information"]
    /// 主目录里不属于任何应用的系统或共享目录；同名应用目录不会与它们混淆。
    static let homeReservedEntries: Set<String> = ["library", "desktop", "documents", "downloads", "movies", "music", "pictures", "public",
        "applications", "trash", "config", "cache", "local", "ssh", "gnupg", "git", "gitconfig", "npm", "node", "docker", "cocoapods",
        "bashhistory", "zshhistory", "cfusertextencoding", "dsstore", "volumes"]

    /// 产品名写法变体归一：忽略大小写、空格、点、横线与下划线（WorkBuddy AI / workbuddy-ai / workbuddy.ai 视为同一应用）。
    static func normalizedName(_ value: String) -> String {
        value.lowercased().filter { !" -_.".contains($0) }
    }

    static func missing(_ error: Error) -> Bool {
        let value = error as NSError
        return value.domain == NSPOSIXErrorDomain && value.code == Int(ENOENT)
    }

    /// 共享目录清单：一次批量检测里同一个目录只枚举一次，避免按应用重复遍历 ~/Library。
    static func entries(_ root: URL, boundary: URL, token: CancellationToken, note: @escaping (String) -> Void) -> [URL] {
        do {
            try validateHomePath(root, home: boundary)
            var result: [URL] = []
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [], options: [.skipsSubdirectoryDescendants],
                errorHandler: { _, error in note(error.localizedDescription); return false }) else { note(localized("无法枚举：\(root.path)")); return [] }
            while !token.isCancelled, let url = enumerator.nextObject() as? URL {
                if result.count >= 16384 { note(localized("目录发现达到 16384 项上限：\(root.path)")); break }
                result.append(url)
            }
            return result
        } catch { if !missing(error) { note(error.localizedDescription) }; return [] }
    }

    /// 主目录自身的直接子项；validateHomePath 要求路径位于主目录之内，因此单独枚举。
    static func homeEntries(_ home: URL, token: CancellationToken, note: @escaping (String) -> Void) -> [URL] {
        var result: [URL] = []
        guard let enumerator = FileManager.default.enumerator(at: home, includingPropertiesForKeys: [], options: [.skipsSubdirectoryDescendants],
            errorHandler: { _, error in note(error.localizedDescription); return false }) else { note(localized("无法枚举主目录：\(home.path)")); return [] }
        while !token.isCancelled, let url = enumerator.nextObject() as? URL {
            if result.count >= 16384 { note(localized("主目录发现达到 16384 项上限。")); break }
            result.append(url)
        }
        return result
    }

    static func plist(_ url: URL, root: URL) throws -> [String: Any]? {
        try validateHomePath(url, home: root)
        let identity = try FileIdentity.read(url)
        guard identity.isRegular, identity.size <= 1048576 else { throw MacEvenError(localized("元数据不是普通文件或超过 1 MiB：\(url.path)")) }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: 1048577) ?? Data()
        guard data.count <= 1048576 else { throw MacEvenError(localized("元数据超过 1 MiB：\(url.path)")) }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    static func groups(_ bundle: URL) -> [String] {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code else { return [] }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any],
              let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any] else { return [] }
        return (entitlements["com.apple.security.application-groups"] as? [String] ?? []).filter(validCacheIdentifier)
    }

    static func discover(app: InstalledApplication, home: URL, exact: [URL], token: CancellationToken,
                         cache: ApplicationDataListingCache? = nil) throws -> ([Candidate], [String]) {
        var identifiers = Set([app.bundleIdentifier])
        var names = Set([app.name, app.url.deletingPathExtension().lastPathComponent])
        var productNames = names
        var groupIDs = Set(groups(app.url)), warnings: [String] = []
        let listing = cache ?? ApplicationDataListingCache()
        func note(_ text: String) { if warnings.count < 100 { warnings.append(text) } }
        func checkCancellation() throws { if token.isCancelled { throw MacEvenError(localized("关联数据扫描已取消。")) } }
        func remember(_ info: [String: Any]) {
            if let id = info["CFBundleIdentifier"] as? String, validCacheIdentifier(id), identifiers.count < 256 { identifiers.insert(id) }
        }
        try checkCancellation()
        if let info = try plist(app.url.appendingPathComponent("Contents/Info.plist"), root: app.url) {
            for key in ["CFBundleName", "CFBundleDisplayName", "CFBundleExecutable"] {
                if let name = info[key] as? String {
                    names.insert(name)
                    if key != "CFBundleExecutable" { productNames.insert(name) }
                }
            }
        }
        // 飞书的产品目录与包标识不同。
        if app.bundleIdentifier == "com.electron.lark" { names.insert("LarkShell"); productNames.insert("LarkShell") }
        names = names.filter { !$0.isEmpty && $0.utf8.count <= 255 && !$0.hasPrefix(".") && !$0.contains("/") && !$0.contains(":") && !$0.contains("\\") }
        productNames.formIntersection(names)
        // 归一后的写法变体用于匹配；产品名不含 CFBundleExecutable（Electron 等共享名会误伤其他应用）。
        let nameKeys = Set(names.map(normalizedName).filter { !$0.isEmpty })
        let productKeys = Set(productNames.map(normalizedName).filter { !$0.isEmpty })

        var visited = 0
        for relative in ["Contents/Frameworks", "Contents/PlugIns", "Contents/XPCServices", "Contents/Library", "Contents/Helpers"] {
            let root = app.url.appendingPathComponent(relative)
            do {
                try validateHomePath(root, home: app.url)
                guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [], options: [.skipsHiddenFiles],
                    errorHandler: { _, error in note(error.localizedDescription); return !token.isCancelled }) else { continue }
                while let url = enumerator.nextObject() as? URL {
                    try checkCancellation(); visited += 1
                    if visited > 32768 { note(localized("内嵌程序发现达到 32768 项上限，结果可能不完整。")); break }
                    let identity = try FileIdentity.read(url)
                    if identity.isSymlink { if identity.isDirectory { enumerator.skipDescendants() }; continue }
                    if url.lastPathComponent == "Info.plist", let info = try? plist(url, root: app.url) { remember(info) }
                    if identity.isDirectory, ["app", "appex", "xpc"].contains(url.pathExtension.lowercased()) {
                        groupIDs.formUnion(groups(url))
                    }
                }
            } catch { if token.isCancelled { throw error }; if !missing(error) { note(error.localizedDescription) } }
            if visited > 32768 { break }
        }

        var candidates: [String: Candidate] = [:]
        func add(_ url: URL, category: String, evidence: String, included: Bool = false) {
            if candidates[url.path] != nil { return }
            if candidates.count >= 512 { note(localized("关联数据候选达到 512 项上限，结果可能不完整。")); return }
            candidates[url.path] = Candidate(url: url, category: category, evidence: evidence, included: included)
        }
        for url in exact { add(url, category: url.deletingLastPathComponent().lastPathComponent, evidence: localized("主程序精确标识 · 卸载前重新校验"), included: true) }
        // 标识加后缀（com.foo.app.BundleMigration）：完整标识加单个后缀才视为归属明确；多段后缀（可能属于内嵌程序）保留。
        // 后缀名本身是已发现的内嵌程序标识（com.foo.app.helper）时不算加后缀，交由内嵌程序规则按“可能共享”处理。
        func identifierSuffix(_ filename: String) -> (identifier: String, isMain: Bool)? {
            for id in identifiers.sorted() {
                for separator in [".", "-"] where filename.hasPrefix(id + separator) {
                    let rest = filename.dropFirst(id.count + 1)
                    guard !rest.isEmpty, !rest.contains("."), !rest.contains("-"), !identifiers.contains(id + separator + rest) else { continue }
                    return (id, id == app.bundleIdentifier)
                }
            }
            return nil
        }
        func match(_ filename: String) -> String? {
            for id in identifiers.sorted() {
                if filename == id || [".plist", ".savedState", ".binarycookies"].contains(where: { filename == id + $0 }) {
                    return id == app.bundleIdentifier ? localized("主程序标识候选 · 需核对归属") : localized("内嵌程序标识 \(id) · 可能共享，保留")
                }
            }
            for id in identifiers.sorted() {
                if filename.hasPrefix(id + ".") || filename.hasPrefix(id + "-") {
                    if let suffix = identifierSuffix(filename) {
                        return suffix.isMain ? localized("主程序标识加后缀 · 确认后清理") : localized("内嵌程序标识 \(suffix.identifier) 加后缀 · 可能共享，保留")
                    }
                    return localized("应用标识前缀 · 需核对归属")
                }
                if filename == "group." + id || filename.hasPrefix("group." + id + ".") { return localized("应用组标识候选 · 共享内容保留") }
            }
            for name in names.sorted() {
                if filename.caseInsensitiveCompare(name) == .orderedSame || [".plist", ".savedState"].contains(where: { filename.caseInsensitiveCompare(name + $0) == .orderedSame }) {
                    return localized("应用名称或产品目录名称 · 需核对归属")
                }
            }
            if nameKeys.contains(normalizedName(filename)) { return localized("应用名称或产品目录名称（写法变体）· 需核对归属") }
            return nil
        }
        func included(_ filename: String, directory: String) -> Bool {
            guard ["Application Support", "Caches", "Preferences", "Saved Application State", "Logs", "HTTPStorages", "WebKit", "Application Scripts", "Containers"].contains(directory) else { return false }
            if filename == app.bundleIdentifier || [".plist", ".savedState", ".binarycookies"].contains(where: { filename == app.bundleIdentifier + $0 }) { return true }
            if directory != "Containers", identifierSuffix(filename)?.isMain == true { return true }
            guard ["Application Support", "Caches", "Logs", "Saved Application State", "HTTPStorages", "WebKit"].contains(directory) else { return false }
            return productKeys.contains(normalizedName(filename))
        }
        func entries(_ root: URL, boundary: URL) -> [URL] {
            listing.entries(root, boundary: boundary, token: token, note: note)
        }
        for directory in directories {
            try checkCancellation()
            let root = home.appendingPathComponent("Library/\(directory)")
            for url in entries(root, boundary: home) {
                if directory == "Group Containers", groupIDs.contains(url.lastPathComponent) {
                    add(url, category: directory, evidence: localized("签名声明的 App Group · 共享内容保留"))
                } else if let evidence = match(url.lastPathComponent) {
                    let selected = included(url.lastPathComponent, directory: directory)
                    add(url, category: directory, evidence: selected ? localized("精确标识或产品名称匹配 · 确认后清理") : evidence, included: selected)
                }
            }
        }
        for relative in [".config", ".local/share", ".cache", "Library/Preferences/ByHost"] {
            try checkCancellation()
            for url in entries(home.appendingPathComponent(relative), boundary: home) {
                if let evidence = match(url.lastPathComponent) { add(url, category: relative, evidence: evidence) }
            }
        }
        // 主目录本身：应用常把数据放在按产品名命名的隐藏目录（~/.workbuddy-ai、~/.codex）；隐藏目录进入确认范围，
        // 可见的同名目录可能存放你的文件，只统计并在确认窗口列出。名称按归一写法全名匹配，WorkBuddy 与 WorkBuddy AI 不会互相误配。
        try checkCancellation()
        do {
            for url in listing.homeEntries(home, token: token, note: note) {
                let leaf = url.lastPathComponent
                let hidden = leaf.hasPrefix(".")
                let key = normalizedName(hidden ? String(leaf.dropFirst()) : leaf)
                guard !key.isEmpty, !homeReservedEntries.contains(key), productKeys.contains(key),
                    (try? FileIdentity.read(url))?.isDirectory == true else { continue }
                if hidden {
                    add(url, category: localized("主目录"), evidence: localized("主目录隐藏数据目录 · 产品名全名匹配 · 确认后清理"), included: true)
                } else {
                    add(url, category: localized("主目录"), evidence: localized("主目录同名目录 · 可能存放你的文件，保留"))
                }
            }
        }
        let system = URL(fileURLWithPath: "/Library")
        // Injected test homes never inspect real system data.
        let realHome = (try? canonicalFileURL(FileManager.default.homeDirectoryForCurrentUser)) == home
        for boundary in realHome ? [home, system] : [home] {
            for directory in ["LaunchAgents", "LaunchDaemons", "PrivilegedHelperTools"] {
                try checkCancellation()
                let root = boundary == home ? home.appendingPathComponent("Library/\(directory)") : boundary.appendingPathComponent(directory)
                for url in entries(root, boundary: boundary) {
                    if let evidence = match(url.lastPathComponent) { add(url, category: directory, evidence: evidence + localized(" · 后台服务保留")) }
                    if url.pathExtension == "plist", let info = listing.plist(url, root: boundary) {
                        let programs = ([info["Program"] as? String].compactMap { $0 }) + (info["ProgramArguments"] as? [String] ?? [])
                        if programs.contains(where: { $0.hasPrefix(app.url.path + "/") }) { add(url, category: directory, evidence: localized("启动项指向应用包 · 后台服务保留")) }
                    }
                }
            }
            if boundary == system {
                for directory in ["Application Support", "Caches", "Preferences", "Logs"] {
                    for url in entries(system.appendingPathComponent(directory), boundary: system) {
                        if let evidence = match(url.lastPathComponent) { add(url, category: localized("系统 \(directory)"), evidence: evidence + localized(" · 系统数据保留")) }
                    }
                }
            }
        }
        try checkCancellation()
        // Count containers once, never again through their nested data paths.
        var roots: [Candidate] = []
        for item in candidates.values.sorted(by: { $0.url.path < $1.url.path }) {
            if !roots.contains(where: { item.url.path.hasPrefix($0.url.path + "/") }) { roots.append(item) }
        }
        return (roots, warnings)
    }
}
