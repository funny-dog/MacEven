import Foundation
import Darwin

/// AI 工作资料会话/工作记录清理规则
public enum AIWorkCleanupRule: String, CaseIterable, Sendable {
    case codexSessions
    case codexArchivedSessions
    case claudeProjectSessions
    case claudeFileHistory
    case claudePlans
    case antigravitySessions
    case antigravityCliSessions

    public var title: String {
        switch self {
        case .codexSessions: return localized("Codex 会话记录")
        case .codexArchivedSessions: return localized("Codex 已归档会话")
        case .claudeProjectSessions: return localized("Claude Code 项目会话")
        case .claudeFileHistory: return localized("Claude Code 文件修改快照")
        case .claudePlans: return localized("Claude Code 任务计划记录")
        case .antigravitySessions: return localized("Antigravity 会话数据库")
        case .antigravityCliSessions: return localized("Antigravity CLI 会话数据库")
        }
    }

    public var relativePath: String {
        switch self {
        case .codexSessions: return ".codex/sessions"
        case .codexArchivedSessions: return ".codex/archived_sessions"
        case .claudeProjectSessions: return ".claude/projects"
        case .claudeFileHistory: return ".claude/file-history"
        case .claudePlans: return ".claude/plans"
        case .antigravitySessions: return ".gemini/antigravity/conversations"
        case .antigravityCliSessions: return ".gemini/antigravity-cli/conversations"
        }
    }

    public var impact: String {
        switch self {
        case .codexSessions:
            return localized("Codex 对话与工具调用历史将被清除，后续无法查看历史会话；长期记忆、配置与工作树完整保留。")
        case .codexArchivedSessions:
            return localized("Codex 已归档的历史会话将被清除，后续无法查阅归档会话。")
        case .claudeProjectSessions:
            return localized("Claude Code 对话历史（.jsonl）将被清除，无法恢复既有会话上下文；项目长期记忆与配置完整保留。")
        case .claudeFileHistory:
            return localized("Claude Code 文件修改历史与快照将被清除，后续无法通过快照回滚代码编辑。")
        case .claudePlans:
            return localized("Claude Code 任务计划记录将被清除，后续无法回顾历史任务规划。")
        case .antigravitySessions, .antigravityCliSessions:
            return localized("Antigravity 会话数据库将被清除，对应对话历史无法再打开；brain、记忆与配置完整保留。")
        }
    }

    /// 会话文件类规则：候选为会话目录下的单个会话文件（.jsonl 或会话 .db），可按时间与来源逐项确认。
    /// 这些规则绝不允许把父目录本身作为候选。
    public var isSessionFile: Bool {
        switch self {
        case .codexSessions, .codexArchivedSessions, .claudeProjectSessions, .antigravitySessions, .antigravityCliSessions: return true
        case .claudeFileHistory, .claudePlans: return false
        }
    }

    /// 会话文件扩展名：Antigravity 会话是单个 SQLite 数据库（.db），Codex/Claude 是 .jsonl。
    var sessionFileExtension: String {
        switch self {
        case .antigravitySessions, .antigravityCliSessions: return "db"
        default: return "jsonl"
        }
    }

    public var tool: AIWorkTool {
        switch self {
        case .codexSessions, .codexArchivedSessions: return .codex
        case .claudeProjectSessions, .claudeFileHistory, .claudePlans: return .claude
        case .antigravitySessions, .antigravityCliSessions: return .antigravity
        }
    }
}

public enum AIWorkTool: String, Sendable, CaseIterable {
    case codex
    case antigravity
    case claude

    public var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        case .antigravity: return "Antigravity"
        }
    }

    public var processNames: [String] {
        switch self {
        case .codex: return ["codex", "codex-exec"]
        case .claude: return ["claude"]
        case .antigravity: return ["Antigravity", "antigravity"]
        }
    }
}

/// 会话文件记录的工作目录：用于说明记录来源，并识别项目文件夹已不存在的记录。
public struct AIWorkSessionContext: Sendable, Equatable {
    public let projectPath: String
    public let projectName: String
    /// 扫描时项目文件夹已不存在（仅当能确认缺失时为真；无法判断一律为假）。
    public let projectMissing: Bool

    public init(projectPath: String, projectName: String, projectMissing: Bool) {
        self.projectPath = projectPath
        self.projectName = projectName
        self.projectMissing = projectMissing
    }
}

/// 只读探测会话文件里记录的工作目录：有界读取、不跟随链接、身份复核后才解析。
public enum AIWorkSessionProbe {
    /// 每个会话文件最多读取的字节数；超出部分不解析。
    public static let readLimit = 65_536
    /// 每个会话文件最多尝试解析的行数，避免超大文件拖慢扫描。
    static let maxParsedLines = 8

    public static func context(of url: URL, identity: FileIdentity) -> AIWorkSessionContext? {
        guard let path = projectPath(in: url, identity: identity) else { return nil }
        let name = path == "/" ? "/" : (path as NSString).lastPathComponent
        return AIWorkSessionContext(projectPath: path, projectName: name, projectMissing: missing(path))
    }

    /// 项目文件夹当前是否已不存在：只有明确的 ENOENT 才算缺失，其他错误保守视为存在。
    public static func missing(_ path: String) -> Bool {
        var info = stat()
        let result = URL(fileURLWithPath: path).withUnsafeFileSystemRepresentation { lstat($0, &info) }
        if result == 0 { return false }
        return errno == ENOENT
    }

    /// 读取文件头部并找出首个记录的工作目录；失败一律返回 nil（保持保守，不影响清理白名单）。
    static func projectPath(in url: URL, identity: FileIdentity) -> String? {
        guard identity.isRegular else { return nil }
        let fd = url.withUnsafeFileSystemRepresentation { open($0!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) }
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, Int64(info.st_dev) == identity.device,
              Int64(bitPattern: UInt64(info.st_ino)) == identity.inode, info.st_mode & S_IFMT == S_IFREG else { return nil }
        var bytes = [UInt8](repeating: 0, count: readLimit)
        var filled = 0
        while filled < bytes.count {
            let count = bytes.withUnsafeMutableBytes { buffer in
                read(fd, buffer.baseAddress!.advanced(by: filled), buffer.count - filled)
            }
            if count > 0 { filled += count; continue }
            if count < 0 && errno == EINTR { continue }
            break
        }
        guard filled > 0 else { return nil }
        let text = String(decoding: bytes[0..<filled], as: UTF8.self)
        var parsed = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.contains("\"cwd\"") else { continue }
            guard parsed < maxParsedLines else { break }
            parsed += 1
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let value = object["cwd"] as? String ?? (object["payload"] as? [String: Any])?["cwd"] as? String
            guard let value, value.hasPrefix("/"), value.count <= 4096 else { continue }
            return value
        }
        return nil
    }
}

public struct AIWorkCleanupTarget: Identifiable, Sendable, Equatable {
    public var id: String { url.path }
    public let rule: AIWorkCleanupRule
    public let url: URL
    public let allocatedSize: Int64
    public let identity: FileIdentity
    public let ancestors: [URL: FileIdentity]
    public let impact: String
    /// 候选自身最后修改时间（会话文件的“多久未使用”按此判断）。
    public let modifiedAt: Date?
    /// 会话文件记录的工作目录；无法确认时为 nil。
    public let projectPath: String?
    public let projectName: String?
    /// 扫描时项目文件夹已不存在；无法确认时为 false。
    public let projectMissing: Bool
    /// 目录型候选内部最新的内容修改时间（活跃度看内容而不是目录自身 mtime）；单文件候选与未知时为 nil。
    public let newestContentModified: Date?

    public init(rule: AIWorkCleanupRule, url: URL, allocatedSize: Int64, identity: FileIdentity, ancestors: [URL: FileIdentity], impact: String,
                modifiedAt: Date? = nil, projectPath: String? = nil, projectName: String? = nil, projectMissing: Bool = false,
                newestContentModified: Date? = nil) {
        self.rule = rule
        self.url = url
        self.allocatedSize = allocatedSize
        self.identity = identity
        self.ancestors = ancestors
        self.impact = impact
        self.modifiedAt = modifiedAt
        self.projectPath = projectPath
        self.projectName = projectName
        self.projectMissing = projectMissing
        self.newestContentModified = newestContentModified
    }
}

public struct AIWorkCleanupGroup: Identifiable, Sendable, Equatable {
    public var id: String { rule.rawValue }
    public let rule: AIWorkCleanupRule
    public let title: String
    public let targets: [AIWorkCleanupTarget]
    public var allocatedSize: Int64 { targets.reduce(0) { $0 + $1.allocatedSize } }
    public var count: Int { targets.count }
    public var paths: [URL] { targets.map(\.url) }
    public var impact: String { rule.impact }
    /// 会话文件规则移走文件后可能留下空的日期目录；界面上如实说明。
    public var leavesEmptyDirectories: Bool { rule.isSessionFile }

    public init(rule: AIWorkCleanupRule, targets: [AIWorkCleanupTarget]) {
        self.rule = rule
        self.title = rule.title
        self.targets = targets
    }

    /// 把任意候选集合按规则聚合成组，顺序与规则枚举一致；供“逐项确认”的选中集合复用。
    public static func grouped(_ targets: [AIWorkCleanupTarget]) -> [AIWorkCleanupGroup] {
        AIWorkCleanupRule.allCases.compactMap { rule in
            let values = targets.filter { $0.rule == rule }
            return values.isEmpty ? nil : AIWorkCleanupGroup(rule: rule, targets: values)
        }
    }
}

public typealias AIWorkActivityChecker = @Sendable (AIWorkTool, URL) -> String?

public enum AIWorkActivity {
    public static func processReason(_ tool: AIWorkTool, processes: String) -> String? {
        for line in processes.split(separator: "\n") {
            let name = (String(line).trimmingCharacters(in: .whitespaces) as NSString).lastPathComponent
            if tool.processNames.contains(where: { name.lowercased() == $0.lowercased() || name.lowercased().hasPrefix($0.lowercased() + "-") || name.lowercased().hasPrefix($0.lowercased() + ".") }) {
                return localized("检测到可能使用该工作资料的进程 \(name)，请退出相关工具后重试。")
            }
        }
        return nil
    }

    /// 咨询提示：检测到工具运行时的建议说明，不作为强行阻断删除的硬性原因。
    public static func advisoryReason(_ tool: AIWorkTool, processes: String) -> String? {
        for line in processes.split(separator: "\n") {
            let name = (String(line).trimmingCharacters(in: .whitespaces) as NSString).lastPathComponent
            if tool.processNames.contains(where: { name.lowercased() == $0.lowercased() || name.lowercased().hasPrefix($0.lowercased() + "-") || name.lowercased().hasPrefix($0.lowercased() + ".") }) {
                return localized("相关工具 \(name) 正在运行（不建议删除活跃会话）")
            }
        }
        return nil
    }

    public static func blockedReason(_ tool: AIWorkTool, _ url: URL) -> String? {
        // 会话与工作记录为历史文件，不因后台进程存活而阻断清理；仅在文件正被打开占用时保留。
        guard let (status, files) = DeveloperCleanupActivity.openFiles(at: url), status == 0 || status == 1 else {
            return localized("文件占用核验失败、超时或不完整，已保留。")
        }
        let rootPath = url.path
        return files.split(separator: "\n").contains(where: { line in
            guard line.first == "n" else { return false }
            let path = line.dropFirst()
            return path == rootPath || path.hasPrefix(rootPath + "/")
        }) ? localized("文件或目录正在被打开使用，已保留。") : nil
    }
}

public final class AIWorkCleanup: @unchecked Sendable {
    private let home: URL
    private let protection: ProtectionStore
    private let log: OperationLog
    private let indexURL = FileManager.default.temporaryDirectory.appendingPathComponent("MacEven-aiwork-\(UUID()).sqlite")
    private var index: DiskIndex?
    private var roots: [String: Int64] = [:]
    public private(set) var warnings: [String] = []

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, protection: ProtectionStore = .shared, log: OperationLog? = nil) {
        self.home = (try? canonicalFileURL(home)) ?? home.standardizedFileURL
        self.protection = protection
        self.log = log ?? OperationLog(directory: self.home.appendingPathComponent("Library/Logs/MacEven"))
    }

    deinit {
        index?.close()
        for suffix in ["", "-journal", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: indexURL.path + suffix) }
    }

    /// 祖先目录快照与路径安全校验
    public func ancestors(of url: URL) throws -> [URL: FileIdentity] {
        try validateHomePath(url, home: home)
        var snapshots: [URL: FileIdentity] = [home: try FileIdentity.read(home)]
        var current = home
        let parts = url.path.dropFirst(home.path.count + 1).split(separator: "/")
        for part in parts.dropLast() {
            current.appendPathComponent(String(part))
            snapshots[current] = try FileIdentity.read(current)
        }
        return snapshots
    }

    /// 核心白名单安全校验：防混淆、保留长期记忆、配置、凭据与源码/工作树
    public func validateSafety(_ url: URL, rule: AIWorkCleanupRule) throws {
        let path = url.path
        guard path.hasPrefix(home.path + "/"), !url.pathComponents.contains(".."), !url.pathComponents.contains(".") else {
            throw MacEvenError(localized("路径不在允许的主目录范围内。"))
        }

        // 绝不能整体删除工具根目录与混合父目录
        let forbiddenRoots = [
            home.path,
            home.appendingPathComponent(".codex").path,
            home.appendingPathComponent(".claude").path,
            home.appendingPathComponent(".claude/projects").path,
            home.appendingPathComponent(".cursor").path,
            home.appendingPathComponent(".trae").path,
            home.appendingPathComponent(".workbuddy").path,
            home.appendingPathComponent(".gemini").path,
            home.appendingPathComponent(".gemini/antigravity").path,
            home.appendingPathComponent(".gemini/antigravity-cli").path,
            home.appendingPathComponent(".kimi-code").path,
            home.appendingPathComponent(".copilot").path,
            home.appendingPathComponent(".codebuddy").path,
            home.appendingPathComponent(".aider").path,
            home.appendingPathComponent(".continue").path,
            home.appendingPathComponent(".ollama").path
        ]
        if forbiddenRoots.contains(path) {
            throw MacEvenError(localized("混合根目录受系统保护，不可整体删除：\(path)"))
        }

        // 严格保留长期记忆
        if path.lowercased().contains("/memories/") || path.lowercased().hasSuffix("/memories") ||
            path.lowercased().contains("/memories_v2/") || path.lowercased().hasSuffix("/memories_v2") ||
            path.lowercased().contains("/memory/") || path.lowercased().hasSuffix("/memory") ||
            url.lastPathComponent.lowercased().hasPrefix("memory") {
            throw MacEvenError(localized("长期记忆受保护，不可清理：\(path)"))
        }

        // 严格保留 brain 知识库（Antigravity 等工具的长期知识索引）
        if path.lowercased().contains("/brain/") || path.lowercased().hasSuffix("/brain") {
            throw MacEvenError(localized("brain 知识库受保护，不可清理：\(path)"))
        }

        // 严格保留项目源码与工作树；会话目录也不能作为整体候选
        if path.lowercased().contains("/worktrees/") || path.lowercased().hasSuffix("/worktrees") {
            throw MacEvenError(localized("项目源码与工作树受保护，不可清理：\(path)"))
        }

        // 严格保留配置与凭据
        let last = url.lastPathComponent.lowercased()
        if last.hasPrefix("config") || last.hasPrefix("settings") || last.hasPrefix("credentials") || last == ".claude.json" {
            throw MacEvenError(localized("工具配置与凭据受保护，不可清理：\(path)"))
        }

        // 规则限定校验
        let relative = path.dropFirst(home.path.count + 1)
        let parts = relative.split(separator: "/")

        switch rule {
        case .codexSessions:
            try requireSessionFile(url, rule: rule, parts: parts, prefix: [".codex", "sessions"])
        case .codexArchivedSessions:
            try requireSessionFile(url, rule: rule, parts: parts, prefix: [".codex", "archived_sessions"])
        case .claudeProjectSessions:
            // 绝不能删除项目根目录本身；必须是 .claude/projects 下的会话文件
            try requireSessionFile(url, rule: rule, parts: parts, prefix: [".claude", "projects"])
        case .claudeFileHistory:
            guard parts.count >= 2, parts[0] == ".claude", parts[1] == "file-history" else {
                throw MacEvenError(localized("路径不在 Claude 文件快照白名单内：\(path)"))
            }
        case .claudePlans:
            guard parts.count >= 2, parts[0] == ".claude", parts[1] == "plans" else {
                throw MacEvenError(localized("路径不在 Claude 计划白名单内：\(path)"))
            }
        case .antigravitySessions:
            try requireSessionFile(url, rule: rule, parts: parts, prefix: [".gemini", "antigravity", "conversations"])
        case .antigravityCliSessions:
            try requireSessionFile(url, rule: rule, parts: parts, prefix: [".gemini", "antigravity-cli", "conversations"])
        }

        if let reason = protection.reason(for: url) {
            throw MacEvenError(reason)
        }
    }

    /// 会话规则只接受单个会话文件（.jsonl 或会话 .db）：目录、快捷方式与其他格式一律拒绝。
    private func requireSessionFile(_ url: URL, rule: AIWorkCleanupRule, parts: [Substring], prefix: [Substring]) throws {
        guard parts.count >= prefix.count + 1, Array(parts.prefix(prefix.count)) == prefix,
              url.pathExtension.lowercased() == rule.sessionFileExtension else {
            throw MacEvenError(localized("会话目录仅允许清理单个会话文件，目录与其他格式已保留：\(url.path)"))
        }
    }

    /// 会话规则枚举目录下的 .jsonl 文件；工作记录规则使用整目录。
    private func candidates(rule: AIWorkCleanupRule, token: CancellationToken) throws -> [URL] {
        let base = home.appendingPathComponent(rule.relativePath)
        try validateHomePath(base, home: home)
        guard rule.isSessionFile else { return [base] }
        var issue: String?
        guard let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [], options: [], errorHandler: { _, error in
            issue = error.localizedDescription; return !token.isCancelled
        }) else { throw MacEvenError(localized("无法枚举 \(rule.title) 目录。")) }
        var found: [URL] = []
        var visited = 0
        while !token.isCancelled, let url = autoreleasepool(invoking: { enumerator.nextObject() as? URL }) {
            visited += 1
            guard visited <= 1_000_000, found.count < 8192 else { issue = localized("\(rule.title)候选达到上限，部分记录保留。"); break }
            if url.pathExtension.lowercased() == rule.sessionFileExtension, (try? validateSafety(url, rule: rule)) != nil,
               (try? FileIdentity.read(url).isRegular) == true { found.append(url) }
        }
        if let issue { warnings.append(issue) }
        return found
    }

    /// 仅在调用者的串行后台任务上访问索引。
    public func scan(token: CancellationToken = CancellationToken()) throws -> [AIWorkCleanupGroup] {
        if index == nil { index = try DiskIndex(url: indexURL) }
        guard let index else { throw MacEvenError(localized("工作记录索引不可用。")) }
        try index.reset(); roots = [:]; warnings = []
        var groups: [AIWorkCleanupGroup] = []
        for rule in AIWorkCleanupRule.allCases {
            guard !token.isCancelled else { break }
            do {
                let candidates = try candidates(rule: rule, token: token)
                var targets: [AIWorkCleanupTarget] = []
                var pending = 0
                if rule.isSessionFile { try index.begin() }
                for url in candidates {
                    guard !token.isCancelled else { break }
                    do {
                        try validateSafety(url, rule: rule)
                        let parents = try ancestors(of: url), identity = try FileIdentity.read(url)
                        guard (identity.isDirectory || identity.isRegular), !rule.isSessionFile || identity.isRegular else { throw MacEvenError(localized("候选既不是目录也不是普通文件，已保留：\(url.path)")) }
                        let root: Int64
                        if identity.isDirectory {
                            let summary = try Scanner.scan(root: url, index: index, token: token, resetIndex: false, requireCompleteTraversal: true) { progress in
                                if progress.visited > 1_000_000 { token.cancel() }
                            }
                            guard !summary.cancelled, summary.errors == 0 else {
                                try index.removeSubtree(id: summary.rootID)
                                throw MacEvenError(localized("工作记录统计不完整，已保留：\(url.path)"))
                            }
                            root = summary.rootID
                        } else {
                            root = try index.insert(parent: 0, url: url, identity: identity).id
                            if rule.isSessionFile {
                                pending += 1
                                if pending == 500 { try index.commit(); try index.begin(); pending = 0 }
                            }
                        }
                        roots[url.path] = root
                        // 会话文件按修改时间与记录的工作目录补充说明；读取失败或无法确认时保持保守。
                        let context = rule.isSessionFile ? AIWorkSessionProbe.context(of: url, identity: identity) : nil
                        // 目录型候选的活跃度看内部文件的最新内容 mtime，而不是目录自身 mtime；空目录回退到目录自身。
                        var newestContent: Date?
                        if identity.isDirectory {
                            let newest = (try? index.newestModified(inSubtreeOf: root)) ?? identity.modified
                            newestContent = Date(timeIntervalSince1970: Double(newest) / 1_000_000_000)
                        }
                        targets.append(AIWorkCleanupTarget(rule: rule, url: url, allocatedSize: try index.entry(id: root)?.allocatedSize ?? 0,
                            identity: identity, ancestors: parents, impact: rule.impact,
                            modifiedAt: Date(timeIntervalSince1970: Double(identity.modified) / 1_000_000_000),
                            projectPath: context?.projectPath, projectName: context?.projectName, projectMissing: context?.projectMissing == true,
                            newestContentModified: newestContent))
                    } catch { warnings.append(error.localizedDescription) }
                }
                if rule.isSessionFile { try index.commit() }
                if !targets.isEmpty { groups.append(AIWorkCleanupGroup(rule: rule, targets: targets)) }
            } catch {
                index.rollback()
                let error = error as NSError
                if error.domain != NSPOSIXErrorDomain || error.code != Int(ENOENT) { warnings.append(error.localizedDescription) }
            }
        }
        if token.isCancelled { roots = [:]; groups = []; warnings.append(localized("会话扫描已取消或达到上限，请重新扫描。")) }
        return groups
    }

    /// 将选中的目标移动到废纸篓
    public func move(
        targets: [AIWorkCleanupTarget],
        token: CancellationToken = CancellationToken(),
        activity: AIWorkActivityChecker? = nil,
        recordOperation: (@Sendable ([TrashResult]) -> Void)? = nil
    ) -> [TrashResult] {
        let checker = activity ?? AIWorkActivity.blockedReason
        var results: [TrashResult] = []

        for target in targets {
            var destination: NSURL?
            do {
                guard !token.isCancelled else { throw MacEvenError(localized("操作已取消，余下记录保留。")) }
                try validateSafety(target.url, rule: target.rule)
                try validateHomePath(target.url, home: home)

                // 2. 祖先目录验证：每一级祖先不能是 symlink，不能被替换
                for (ancestorURL, oldIdentity) in target.ancestors {
                    let current = try FileIdentity.read(ancestorURL)
                    guard current.isDirectory, !current.isSymlink, current.device == oldIdentity.device, current.inode == oldIdentity.inode else {
                        throw MacEvenError(localized("祖先目录已被替换或变为符号链接，已保留：\(ancestorURL.path)"))
                    }
                }

                // 3. 自身身份复核：文件变化拒绝移动、拒绝符号链接
                let fresh = try FileIdentity.read(target.url)
                guard !fresh.isSymlink else {
                    throw MacEvenError(localized("目标是符号链接，已拒绝移动以保护外部数据：\(target.url.path)"))
                }
                guard fresh == target.identity else {
                    throw MacEvenError(localized("文件自扫描后已被修改或替换，已保留：\(target.url.path)"))
                }

                guard let index, let root = roots[target.id] else { throw MacEvenError(localized("工作记录确认已失效，请重新扫描。")) }
                try index.validateSubtree(id: root)

                // 工具退出后，再次核对文件身份，避免核验期间发生变化。
                if let reason = checker(target.rule.tool, target.url) {
                    throw MacEvenError(reason)
                }

                guard !token.isCancelled else { throw MacEvenError(localized("操作已取消，记录保留。")) }
                try validateSafety(target.url, rule: target.rule)
                try validateHomePath(target.url, home: home)
                for (url, old) in target.ancestors {
                    let current = try FileIdentity.read(url)
                    guard current.isDirectory, !current.isSymlink, current.device == old.device, current.inode == old.inode else { throw MacEvenError(localized("祖先目录已变化，记录保留。")) }
                }
                try index.validateSubtree(id: root)
                try FileManager.default.trashItem(at: target.url, resultingItemURL: &destination)
                roots[target.id] = nil
                do { try index.removeSubtree(id: root) }
                catch { roots = [:]; throw error }
                results.append(TrashResult(
                    id: 0,
                    path: target.url.path,
                    destination: destination as URL?,
                    error: nil,
                    allocatedSize: target.allocatedSize
                ))
            } catch {
                results.append(TrashResult(
                    id: 0,
                    path: target.url.path,
                    destination: destination as URL?,
                    error: error.localizedDescription,
                    allocatedSize: target.allocatedSize
                ))
            }
        }

        // 写入操作日志
        if !results.isEmpty {
            if let recordOperation {
                recordOperation(results)
            } else {
                try? log.append(OperationRecord.batch(results, source: "aiwork"))
            }
        }

        return results
    }

    /// 复用仍有效的扫描快照，读取局部索引维护后的大小，不再遍历所有会话目录。
    public func remainingGroups(_ groups: [AIWorkCleanupGroup]) throws -> [AIWorkCleanupGroup] {
        guard let index else { return [] }
        return try groups.compactMap { group in
            let retained = try group.targets.compactMap { target -> AIWorkCleanupTarget? in
                guard let root = roots[target.id], let entry = try index.entry(id: root) else { return nil }
                return AIWorkCleanupTarget(rule: target.rule, url: target.url, allocatedSize: entry.allocatedSize,
                    identity: target.identity, ancestors: target.ancestors, impact: target.impact, modifiedAt: target.modifiedAt,
                    projectPath: target.projectPath, projectName: target.projectName, projectMissing: target.projectMissing,
                    newestContentModified: target.newestContentModified)
            }
            return retained.isEmpty ? nil : AIWorkCleanupGroup(rule: group.rule, targets: retained)
        }
    }

    /// 「查看构成」：从本次扫描索引读取目录型候选的直接子项（按占用排序）；只读，不引入新扫描。
    public func composition(of target: AIWorkCleanupTarget, limit: Int = 20) throws -> CleanupComposition? {
        guard target.identity.isDirectory, let index, let root = roots[target.id] else { return nil }
        let total = try index.childCount(of: root)
        let entries = try index.children(of: root, offset: 0, limit: max(1, min(limit, 100))).map { child in
            CleanupCompositionEntry(url: child.url, allocatedSize: child.allocatedSize, isDirectory: child.isDirectory,
                modifiedAt: Date(timeIntervalSince1970: Double(child.identity.modified) / 1_000_000_000))
        }
        return CleanupComposition(root: target.url, entries: entries, totalChildren: total, measuredLive: false)
    }

    public func move(
        groups: [AIWorkCleanupGroup],
        token: CancellationToken = CancellationToken(),
        activity: AIWorkActivityChecker? = nil,
        recordOperation: (@Sendable ([TrashResult]) -> Void)? = nil
    ) -> [TrashResult] {
        let allTargets = groups.flatMap(\.targets)
        return move(targets: allTargets, token: token, activity: activity, recordOperation: recordOperation)
    }
}
