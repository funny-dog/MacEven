import Foundation
import Darwin

public struct StorageLocation: Sendable, Equatable, Identifiable {
    public var id: String { url.path }
    public let name: String
    public let url: URL
    public let note: String
    public init(name: String, url: URL, note: String) { self.name = name; self.url = url; self.note = note }
}

public struct StorageMeasurement: Sendable, Equatable, Identifiable {
    public var id: String { location.id }
    public let location: StorageLocation
    /// 已统计部分的物理占用估算（分配块 × 512）；硬链接可能重复计入。
    public let allocatedSize: Int64
    public let items: Int
    /// 跳过或统计不完整的原因；有值时该位置未计入或合计偏小。
    public let issue: String?
    /// 按不跟随链接的规则主动跳过，区别于读取失败。
    public let skipped: Bool
    public var incomplete: Bool { issue != nil && !skipped }
    public init(location: StorageLocation, allocatedSize: Int64, items: Int, issue: String?, skipped: Bool = false) {
        self.location = location; self.allocatedSize = allocatedSize; self.items = items; self.issue = issue; self.skipped = skipped
    }
}

public struct AIStorageConfirmation: Identifiable, Sendable, Equatable {
    public var id: String { paths.map(\.path).joined(separator: "|") }
    public let count: Int
    public let allocatedSize: Int64
    public let items: [StorageMeasurement]
    public let paths: [URL]

    public init(items: [StorageMeasurement]) {
        self.items = items
        self.count = items.count
        self.allocatedSize = items.reduce(0) { $0 + $1.allocatedSize }
        self.paths = items.map(\.location.url)
    }
}

// “其他存储”统计：备份、归档、虚拟机、模型与废纸篓。
public enum OtherStorage {
    public static func locations(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [StorageLocation] {
        [
            StorageLocation(name: localized("废纸篓"), url: home.appendingPathComponent(".Trash"), note: localized("移到废纸篓的内容仍占用空间，在 Finder 中清空后才释放；MacEven 不会清空废纸篓。")),
            StorageLocation(name: localized("iPhone / iPad 备份"), url: home.appendingPathComponent("Library/Application Support/MobileSync/Backup"), note: localized("在“访达 › 设备”中管理备份；删除前确认已有其他备份。")),
            StorageLocation(name: localized("Xcode 归档"), url: home.appendingPathComponent("Library/Developer/Xcode/Archives"), note: localized("已发布版本的符号与包，可在 Xcode Organizer 中管理。")),
            StorageLocation(name: localized("模拟器设备"), url: home.appendingPathComponent("Library/Developer/CoreSimulator/Devices"), note: localized("含模拟器中的应用与数据；用 Xcode 或 xcrun simctl 管理。")),
            StorageLocation(name: localized("Docker 数据"), url: home.appendingPathComponent("Library/Containers/com.docker.docker/Data"), note: localized("镜像与容器磁盘；用 Docker Desktop 或 docker system prune 管理。")),
            StorageLocation(name: localized("Parallels 虚拟机"), url: home.appendingPathComponent("Parallels"), note: localized("虚拟机磁盘；在 Parallels 中管理。")),
            StorageLocation(name: localized("Ollama 模型"), url: home.appendingPathComponent(".ollama/models"), note: localized("用 ollama rm 删除不需要的模型。")),
            StorageLocation(name: localized("Hugging Face 缓存"), url: home.appendingPathComponent(".cache/huggingface"), note: localized("下载的模型与数据集；可用 huggingface-cli 管理。"))
        ]
    }

    /// AI 工作资料统计：会话、恢复快照与计划可在资料卡片中独立确认清理；长期记忆、配置、凭据与工作树明确保留。
    public static func aiLocations(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [StorageLocation] {
        let entries = [
            (localized("Codex 会话"), ".codex/sessions", localized("对话与工具调用记录；可在 AI 工作资料卡片中独立确认清理，长期记忆与工作树保留。")),
            (localized("Codex 已归档会话"), ".codex/archived_sessions", localized("已归档历史会话；可在 AI 工作资料卡片中独立确认清理。")),
            (localized("Codex 工作树"), ".codex/worktrees", localized("可能含未提交代码与未合并提交，明确保留并通过 Codex/Git 管理。")),
            (localized("Codex 记忆"), ".codex/memories", localized("跨会话长期记忆，明确保留。")),
            (localized("Codex 记忆资料"), ".codex/memories_v2", localized("跨会话记忆与来源资料，明确保留。")),
            (localized("Codex 生成产物"), ".codex/visualizations", localized("生成的图表、页面与附件可能仍有用途，保留。")),
            (localized("Codex 生成图片"), ".codex/generated_images", localized("生成的图片是工作成果，保留。")),
            (localized("Claude Code 项目与会话"), ".claude/projects", localized("项目目录与长期记忆明确保留；会话记录（.jsonl）可在资料卡片中独立清理。")),
            (localized("Claude Code 文件快照"), ".claude/file-history", localized("用于恢复编辑前的文件快照；可在 AI 工作资料卡片中独立确认清理。")),
            (localized("Claude Code 计划"), ".claude/plans", localized("任务计划与规划记录；可在 AI 工作资料卡片中独立确认清理。")),
            (localized("Cursor 工作资料"), ".cursor", localized("包含扩展、配置与 Agent 数据，保留并在 Cursor 中管理。")),
            (localized("Trae 工作资料"), ".trae", localized("包含扩展、会话与项目工作资料，保留并在 Trae 中管理。")),
            (localized("WorkBuddy 工作资料"), ".workbuddy", localized("包含会话、记忆、项目历史、配置与工作树数据，保留并在 WorkBuddy 中管理。")),
            (localized("Gemini / Antigravity 工作资料"), ".gemini", localized("可能由多个工具共享，包含会话、配置与产物，保留。")),
            (localized("Kimi Code 工作资料"), ".kimi-code", localized("包含会话、记忆、凭据与配置，保留并通过 Kimi Code 管理。")),
            (localized("GitHub Copilot 工作资料"), ".copilot", localized("包含认证信息、技能与配置，保留。")),
            (localized("CodeBuddy 工作资料"), ".codebuddy", localized("包含诊断与配置，保留。")),
            (localized("aider 工作资料"), ".aider", localized("包含会话历史、凭据与配置，保留。")),
            (localized("Continue 工作资料"), ".continue", localized("包含模型配置、Prompt 模板与历史记录，保留。")),
            (localized("Ollama 本地模型与资料"), ".ollama", localized("本地大模型权重文件与数据，占用较大，保留并在 Ollama 中管理。")),
            (localized("Devin 工作资料"), ".local/share/devin", localized("运行环境状态与凭据，保留。")),
            (localized("HuggingFace 模型权重"), ".cache/huggingface", localized("下载的模型权重与分词器缓存，保留。")),
            (localized("OpenCode 工作资料"), ".local/share/opencode", localized("数据库与附件需通过 OpenCode 管理；不直接删除或压缩数据库。"))
        ]
        return entries.map { StorageLocation(name: $0.0, url: home.appendingPathComponent($0.1), note: $0.2) }
    }

    /// 子目录先统计，父目录复用已完成的子树；同一路径只遍历一次。
    public static func measure(_ locations: [StorageLocation], token: CancellationToken,
                               limit: Int = 2_000_000, progress: @Sendable (Int) -> Void = { _ in }) -> [StorageMeasurement] {
        var measured: [String: StorageMeasurement] = [:]
        for (offset, location) in locations.sorted(by: { $0.url.path.count > $1.url.path.count }).enumerated() {
            if token.isCancelled { break }
            if measured[location.id] == nil {
                measured[location.id] = measure(location, token: token, limit: limit, reusing: measured)
            }
            progress(offset + 1)
        }
        return locations.compactMap { location in
            measured[location.id].map { StorageMeasurement(location: location, allocatedSize: $0.allocatedSize, items: $0.items, issue: $0.issue, skipped: $0.skipped) }
        }
    }

    /// 仅刷新发生移动的位置及与之重叠的父子位置，其余结果保持当前扫描快照。
    public static func refresh(_ previous: [StorageMeasurement], locations: [StorageLocation], changedPaths: [String],
                               token: CancellationToken) -> [StorageMeasurement] {
        let affected = locations.filter { location in changedPaths.contains { path in
            path == location.id || path.hasPrefix(location.id + "/") || location.id.hasPrefix(path + "/")
        } }
        let ids = Set(affected.map(\.id))
        return (previous.filter { !ids.contains($0.id) } + measure(affected, token: token)).sorted { $0.allocatedSize > $1.allocatedSize }
    }

    /// 不跟随符号链接、不进入其他卷，最多统计 limit 个条目；位置不存在返回 nil。
    public static func measure(_ location: StorageLocation, token: CancellationToken, limit: Int = 2_000_000) -> StorageMeasurement? {
        measure(location, token: token, limit: limit, reusing: [:])
    }

    private static func measure(_ location: StorageLocation, token: CancellationToken, limit: Int,
                                reusing: [String: StorageMeasurement]) -> StorageMeasurement? {
        var ancestor = location.url.deletingLastPathComponent()
        while ancestor.path != "/" {
            if let info = try? FileIdentity.read(ancestor), info.isSymlink {
                return StorageMeasurement(location: location, allocatedSize: 0, items: 0, issue: localized("位置经过符号链接，未统计。"), skipped: true)
            }
            ancestor.deleteLastPathComponent()
        }
        let root: FileIdentity
        do { root = try FileIdentity.read(location.url) } catch {
            let failure = error as NSError
            if failure.domain == NSPOSIXErrorDomain && failure.code == Int(ENOENT) { return nil }
            return StorageMeasurement(location: location, allocatedSize: 0, items: 0, issue: localized("无法读取：\(error.localizedDescription)"))
        }
        guard root.isDirectory, !root.isSymlink else {
            return StorageMeasurement(location: location, allocatedSize: root.isSymlink ? 0 : root.allocated, items: 1, issue: root.isSymlink ? localized("位置是符号链接，未统计。") : nil, skipped: root.isSymlink)
        }
        var total = root.allocated, items = 0, denied = 0
        var issue: String?
        let enumerator = FileManager.default.enumerator(at: location.url, includingPropertiesForKeys: [], options: [], errorHandler: { _, _ in denied += 1; return true })
        while let url = autoreleasepool(invoking: { enumerator?.nextObject() as? URL }) {
            if token.isCancelled { issue = localized("统计已取消，合计偏小。"); break }
            items += 1
            if items > limit { issue = localized("超过 \(limit) 个条目，只统计了一部分。"); break }
            guard let info = try? FileIdentity.read(url) else { denied += 1; continue }
            if info.device != root.device { enumerator?.skipDescendants(); continue }
            if info.isSymlink { continue }
            if info.isDirectory, let cached = reusing[url.path], !cached.incomplete, !cached.skipped,
               cached.items <= limit - items {
                total += cached.allocatedSize; items += cached.items
                enumerator?.skipDescendants()
            } else { total += info.allocated }
        }
        if enumerator == nil { issue = localized("无法枚举该位置（可能需要完全磁盘访问权限）。") }
        if issue == nil && denied > 0 { issue = localized("\(denied) 处无法读取（可能需要完全磁盘访问权限），合计偏小。") }
        return StorageMeasurement(location: location, allocatedSize: total, items: items, issue: issue)
    }
}
