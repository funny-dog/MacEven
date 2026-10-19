import Foundation
import ServiceManagement
import Darwin
import AppKit

public enum StartupKind: String, Sendable {
    case loginItem
    case userAgent
    case systemAgent
    case systemDaemon
}

public struct StartupItem: Identifiable, Sendable {
    public var id: String
    public var url: URL
    public var label: String
    public var program: URL?
    public var kind: StartupKind
    public var enabled: Bool?
    public var loaded: Bool?
    public var running: Bool?
    public var blockedReason: String?
    public var identity: FileIdentity?
    public var appName: String?
    public var appURL: URL?
    public var displayName: String { (appName?.isEmpty == false ? appName : nil) ?? label }

    public init(
        id: String,
        url: URL,
        label: String,
        program: URL? = nil,
        kind: StartupKind,
        enabled: Bool? = nil,
        loaded: Bool? = nil,
        running: Bool? = nil,
        blockedReason: String? = nil,
        identity: FileIdentity? = nil,
        appName: String? = nil,
        appURL: URL? = nil
    ) {
        self.id = id
        self.url = url
        self.label = label
        self.program = program
        self.kind = kind
        self.enabled = enabled
        self.loaded = loaded
        self.running = running
        self.blockedReason = blockedReason
        self.identity = identity
        self.appName = appName
        self.appURL = appURL
    }
}

public struct StartupScanResult: Sendable {
    public var items: [StartupItem]
    public var incomplete: Bool
    public var errors: [String]

    public init(items: [StartupItem] = [], incomplete: Bool = false, errors: [String] = []) {
        self.items = items
        self.incomplete = incomplete
        self.errors = errors
    }
}

public final class StartupItems {
    private struct Record {
        var item: StartupItem
        let ancestors: [(URL, FileIdentity)]
        let defaultDisabled: Bool
    }
    private let home: URL
    private let roots: [(URL, StartupKind)]
    private let runner: @Sendable (URL, [String], CancellationToken?) throws -> SoftwareCommandResult
    private var records: [String: Record] = [:]
    private let launchctl = URL(fileURLWithPath: "/bin/launchctl")
    private var domain: String { "gui/\(getuid())" }
    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        systemRoots: [(URL, StartupKind)]? = nil,
        runner: (@Sendable (URL, [String]) throws -> SoftwareCommandResult)? = nil,
        cancellableRunner: (@Sendable (URL, [String], CancellationToken?) throws -> SoftwareCommandResult)? = nil
    ) {
        self.home = (try? canonicalFileURL(home)) ?? home
        self.roots = (systemRoots ?? [(URL(fileURLWithPath: "/Library/LaunchAgents"), .systemAgent), (URL(fileURLWithPath: "/Library/LaunchDaemons"), .systemDaemon)]).map { ((try? canonicalFileURL($0.0)) ?? $0.0, $0.1) }
        if let cancellableRunner {
            self.runner = cancellableRunner
        } else if let runner {
            self.runner = { exec, args, _ in try runner(exec, args) }
        } else {
            self.runner = { try SoftwareCommand.run($0, arguments: $1, token: $2) }
        }
    }

    private func disabledState(_ target: String? = nil, token: CancellationToken? = nil) throws -> [String: Bool] {
        if token?.isCancelled == true { throw MacEvenError(localized("检查已取消。")) }
        let result = try runner(launchctl, ["print-disabled", target ?? domain], token)
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.status == 0, output.hasPrefix("disabled services = {"), output.hasSuffix("}") else { throw MacEvenError(localized("无法核验启动许可，状态未知。")) }
        let body = output.dropFirst("disabled services = {".count).dropLast()
        let pattern = #"^\s*"([A-Za-z0-9_.-]+)"\s*=>\s*(disabled|enabled|true|false)\s*;?\s*$"#
        let expression = try NSRegularExpression(pattern: pattern)
        var map: [String: Bool] = [:]
        for line in body.split(separator: "\n") {
            let value = String(line)
            if value.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            guard let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
                  let labelRange = Range(match.range(at: 1), in: value), let stateRange = Range(match.range(at: 2), in: value), map[String(value[labelRange])] == nil else { throw MacEvenError(localized("启动许可输出格式不完整，状态未知。")) }
            map[String(value[labelRange])] = ["disabled", "true"].contains(String(value[stateRange]))
        }
        return map
    }
    private func runningState(token: CancellationToken? = nil) throws -> [String: Bool] {
        if token?.isCancelled == true { throw MacEvenError(localized("检查已取消。")) }
        let result = try runner(launchctl, ["list"], token)
        let lines = result.output.split(separator: "\n")
        guard result.status == 0, lines.first?.split(whereSeparator: { $0.isWhitespace }).map(String.init) == ["PID", "Status", "Label"] else { throw MacEvenError(localized("运行状态不可核验。")) }
        var map: [String: Bool] = [:]
        for line in lines.dropFirst() {
            let fields = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard fields.count == 3, Int32(fields[1]) != nil, fields[0] == "-" || (Int32(fields[0]) ?? 0) > 0,
                map[fields[2]] == nil else { throw MacEvenError(localized("运行状态输出格式不完整。")) }
            map[fields[2]] = fields[0] != "-"
        }
        return map
    }
    private func ancestors(_ url: URL) throws -> [(URL, FileIdentity)] {
        guard try canonicalFileURL(url).path == url.path else { throw MacEvenError(localized("启动项路径包含链接。")) }
        var current = URL(fileURLWithPath: "/"), result: [(URL, FileIdentity)] = []
        for part in url.pathComponents.dropFirst().dropLast() {
            current.appendPathComponent(part)
            let identity = try FileIdentity.read(current)
            guard identity.isDirectory, !identity.isSymlink else { throw MacEvenError(localized("启动项祖先目录无效。")) }
            result.append((current, identity))
        }
        return result
    }
    private func extractAppURL(from text: String) -> URL? {
        guard text.contains(".app") else { return nil }
        let pattern = #"(/[^\s"'\\]+?\.app)"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range(at: 1), in: text) {
            let path = String(text[range])
            let candidate = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        var cur = URL(fileURLWithPath: text)
        while cur.path != "/" && cur.pathComponents.count > 1 {
            if cur.pathExtension == "app" && FileManager.default.fileExists(atPath: cur.path) {
                return cur
            }
            cur = cur.deletingLastPathComponent()
        }
        return nil
    }

    private func appDisplayName(_ url: URL) -> String {
        if let bundle = Bundle(url: url) {
            if let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, !name.isEmpty {
                return name
            }
            if let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String, !name.isEmpty {
                return name
            }
        }
        return FileManager.default.displayName(atPath: url.path)
    }

    private func resolveApp(plist: [String: Any], program: URL?, label: String, url: URL) -> (appName: String?, appURL: URL?) {
        let associated = (plist["AssociatedBundleIdentifiers"] as? [String])?.first
            ?? (plist["AssociatedBundleIdentifiers"] as? String)
            ?? (plist["BundleProgram"] as? String)
        if let associated, !associated.isEmpty,
           let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: associated) {
            return (appDisplayName(app), app)
        }

        var candidates: [String] = []
        if let prog = program?.path { candidates.append(prog) }
        if let args = plist["ProgramArguments"] as? [String] { candidates.append(contentsOf: args) }
        candidates.append(url.path)

        for candidate in candidates {
            if let app = extractAppURL(from: candidate) {
                return (appDisplayName(app), app)
            }
        }

        var parts = label.split(separator: ".").map(String.init)
        while parts.count >= 2 {
            let candidate = parts.joined(separator: ".")
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: candidate) {
                return (appDisplayName(app), app)
            }
            parts.removeLast()
        }

        if label.hasPrefix("homebrew.mxcl.") {
            let service = label.dropFirst("homebrew.mxcl.".count).capitalized
            return (String(service), program ?? url)
        }

        if label.hasPrefix("com.apple.") {
            return (localized("macOS 系统服务"), program ?? url)
        }

        if let program {
            return (FileManager.default.displayName(atPath: program.path), program)
        }

        return (label, url)
    }

    private func read(_ url: URL, kind: StartupKind) throws -> Record {
        let identity = try FileIdentity.read(url)
        guard identity.isRegular, !identity.isSymlink, identity.size <= 1_048_576 else { throw MacEvenError(localized("启动项不是普通 plist 或超过 1 MiB。")) }
        let parents = try ancestors(url)
        let fd = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_NOFOLLOW)
        }
        guard fd >= 0 else { throw MacEvenError(localized("无法读取启动项。")) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 1_048_577) ?? Data()
        guard data.count <= 1_048_576, try FileIdentity.read(url) == identity,
            let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let label = plist["Label"] as? String, label.utf8.count <= 255,
            label.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]*$"#, options: .regularExpression) != nil else { throw MacEvenError(localized("启动项标签或文件身份无效。")) }
        let path = plist["Program"] as? String ?? (plist["ProgramArguments"] as? [String])?.first
        let program = path.flatMap { $0.hasPrefix("/") && $0.utf8.count <= 4096 ? URL(fileURLWithPath: $0) : nil }
        var reason: String?
        if kind != .userAgent { reason = localized("系统级项目只读，请在系统设置或所属应用管理。") }
        else if label.lowercased().hasPrefix("com.apple.") || label.lowercased().contains("maceven") { reason = localized("Apple 和 MacEven 自身启动项受保护。") }
        else if ["jamf", "intune", "kandji", "munki", "tanium", "mdm", "managed"].contains(where: { label.lowercased().contains($0) || (path ?? "").lowercased().contains($0) }) { reason = localized("管理服务保持只读，请联系系统管理者。") }
        else if program == nil || program.map({ !FileManager.default.isExecutableFile(atPath: $0.path) }) == true { reason = localized("程序路径或归属不可核验，保持只读。") }
        var fileStat = stat()
        if url.withUnsafeFileSystemRepresentation({ lstat($0, &fileStat) }) != 0 || fileStat.st_uid != getuid() || fileStat.st_mode & 0o022 != 0 { reason = localized("文件所有权或权限不可核验，保持只读。") }
        let (appName, appURL) = resolveApp(plist: plist, program: program, label: label, url: url)
        let item = StartupItem(id: url.path, url: url, label: label, program: program, kind: kind, blockedReason: reason, identity: identity, appName: appName, appURL: appURL)
        return Record(item: item, ancestors: parents, defaultDisabled: plist["Disabled"] as? Bool ?? false)
    }
    private func query(_ record: Record, disabled: [String: Bool]?, running: [String: Bool]?, token: CancellationToken? = nil) -> StartupItem {
        var item = record.item
        item.enabled = disabled.map { !($0[item.label] ?? record.defaultDisabled) }
        if SMAppService.statusForLegacyPlist(at: item.url) == .requiresApproval { item.enabled = false; item.blockedReason = localized("系统要求用户批准，请在系统设置管理。") }
        let target = (item.kind == .systemDaemon ? "system" : domain) + "/" + item.label
        if let result = try? runner(launchctl, ["print", target], token) { item.loaded = result.status == 0 ? true : result.status == 113 ? false : nil }
        if let running {
            item.running = item.kind == .systemDaemon ? (item.loaded == false ? false : nil) : running[item.label] ?? (item.loaded == false ? false : nil)
        }
        if item.enabled == nil || item.loaded == nil || (item.kind == .userAgent && item.running == nil) { item.blockedReason = item.blockedReason ?? localized("系统状态未知，禁止变更。") }
        return item
    }

    private func scanLoginItems(token: CancellationToken? = nil) -> [StartupItem] {
        if token?.isCancelled == true { return [] }
        let script = """
        tell application "System Events"
            set itemNames to name of every login item
            set itemPaths to path of every login item
            set output to ""
            repeat with i from 1 to count of itemNames
                set output to output & (item i of itemNames) & tab & (item i of itemPaths) & linefeed
            end repeat
            return output
        end tell
        """
        guard let result = try? runner(URL(fileURLWithPath: "/usr/bin/osascript"), ["-e", script], token),
              result.status == 0 else { return [] }
        if token?.isCancelled == true { return [] }
        var items: [StartupItem] = []
        let runningApps = NSWorkspace.shared.runningApplications
        for line in result.output.split(separator: "\n") {
            if token?.isCancelled == true { break }
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            let path = parts[1].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !path.isEmpty else { continue }
            let appURL = URL(fileURLWithPath: path)
            let isRunning = runningApps.contains { app in
                !app.isTerminated && (app.bundleURL?.path == path || app.executableURL?.path.hasPrefix(path) == true)
            }
            let item = StartupItem(
                id: "loginItem:" + name + ":" + path,
                url: appURL,
                label: name,
                program: appURL,
                kind: .loginItem,
                enabled: true,
                loaded: true,
                running: isRunning,
                blockedReason: nil,
                identity: try? FileIdentity.read(appURL),
                appName: name,
                appURL: appURL
            )
            items.append(item)
        }
        return items
    }

    public func removeLoginItem(_ item: StartupItem) throws {
        guard item.kind == .loginItem else { throw MacEvenError(localized("不是系统登录项，无法以此方式移除。")) }
        let safeName = item.label.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"System Events\" to delete (every login item whose name is \"\(safeName)\")"
        let result = try runner(URL(fileURLWithPath: "/usr/bin/osascript"), ["-e", script], nil)
        guard result.status == 0 else { throw MacEvenError(localized("移除登录项失败：") + result.error) }
    }

    public func addLoginItem(at url: URL) throws {
        let path = url.path
        guard FileManager.default.fileExists(atPath: path) else { throw MacEvenError(localized("应用文件不存在。")) }
        let safePath = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"System Events\" to make new login item at end with properties {path:\"\(safePath)\", hidden:false}"
        let result = try runner(URL(fileURLWithPath: "/usr/bin/osascript"), ["-e", script], nil)
        guard result.status == 0 else { throw MacEvenError(localized("添加启动项失败：") + result.error) }
    }

    public func scan(token: CancellationToken, includeServices: Bool = true) throws -> StartupScanResult {
        records = [:]
        if token.isCancelled {
            return StartupScanResult(items: [], incomplete: true, errors: [localized("检查已取消。")])
        }
        let loginItems = scanLoginItems(token: token)
        if token.isCancelled {
            return StartupScanResult(items: loginItems, incomplete: true, errors: [localized("检查已取消。")])
        }
        guard includeServices else {
            return StartupScanResult(items: loginItems, incomplete: false, errors: [])
        }
        var items: [StartupItem] = [], errors: [String] = [], incomplete = false, seen = 0
        func note(_ text: String) { incomplete = true; if errors.count < 100 { errors.append(String(text.prefix(1000))) } }
        let disabled: [String: Bool]?, systemDisabled: [String: Bool]?, running: [String: Bool]?
        do { disabled = try disabledState(token: token) } catch { disabled = nil; note(error.localizedDescription) }
        do { systemDisabled = try disabledState("system", token: token) } catch { systemDisabled = nil; note(error.localizedDescription) }
        do { running = try runningState(token: token) } catch { running = nil; note(error.localizedDescription) }
        for (directory, kind) in [(home.appendingPathComponent("Library/LaunchAgents"), StartupKind.userAgent)] + roots {
            if token.isCancelled { incomplete = true; break }
            if !FileManager.default.fileExists(atPath: directory.path) { continue }
            do {
                let root = try canonicalFileURL(directory)
                guard root.path == directory.path else { throw MacEvenError(localized("启动项目录包含链接。")) }
                for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: []).sorted(by: { $0.path < $1.path }) where url.pathExtension == "plist" {
                    if token.isCancelled { incomplete = true; break }
                    seen += 1
                    guard seen <= 1024 else { note(localized("启动项达到 1024 条上限。")); break }
                    do {
                        var record = try read(url, kind: kind)
                        if token.isCancelled { incomplete = true; break }
                        record.item = query(record, disabled: kind == .systemDaemon ? systemDisabled : disabled, running: running, token: token)
                        records[url.path] = record; items.append(record.item)
                    } catch { note("\(url.path)：\(error.localizedDescription)") }
                }
            } catch { note(error.localizedDescription) }
            if seen > 1024 { break }
        }
        if token.isCancelled {
            incomplete = true
            if !errors.contains(localized("检查已取消。")) && errors.count < 100 {
                errors.append(localized("检查已取消。"))
            }
        }
        let labels = Dictionary(grouping: items, by: \.label)
        for index in items.indices where (labels[items[index].label]?.count ?? 0) > 1 {
            items[index].blockedReason = localized("标签对应多个 plist，保持只读。"); records[items[index].id]?.item = items[index]
        }
        if incomplete {
            for index in items.indices { items[index].blockedReason = items[index].blockedReason ?? localized("检查范围或状态不完整，请重新检查。"); records[items[index].id]?.item = items[index] }
        }
        return StartupScanResult(items: loginItems + items, incomplete: incomplete, errors: errors)
    }

    public func setEnabled(_ item: StartupItem, enabled: Bool) throws -> StartupItem {
        guard let record = records[item.id], record.item.kind == .userAgent, record.item.blockedReason == nil,
            item.label == record.item.label, item.url == record.item.url, item.identity == record.item.identity,
            item.url.deletingLastPathComponent().path == home.appendingPathComponent("Library/LaunchAgents").path else { throw MacEvenError(localized("该启动项不可变更，请重新检查。")) }
        try validate(record)
        let before = query(record, disabled: try disabledState(), running: try runningState())
        guard before.blockedReason == nil, let originalEnabled = before.enabled, let originalLoaded = before.loaded,
            originalEnabled == item.enabled else { throw MacEvenError(localized("启动项状态已变化或未知，请重新检查。")) }
        if originalEnabled == enabled { return before }
        let target = domain + "/" + item.label
        func execute(_ args: [String]) throws {
            let result = try runner(launchctl, args, nil)
            guard result.status == 0 else { throw MacEvenError(localized("launchctl 操作失败：") + String(result.error.prefix(1000))) }
        }
        do {
            try validate(record)
            try execute([enabled ? "enable" : "disable", target])
            try validate(record)
            if enabled && !originalLoaded { try execute(["bootstrap", domain, item.url.path]) }
            if !enabled && originalLoaded { try execute(["bootout", target]) }
            let after = query(record, disabled: try disabledState(), running: try runningState())
            guard after.enabled == enabled, after.loaded == enabled else { throw MacEvenError(localized("实际许可或加载状态未达到目标。")) }
            records[item.id]?.item = after
            return after
        } catch {
            // Restore the prior permission after a partial change; never rewrite the plist.
            var restoration = ""
            do {
                try validate(record)
                try execute([originalEnabled ? "enable" : "disable", target])
                let state = query(record, disabled: try disabledState(), running: try runningState())
                if originalLoaded && state.loaded == false { try execute(["bootstrap", domain, item.url.path]) }
                if !originalLoaded && state.loaded == true { try execute(["bootout", target]) }
                let restored = query(record, disabled: try disabledState(), running: try runningState())
                guard restored.enabled == originalEnabled, restored.loaded == originalLoaded else { throw MacEvenError(localized("恢复状态未确认。")) }
            } catch { restoration = localized("；原状态恢复未确认，请在系统设置检查：") + error.localizedDescription }
            throw MacEvenError(error.localizedDescription + restoration)
        }
    }
    private func validate(_ record: Record) throws {
        let latest = try read(record.item.url, kind: .userAgent)
        guard latest.item.identity == record.item.identity, latest.item.label == record.item.label, latest.item.program == record.item.program,
            latest.item.blockedReason == nil else { throw MacEvenError(localized("启动项身份或程序已变化。")) }
        for (url, old) in record.ancestors {
            let new = try FileIdentity.read(url)
            guard new.device == old.device, new.inode == old.inode, new.mode == old.mode, new.isDirectory, !new.isSymlink else { throw MacEvenError(localized("启动项祖先目录已变化。")) }
        }
    }
}
