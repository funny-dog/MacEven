import Foundation

/// 应用包与资源包内部的路径判定。
/// 与索引粗筛的 `.app/`、`.bundle/` 条件保持一致：按路径组件后缀匹配，区分大小写。
public enum BundlePath {
    public static func containsBundleAncestor(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count > 1 else { return false }
        return components.dropLast().contains { $0.hasSuffix(".app") || $0.hasSuffix(".bundle") }
    }
}
