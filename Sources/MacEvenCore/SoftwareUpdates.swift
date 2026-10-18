import Foundation
import AppKit

public enum SoftwareSource: String, Sendable {
    case homebrewFormula = "Homebrew Formula", homebrewCask = "Homebrew Cask", sparkle = "Sparkle", electron = "Electron 更新源", appStore = "App Store", unknown = "未知来源"
}

public struct SoftwareEntry: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let url: URL?
    public let bundleIdentifier: String?
    public let version: String
    public let buildVersion: String
    public let identity: FileIdentity?
    public var source: SoftwareSource
    public var feedURL: URL?
    public var actionURL: URL?
    public var brewToken: String?
    /// 仅用于查询版本的 Homebrew 公开目录 token；应用不是经 Homebrew 安装的，不能据此升级
    public var caskToken: String?
    public var latestVersion: String?
    public var hasUpdate = false
    public var blockedReason: String?
    public var note = localized("尚未检查")
    public var isIPadApp: Bool
    public var canUpgrade: Bool {
        [.homebrewFormula, .homebrewCask].contains(source) && brewToken != nil && hasUpdate && blockedReason == nil
    }
    public init(id: String, name: String, url: URL? = nil, bundleIdentifier: String? = nil, version: String,
                buildVersion: String? = nil, identity: FileIdentity? = nil, source: SoftwareSource = .unknown, isIPadApp: Bool = false) {
        self.id = id; self.name = name; self.url = url; self.bundleIdentifier = bundleIdentifier
        self.version = version; self.buildVersion = buildVersion ?? version; self.identity = identity; self.source = source
        self.isIPadApp = isIPadApp
    }
}

public struct SoftwareScanResult: Sendable {
    public let entries: [SoftwareEntry]
    public let errors: [String]
    public init(entries: [SoftwareEntry], errors: [String] = []) { self.entries = entries; self.errors = errors }
}

public enum SoftwareUpdates {
    public static func compareVersions(_ a: String, _ b: String) -> ComparisonResult? {
        func parts(_ value: String) -> [String]? {
            let result = value.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard value.utf8.count <= 128, !result.isEmpty, result.count <= 16,
                result.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }) else { return nil }
            return result
        }
        guard let lhs = parts(a), let rhs = parts(b) else { return nil }
        for position in 0..<max(lhs.count, rhs.count) {
            let left = position < lhs.count ? lhs[position] : "0", right = position < rhs.count ? rhs[position] : "0"
            let result = left.compare(right, options: .numeric)
            if result != .orderedSame { return result }
        }
        return .orderedSame
    }

    public static func applications(roots: [URL] = [URL(fileURLWithPath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")], token: CancellationToken) throws -> SoftwareScanResult {
        var result: [SoftwareEntry] = [], errors: [String] = [], seen = Set<String>(), count = 0
        func note(_ value: String) { if errors.count < 100 { errors.append(String(value.prefix(1000))) } }
        for root in roots {
            if !FileManager.default.fileExists(atPath: root.path) { continue }
            guard let actual = try? canonicalFileURL(root), actual.path == root.path else { note(localized("应用目录无法核验或为链接：") + root.path); continue }
            var traversalError: String?
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [], options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, error in traversalError = error.localizedDescription; return !token.isCancelled }) else { note(localized("无法读取应用目录：") + root.path); continue }
            while let url = enumerator.nextObject() as? URL {
                if token.isCancelled { throw MacEvenError(localized("检查已取消。")) }
                count += 1
                guard count <= 16384, result.count < 2048 else { note(localized("应用发现达到上限，结果不完整。")); break }
                guard let identity = try? FileIdentity.read(url) else { note(localized("无法核验应用路径：") + url.path); enumerator.skipDescendants(); continue }
                if identity.isSymlink { if identity.isDirectory { enumerator.skipDescendants() }; continue }
                guard identity.isDirectory, url.pathExtension.lowercased() == "app" else { continue }
                enumerator.skipDescendants()
                guard seen.insert(url.path).inserted else { continue }
                let infoURL = url.appendingPathComponent("Contents/Info.plist")
                do {
                    try validateHomePath(infoURL, home: root)
                    let infoIdentity = try FileIdentity.read(infoURL)
                    guard infoIdentity.isRegular, infoIdentity.size <= 1_048_576 else { throw MacEvenError(localized("应用信息超过限制。")) }
                    let data = try Data(contentsOf: infoURL)
                    guard data.count <= 1_048_576, let info = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                        info["CFBundlePackageType"] as? String == "APPL", let id = info["CFBundleIdentifier"] as? String, validCacheIdentifier(id) else { continue }
                    let version = info["CFBundleShortVersionString"] as? String ?? info["CFBundleVersion"] as? String ?? localized("未知")
                    let isIPad = info["UIDeviceFamily"] != nil
                    var entry = SoftwareEntry(id: url.path, name: String((info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? url.deletingPathExtension().lastPathComponent).prefix(512)),
                        url: url, bundleIdentifier: id, version: String(version.prefix(128)), buildVersion: String((info["CFBundleVersion"] as? String ?? version).prefix(128)), identity: identity, isIPadApp: isIPad)
                    if FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/_MASReceipt/receipt").path) { entry.source = .appStore }
                    else if let feed = info["SUFeedURL"] as? String, let feedURL = URL(string: feed), secureURL(feedURL) { entry.source = .sparkle; entry.feedURL = feedURL }
                    else if let feedURL = electronFeed(of: url) { entry.source = .electron; entry.feedURL = feedURL }
                    if id.hasPrefix("com.apple.") || id.hasPrefix("local.maceven") { entry.blockedReason = localized("系统和 MacEven 自身由对应系统更新入口管理。") }
                    result.append(entry)
                } catch { note("\(url.path)：\(error.localizedDescription)") }
            }
            if let traversalError { note(traversalError) }
            if count > 16384 || result.count >= 2048 { break }
        }
        return SoftwareScanResult(entries: result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, errors: errors)
    }

    public static var brewExecutable: URL? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].map { URL(fileURLWithPath: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
    private static let brewEnvironment = ["HOMEBREW_NO_ANALYTICS":"1", "HOMEBREW_NO_AUTO_UPDATE":"1", "HOMEBREW_NO_INSTALL_CLEANUP":"1", "HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK":"1", "HOMEBREW_NO_UPGRADE_QUIT_CASKS":"1", "PATH":"/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"]
    public static func validBrewToken(_ value: String) -> Bool {
        !value.hasPrefix("-") && !value.isEmpty && value.utf8.count <= 255 && value.range(of: #"^[A-Za-z0-9][A-Za-z0-9+_.-]*(/[A-Za-z0-9][A-Za-z0-9+_.-]*){0,2}$"#, options: .regularExpression) != nil
    }
    private static let knownCaskAliases: [String: String] = [
        "雷神加速器": "leigod", "leigod": "leigod",
        "阿里云盘": "adrive", "adrive": "adrive",
        "百度网盘": "baidunetdisk", "baidunetdisk_mac": "baidunetdisk", "baidunetdisk": "baidunetdisk",
        "微信": "wechat", "wechat": "wechat", "qq": "qq",
        "豆包": "doubao", "doubao": "doubao", "kimi": "kimi",
        "网易uu远程": "uuremote", "uuremote": "uuremote",
        "uu加速器": "uu-booster", "uubooster": "uu-booster", "uu-booster": "uu-booster",
        "wpsoffice": "wpsoffice", "wps office": "wpsoffice",
        "谷歌浏览器": "google-chrome", "google chrome": "google-chrome", "google-chrome": "google-chrome", "chrome": "google-chrome",
        "火狐": "firefox", "firefox": "firefox",
        "网易云音乐": "neteasemusic", "neteasemusic": "neteasemusic",
        "obsidian": "obsidian",
        "visual studio code": "visual-studio-code", "visual-studio-code": "visual-studio-code", "vscode": "visual-studio-code", "code": "visual-studio-code",
        "chatgpt": "chatgpt", "claude": "claude", "notion": "notion", "telegram": "telegram", "discord": "discord", "steam": "steam",
        "raycast": "raycast", "snipaste": "snipaste", "stats": "stats", "localsend": "localsend", "motrix": "motrix", "zed": "zed",
        "docker": "docker", "orbstack": "orbstack", "postman": "postman", "sublime text": "sublime-text", "typora": "typora",
        "iina": "iina", "keka": "keka", "iterm2": "iterm2", "iterm": "iterm2", "alacritty": "alacritty", "warp": "warp",
        "clash verge": "clash-verge-rev", "clash-verge": "clash-verge-rev", "clash-verge-rev": "clash-verge-rev",
        "surge": "surge", "shadowrocket": "shadowrocket", "proxyman": "proxyman", "charles": "charles", "wireshark": "wireshark",
        "dbeaver": "dbeaver-community", "navicat premium lite": "navicat-premium-lite", "tableplus": "tableplus",
        "pear cleaner": "pearcleaner", "pearcleaner": "pearcleaner", "losslesscut": "losslesscut",
        "macs fan control": "macs-fan-control", "markedit": "markedit",
        "microsoft edge": "microsoft-edge", "edge": "microsoft-edge",
        "swiftbar": "swiftbar", "termius": "termius", "thonny": "thonny", "utm": "utm", "workbuddy": "workbuddy-cn"
    ]
    public static func inferBrewToken(name: String, bundleId: String?) -> String? {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let token = knownCaskAliases[cleanName] { return token }
        let normalized = cleanName.replacingOccurrences(of: "_", with: "-").replacingOccurrences(of: " ", with: "-")
        if let token = knownCaskAliases[normalized] { return token }
        if let bundleId = bundleId?.lowercased() {
            let parts = bundleId.split(separator: ".").map(String.init)
            if let last = parts.last {
                if let token = knownCaskAliases[last] { return token }
                let noMac = last.replacingOccurrences(of: "-mac", with: "").replacingOccurrences(of: "_mac", with: "")
                if let token = knownCaskAliases[noMac] { return token }
            }
        }
        if validBrewToken(normalized) && normalized.allSatisfy({ $0.isASCII }) && normalized.count >= 3 && !normalized.contains("/") {
            return normalized
        }
        return nil
    }
    public static func brewEntries(_ data: Data, caskroom: URL, applications: [SoftwareEntry]) throws -> [SoftwareEntry] {
        guard data.count <= 2 * 1024 * 1024, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let formulae = json["formulae"] as? [[String: Any]], let casks = json["casks"] as? [[String: Any]], formulae.count + casks.count <= 4096 else { throw MacEvenError(localized("Homebrew 数据格式不完整或超过上限。")) }
        var rows: [SoftwareEntry] = []
        for formula in formulae {
            guard let name = formula["name"] as? String, let token = formula["full_name"] as? String, validBrewToken(token),
                let installed = formula["installed"] as? [[String: Any]], let version = installed.first?["version"] as? String else { throw MacEvenError(localized("Homebrew Formula 安装记录无效。")) }
            var row = SoftwareEntry(id: "formula:" + token, name: name, version: version, source: .homebrewFormula)
            row.brewToken = token; row.latestVersion = (formula["versions"] as? [String: Any])?["stable"] as? String
            row.hasUpdate = formula["outdated"] as? Bool ?? false
            if formula["pinned"] as? Bool == true { row.blockedReason = localized("Homebrew 固定版本，保留。") }
            if formula["disabled"] as? Bool == true || formula["deprecated"] as? Bool == true { row.blockedReason = localized("Homebrew 已停用或弃用，请在终端审查。") }
            if installed.count != 1 || row.latestVersion == nil { row.blockedReason = localized("安装版本或目标版本不明确，请在终端审查。") }
            row.note = row.hasUpdate ? localized("发现更新") : localized("Homebrew 未报告更新"); rows.append(row)
        }
        var used = Set<String>()
        for cask in casks {
            guard let token = cask["full_token"] as? String ?? cask["token"] as? String, validBrewToken(token),
                  let installed = cask["installed"] as? String else { throw MacEvenError(localized("Homebrew Cask 安装记录无效。")) }
            let shortToken = String(token.split(separator: "/").last ?? "")
            var match: SoftwareEntry?
            if !installed.contains("/"), let artifacts = cask["artifacts"] as? [[String: Any]] {
                for artifact in artifacts {
                    guard let app = (artifact["app"] as? [Any])?.first as? String, !app.hasPrefix("/"), !app.split(separator: "/").contains("..") else { continue }
                    let installedURL = caskroom.appendingPathComponent(shortToken).appendingPathComponent(installed).appendingPathComponent(app)
                    if let actual = try? canonicalFileURL(installedURL) { match = applications.first { $0.url?.path == actual.path } }
                }
            }
            var row = match ?? SoftwareEntry(id: "cask:" + token, name: (cask["name"] as? [String])?.first ?? shortToken, version: installed, source: .homebrewCask)
            row.source = .homebrewCask; row.brewToken = token; row.latestVersion = cask["version"] as? String
            row.hasUpdate = cask["outdated"] as? Bool ?? false
            if cask["pinned"] as? Bool == true { row.blockedReason = localized("Homebrew 固定版本，保留。") }
            if cask["disabled"] as? Bool == true || cask["deprecated"] as? Bool == true { row.blockedReason = localized("Homebrew 已停用或弃用，请在终端审查。") }
            if row.latestVersion == nil || row.latestVersion == "latest" { row.blockedReason = localized("目标版本不明确，请使用应用自身更新器。") }
            if let match {
                guard used.insert(match.id).inserted else { throw MacEvenError(localized("多个 Cask 指向同一应用，无法确认更新归属。")) }
                if let installedBuild = cask["bundle_version"] as? String,
                   compareVersions(match.buildVersion, installedBuild) == .orderedDescending { row.blockedReason = localized("应用已自行更新，Homebrew 安装记录较旧；保留当前应用。") }
            } else { row.blockedReason = localized("无法精确关联应用安装路径，请在终端更新。") }
            row.note = row.hasUpdate ? localized("发现更新") : localized("Homebrew 未报告更新"); rows.append(row)
        }
        return rows
    }

    public static func discover(token: CancellationToken, roots: [URL]? = nil, refreshBrew: Bool = true, caskCatalog: Bool = true) throws -> SoftwareScanResult {
        let catalog = try applications(roots: roots ?? [URL(fileURLWithPath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")], token: token)
        let apps = catalog.entries
        var errors = catalog.errors, brewRows: [SoftwareEntry] = []
        if let brew = brewExecutable {
            var fresh = !refreshBrew
            do {
                if refreshBrew {
                    do {
                        let update = try SoftwareCommand.run(brew, arguments: ["update"], token: token, timeout: 120, environment: brewEnvironment)
                        fresh = update.status == 0
                        if !fresh { errors.append(localized("Homebrew 元数据刷新失败：") + String(update.error.prefix(1000))) }
                    } catch {
                        if token.isCancelled { throw error }
                        errors.append(localized("Homebrew 元数据刷新失败：") + error.localizedDescription)
                    }
                }
                let info = try SoftwareCommand.run(brew, arguments: ["info", "--json=v2", "--installed"], token: token, timeout: 90, environment: brewEnvironment)
                guard info.status == 0 else { throw MacEvenError(String(info.error.prefix(1000))) }
                let caskroom = brew.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Caskroom")
                brewRows = try brewEntries(Data(info.output.utf8), caskroom: caskroom, applications: apps)
                if !fresh { for position in brewRows.indices { brewRows[position].blockedReason = localized("元数据未成功刷新，更新状态待核验。"); brewRows[position].note = localized("检查失败，不能判断最新版本") } }
            } catch {
                if token.isCancelled { throw error }
                brewRows = []; errors.append(localized("Homebrew 查询失败：") + error.localizedDescription)
            }
        } else { errors.append(localized("未安装 Homebrew；其他来源仍可检查。")) }
        let replaced = Set(brewRows.map(\.id))
        var others = apps.filter { !replaced.contains($0.id) }
        // 非 Homebrew 安装的应用：一次性下载 Homebrew 公开 cask 目录在本地匹配，避免逐个联网查询
        var casks: CaskCatalog?
        if caskCatalog {
            do { casks = try CaskCatalog.parse(download(caskCatalogURL, limit: 64 * 1024 * 1024, timeout: 60, token: token)) }
            catch {
                if token.isCancelled { throw error }
                errors.append(localized("Homebrew 公开目录获取失败，改为逐个查询：") + String(error.localizedDescription.prefix(500)))
            }
        }
        others = resolveCasks(others, catalog: casks)
        return SoftwareScanResult(entries: (others + brewRows).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, errors: errors)
    }

    // MARK: - Homebrew 公开 cask 目录

    static let caskCatalogURL = URL(string: "https://formulae.brew.sh/api/cask.json")!

    /// 公开 cask 目录中识别应用所需的最小信息
    public struct CaskRecord: Sendable, Equatable {
        public let token: String
        /// 去掉逗号后构建号等附加段的版本
        public let version: String
        /// 安装到 Applications 后的 .app 文件名（小写）
        public let appNames: [String]
        /// uninstall/zap 中 quit 声明的包标识
        public let bundleIdentifiers: [String]
        /// uninstall 中 pkgutil 声明的安装包收据标识（pkg 安装的 cask 通常没有 app 产物，靠它识别）
        public let packageIdentifiers: [String]
        public init(token: String, version: String, appNames: [String], bundleIdentifiers: [String], packageIdentifiers: [String] = []) {
            self.token = token; self.version = version; self.appNames = appNames.map { $0.lowercased() }
            self.bundleIdentifiers = bundleIdentifiers; self.packageIdentifiers = packageIdentifiers
        }
        /// 解析单个 cask 的 API JSON；没有 app 产物或版本不明确时返回 nil
        public init?(json cask: [String: Any]) {
            guard let token = cask["token"] as? String, validBrewToken(token), let raw = cask["version"] as? String, raw != "latest",
                  let artifacts = cask["artifacts"] as? [[String: Any]] else { return nil }
            var names: [String] = [], ids: [String] = [], packages: [String] = []
            for artifact in artifacts {
                if let apps = artifact["app"] as? [Any] {
                    // 优先用安装目标路径；其次 app 数组中的重命名目标；最后用源文件名
                    if let target = artifact["target"] as? String { names.append((target as NSString).lastPathComponent) }
                    else if let renamed = apps.compactMap({ ($0 as? [String: Any])?["target"] as? String }).first { names.append((renamed as NSString).lastPathComponent) }
                    else if let source = apps.first as? String { names.append((source as NSString).lastPathComponent) }
                }
                for key in ["uninstall", "zap"] {
                    for directive in artifact[key] as? [[String: Any]] ?? [] {
                        if let quit = directive["quit"] as? String { ids.append(quit) }
                        else if let quit = directive["quit"] as? [String] { ids.append(contentsOf: quit) }
                        if key == "uninstall", let receipt = directive["pkgutil"] as? String { packages.append(receipt) }
                        else if key == "uninstall", let receipts = directive["pkgutil"] as? [String] { packages.append(contentsOf: receipts) }
                    }
                }
            }
            let version = String(raw.split(separator: ",").first ?? Substring(raw))
            guard !names.isEmpty || !ids.isEmpty || !packages.isEmpty, !version.isEmpty, version.utf8.count <= 128 else { return nil }
            self.init(token: token, version: version, appNames: names, bundleIdentifiers: ids, packageIdentifiers: packages)
        }
    }

    public struct CaskCatalog: Sendable {
        private let byAppName: [String: [CaskRecord]], byIdentifier: [String: [CaskRecord]]
        public init(records: [CaskRecord]) {
            var names: [String: [CaskRecord]] = [:], identifiers: [String: [CaskRecord]] = [:]
            for record in records {
                for name in Set(record.appNames) { names[name, default: []].append(record) }
                for id in Set(record.bundleIdentifiers + record.packageIdentifiers) { identifiers[id, default: []].append(record) }
            }
            byAppName = names; byIdentifier = identifiers
        }
        public static func parse(_ data: Data) throws -> CaskCatalog {
            guard let casks = try JSONSerialization.jsonObject(with: data) as? [[String: Any]], casks.count <= 50_000 else { throw MacEvenError(localized("Homebrew 公开目录格式无效或超过上限。")) }
            return CaskCatalog(records: casks.compactMap(CaskRecord.init(json:)))
        }
        /// 多个候选时：包标识能唯一确认的优先；否则若只有一个非 @beta 等变体的正式版，取正式版；仍无法区分则不猜测
        private static func pick(_ candidates: [CaskRecord], bundleIdentifier: String?) -> CaskRecord? {
            if candidates.count <= 1 { return candidates.first }
            if let bundleIdentifier {
                let confirmed = candidates.filter { $0.bundleIdentifiers.contains(bundleIdentifier) }
                if confirmed.count == 1 { return confirmed[0] }
            }
            let stable = candidates.filter { !$0.token.contains("@") }
            return stable.count == 1 ? stable[0] : nil
        }
        /// 先以安装后的 .app 文件名匹配：cask 声明了退出包标识却不含本应用标识时视为同名的其他应用；
        /// 文件名无匹配（pkg 安装或用户改名）时，再以 quit/pkgutil 中与本应用完全相同的包标识匹配
        public func match(appFileName: String, bundleIdentifier: String?) -> CaskRecord? {
            let byName = (byAppName[appFileName.lowercased()] ?? []).filter { record in
                guard let bundleIdentifier, !record.bundleIdentifiers.isEmpty else { return true }
                return record.bundleIdentifiers.contains(bundleIdentifier)
            }
            if !byName.isEmpty { return Self.pick(byName, bundleIdentifier: bundleIdentifier) }
            guard let bundleIdentifier else { return nil }
            return Self.pick(byIdentifier[bundleIdentifier] ?? [], bundleIdentifier: bundleIdentifier)
        }
    }

    /// 为未识别来源（或仅有 Electron 更新源）的应用关联公开 cask。有目录时只接受精确匹配；目录不可用时退回名称推断，留到检查阶段逐个核验。
    public static func resolveCasks(_ entries: [SoftwareEntry], catalog: CaskCatalog?) -> [SoftwareEntry] {
        entries.map { entry in
            guard [.unknown, .electron].contains(entry.source), entry.blockedReason == nil, let url = entry.url else { return entry }
            var row = entry
            if let catalog {
                guard let record = catalog.match(appFileName: url.lastPathComponent, bundleIdentifier: entry.bundleIdentifier) else { return entry }
                row.source = .homebrewCask; row.caskToken = record.token; row.latestVersion = record.version
            } else if entry.source == .unknown, let token = inferBrewToken(name: entry.name, bundleId: entry.bundleIdentifier) {
                row.source = .homebrewCask; row.caskToken = token
            }
            return row
        }
    }

    // MARK: - Electron（electron-updater）更新源

    /// 读取应用内 electron-updater 的 app-update.yml，换算出 latest-mac.yml 地址；仅支持 generic 与 github 两种公开提供方
    static func electronFeed(of app: URL) -> URL? {
        let config = app.appendingPathComponent("Contents/Resources/app-update.yml")
        guard let identity = try? FileIdentity.read(config), identity.isRegular, identity.size <= 65_536,
              let data = try? Data(contentsOf: config), let text = String(data: data, encoding: .utf8) else { return nil }
        return electronFeedURL(text)
    }
    private static func topLevelYAML(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) where !line.hasPrefix(" ") && !line.hasPrefix("\t") && !line.hasPrefix("-") && !line.hasPrefix("#") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == "'" || first == "\"", value.last == first { value = String(value.dropFirst().dropLast()) }
            values[line[..<colon].trimmingCharacters(in: .whitespaces)] = value
        }
        return values
    }
    public static func electronFeedURL(_ yaml: String) -> URL? {
        let values = topLevelYAML(yaml)
        func safe(_ value: String?) -> String? {
            guard let value, !value.isEmpty, value.utf8.count <= 100, value.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil, value != ".", value != ".." else { return nil }
            return value
        }
        switch values["provider"] {
        case "generic":
            guard let raw = values["url"], let base = URL(string: raw), secureURL(base), base.query == nil, base.fragment == nil else { return nil }
            var channel = "latest"
            if let raw = values["channel"] { guard let valid = safe(raw) else { return nil }; channel = valid }
            return base.appendingPathComponent("\(channel)-mac.yml")
        case "github":
            guard values["host"] == nil || values["host"] == "github.com", let owner = safe(values["owner"]), let repo = safe(values["repo"]) else { return nil }
            return URL(string: "https://github.com/\(owner)/\(repo)/releases/latest/download/latest-mac.yml")
        default: return nil
        }
    }
    /// 解析 latest-mac.yml 顶层的 version 字段
    public static func electronVersion(_ data: Data) throws -> String {
        guard data.count <= 2 * 1024 * 1024, let text = String(data: data, encoding: .utf8),
              let version = topLevelYAML(text)["version"], !version.isEmpty, version.utf8.count <= 128 else { throw MacEvenError(localized("Electron 更新源缺少版本信息。")) }
        return version
    }

    public struct FeedVersion: Sendable { public let build: String; public let display: String }
    private final class FeedParser: NSObject, XMLParserDelegate {
        struct Item { var build = "", display = "", minimum = "", maximum = "", channel = "", os = "" }
        var items: [Item] = [], current: Item?, text = "", nodes = 0, capturing = false
        func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            nodes += 1; text = ""
            capturing = ["sparkle:minimumSystemVersion", "sparkle:maximumSystemVersion", "sparkle:channel", "sparkle:version", "sparkle:shortVersionString"].contains(element)
            if nodes > 16384 || items.count > 1024 { parser.abortParsing(); return }
            if element == "item" { current = Item() }
            if element == "enclosure", var item = current {
                item.build = attributes["sparkle:version"] ?? item.build
                item.display = attributes["sparkle:shortVersionString"] ?? (item.display.isEmpty ? item.build : item.display)
                item.os = attributes["sparkle:os"] ?? ""
                current = item
            }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { if !capturing { return }; if text.utf8.count + string.utf8.count <= 4096 { text += string } else { parser.abortParsing() } }
        func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch element {
            case "sparkle:minimumSystemVersion": current?.minimum = value
            case "sparkle:maximumSystemVersion": current?.maximum = value
            case "sparkle:channel": current?.channel = value
            case "sparkle:version": if current?.build.isEmpty == true { current?.build = value }
            case "sparkle:shortVersionString": if current?.display.isEmpty == true { current?.display = value }
            case "item": if let current { items.append(current) }; current = nil
            default: break
            }
            text = ""; capturing = false
        }
    }
    public static func sparkleVersion(_ data: Data, systemVersion: String) throws -> FeedVersion? {
        guard data.count <= 2 * 1024 * 1024, String(data: data, encoding: .utf8)?.uppercased().contains("<!DOCTYPE") != true else { throw MacEvenError(localized("更新源超过限制或包含不支持的 XML 声明。")) }
        let parser = XMLParser(data: data), delegate = FeedParser()
        parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse() else { throw MacEvenError(localized("更新源无法解析。")) }
        let compatible = delegate.items.filter { item in
            !item.build.isEmpty && compareVersions(item.build, "0") != nil && (item.channel.isEmpty || item.channel == "stable") &&
            (item.os.isEmpty || ["osx", "macos"].contains(item.os)) &&
            (item.minimum.isEmpty || [.orderedSame, .orderedDescending].contains(compareVersions(systemVersion, item.minimum))) &&
            (item.maximum.isEmpty || [.orderedSame, .orderedAscending].contains(compareVersions(systemVersion, item.maximum)))
        }
        guard let best = compatible.max(by: { compareVersions($0.build, $1.build) == .orderedAscending }) else { return nil }
        return FeedVersion(build: best.build, display: best.display.isEmpty ? best.build : best.display)
    }
    public static func secureURL(_ url: URL) -> Bool { url.scheme == "https" && url.host?.isEmpty == false && url.user == nil && url.password == nil }
    /// 所有更新源请求共用一个会话，复用连接，避免每个应用重新握手
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20; configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }()
    private static func fetch(_ url: URL, token: CancellationToken) async throws -> Data {
        guard secureURL(url), !token.isCancelled else { throw MacEvenError(localized("更新源不安全或检查已取消。")) }
        let (bytes, response) = try await session.bytes(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), let finalURL = http.url, secureURL(finalURL), http.expectedContentLength <= 2 * 1024 * 1024 else { throw MacEvenError(localized("更新源响应失败或超过限制。")) }
        var data = Data()
        for try await byte in bytes {
            if token.isCancelled || Task.isCancelled { throw MacEvenError(localized("检查已取消。")) }
            guard data.count < 2 * 1024 * 1024 else { throw MacEvenError(localized("更新源超过 2 MiB。")) }
            data.append(byte)
        }
        return data
    }
    /// 同步下载并限制大小（用于目录发现阶段的大文件），可随取消令牌中断
    private final class LimitedDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let limit: Int, done = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var buffer = Data(), failure: Error?
        init(limit: Int) { self.limit = limit }
        var result: Result<Data, Error> { lock.lock(); defer { lock.unlock() }; return failure.map { .failure($0) } ?? .success(buffer) }
        private func fail(_ error: Error) { lock.lock(); if failure == nil { failure = error }; lock.unlock() }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), let finalURL = http.url, SoftwareUpdates.secureURL(finalURL),
                  http.expectedContentLength <= Int64(limit) else { fail(MacEvenError(localized("下载响应失败或超过限制。"))); completionHandler(.cancel); return }
            completionHandler(.allow)
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            lock.lock(); let over = buffer.count + data.count > limit; if !over { buffer.append(data) }; lock.unlock()
            if over { fail(MacEvenError(localized("下载内容超过限制。"))); dataTask.cancel() }
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error { fail(error) }
            done.signal()
        }
    }
    static func download(_ url: URL, limit: Int, timeout: TimeInterval, token: CancellationToken) throws -> Data {
        guard secureURL(url), !token.isCancelled else { throw MacEvenError(localized("下载地址不安全或检查已取消。")) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = timeout
        let delegate = LimitedDownload(limit: limit)
        let downloadSession = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { downloadSession.finishTasksAndInvalidate() }
        let task = downloadSession.dataTask(with: url)
        task.resume()
        while delegate.done.wait(timeout: .now() + 0.2) == .timedOut { if token.isCancelled { task.cancel() } }
        if token.isCancelled { throw MacEvenError(localized("检查已取消。")) }
        return try delegate.result.get()
    }

    public static func check(_ entry: SoftwareEntry, token: CancellationToken) async throws -> SoftwareEntry {
        var row = entry
        switch row.source {
        case .sparkle:
            guard let feed = row.feedURL else { throw MacEvenError(localized("应用未提供可用更新源。")) }
            let os = ProcessInfo.processInfo.operatingSystemVersion
            guard let latest = try sparkleVersion(await fetch(feed, token: token), systemVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)") else { throw MacEvenError(localized("没有可用的兼容稳定版本。")) }
            // 优先用 build 号（CFBundleVersion）比较；若格式不兼容则降级用 display 版本号比较
            let comparison = compareVersions(row.buildVersion, latest.build) ?? compareVersions(row.version, latest.display)
            guard let comparison else { throw MacEvenError(localized("没有可比较的兼容稳定版本，不能判断更新。")) }
            row.latestVersion = latest.display; row.hasUpdate = comparison == .orderedAscending
            row.note = row.hasUpdate ? localized("发现更新 · 使用应用自身更新器") : localized("更新源未发现更高版本")
        case .electron:
            guard let feed = row.feedURL else { throw MacEvenError(localized("应用未提供可用更新源。")) }
            let latest = try electronVersion(await fetch(feed, token: token))
            guard let comparison = compareVersions(row.version, latest) else { throw MacEvenError(localized("更新源版本 \(latest) 无法与已安装版本比较。")) }
            row.latestVersion = latest; row.hasUpdate = comparison == .orderedAscending
            row.note = row.hasUpdate ? localized("发现更新 · 使用应用自身更新器") : localized("更新源未发现更高版本")
        case .homebrewCask:
            if let latest = row.latestVersion {
                let clean = latest.components(separatedBy: ",").first ?? latest
                let mainVer = clean.components(separatedBy: "_").first ?? clean
                let comparison = compareVersions(row.version, mainVer) ?? compareVersions(row.version, clean)
                if let comparison {
                    row.hasUpdate = comparison == .orderedAscending
                    row.note = row.hasUpdate ? localized("发现更新 · 可通过官网或 Homebrew 升级") : localized("已是最新版本")
                } else { row.note = localized("已关联 Homebrew，版本格式特殊") }
                break
            }
            // 公开目录不可用时的退路：逐个查询推断出的 token，并用 app 产物核验确实是同一个应用
            guard let tokenStr = row.caskToken, validBrewToken(tokenStr),
                  let apiURL = URL(string: "https://formulae.brew.sh/api/cask/\(tokenStr).json") else { break }
            do {
                let data = try await fetch(apiURL, token: token)
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let record = CaskRecord(json: json),
                      let url = row.url, CaskCatalog(records: [record]).match(appFileName: url.lastPathComponent, bundleIdentifier: row.bundleIdentifier) != nil else {
                    row.source = .unknown; row.caskToken = nil
                    row.note = localized("未识别更新源；请使用应用自身更新入口")
                    break
                }
                let clean = record.version
                let mainVer = clean.components(separatedBy: "_").first ?? clean
                row.latestVersion = clean
                let comparison = compareVersions(row.version, mainVer) ?? compareVersions(row.version, clean)
                if let comparison {
                    row.hasUpdate = comparison == .orderedAscending
                    row.note = row.hasUpdate ? localized("发现更新 · 可通过官网或 Homebrew 升级") : localized("已是最新版本")
                } else {
                    row.note = localized("已关联 Homebrew，版本格式特殊")
                }
            } catch {
                if token.isCancelled || Task.isCancelled { throw error }
                row.source = .unknown; row.caskToken = nil
                row.note = localized("未识别更新源；请使用应用自身更新入口")
            }
        case .appStore:
            guard let id = row.bundleIdentifier else { throw MacEvenError(localized("缺少应用标识。")) }
            // 先用当前地区查询，若未找到匹配条目则 fallback 到 US 区
            let currentRegion = Locale.current.region?.identifier ?? "US"
            func makeComponents(_ country: String) -> URL {
                var c = URLComponents(string: "https://itunes.apple.com/lookup")!
                c.queryItems = [URLQueryItem(name: "bundleId", value: id), URLQueryItem(name: "entity", value: "macSoftware"), URLQueryItem(name: "country", value: country)]
                return c.url!
            }
            func extractApp(_ data: Data) -> [String: Any]? {
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let results = json["results"] as? [[String: Any]] else { return nil }
                return results.first { item in
                    guard (item["bundleId"] as? String) == id else { return false }
                    let kind = item["kind"] as? String
                    return row.isIPadApp ? (kind == "mac-software" || kind == "software") : (kind == "mac-software")
                }
            }
            var app: [String: Any]?
            let primaryData = try await fetch(makeComponents(currentRegion), token: token)
            app = extractApp(primaryData)
            if app == nil && currentRegion != "US" {
                let fallbackData = try await fetch(makeComponents("US"), token: token)
                app = extractApp(fallbackData)
            }
            if let app,
               let version = app["version"] as? String,
               let comparison = compareVersions(row.version, version),
               let link = app["trackViewUrl"] as? String,
               let url = URL(string: link), secureURL(url), url.host == "apps.apple.com" {
                row.latestVersion = version
                row.hasUpdate = comparison == .orderedAscending
                row.actionURL = url
                row.note = row.hasUpdate ? localized("发现更新 · 在 App Store 安装") : localized("该地区商店未发现更高版本")
            } else {
                row.latestVersion = row.version
                row.hasUpdate = false
                row.note = row.isIPadApp ? localized("商店未发现匹配更新") : localized("独立 Mac 原生版；商店未提供对应原生更新")
            }
        case .unknown:
            if let id = row.bundleIdentifier, !id.hasPrefix("com.apple."), !id.hasPrefix("local.maceven") {
                let region = Locale.current.region?.identifier ?? "CN"
                var c = URLComponents(string: "https://itunes.apple.com/lookup")!
                c.queryItems = [URLQueryItem(name: "bundleId", value: id), URLQueryItem(name: "entity", value: "macSoftware"), URLQueryItem(name: "country", value: region)]
                if let lookupURL = c.url, let data = try? await fetch(lookupURL, token: token),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let results = json["results"] as? [[String: Any]],
                   let app = results.first(where: { ($0["bundleId"] as? String) == id && ($0["kind"] as? String) == "mac-software" }),
                   let version = app["version"] as? String,
                   let comparison = compareVersions(row.version, version),
                   let link = app["trackViewUrl"] as? String,
                   let actionURL = URL(string: link), secureURL(actionURL), actionURL.host == "apps.apple.com" {
                    row.source = .appStore
                    row.latestVersion = version
                    row.hasUpdate = comparison == .orderedAscending
                    row.actionURL = actionURL
                    row.note = row.hasUpdate ? localized("发现更新 · 在 App Store 安装") : localized("该地区商店未发现更高版本")
                    break
                }
            }
            row.note = localized("未识别更新源；请使用应用自身更新入口")
        default: break
        }
        return row
    }

    public static func upgrade(_ entry: SoftwareEntry, token: CancellationToken,
        inventory: (@Sendable (CancellationToken) throws -> SoftwareScanResult)? = nil,
        command: (@Sendable (URL, [String]) throws -> SoftwareCommandResult)? = nil) throws -> SoftwareEntry {
        guard entry.canUpgrade, let expectedToken = entry.brewToken, validBrewToken(expectedToken), let brew = brewExecutable else { throw MacEvenError(localized("该项目不能直接升级。")) }
        if let url = entry.url, let identity = entry.identity {
            guard try canonicalFileURL(url).path == url.path, try FileIdentity.read(url) == identity else { throw MacEvenError(localized("应用已变化，请重新检查更新。")) }
        }
        let readInventory = inventory ?? { try discover(token: $0, refreshBrew: false, caskCatalog: false) }
        let before = try readInventory(token)
        guard let actual = before.entries.first(where: { $0.brewToken == expectedToken && $0.source == entry.source }), actual.canUpgrade,
            actual.version == entry.version, actual.latestVersion == entry.latestVersion, actual.url == entry.url else { throw MacEvenError(localized("安装记录或目标版本已变化，请重新检查。")) }
        let kind = entry.source == .homebrewCask ? "--cask" : "--formula"
        if let url = entry.url, NSWorkspace.shared.runningApplications.contains(where: { !$0.isTerminated && ($0.bundleURL?.resolvingSymlinksInPath() == url || $0.executableURL?.path.hasPrefix(url.path + "/") == true) }) {
            throw MacEvenError(localized("应用正在运行，请自行退出并重新检查更新。"))
        }
        if token.isCancelled { throw MacEvenError(localized("升级尚未开始，已取消。")) }
        var arguments = ["upgrade", kind, "--no-ask"]
        if entry.source == .homebrewCask { arguments += ["--no-quit", "--require-sha", "--greedy-auto-updates"] }
        arguments.append(expectedToken)
        let execute = command ?? { try SoftwareCommand.run($0, arguments: $1, timeout: nil, environment: brewEnvironment) }
        let result = try execute(brew, arguments)
        let after = try readInventory(CancellationToken())
        guard result.status == 0, let updated = after.entries.first(where: { $0.brewToken == expectedToken && $0.source == entry.source }),
            !updated.hasUpdate, updated.version != entry.version || updated.buildVersion != entry.buildVersion else { throw MacEvenError(localized("升级未通过安装版本复核，请重新检查；") + String(result.error.prefix(1000))) }
        return updated
    }
}
