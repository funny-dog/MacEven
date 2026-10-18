import Foundation
import Darwin

/// 用途标签的安全等级。数值越小越保守；同一节点命中多条规则时取最小值。
public enum PurposeSafety: Int, Sendable, Comparable {
    case keep = 0, caution, regenerable
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    public var title: String {
        switch self {
        case .keep: return localized("勿动")
        case .caution: return localized("谨慎")
        case .regenerable: return localized("可重建")
        }
    }
    public var explanation: String {
        switch self {
        case .keep: return localized("系统或重要数据，不建议手动删除")
        case .caution: return localized("包含你的数据或设置，删除前请确认")
        case .regenerable: return localized("删除后会自动或可手动重新生成")
        }
    }
}

public enum PurposeCategory: String, Sendable {
    case system, application, appData, cache, log, developer, buildArtifact, userFiles, cloud, backup, installer
    public var title: String {
        switch self {
        case .system: return localized("系统")
        case .application: return localized("应用")
        case .appData: return localized("应用数据")
        case .cache: return localized("缓存")
        case .log: return localized("日志")
        case .developer: return localized("开发工具")
        case .buildArtifact: return localized("项目依赖与构建产物")
        case .userFiles: return localized("你的文件")
        case .cloud: return localized("云盘")
        case .backup: return localized("备份")
        case .installer: return localized("安装包")
        }
    }
}

/// 只用于解释，不参与任何删除授权。
public struct PurposeLabel: Sendable, Equatable {
    public let ruleID: String
    public let category: PurposeCategory
    public let safety: PurposeSafety
    public let title: String
    public let detail: String
    public let evidence: String
    /// true 表示继承自祖先目录。
    public let inherited: Bool
}

public struct PurposeRule: Sendable {
    public enum Match: Sendable {
        /// 以 "~/" 或 "/" 开头；组件可以是字面量、"*"、"{app}"（应用标识）或 "{appName}"（应用名称）。
        case path(String)
        /// 任意位置的名称；"*" 表示任意名称，必须带条件。
        case name(String)
        case pathExtension(String)
    }
    public enum Condition: Sendable { case siblingAny([String]), childAny([String]) }
    public enum Kind: Sendable { case directory, file, any }
    public let id: String
    public let match: Match
    public let kind: Kind
    public let condition: Condition?
    public let category: PurposeCategory
    public let safety: PurposeSafety
    /// 可含 {app}（解析后的应用名称）、{name}（当前名称）、{parent}（父目录名）。
    public let title: String
    public let detail: String
    /// 子树不再匹配，整体继承本标签。
    public let opaque: Bool
    /// false 表示只标注节点本身，后代不继承（例如 /Users，否则主目录里处处是“属于：用户主目录”）。
    public let heritable: Bool

    public init(id: String, match: Match, kind: Kind = .directory, condition: Condition? = nil, category: PurposeCategory,
        safety: PurposeSafety, title: String, detail: String, opaque: Bool = false, heritable: Bool = true) {
        self.id = id; self.match = match; self.kind = kind; self.condition = condition; self.category = category
        self.safety = safety; self.title = title; self.detail = detail; self.opaque = opaque; self.heritable = heritable
    }
}

/// 扫描时写入索引的用途标记：规则序号、安全等级与是否向下继承打包成一个整数，0 表示没有标记。
public struct PurposeTag: Sendable, Hashable {
    public let ruleIndex: Int
    public let safety: PurposeSafety
    public let heritable: Bool
    public init(ruleIndex: Int, safety: PurposeSafety, heritable: Bool) {
        self.ruleIndex = ruleIndex; self.safety = safety; self.heritable = heritable
    }
    public init?(rawValue: Int64) {
        guard rawValue > 0, let safety = PurposeSafety(rawValue: Int(rawValue & 3)) else { return nil }
        self.init(ruleIndex: Int(rawValue >> 3) - 1, safety: safety, heritable: rawValue & 4 != 0)
    }
    public var rawValue: Int64 { Int64(ruleIndex + 1) << 3 | (heritable ? 4 : 0) | Int64(safety.rawValue) }
    /// 索引只需要可继承位，不依赖规则表。
    static func isHeritable(_ rawValue: Int64) -> Bool { rawValue & 4 != 0 }
}

/// 规则表编译后只读；每次调用的缓存都是局部变量，可在任意队列使用。
public struct PurposeClassifier: Sendable {
    private enum Segment: Sendable { case literal(String), any, app, appName }
    private struct Compiled: Sendable {
        let index: Int
        let segments: [Segment]
        let score: Int
    }
    fileprivate struct Hit: Sendable {
        let ruleIndex: Int
        let app: String?
        let appEvidence: String?
    }
    /// 只保存判定结果；标题、说明与依据最后才用路径组件生成，扫描时不拼字符串。
    fileprivate struct State: Sendable {
        var hit: Hit?
        var safety = PurposeSafety.keep
        /// 命中所在深度（路径组件数）；继承时指向来源目录。
        var depth = 0
        var inherited = false
        var opaque = false
        var keepCap = false
        var heritable = true
    }
    private final class Memo {
        var states: [String: State] = [:]
        var exists: [String: Bool] = [:]
        var apps: [String: (String, String)] = [:]
    }

    /// 扫描用的增量状态。目录保存自己的完整路径组件；文件共用父目录的组件，只另记自己的名称。
    public struct Trail: Sendable {
        fileprivate let state: State
        fileprivate let display: [String]
        fileprivate let normalized: [String]
        fileprivate let leaf: String?
        public var isDirectory: Bool { leaf == nil }
        /// 生效的标记（自己的或继承的）。
        public var tag: PurposeTag? {
            state.hit.map { PurposeTag(ruleIndex: $0.ruleIndex, safety: state.safety, heritable: state.heritable) }
        }
        /// 自己命中的标记，即用途边界；继承来的为 nil。
        public var ownTag: PurposeTag? { state.inherited ? nil : tag }
    }

    public let rules: [PurposeRule]
    private let anchored: [Int: [Compiled]]
    private let byName: [String: [Compiled]]
    private let wildcard: [Compiled]
    private let byExtension: [String: [Compiled]]
    private let applications: [String: String]
    private let applicationNames: [String: String]

    public init(rules: [PurposeRule] = PurposeRule.builtIn, home: URL = FileManager.default.homeDirectoryForCurrentUser, applications: [CacheApplication] = []) {
        self.rules = rules
        let homePath = ((try? canonicalFileURL(home)) ?? home).path
        let homeComponents = Self.components(homePath).map(Self.normalize)
        var anchored: [Int: [Compiled]] = [:], byName: [String: [Compiled]] = [:], wildcard: [Compiled] = [], byExtension: [String: [Compiled]] = [:]
        for (index, rule) in rules.enumerated() where Self.problem(rule) == nil {
            switch rule.match {
            case .path(let pattern):
                let relative = pattern.hasPrefix("~/") ? String(pattern.dropFirst(2)) : pattern
                var segments: [Segment] = pattern.hasPrefix("~/") ? homeComponents.map { .literal($0) } : []
                for part in Self.components(relative) {
                    switch part {
                    case "*": segments.append(.any)
                    case "{app}": segments.append(.app)
                    case "{appName}": segments.append(.appName)
                    default: segments.append(.literal(Self.normalize(part)))
                    }
                }
                let literals = segments.filter { if case .literal = $0 { return true }; return false }.count
                let score = 1000 + 10 * literals + 5 * (segments.count - literals)
                anchored[segments.count, default: []].append(Compiled(index: index, segments: segments, score: score))
            case .name(let name):
                if name == "*" { wildcard.append(Compiled(index: index, segments: [], score: 100)) }
                else { byName[Self.normalize(name), default: []].append(Compiled(index: index, segments: [], score: rule.condition == nil ? 200 : 300)) }
            case .pathExtension(let ext):
                byExtension[Self.normalize(ext), default: []].append(Compiled(index: index, segments: [], score: 150))
            }
        }
        self.anchored = anchored; self.byName = byName; self.wildcard = wildcard; self.byExtension = byExtension
        var ids: [String: String] = [:], names: [String: String] = [:]
        for app in applications { ids[Self.normalize(app.id)] = app.name; names[Self.normalize(app.name)] = names[Self.normalize(app.name)] ?? app.name }
        self.applications = ids; self.applicationNames = names
    }

    /// 规则自检：返回问题描述，nil 表示规则可用。不可用的规则在初始化时被跳过。
    public static func problem(_ rule: PurposeRule) -> String? {
        switch rule.match {
        case .path(let pattern):
            guard pattern.hasPrefix("/") || pattern.hasPrefix("~/") else { return localized("\(rule.id)：锚定路径必须以 / 或 ~/ 开头") }
            if components(pattern).contains(where: { $0.contains("{") && !["{app}", "{appName}"].contains($0) }) { return localized("\(rule.id)：未知的捕获组件") }
        case .name(let name):
            if name.isEmpty || name.contains("/") { return localized("\(rule.id)：名称不能为空或包含 /") }
            if name == "*" && rule.condition == nil { return localized("\(rule.id)：任意名称规则必须带条件") }
        case .pathExtension(let ext):
            if ext.isEmpty || ext.contains(".") || ext.contains("/") { return localized("\(rule.id)：扩展名格式错误") }
        }
        return nil
    }

    public func label(for path: String, isDirectory: Bool) -> PurposeLabel? {
        resolve(path, isDirectory: isDirectory, memo: Memo())
    }

    /// 同一次调用内共享前缀缓存；只做 lstat 级别的元数据检查。
    public func labels(for entries: [DiskEntry], directory: String? = nil) -> (entries: [Int64: PurposeLabel], directory: PurposeLabel?) {
        let memo = Memo()
        var values: [Int64: PurposeLabel] = [:]
        for entry in entries { if let label = resolve(entry.url.path, isDirectory: entry.isDirectory, memo: memo) { values[entry.id] = label } }
        return (values, directory.flatMap { resolve($0, isDirectory: true, memo: memo) })
    }

    // MARK: - 增量（扫描时使用）

    /// 扫描根：按整条路径逐层计算，之后的子项用 `child` 前进一步。
    public func trail(for path: String, isDirectory: Bool) -> Trail {
        let display = Self.components(path), normalized = display.map(Self.normalize)
        var state = State()
        for depth in stride(from: 1, through: display.count, by: 1) {
            state = step(parent: state, display: display[0..<(depth - 1)], normalized: normalized[0..<(depth - 1)], name: display[depth - 1],
                normalizedName: normalized[depth - 1], isDirectory: depth == display.count ? isDirectory : true, memo: nil)
        }
        if isDirectory || display.isEmpty { return Trail(state: state, display: display, normalized: normalized, leaf: nil) }
        return Trail(state: state, display: Array(display.dropLast()), normalized: Array(normalized.dropLast()), leaf: display.last)
    }

    /// 在目录的状态上前进一步。祖先是 opaque 时直接继承，不做匹配。
    public func child(of parent: Trail, name: String, isDirectory: Bool) -> Trail {
        let sealed = parent.state.opaque && parent.state.heritable
        let normalizedName = sealed ? name : Self.normalize(name)
        let state = sealed ? inherit(parent.state) : step(parent: parent.state, display: parent.display[...], normalized: parent.normalized[...],
            name: name, normalizedName: normalizedName, isDirectory: isDirectory, memo: nil)
        if isDirectory { return Trail(state: state, display: parent.display + [name], normalized: parent.normalized + [normalizedName], leaf: nil) }
        return Trail(state: state, display: parent.display, normalized: parent.normalized, leaf: name)
    }

    public func label(of trail: Trail) -> PurposeLabel? {
        label(trail.state, display: trail.leaf.map { trail.display + [$0] } ?? trail.display)
    }

    // MARK: - 匹配

    private func resolve(_ path: String, isDirectory: Bool, memo: Memo) -> PurposeLabel? {
        let display = Self.components(path)
        guard !display.isEmpty else { return nil }
        let normalized = display.map(Self.normalize)
        var state = State()
        for depth in 1...display.count {
            let directory = depth == display.count ? isDirectory : true
            let key = normalized[0..<depth].joined(separator: "/") + (directory ? "/" : "")
            if let cached = memo.states[key] { state = cached; continue }
            state = step(parent: state, display: display[0..<(depth - 1)], normalized: normalized[0..<(depth - 1)], name: display[depth - 1],
                normalizedName: normalized[depth - 1], isDirectory: directory, memo: memo)
            memo.states[key] = state
        }
        return label(state, display: display)
    }

    /// display/normalized 是父目录的路径组件，name 是当前组件。
    private func step(parent: State, display: ArraySlice<String>, normalized: ArraySlice<String>, name: String, normalizedName: String,
        isDirectory: Bool, memo: Memo?) -> State {
        if parent.opaque { return inherit(parent) }
        let depth = display.count + 1
        var hits: [(compiled: Compiled, hit: Hit)] = []
        for compiled in anchored[depth] ?? [] {
            if let hit = matchPath(compiled, display: display, normalized: normalized, name: name, normalizedName: normalizedName, memo: memo) {
                hits.append((compiled, hit))
            }
        }
        for compiled in byName[normalizedName] ?? [] { hits.append((compiled, Hit(ruleIndex: compiled.index, app: nil, appEvidence: nil))) }
        for compiled in wildcard { hits.append((compiled, Hit(ruleIndex: compiled.index, app: nil, appEvidence: nil))) }
        if let ext = Self.pathExtension(normalizedName) {
            for compiled in byExtension[ext] ?? [] { hits.append((compiled, Hit(ruleIndex: compiled.index, app: nil, appEvidence: nil))) }
        }
        // 先按类型过滤（不拼字符串）；只有带条件的候选才需要路径做 lstat。
        hits = hits.filter { candidate in
            switch rules[candidate.compiled.index].kind {
            case .directory: return isDirectory
            case .file: return !isDirectory
            case .any: return true
            }
        }
        guard !hits.isEmpty else { return inherit(parent) }
        if hits.contains(where: { rules[$0.compiled.index].condition != nil }) {
            let parentPath = depth == 1 ? "" : "/" + display.joined(separator: "/")
            let nodePath = parentPath + "/" + name
            hits = hits.filter { candidate in
                switch rules[candidate.compiled.index].condition {
                case nil: return true
                case .siblingAny(let names): return names.contains { exists(parentPath + "/" + $0, memo: memo) }
                case .childAny(let names): return isDirectory && names.contains { exists(nodePath + "/" + $0, memo: memo) }
                }
            }
        }
        guard let best = hits.max(by: { $0.compiled.score != $1.compiled.score ? $0.compiled.score < $1.compiled.score : $0.compiled.index > $1.compiled.index }) else {
            return inherit(parent)
        }
        var safety = hits.map { rules[$0.compiled.index].safety }.min() ?? rules[best.compiled.index].safety
        if parent.keepCap { safety = .keep }
        let rule = rules[best.compiled.index]
        return State(hit: best.hit, safety: safety, depth: depth, inherited: false, opaque: rule.opaque,
            keepCap: parent.keepCap || safety == .keep, heritable: rule.heritable)
    }

    private func inherit(_ parent: State) -> State {
        guard parent.heritable else { return State(keepCap: parent.keepCap) }
        var state = parent
        if state.hit != nil { state.inherited = true }
        return state
    }

    /// 生成可读的标签；display 是条目的完整路径组件。
    private func label(_ state: State, display: [String]) -> PurposeLabel? {
        guard let hit = state.hit, state.depth >= 1, state.depth <= display.count else { return nil }
        let rule = rules[hit.ruleIndex]
        let name = display[state.depth - 1]
        let parentName = state.depth >= 2 ? display[state.depth - 2] : "/"
        func fill(_ text: String) -> String {
            text.replacingOccurrences(of: "{app}", with: hit.app ?? name)
                .replacingOccurrences(of: "{name}", with: name)
                .replacingOccurrences(of: "{parent}", with: parentName)
        }
        var evidence: String
        switch rule.match {
        case .path(let pattern): evidence = localized("位于 \(pattern)")
        case .name(let value): evidence = value == "*" ? localized("目录特征") : localized("名称为 \(value)")
        case .pathExtension(let ext): evidence = localized("扩展名为 .\(ext)")
        }
        switch rule.condition {
        case .siblingAny(let names): evidence += localized("，且同级有 \(names.joined(separator: " / ")) 之一")
        case .childAny(let names): evidence += localized("，且目录中有 \(names.joined(separator: " / ")) 之一")
        case nil: break
        }
        if let appEvidence = hit.appEvidence { evidence += "；\(appEvidence)" }
        let title = fill(rule.title)
        if state.inherited {
            evidence = localized("所在目录 /\(display[0..<state.depth].joined(separator: "/")) 被识别为「\(title)」：\(evidence)")
        }
        return PurposeLabel(ruleID: rule.id, category: rule.category, safety: state.safety, title: title, detail: fill(rule.detail),
            evidence: evidence, inherited: state.inherited)
    }

    /// 先比较全部字面量，再解析捕获的应用名，避免为不会命中的规则查应用目录。
    private func matchPath(_ compiled: Compiled, display: ArraySlice<String>, normalized: ArraySlice<String>, name: String, normalizedName: String,
        memo: Memo?) -> Hit? {
        let last = compiled.segments.count - 1
        func value(_ position: Int) -> (display: String, normalized: String) {
            position == last ? (name, normalizedName)
                : (display[display.startIndex + position], normalized[normalized.startIndex + position])
        }
        for (position, segment) in compiled.segments.enumerated() {
            if case .literal(let expected) = segment, value(position).normalized != expected { return nil }
        }
        var app: String?, appEvidence: String?
        for (position, segment) in compiled.segments.enumerated() {
            switch segment {
            case .literal, .any: break
            case .app: (app, appEvidence) = resolveApplication(value(position).display, memo: memo)
            case .appName:
                if let found = applicationNames[value(position).normalized] { app = found; appEvidence = localized("文件夹名与已安装应用「\(found)」一致") }
                else { app = value(position).display }
            }
        }
        return Hit(ruleIndex: compiled.index, app: app, appEvidence: appEvidence)
    }

    /// 标识 → 应用名称：精确 → 去掉团队 ID 与 group(s). 前缀 → 前缀关系 → 同一开发商；
    /// 不是标识的普通文件夹名先按应用名匹配，再原样使用。未解析时不下“已卸载”结论。
    private func resolveApplication(_ raw: String, memo: Memo?) -> (String, String) {
        if let cached = memo?.apps[raw] { return cached }
        let id = Self.normalize(raw)
        var result: (String, String)
        if let name = applications[id] {
            result = (name, localized("标识 \(raw) 对应已安装应用「\(name)」"))
        } else if let name = applicationNames[id] {
            result = (name, localized("文件夹名与已安装应用「\(name)」一致"))
        } else if !id.contains(".") {
            result = (raw, localized("按文件夹名「\(raw)」显示，未与已安装应用对应"))
        } else {
            var candidate = id
            let parts = raw.split(separator: ".", maxSplits: 1)
            if parts.count == 2, parts[0].count == 10, parts[0].allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) {
                candidate = Self.normalize(String(parts[1]))
            }
            for prefix in ["group.", "groups."] where candidate.hasPrefix(prefix) { candidate.removeFirst(prefix.count) }
            func names(_ matches: (String) -> Bool) -> [String] {
                Array(Set(applications.filter { matches($0.key) }.map(\.value))).sorted()
            }
            func summary(_ names: [String]) -> String { names.count == 1 ? names[0] : localized("\(names[0]) 等") }
            var found = applications[candidate].map { [$0] } ?? []
            var how = localized("标识 \(raw) 对应已安装应用")
            if found.isEmpty {
                // 取最长的“已安装标识是它的前缀”的应用（如 com.foo.app.helper → com.foo.app）；否则看它是哪些应用的前缀。
                if let owner = applications.keys.filter({ candidate.hasPrefix($0 + ".") }).max(by: { $0.count != $1.count ? $0.count < $1.count : $0 > $1 }) {
                    found = [applications[owner]!]
                } else { found = names { $0.hasPrefix(candidate + ".") } }
                how = localized("标识 \(raw) 关联已安装应用")
            }
            let vendor = candidate.split(separator: ".").prefix(2).joined(separator: ".")
            if found.isEmpty, !candidate.hasPrefix("com.apple."), candidate.split(separator: ".").count >= 2,
                !["com.github", "io.github", "com.electron", "org.chromium"].contains(vendor) {
                found = names { $0 == vendor || $0.hasPrefix(vendor + ".") }
                how = localized("标识 \(raw) 按开发商前缀 \(vendor) 关联已安装应用")
            }
            if !found.isEmpty { result = (summary(found), "\(how)「\(found.prefix(3).joined(separator: "、"))」") }
            else if candidate.hasPrefix("com.apple.") { result = (localized("系统组件"), localized("Apple 系统组件标识 \(raw)")) }
            else { result = (localized("未识别应用"), localized("标识 \(raw) 未在应用目录中找到对应应用")) }
        }
        memo?.apps[raw] = result
        return result
    }

    private func exists(_ path: String, memo: Memo?) -> Bool {
        if let cached = memo?.exists[path] { return cached }
        var info = stat()
        let value = lstat(path, &info) == 0
        memo?.exists[path] = value
        return value
    }

    static func components(_ path: String) -> [String] { path.split(separator: "/").map(String.init) }
    /// ASCII 名称的 NFC 就是自身，只需转小写；扫描时绝大多数名称走这条快路径。
    static func normalize(_ value: String) -> String {
        if value.utf8.allSatisfy({ $0 < 0x80 }) { return value.lowercased() }
        return value.precomposedStringWithCanonicalMapping.lowercased()
    }
    static func pathExtension(_ name: String) -> String? {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex, name.index(after: dot) != name.endIndex else { return nil }
        return String(name[name.index(after: dot)...])
    }
}
