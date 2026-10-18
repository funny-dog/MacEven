import Foundation

/// Dock 图标条目匹配信息
public struct DockTileMatch: Sendable, Equatable {
    /// 在 persistent-apps 数组中的索引位置
    public let index: Int
    /// 图标显示标签（来自 file-label）
    public let label: String
    /// 解析得到的文件路径（去尾部斜杠，若无则为 nil）
    public let path: String?
    /// 应用 Bundle 标识符（若无则为 nil）
    public let bundleIdentifier: String?

    public init(index: Int, label: String, path: String?, bundleIdentifier: String?) {
        self.index = index
        self.label = label
        self.path = path
        self.bundleIdentifier = bundleIdentifier
    }
}

/// Dock persistent-apps 匹配与过滤工具
public enum DockTiles {
    /// 匹配 Dock persistent-apps 数组中的条目
    ///
    /// 匹配规则：
    /// 1. 优先按路径匹配：把 _CFURLString 解析为文件路径，去掉尾部斜杠后与 appPaths（去尾斜杠）不区分大小写比较；
    /// 2. 只有当该 tile 没有可解析路径时，才退而按 bundleIdentifier（不区分大小写）精确匹配；
    /// 3. 不认识的结构（非字典、缺少字段）一律跳过不匹配。
    public static func matches(
        in tiles: [[String: Any]],
        appPaths: [String],
        bundleIdentifiers: [String]
    ) -> [DockTileMatch] {
        let normalizedPaths = Set(appPaths.map { normalizePath($0).lowercased() })
        let normalizedBundleIDs = Set(bundleIdentifiers.map { $0.lowercased() })

        var matches: [DockTileMatch] = []

        for (index, tile) in tiles.enumerated() {
            guard let tileData = tile["tile-data"] as? [String: Any],
                  let label = tileData["file-label"] as? String else {
                continue
            }

            let bundleId = tileData["bundle-identifier"] as? String

            let parsedPath: String?
            if let fileData = tileData["file-data"] as? [String: Any],
               let rawURL = fileData["_CFURLString"] as? String {
                parsedPath = extractPath(from: rawURL)
            } else {
                parsedPath = nil
            }

            var isMatched = false
            if let parsedPath = parsedPath {
                let normalizedPath = parsedPath.lowercased()
                if normalizedPaths.contains(normalizedPath) {
                    isMatched = true
                }
            } else if let bundleId = bundleId {
                let normalizedBundleId = bundleId.lowercased()
                if normalizedBundleIDs.contains(normalizedBundleId) {
                    isMatched = true
                }
            }

            if isMatched {
                matches.append(
                    DockTileMatch(
                        index: index,
                        label: label,
                        path: parsedPath,
                        bundleIdentifier: bundleId
                    )
                )
            }
        }

        return matches
    }

    /// 移除指定下标的条目，其余顺序与内容原样保留
    public static func removing(_ indices: Set<Int>, from tiles: [[String: Any]]) -> [[String: Any]] {
        guard !indices.isEmpty else { return tiles }
        return tiles.enumerated().compactMap { index, tile in
            indices.contains(index) ? nil : tile
        }
    }

    // MARK: - 内部辅助方法

    /// 去除路径末尾的斜杠（根目录 "/" 除外）
    private static func normalizePath(_ path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") {
            p.removeLast()
        }
        return p
    }

    /// 从 _CFURLString 解析本地文件路径
    private static func extractPath(from raw: String) -> String? {
        guard !raw.isEmpty else { return nil }

        var candidateURL: URL?
        if let u = URL(string: raw) {
            candidateURL = u
        } else if let encoded = raw.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed.union(.urlPathAllowed)),
                  let u = URL(string: encoded) {
            candidateURL = u
        }

        if let url = candidateURL {
            if url.scheme == "file" || (url.scheme == nil && raw.hasPrefix("/")) {
                let p = url.path
                if !p.isEmpty {
                    return normalizePath(p)
                }
            }
        }

        if raw.hasPrefix("file://") {
            let afterScheme = String(raw.dropFirst(7))
            let pathPart: String
            if afterScheme.hasPrefix("localhost/") {
                pathPart = String(afterScheme.dropFirst(9))
            } else if afterScheme.hasPrefix("/") {
                pathPart = afterScheme
            } else {
                pathPart = "/" + afterScheme
            }
            let decoded = pathPart.removingPercentEncoding ?? pathPart
            if !decoded.isEmpty {
                return normalizePath(decoded)
            }
        }

        return nil
    }
}
