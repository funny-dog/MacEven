import Foundation

/// 按包元数据发现应用目录；扫描与执行共用缓存结构规则。
enum ApplicationCachePaths {
    static let cacheDirectories = ["Cache", "Code Cache", "GPUCache", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache", "GrShaderCache", "ShaderCache"]
    // 这些历史产品名无法从当前应用包名得知；常规应用不需要逐个登记。
    static let legacyNames = ["com.openai.codex": ["Codex"], "com.electron.lark": ["LarkShell"], "com.bitwarden.desktop": ["bitwarden-updater"]]
    static let reservedNames: Set<String> = ["app", "application", "applications", "electron", "helper", "cache", "caches", "default", "shared", "google", "microsoft", "apple", "mac even", "maceven"]
    static let browserIDs: Set<String> = ["com.google.Chrome", "com.microsoft.edgemac", "org.mozilla.firefox"]

    static func key(_ relative: String) -> String { relative.precomposedStringWithCanonicalMapping.lowercased() }

    static func relativeRoots(for app: CacheApplication) -> Set<String> {
        guard validCacheIdentifier(app.id) else { return [] }
        let names = Set((app.directoryNames + (legacyNames[app.id] ?? [])).filter {
            !$0.isEmpty && $0.utf8.count <= 255 && !$0.hasPrefix(".") && !$0.contains("/") && !$0.contains("\\") && !$0.contains(":") &&
            !reservedNames.contains($0.lowercased()) && $0.trimmingCharacters(in: .whitespacesAndNewlines) == $0
        })
        var roots: Set<String> = ["Library/Caches/\(app.id)", "Library/Containers/\(app.id)/Data/Library/Caches"]
        if !browserIDs.contains(app.id) {
            for name in names.union([app.id]) {
                roots.insert("Library/Caches/\(name)")
                roots.insert(".cache/\(name)")
                for cache in cacheDirectories { roots.insert("Library/Application Support/\(name)/\(cache)") }
            }
        }
        for group in app.applicationGroups { roots.insert("Library/Group Containers/\(group)/Library/Caches") }
        return roots
    }

    static func contains(_ relative: String, application: CacheApplication) -> Bool {
        guard !isDeveloperPath(relative), !relative.lowercased().hasPrefix("library/group containers/") else { return false }
        let path = key(relative)
        return relativeRoots(for: application).contains { path == key($0) || path.hasPrefix(key($0) + "/") }
    }

    static func isDeveloperPath(_ relative: String) -> Bool {
        let key = relative.lowercased()
        return DeveloperCleanupRule.allCases.contains {
            let root = $0.relativePath.lowercased()
            return key == root || key.hasPrefix(root + "/") || root.hasPrefix(key + "/")
        }
    }
}
