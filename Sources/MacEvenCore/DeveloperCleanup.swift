import Foundation
import Darwin

public enum DeveloperCleanupRule: String, CaseIterable, Sendable {
    case derivedData, pip, npm, claudeCache, claudeDebug, codexLogs
    // 0.15：整目录由工具自身管理、可重建的缓存；每条要求目录里有该工具的标志才可选择。
    case homebrew, cocoapods, swiftpm, goBuild, yarn, gradle, cargo, deviceSupport, simulatorCaches, chrome, edge, firefox
    // AI Agent 日志与缓存：各工具标志文件确认后可安全清理；不含会话、记忆、配置与凭据。
    case copilotLogs, kimiLogs, kimiCache, codebuddyLogs, aiderCache
    // 热门 AI Agent 与编辑器：WorkBuddy, Cursor, Trae, Windsurf, Continue, Devin, Chroma
    case workbuddyLogs, workbuddyCache, workbuddyTraces
    case cursorLogs, traeLogs, windsurfLogs, continueLogs, devinCache, chromaCache
    // 工具自身 tmp 区的泄漏残留：候选是其下匹配“已知前缀 + 随机/时间戳后缀”且内容长期未动的子目录，不是 tmp 根本身。
    case codexTmp, codexTmpRoot
    public var name: String {
        switch self {
        case .claudeCache: return localized("Claude Code 更新说明缓存")
        case .claudeDebug: return localized("Claude Code 诊断日志")
        case .codexLogs: return localized("Codex CLI 诊断日志")
        case .copilotLogs: return localized("GitHub Copilot 诊断日志")
        case .kimiLogs: return localized("Kimi Code 诊断日志")
        case .kimiCache: return localized("Kimi Code 配置缓存")
        case .codebuddyLogs: return localized("CodeBuddy 诊断日志")
        case .aiderCache: return localized("aider 模型信息缓存")
        case .workbuddyLogs: return localized("WorkBuddy 诊断日志")
        case .workbuddyCache: return localized("WorkBuddy 配置缓存")
        case .workbuddyTraces: return localized("WorkBuddy 跟踪日志")
        case .cursorLogs: return localized("Cursor 运行日志")
        case .traeLogs: return localized("Trae 运行日志")
        case .windsurfLogs: return localized("Windsurf 运行日志")
        case .continueLogs: return localized("Continue 运行日志")
        case .devinCache: return localized("Devin 运行缓存")
        case .chromaCache: return localized("Chroma 向量模型缓存")
        case .codexTmp: return localized("Codex 临时区泄漏克隆")
        case .codexTmpRoot: return localized("Codex 临时目录泄漏残留")
        case .derivedData: return "Xcode DerivedData"
        case .pip: return localized("pip 下载缓存")
        case .npm: return localized("npm 内容缓存")
        case .homebrew: return localized("Homebrew 下载缓存")
        case .cocoapods: return localized("CocoaPods 缓存")
        case .swiftpm: return localized("Swift Package Manager 缓存")
        case .goBuild: return localized("Go 构建缓存")
        case .yarn: return localized("Yarn 缓存")
        case .gradle: return localized("Gradle 缓存")
        case .cargo: return localized("Cargo 下载的 crate 包")
        case .deviceSupport: return localized("Xcode iOS 设备支持文件")
        case .simulatorCaches: return localized("模拟器缓存")
        case .chrome: return localized("Google Chrome 缓存")
        case .edge: return localized("Microsoft Edge 缓存")
        case .firefox: return localized("Firefox 缓存")
        }
    }
    public var category: String {
        switch self {
        case .claudeCache, .claudeDebug, .codexLogs,
             .copilotLogs, .kimiLogs, .kimiCache, .codebuddyLogs, .aiderCache,
             .workbuddyLogs, .workbuddyCache, .workbuddyTraces,
             .cursorLogs, .traeLogs, .windsurfLogs, .continueLogs, .devinCache, .chromaCache,
             .codexTmp, .codexTmpRoot: return "AI Agent"
        case .chrome, .edge, .firefox: return localized("浏览器")
        default: return localized("开发工具")
        }
    }
    /// AI Agent 缓存所属工具名；「AI 清理与维护」按工具聚合展示。非 AI 缓存为 nil。
    public var aiToolName: String? {
        switch self {
        case .claudeCache, .claudeDebug: return "Claude Code"
        case .codexLogs: return "Codex"
        case .copilotLogs: return "GitHub Copilot"
        case .kimiLogs, .kimiCache: return "Kimi Code"
        case .codebuddyLogs: return "CodeBuddy"
        case .aiderCache: return "aider"
        case .workbuddyLogs, .workbuddyCache, .workbuddyTraces: return "WorkBuddy"
        case .cursorLogs: return "Cursor"
        case .traeLogs: return "Trae"
        case .windsurfLogs: return "Windsurf"
        case .continueLogs: return "Continue"
        case .devinCache: return "Devin"
        case .chromaCache: return "Chroma"
        case .codexTmp, .codexTmpRoot: return "Codex"
        default: return nil
        }
    }
    public var relativePath: String {
        switch self {
        case .claudeCache: return ".claude/cache"
        case .claudeDebug: return ".claude/debug"
        case .codexLogs: return ".codex/log"
        case .copilotLogs: return ".copilot/logs"
        case .kimiLogs: return ".kimi-code/logs"
        case .kimiCache: return ".kimi-code/cache"
        case .codebuddyLogs: return ".codebuddy/logs"
        case .aiderCache: return ".aider/caches"
        case .workbuddyLogs: return ".workbuddy/logs"
        case .workbuddyCache: return ".workbuddy/cache"
        case .workbuddyTraces: return ".workbuddy/traces"
        case .cursorLogs: return "Library/Application Support/Cursor/logs"
        case .traeLogs: return "Library/Application Support/Trae/logs"
        case .windsurfLogs: return "Library/Application Support/Windsurf/logs"
        case .continueLogs: return ".continue/logs"
        case .devinCache: return ".cache/devin"
        case .chromaCache: return ".cache/chroma"
        case .derivedData: return "Library/Developer/Xcode/DerivedData"
        case .pip: return "Library/Caches/pip"
        case .npm: return ".npm/_cacache"
        case .homebrew: return "Library/Caches/Homebrew"
        case .cocoapods: return "Library/Caches/CocoaPods"
        case .swiftpm: return "Library/Caches/org.swift.swiftpm"
        case .goBuild: return "Library/Caches/go-build"
        case .yarn: return "Library/Caches/Yarn"
        case .gradle: return ".gradle/caches"
        case .cargo: return ".cargo/registry/cache"
        case .deviceSupport: return "Library/Developer/Xcode/iOS DeviceSupport"
        case .simulatorCaches: return "Library/Developer/CoreSimulator/Caches"
        case .codexTmp: return ".codex/.tmp"
        case .codexTmpRoot: return ".codex/tmp"
        case .chrome: return "Library/Caches/Google/Chrome"
        case .edge: return "Library/Caches/Microsoft Edge"
        case .firefox: return "Library/Caches/Firefox"
        }
    }
    public var rebuildCost: String {
        switch self {
        case .claudeCache: return localized("更新说明可重新下载；不涉及会话、记忆、配置与凭据")
        case .claudeDebug, .codexLogs,
             .copilotLogs, .kimiLogs, .codebuddyLogs,
             .workbuddyLogs, .workbuddyTraces, .cursorLogs, .traeLogs, .windsurfLogs, .continueLogs:
            return localized("旧诊断、运行与跟踪日志将丢失，后续日志由工具重新生成；不涉及会话与记忆")
        case .kimiCache, .workbuddyCache, .devinCache, .chromaCache:
            return localized("配置与环境模型缓存可联网重新同步；不涉及会话、记忆与凭据")
        case .aiderCache: return localized("模型价格与上下文信息可联网重新拉取；不涉及会话与配置")
        case .codexTmp, .codexTmpRoot:
            return localized("工具升级或克隆留下的临时副本，删除后由工具按需重建；副本内可能有旧项目文件，确认无需保留后再清理")
        case .derivedData: return localized("需要重新构建项目")
        case .pip: return localized("需要网络重新下载依赖；本地构建 wheel 可能需要重新构建")
        case .deviceSupport: return localized("连接设备调试时 Xcode 会重新复制符号文件，耗时较长")
        case .simulatorCaches: return localized("模拟器下次启动时重新生成，首次启动变慢")
        case .goBuild: return localized("需要重新编译 Go 包")
        case .chrome, .edge, .firefox: return localized("网页资源需要重新下载；不影响书签、密码、Cookie 与历史记录")
        default: return localized("需要网络重新下载依赖")
        }
    }
    /// 整目录移动时内部的符号链接只作为链接移动、从不跟随；仅 Homebrew 缓存按设计含指向自身下载目录的链接。
    var allowsInternalLinks: Bool { self == .homebrew }

    /// 工具 tmp 根规则：扫描其下泄漏子目录而不是 tmp 根；默认不选中、逐项确认。
    public var isToolTmpRoot: Bool { self == .codexTmp || self == .codexTmpRoot }

    /// 泄漏命名判定：只认登记过的“已知前缀 + 随机/时间戳后缀”，工具自己的稳定工作目录（如 marketplaces）一律不命中。
    public static func isToolTmpLeakName(_ rule: DeveloperCleanupRule, _ name: String) -> Bool {
        switch rule {
        case .codexTmp:
            // git-XXXXXX：Codex 会话期间创建的裸 git 临时克隆（6 位随机后缀）
            if name.hasPrefix("git-") {
                let suffix = name.dropFirst(4)
                if suffix.count == 6, suffix.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) { return true }
            }
            // marketplace-upgrade-*：插件市场升级留下的克隆（后缀为随机串）
            if name.hasPrefix("marketplace-upgrade-"), name.dropFirst("marketplace-upgrade-".count).count >= 6 { return true }
            return false
        case .codexTmpRoot:
            // <名称>-misplaced-YYYYMMDD-HHMMSS：Codex 移错位置的工作区副本
            guard let marker = name.range(of: "-misplaced-") else { return false }
            let parts = name[marker.upperBound...].split(separator: "-")
            return parts.count == 2 && parts[0].count == 8 && parts[1].count == 6
                && parts.allSatisfy { $0.allSatisfy(\.isNumber) }
        default: return false
        }
    }
}

public struct DeveloperCleanupGroup: Identifiable, Sendable, Equatable {
    public let id: String
    public let rule: DeveloperCleanupRule
    public let name: String
    public let paths: [URL]
    public let allocatedSize: Int64?
    public let logicalSize: Int64?
    public let blockedReason: String?
    public let advisoryReason: String?
    public var rebuildCost: String { rule.rebuildCost }

    public init(id: String, rule: DeveloperCleanupRule, name: String, paths: [URL], allocatedSize: Int64?, logicalSize: Int64?, blockedReason: String?, advisoryReason: String? = nil) {
        self.id = id
        self.rule = rule
        self.name = name
        self.paths = paths
        self.allocatedSize = allocatedSize
        self.logicalSize = logicalSize
        self.blockedReason = blockedReason
        self.advisoryReason = advisoryReason
    }
}

public struct DeveloperCleanupScanResult: Sendable {
    public let groups: [DeveloperCleanupGroup]
    public let summary: ScanSummary
}

public enum DeveloperCleanupActivity {
    // Drain both pipes while the child runs; truncation, stderr and timeout are failures.
    static func command(_ executable: String, _ arguments: [String], timeout: TimeInterval = 2, maxBytes: Int = 1_048_576) -> (Int32, String)? {
        let process = Process(), stdout = Pipe(), stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = stdout; process.standardError = stderr
        do { try process.run() } catch { return nil }
        let descriptors = [stdout.fileHandleForReading.fileDescriptor, stderr.fileHandleForReading.fileDescriptor]
        defer { try? stdout.fileHandleForReading.close(); try? stderr.fileHandleForReading.close() }
        for fd in descriptors { guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { kill(process.processIdentifier, SIGKILL); return nil } }
        var output = [Data(), Data()], buffer = [UInt8](repeating: 0, count: 8192)
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            for (position, fd) in descriptors.enumerated() {
                while true {
                    let count = read(fd, &buffer, buffer.count)
                    if count > 0 {
                        output[position].append(contentsOf: buffer.prefix(count))
                        if output[position].count > maxBytes { kill(process.processIdentifier, SIGKILL); return nil }
                    } else {
                        if count < 0 && errno != EAGAIN && errno != EINTR { kill(process.processIdentifier, SIGKILL); return nil }
                        break
                    }
                }
            }
            if !process.isRunning { break }
            if Date() >= deadline { kill(process.processIdentifier, SIGKILL); return nil }
            usleep(10_000)
        }
        // One final drain after termination, since the last write may follow the prior read.
        for (position, fd) in descriptors.enumerated() {
            while true {
                let count = read(fd, &buffer, buffer.count)
                if count <= 0 { break }
                output[position].append(contentsOf: buffer.prefix(count))
                if output[position].count > maxBytes { return nil }
            }
        }
        guard output[1].isEmpty, let text = String(data: output[0], encoding: .utf8) else { return nil }
        return (process.terminationStatus, text)
    }
    static func openFiles(at root: URL? = nil) -> (Int32, String)? {
        var arguments = ["-nP", "-a", "-u", String(getuid()), "-F", "n"]
        if let root {
            arguments += (try? FileIdentity.read(root).isDirectory) == true ? ["+D", root.path] : ["--", root.path]
        }
        return command("/usr/sbin/lsof", arguments, timeout: 10, maxBytes: 8_388_608)
    }

    static func processReason(_ rule: DeveloperCleanupRule, _ output: String, advisory: Bool = false) -> String? {
        let names: [String]
        switch rule {
        case .claudeCache, .claudeDebug: names = ["claude"]
        case .codexLogs, .codexTmp, .codexTmpRoot: names = ["codex", "codex-exec"]
        case .copilotLogs: names = ["copilot", "github-copilot"]
        case .kimiLogs, .kimiCache: names = ["kimi-code", "kimi"]
        case .codebuddyLogs: names = ["codebuddy", "CodeBuddy"]
        case .aiderCache: names = ["aider"]
        case .workbuddyLogs, .workbuddyCache, .workbuddyTraces: names = ["WorkBuddy", "WorkBuddy AI", "workbuddy", "com.tencent.workbuddy.mac"]
        case .cursorLogs: names = ["Cursor", "cursor"]
        case .traeLogs: names = ["Trae", "trae"]
        case .windsurfLogs: names = ["Windsurf", "windsurf"]
        case .continueLogs: names = ["Continue"]
        case .devinCache: names = ["devin"]
        case .chromaCache: names = ["chroma"]
        case .derivedData: names = ["Xcode", "xcodebuild", "swift", "clang", "ld", "ibtool", "actool", "XCBBuildService", "SourceKitService", "sourcekit-lsp", "swiftc"]
        case .pip: names = ["pip", "pip3", "python", "python3", "uv", "wheel"]
        case .npm, .yarn: names = ["npm", "npx", "node", "nodejs", "yarn", "pnpm", "bun"]
        case .homebrew: names = ["brew", "ruby"]
        case .cocoapods: names = ["pod", "ruby"]
        case .swiftpm: names = ["Xcode", "xcodebuild", "swift", "swiftc", "swift-build", "swift-package", "sourcekit-lsp", "SourceKitService", "XCBBuildService"]
        case .goBuild: names = ["go", "gopls"]
        case .gradle: names = ["gradle", "gradlew", "java", "GradleDaemon", "kotlin-daemon"]
        case .cargo: names = ["cargo", "rustc", "rustup", "rust-analyzer"]
        case .deviceSupport, .simulatorCaches: names = ["Xcode", "xcodebuild", "Simulator", "simctl", "CoreSimulatorService", "launchd_sim", "devicectl"]
        case .chrome: names = ["Google Chrome"]
        case .edge: names = ["Microsoft Edge"]
        case .firefox: names = ["firefox"]
        }
        for line in output.split(separator: "\n") {
            let name = (String(line).trimmingCharacters(in: .whitespaces) as NSString).lastPathComponent
            if names.contains(where: { name.lowercased() == $0.lowercased() || name.lowercased().hasPrefix($0.lowercased() + "-") || name.lowercased().hasPrefix($0.lowercased() + ".") }) {
                return advisory ? localized("检测到可能使用缓存的进程 \(name)，相关工具运行中，不建议清理。") : localized("检测到可能使用缓存的进程 \(name)，请结束相关任务后重新检查。")
            }
        }
        return nil
    }
    public final class Snapshot: @unchecked Sendable {
        private let processes: String?
        private let openFilePaths: [String]?
        private let processProbeFailed: Bool
        private let lsofProbeFailed: Bool

        public init(root: URL? = nil) {
            let psResult = DeveloperCleanupActivity.command("/bin/ps", ["-A", "-o", "comm="])
            if let (status, text) = psResult, status == 0, !text.isEmpty {
                self.processes = text
                self.processProbeFailed = false
            } else {
                self.processes = nil
                self.processProbeFailed = true
            }

            let lsofResult = DeveloperCleanupActivity.openFiles(at: root)
            if let (status, text) = lsofResult, status == 0 || status == 1 {
                self.lsofProbeFailed = false
                var paths: [String] = []
                for line in text.split(separator: "\n") {
                    if line.first == "n" {
                        paths.append(String(line.dropFirst()))
                    }
                }
                self.openFilePaths = paths
            } else {
                self.openFilePaths = nil
                self.lsofProbeFailed = true
            }
        }

        public func blockedReason(_ rule: DeveloperCleanupRule, _ root: URL) -> String? {
            guard !processProbeFailed, let processes else {
                return localized("无法完整核验系统进程状态，已保留。")
            }
            if let reason = DeveloperCleanupActivity.processReason(rule, processes) {
                if rule.category != "AI Agent" {
                    return reason
                }
            }
            guard !lsofProbeFailed, let openFilePaths else {
                return localized("文件占用核验失败、超时或不完整，已保留。")
            }
            let rootPath = root.path
            let prefix = rootPath + "/"
            return openFilePaths.contains(where: { path in
                path == rootPath || path.hasPrefix(prefix)
            }) ? localized("目录内有打开的文件，已保留。") : nil
        }

        public func advisoryReason(_ rule: DeveloperCleanupRule) -> String? {
            guard rule.category == "AI Agent" else { return nil }
            guard !processProbeFailed, let processes else { return nil }
            return DeveloperCleanupActivity.processReason(rule, processes, advisory: true)
        }
    }

    public static func snapshot() -> Snapshot { Snapshot() }

    public static func advisoryReason(_ rule: DeveloperCleanupRule) -> String? {
        Snapshot().advisoryReason(rule)
    }

    public static func blockedReason(_ rule: DeveloperCleanupRule, _ root: URL) -> String? {
        Snapshot(root: root).blockedReason(rule, root)
    }
}

// Access stays on the caller's serial queue; file records and totals remain in SQLite.
public final class DeveloperCleanup {
    private struct Group {
        let id: String
        let rule: DeveloperCleanupRule
        let path: URL
        let rootID: Int64?
        let ancestors: [URL: FileIdentity]
        var issue: String?
        var validated: Bool = false
    }
    private let index: DiskIndex
    private let home: URL
    private var stored: [Group] = []
    private var invalid = false
    private var token: CancellationToken?
    private let protection: ProtectionStore
    public init(index: DiskIndex, home: URL = FileManager.default.homeDirectoryForCurrentUser, protection: ProtectionStore = .shared) {
        self.index = index; self.home = (try? canonicalFileURL(home)) ?? home; self.protection = protection
    }
    private func ancestors(_ path: URL) throws -> [URL: FileIdentity] {
        try validateHomePath(path, home: home)
        var snapshots: [URL: FileIdentity] = [home: try FileIdentity.read(home)], current = home
        for part in path.path.dropFirst(home.path.count + 1).split(separator: "/") {
            current.appendPathComponent(String(part)); snapshots[current] = try FileIdentity.read(current)
        }
        return snapshots
    }
    private func recheck(_ group: Group, force: Bool = false) throws {
        guard !invalid, token?.isCancelled != true, group.issue == nil, let id = group.rootID else { throw MacEvenError(group.issue ?? localized("检查已取消或索引失效，请重新检查。")) }
        if !force && group.validated { return }
        for (path, old) in group.ancestors {
            let fresh = try FileIdentity.read(path)
            guard fresh.isDirectory, !fresh.isSymlink, fresh.device == old.device, fresh.inode == old.inode else { throw MacEvenError(localized("祖先目录已被替换，请重新检查。")) }
        }
        let service = TrashService(index: index, home: home, developerAllowedRoots: [group.path], protection: protection)
        if let reason = service.reasonBlocked(group.path) { throw MacEvenError(reason) }
        try index.validateSubtree(id: id)
        try validateLayout(group.rule, path: group.path, id: id)
    }
    private func hex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private func prefix(_ path: URL, count: Int) throws -> Data {
        // O_NOFOLLOW and identity comparison keep metadata reads from following a replaced leaf.
        let expected = try FileIdentity.read(path)
        guard expected.isRegular else { throw MacEvenError(localized("缓存元数据不是普通文件。")) }
        let fd = path.withUnsafeFileSystemRepresentation { open($0!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) }
        guard fd >= 0 else { throw MacEvenError(localized("无法读取缓存用途证据。")) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, Int64(info.st_dev) == expected.device, Int64(bitPattern: UInt64(info.st_ino)) == expected.inode else { throw MacEvenError(localized("缓存元数据已替换。")) }
        var data = [UInt8](repeating: 0, count: count)
        let size = read(fd, &data, count)
        guard size >= 0, try FileIdentity.read(path) == expected else { throw MacEvenError(localized("读取缓存用途证据失败或内容已变化。")) }
        return Data(data.prefix(size))
    }
    private func json(_ path: URL) throws -> [String: Any] {
        let data = try prefix(path, count: 65_537)
        guard data.count <= 65_536, let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MacEvenError(localized("缓存元数据不完整或不是可识别格式。")) }
        return value
    }
    private func validateLayout(_ rule: DeveloperCleanupRule, path: URL, id: Int64) throws {
        guard let root = try index.entry(id: id), root.identity.isDirectory else { throw MacEvenError(localized("缓存入口不是实际目录。")) }
        let unknown = MacEvenError(localized("用途或缓存格式无法确认，仅供查看；项目、未知内容和源码受保护。"))
        if rule == .derivedData {
            let name = path.lastPathComponent.split(separator: "-").last.map(String.init) ?? ""
            guard name.count == 26, name.allSatisfy({ $0.isASCII && $0.isLowercase }) else { throw unknown }
            let infoURL = path.appendingPathComponent("info.plist")
            let data = try prefix(infoURL, count: 65_537)
            guard data.count <= 65_536,
                  let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let workspace = info["WorkspacePath"] as? String, workspace.hasPrefix("/"),
                  ["xcodeproj", "xcworkspace"].contains(URL(fileURLWithPath: workspace).pathExtension),
                  try FileIdentity.read(path.appendingPathComponent("Build")).isDirectory else { throw unknown }
        }
        if rule.isToolTmpRoot {
            try validateToolTmpCandidate(rule, path: path, id: id, unknown: unknown)
        } else if ![.derivedData, .pip, .npm].contains(rule) { try requireMarker(rule, path: path, root: root, unknown: unknown) }
        var count = 0, recognizedFiles = 0
        func visit(_ entry: DiskEntry, depth: Int) throws {
            count += 1
            guard token?.isCancelled != true else { throw MacEvenError(localized("检查已取消，请重新检查。")) }
            guard depth < 64, count <= 1_000_000 else { throw MacEvenError(localized("用途检查达到安全上限，结果不完整，禁止清理。")) }
            guard !entry.identity.isSymlink || (rule.allowsInternalLinks && entry.id != id), entry.identity.isDirectory || entry.identity.isRegular || entry.identity.isSymlink,
                  entry.identity.device == root.identity.device else { throw MacEvenError(localized("缓存含链接、特殊文件或其他卷，禁止清理。")) }
            let relative = entry.url.path.dropFirst(path.path.count + 1).split(separator: "/").map(String.init)
            if entry.id != id {
                switch rule {
                case .derivedData:
                    guard ["Build", "Logs", "Index.noindex", "info.plist"].contains(relative.first ?? ""),
                          !relative.contains(where: { [".git", ".svn", ".hg", ".env", ".ssh", "Archives", "SourcePackages", "node_modules", "Pods", "venv", "models", "sessions", "memories", "skills"].contains($0) }),
                          !["swift", "m", "mm", "c", "cc", "cpp", "h", "py", "js", "ts", "xcodeproj", "xcworkspace", "xcarchive"].contains(entry.url.pathExtension) else { throw unknown }
                case .pip:
                    guard let first = relative.first else { throw unknown }
                    if ["http", "http-v2"].contains(first) {
                        if entry.isDirectory {
                            guard relative.count <= 6, relative.dropFirst().allSatisfy({ hex($0, count: 1) }) else { throw unknown }
                        } else {
                            guard relative.count == 7 else { throw unknown }
                            let leaf = relative[6], hash = leaf.hasSuffix(".body") ? String(leaf.dropLast(5)) : leaf
                            guard hex(hash, count: 56), Array(hash.prefix(5)).map(String.init) == Array(relative[1...5]) else { throw unknown }
                            let metadata = leaf.hasSuffix(".body") ? entry.url.deletingPathExtension() : entry.url
                            guard try prefix(metadata, count: 5) == Data("cc=4,".utf8) else { throw unknown }
                            if first == "http-v2" { guard try FileIdentity.read(URL(fileURLWithPath: metadata.path + ".body")).isRegular else { throw unknown } }
                        }
                    } else if first == "wheels" {
                        if entry.isDirectory {
                            guard relative.count <= 5, relative.dropFirst().enumerated().allSatisfy({ hex($0.element, count: $0.offset < 3 ? 2 : 50) }) else { throw unknown }
                        } else {
                            guard relative.count == 6 else { throw unknown }
                            let origin = try json(entry.url.deletingLastPathComponent().appendingPathComponent("origin.json"))
                            guard let source = origin["url"] as? String, ["https", "http"].contains(URL(string: source)?.scheme) else { throw unknown }
                            if relative.last != "origin.json" {
                                guard entry.url.pathExtension == "whl", try prefix(entry.url, count: 4) == Data([0x50, 0x4b, 0x03, 0x04]) else { throw unknown }
                            }
                        }
                    } else if first == "selfcheck" {
                        if entry.isDirectory { guard relative.count == 1 else { throw unknown } }
                        else { guard relative.count == 2, hex(relative[1], count: 56), try json(entry.url)["pypi_version"] is String else { throw unknown } }
                    } else { throw unknown }
                case .npm:
                    guard let first = relative.first else { throw unknown }
                    if first == "content-v2" {
                        guard relative.count <= 5 else { throw unknown }
                        if relative.count > 1 { guard ["sha512", "sha256", "sha1"].contains(relative[1]) else { throw unknown } }
                        if relative.count > 2 { guard hex(relative[2], count: 2) else { throw unknown } }
                        if relative.count > 3 { guard hex(relative[3], count: 2) else { throw unknown } }
                        if entry.isDirectory { guard relative.count < 5 else { throw unknown } }
                        else {
                            guard relative.count == 5, hex(relative[4], count: relative[1] == "sha512" ? 124 : relative[1] == "sha256" ? 60 : 36) else { throw unknown }
                        }
                    } else if first == "index-v5" {
                        guard relative.count <= 4 else { throw unknown }
                        if relative.count > 1 { guard hex(relative[1], count: 2) else { throw unknown } }
                        if relative.count > 2 { guard hex(relative[2], count: 2) else { throw unknown } }
                        if entry.isDirectory { guard relative.count < 4 else { throw unknown } }
                        else {
                            guard relative.count == 4, hex(relative[3], count: 60) else { throw unknown }
                            let data = try prefix(entry.url, count: 65_537)
                            guard data.count <= 65_536, let text = String(data: data, encoding: .utf8), !text.isEmpty else { throw unknown }
                            for line in text.split(separator: "\n") {
                                let parts = line.split(separator: "\t", maxSplits: 1)
                                guard parts.count == 2, hex(String(parts[0]), count: 40),
                                      let metadata = try JSONSerialization.jsonObject(with: Data(parts[1].utf8)) as? [String: Any], metadata["key"] is String, metadata["time"] is NSNumber else { throw unknown }
                            }
                        }
                    } else if first == "tmp", relative.count == 1, entry.isDirectory {
                        guard try index.children(of: entry.id, limit: 1).isEmpty else { throw MacEvenError(localized("npm 临时目录非空，可能仍在使用，已保留。")) }
                    } else { throw unknown }
                case .claudeCache, .claudeDebug, .codexLogs:
                    guard relative.count == 1, entry.identity.isRegular else { throw unknown }
                    switch rule {
                    case .claudeCache: guard entry.name == "changelog.md" else { throw unknown }
                    case .claudeDebug:
                        guard entry.url.pathExtension == "txt", UUID(uuidString: entry.url.deletingPathExtension().lastPathComponent) != nil else { throw unknown }
                    case .codexLogs: guard entry.name == "codex-tui.log" else { throw unknown }
                    default: break
                    }
                case .cargo:
                    // 注册表目录下只放下载的 .crate 包。
                    if entry.isDirectory { guard relative.count == 1, Self.cargoRegistry(relative[0]) else { throw unknown } }
                    else { guard relative.count == 2, entry.url.pathExtension == "crate" || relative[1].hasPrefix(".") else { throw unknown } }
                default:
                    // 整目录缓存：标志已核对，内容只需是同卷的普通文件与目录（Homebrew 允许内部链接）。
                    break
                }
                if entry.identity.isRegular { recognizedFiles += 1 }
            }
            if entry.isDirectory {
                var offset = 0
                while true {
                    let page = try index.children(of: entry.id, offset: offset, limit: 500)
                    for child in page { try visit(child, depth: depth + 1) }
                    if page.count < 500 { break }; offset += page.count
                }
            }
        }
        try visit(root, depth: 0)
        guard recognizedFiles > 0 else { throw MacEvenError(localized("没有已确认用途的缓存文件，仅供查看。")) }
    }
    static func cargoRegistry(_ name: String) -> Bool {
        guard let dash = name.lastIndex(of: "-") else { return false }
        let suffix = name[name.index(after: dash)...]
        return suffix.count == 16 && suffix.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } && name[..<dash].contains(".")
    }

    /// 工具 tmp 泄漏候选的三重校验：tmp 根归属（marker）、泄漏命名、内容 mtime 全部超过阈值。
    /// 命名匹配但内容近期仍在变化的一律保留——工具可能正在使用。
    static let toolTmpLeakAge: TimeInterval = 14 * 86_400
    private func validateToolTmpCandidate(_ rule: DeveloperCleanupRule, path: URL, id: Int64, unknown: MacEvenError) throws {
        // 候选必须直接位于登记的 tmp 根之下。
        let tmpRoot = home.appendingPathComponent(rule.relativePath)
        guard path.deletingLastPathComponent().standardizedFileURL.path == tmpRoot.standardizedFileURL.path else { throw unknown }
        // marker：工具根目录必须有自己的 config.toml，防止同名 tmp 目录被误认。
        let toolRoot = tmpRoot.deletingLastPathComponent()
        guard (try? FileIdentity.read(toolRoot.appendingPathComponent("config.toml")))?.isRegular == true else { throw unknown }
        guard DeveloperCleanupRule.isToolTmpLeakName(rule, path.lastPathComponent) else { throw unknown }
        // 活跃度只看文件内容 mtime；无文件的空目录回退到目录自身 mtime。
        let newest = try index.newestModified(inSubtreeOf: id) ?? (try index.entry(id: id))?.identity.modified
        guard let newest else { throw unknown }
        let age = Date().timeIntervalSince1970 - Double(newest) / 1_000_000_000
        guard age >= Self.toolTmpLeakAge else { throw MacEvenError(localized("目录内容在近 \(Int(Self.toolTmpLeakAge / 86_400)) 天内仍有修改，可能仍在使用，已保留。")) }
    }

    /// 每条整目录规则要求根目录直接包含该工具自己的标志，避免同名目录被当作缓存。
    private func requireMarker(_ rule: DeveloperCleanupRule, path: URL, root: DiskEntry, unknown: MacEvenError) throws {
        let children = try index.children(of: root.id, offset: 0, limit: 1000)
        let directories = Set(children.filter(\.isDirectory).map(\.name)), files = Set(children.filter { $0.identity.isRegular }.map(\.name))
        let found: Bool
        switch rule {
        case .claudeCache: found = files.contains("changelog.md")
        case .claudeDebug: found = files.contains { $0.hasSuffix(".txt") && UUID(uuidString: String($0.dropLast(4))) != nil }
        case .codexLogs: found = files.contains("codex-tui.log")
        // process-{timestamp}-{pid}.log 格式：前缀 "process-" 且含数字段
        case .copilotLogs: found = files.contains { $0.hasPrefix("process-") && $0.hasSuffix(".log") }
        case .kimiLogs: found = files.contains("kimi-code.log")
        // client-configs 或 query-store 子目录表明是 Kimi Code 的客户端缓存
        case .kimiCache: found = directories.contains("client-configs") || directories.contains("query-store")
        // memwatch 子目录是 CodeBuddy CLI 的内存监控日志
        case .codebuddyLogs: found = directories.contains("memwatch")
        // model_prices_and_context_window.json 是 aider 独有的模型信息缓存文件
        case .aiderCache: found = files.contains("model_prices_and_context_window.json")
        // WorkBuddy 日志以日期命名子目录（如 2026-xx-xx）或包含 .log 文件
        case .workbuddyLogs: found = directories.contains { $0.hasPrefix("20") } || files.contains { $0.hasSuffix(".log") }
        // WorkBuddy 配置缓存：包含 update-endpoint.json 或 acc-product-config*
        case .workbuddyCache: found = files.contains("update-endpoint.json") || files.contains { $0.hasPrefix("acc-product-config") }
        // WorkBuddy 进程 trace 目录：数字 PID 目录
        case .workbuddyTraces: found = directories.contains { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
        // VS Code / Electron 衍生 AI 编辑器日志：日期目录或 .log 文件
        case .cursorLogs, .traeLogs, .windsurfLogs:
            found = directories.contains { $0.hasPrefix("20") } || files.contains { $0.hasSuffix(".log") }
        // Continue 运行日志：core.log 或 .log
        case .continueLogs: found = files.contains("core.log") || files.contains { $0.hasSuffix(".log") }
        // Devin 运行缓存：telemetry_state.json 或 cli 子目录
        case .devinCache: found = files.contains("telemetry_state.json") || directories.contains("cli")
        // Chroma 向量模型缓存：onnx_models 子目录
        case .chromaCache: found = directories.contains("onnx_models")
        case .homebrew: found = directories.contains("downloads") || directories.contains("api")
        case .cocoapods: found = directories.contains("Pods") || files.contains("search_index.json")
        case .swiftpm: found = !directories.isDisjoint(with: ["repositories", "manifests", "artifacts", "collections", "registry"])
        case .goBuild:
            found = files.contains("README") && (try? prefix(path.appendingPathComponent("README"), count: 128))
                .map { String(decoding: $0, as: UTF8.self).hasPrefix("This directory holds cached build artifacts from the Go build system.") } == true
        case .yarn: found = directories.contains { $0.count > 1 && $0.first == "v" && $0.dropFirst().allSatisfy(\.isNumber) }
        case .gradle: found = directories.contains { $0 == "modules-2" || $0.hasPrefix("jars-") || $0.hasPrefix("transforms-") || $0.hasPrefix("build-cache-") }
        case .cargo: found = directories.contains(where: Self.cargoRegistry)
        case .deviceSupport: found = directories.contains { $0.contains("(") && $0.hasSuffix(")") }
        case .simulatorCaches: found = directories.contains("dyld")
        case .chrome, .edge: found = directories.contains { $0 == "Default" || $0.hasPrefix("Profile ") || $0 == "Guest Profile" || $0 == "System Profile" }
        case .firefox: found = directories.contains("Profiles")
        case .derivedData, .pip, .npm: found = true
        // tmp 泄漏规则不走 requireMarker：归属校验在 validateToolTmpCandidate 里按工具根的 config.toml 判定。
        case .codexTmp, .codexTmpRoot: found = false
        }
        guard found else { throw unknown }
    }

    public func scan(token: CancellationToken, progress: @Sendable (ScanProgress) -> Void = { _ in }) throws -> DeveloperCleanupScanResult {
        try index.reset(); stored = []; invalid = false; self.token = token
        let start = Date(); var visited = 0, errors = 0; var examples: [String] = []; var logical: Int64 = 0, allocated: Int64 = 0
        let rules = DeveloperCleanupRule.allCases, total = rules.count
        func snapshot(_ done: Int, path: String) -> ScanProgress {
            ScanProgress(visited: visited, logicalSize: logical, allocatedSize: allocated, currentPath: path,
                elapsed: Date().timeIntervalSince(start), errors: errors).units(done, of: total)
        }
        for (offset, rule) in rules.enumerated() {
            if token.isCancelled { break }
            let path = home.appendingPathComponent(rule.relativePath)
            progress(snapshot(offset, path: path.path))
            do { _ = try FileIdentity.read(path) }
            catch {
                let value = error as NSError
                if value.domain == NSPOSIXErrorDomain && value.code == Int(ENOENT) { continue }
                errors += 1; examples.append(path.path + "：" + error.localizedDescription)
                stored.append(Group(id: rule.rawValue, rule: rule, path: path, rootID: nil, ancestors: [:], issue: error.localizedDescription)); continue
            }
            do {
                if rule.isToolTmpRoot {
                    // marker：工具根目录必须有自己的 config.toml 才认这个 tmp 区；否则整条规则跳过。
                    let toolRoot = path.deletingLastPathComponent()
                    guard (try? FileIdentity.read(toolRoot.appendingPathComponent("config.toml")))?.isRegular == true else { continue }
                }
                let snapshots = try ancestors(path)
                let oldVisited = visited, oldLogical = logical, oldAllocated = allocated, oldErrors = errors
                let result = try Scanner.scan(root: path, index: index, token: token, resetIndex: false, requireCompleteTraversal: true) { value in
                    progress(ScanProgress(visited: oldVisited + value.visited, logicalSize: oldLogical + value.logicalSize, allocatedSize: oldAllocated + value.allocatedSize, currentPath: value.currentPath, elapsed: Date().timeIntervalSince(start), errors: oldErrors + value.errors).units(offset, of: total))
                }
                visited += result.visited; errors += result.errors; examples.append(contentsOf: result.errorExamples.prefix(max(0, 100 - examples.count)))
                guard let root = try index.entry(id: result.rootID) else { throw MacEvenError(localized("扫描索引不完整。")) }
                logical += root.logicalSize; allocated += root.allocatedSize
                let issue = result.cancelled || result.errors > 0 ? localized("检查不完整或已取消，禁止清理。") : nil
                if rule.isToolTmpRoot {
                    // 只把“泄漏命名 + 内容超过阈值未动”的直接子目录列为候选；活跃子目录与工具自己的稳定工作目录一律不出现。
                    var offset = 0
                    while !token.isCancelled {
                        let page = try index.children(of: root.id, offset: offset, limit: 100)
                        for child in page where child.identity.isDirectory {
                            guard DeveloperCleanupRule.isToolTmpLeakName(rule, child.name) else { continue }
                            // 活跃度只看文件内容 mtime；无文件的空目录回退到目录自身 mtime。
                            let newest = try index.newestModified(inSubtreeOf: child.id) ?? child.identity.modified
                            guard Date().timeIntervalSince1970 - Double(newest) / 1_000_000_000 >= Self.toolTmpLeakAge else { continue }
                            var childSnapshots = snapshots; childSnapshots[child.url] = child.identity
                            stored.append(Group(id: "\(rule.rawValue):\(child.name)", rule: rule, path: child.url, rootID: child.id, ancestors: childSnapshots, issue: issue))
                        }
                        if page.count < 100 { break }; offset += page.count
                        if stored.count >= 4096 { errors += 1; examples.append(localized("开发缓存条目达到上限，结果不完整。")); invalid = true; break }
                    }
                } else if rule == .derivedData {
                    var offset = 0
                    while !token.isCancelled {
                        let page = try index.children(of: root.id, offset: offset, limit: 100)
                        for child in page {
                            var childSnapshots = snapshots; childSnapshots[child.url] = child.identity
                            stored.append(Group(id: "derivedData:\(child.name)", rule: rule, path: child.url, rootID: child.id, ancestors: childSnapshots, issue: issue))
                        }
                        if page.count < 100 { break }; offset += page.count
                        if stored.count >= 4096 { errors += 1; examples.append(localized("开发缓存条目达到上限，结果不完整。")); invalid = true; break }
                    }
                } else { stored.append(Group(id: rule.rawValue, rule: rule, path: path, rootID: root.id, ancestors: snapshots, issue: issue)) }
            } catch {
                errors += 1; if examples.count < 100 { examples.append(path.path + "：" + error.localizedDescription) }
                stored.append(Group(id: rule.rawValue, rule: rule, path: path, rootID: nil, ancestors: [:], issue: error.localizedDescription))
            }
        }
        if !token.isCancelled { progress(snapshot(total, path: home.path)) }
        if token.isCancelled { invalid = true }
        // Discovery does no process probes; refresh and mutation use the production checks by default.
        let groups = try refresh(activity: { _, _ in nil })
        return DeveloperCleanupScanResult(groups: groups, summary: ScanSummary(rootID: 0, visited: visited, cancelled: token.isCancelled, errors: errors, errorExamples: Array(examples.prefix(100)), elapsed: Date().timeIntervalSince(start)))
    }
    public func refresh(
        activity: ((DeveloperCleanupRule, URL) -> String?)? = nil,
        advisory: ((DeveloperCleanupRule) -> String?)? = nil
    ) throws -> [DeveloperCleanupGroup] {
        let snapshot = (activity == nil || advisory == nil) ? DeveloperCleanupActivity.snapshot() : nil
        let checkActivity = activity ?? { snapshot!.blockedReason($0, $1) }
        let checkAdvisory = advisory ?? { snapshot!.advisoryReason($0) }
        var groups: [DeveloperCleanupGroup] = []
        for i in stored.indices {
            let group = stored[i]
            let root = try group.rootID.flatMap { try index.entry(id: $0) }
            if group.rootID != nil, root == nil { continue }
            var reason = group.issue
            if reason == nil {
                do {
                    try recheck(group)
                    stored[i].validated = true
                } catch {
                    reason = error.localizedDescription
                }
            }
            if reason == nil { reason = checkActivity(group.rule, group.path) }
            let adv = (reason == nil && group.rule.category == "AI Agent") ? checkAdvisory(group.rule) : nil
            groups.append(DeveloperCleanupGroup(id: group.id, rule: group.rule, name: group.rule == .derivedData ? group.path.lastPathComponent : group.rule.name, paths: [group.path], allocatedSize: root?.allocatedSize, logicalSize: root?.logicalSize, blockedReason: reason, advisoryReason: adv))
        }
        return groups.sorted { ($0.allocatedSize ?? -1) == ($1.allocatedSize ?? -1) ? $0.id < $1.id : ($0.allocatedSize ?? -1) > ($1.allocatedSize ?? -1) }
    }
    public func rescanBrowserAfterQuit(groupID: String, token: CancellationToken,
        activity: (DeveloperCleanupRule, URL) -> String? = DeveloperCleanupActivity.blockedReason) throws {
        guard !invalid, let position = stored.firstIndex(where: { $0.id == groupID }), stored[position].issue == nil,
            [.chrome, .edge, .firefox].contains(stored[position].rule), let root = stored[position].rootID else { throw MacEvenError(localized("浏览器缓存不可清理，请重新检查。")) }
        let group = stored[position]
        do {
            if let reason = activity(group.rule, group.path) { throw MacEvenError(reason) }
            for (path, old) in group.ancestors {
                let current = try FileIdentity.read(path)
                guard current.device == old.device, current.inode == old.inode, current.mode == old.mode else { throw MacEvenError(localized("缓存祖先目录已替换，内容已保留。")) }
            }
            if let reason = TrashService(index: index, home: home, developerAllowedRoots: [group.path], protection: protection).reasonBlocked(group.path) { throw MacEvenError(reason) }
            let newRoot = try index.rescanAfterApplicationQuit(id: root, token: token)
            stored[position] = Group(id: group.id, rule: group.rule, path: group.path, rootID: newRoot, ancestors: group.ancestors, issue: nil, validated: false)
            try recheck(stored[position], force: true)
            stored[position].validated = true
        } catch { stored[position].issue = error.localizedDescription; throw error }
    }

    /// 「查看构成」：从本次扫描索引读取组的直接子项（按占用排序）；只读，不引入新扫描。
    public func composition(groupID: String, limit: Int = 20) throws -> CleanupComposition? {
        guard !invalid, let group = stored.first(where: { $0.id == groupID }), let rootID = group.rootID,
            let root = try index.entry(id: rootID) else { return nil }
        let total = try index.childCount(of: rootID)
        let entries = try index.children(of: rootID, offset: 0, limit: max(1, min(limit, 100))).map { child in
            CleanupCompositionEntry(url: child.url, allocatedSize: child.allocatedSize, isDirectory: child.isDirectory,
                modifiedAt: Date(timeIntervalSince1970: Double(child.identity.modified) / 1_000_000_000))
        }
        return CleanupComposition(root: root.url, entries: entries, totalChildren: total, measuredLive: false)
    }

    public func move(groupIDs: [String], activity: (DeveloperCleanupRule, URL) -> String? = DeveloperCleanupActivity.blockedReason) -> [TrashResult] {
        let ids = Set(groupIDs)
        guard ids.count <= 50 else { return [TrashResult(id: 0, path: "", destination: nil, error: localized("一次最多选择 50 项。")) ] }
        var results: [TrashResult] = []
        for id in ids.sorted() {
            do {
                guard let group = stored.first(where: { $0.id == id }), let rootID = group.rootID else { throw MacEvenError(localized("条目不可清理，请重新检查。")) }
                try recheck(group, force: true)
                if let reason = activity(group.rule, group.path) { throw MacEvenError(reason) }
                try recheck(group, force: true)
                if let reason = activity(group.rule, group.path) { throw MacEvenError(reason) }
                try recheck(group, force: true)
                // Snapshot checks cannot lock other tools; fail closed and recheck immediately before trash.
                let moved = TrashService(index: index, home: home, developerAllowedRoots: [group.path], protection: protection).move(ids: [rootID])
                results.append(contentsOf: moved)
                if moved.contains(where: { $0.destination != nil && $0.error != nil }) { invalid = true; break }
            } catch { results.append(TrashResult(id: 0, path: id, destination: nil, error: error.localizedDescription)) }
        }
        return results
    }
}
