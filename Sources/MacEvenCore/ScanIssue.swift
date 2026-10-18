import Foundation
import Darwin

public enum ScanIssueCategory: String, Sendable, CaseIterable {
    case permissionDenied
    case operationDenied
    case systemProtected
    case changed
    case io
    case other
    case excluded

    public var title: String {
        switch self {
        case .permissionDenied:
            return localized("权限不足")
        case .operationDenied:
            return localized("操作被系统拒绝")
        case .systemProtected:
            return localized("系统保护")
        case .changed:
            return localized("路径已变动")
        case .io:
            return localized("输入/输出错误")
        case .other:
            return localized("其他错误")
        case .excluded:
            return localized("已排除路径")
        }
    }

    public var guidance: String {
        switch self {
        case .permissionDenied:
            return localized("当前用户或进程缺少读取权限。属于当前用户目录或外置卷的隐私限制，可在系统设置中授予“完全磁盘访问权限”后重新扫描获取。")
        case .operationDenied:
            return localized("系统拒绝访问。若属于受隐私保护的用户路径，完全磁盘访问权限可协助读取。")
        case .systemProtected:
            return localized("受 macOS 系统完整性保护（SIP）、Data Vault 沙盒或系统服务/守护进程专有权限保护，属于系统底层保留项目。无法且无需通过用户授权获取访问，不影响日常磁盘分析与清理。")
        case .changed:
            return localized("路径已不存在或暂时失效，可能在扫描期间被移动、重命名或删除。可稍后重扫确认。")
        case .io:
            return localized("读取时发生输入/输出错误，可能涉及磁盘或文件系统。请根据详细错误信息进一步排查。")
        case .other:
            return localized("扫描遇到未分类的错误，请参考详细错误信息排查。")
        case .excluded:
            return localized("该项目属于受限制的扫描边界、系统保留路径或其他挂载卷，已被安全排除。")
        }
    }
}

public struct ScanIssue: Sendable, Equatable {
    public let path: String?
    public let domain: String
    public let code: Int
    public let posixCode: Int?
    public let category: ScanIssueCategory
    public let message: String
    public var formattedText: String {
        let details = "\(domain) \(code)" + (posixCode.map { localized("，POSIX \($0)") } ?? "")
        return localized("[\(category.title)] \(path ?? localized("未定位路径"))\n\(message)\n错误代码：\(details)")
    }

    public static func isSystemProtectedPath(_ rawPath: String) -> Bool {
        let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
        if path == "/System" || path.hasPrefix("/System/") { return true }
        if path == "/usr" || (path.hasPrefix("/usr/") && !path.hasPrefix("/usr/local/")) { return true }
        if path == "/sbin" || path.hasPrefix("/sbin/") { return true }
        if path == "/bin" || path.hasPrefix("/bin/") { return true }
        if path == "/etc" || path.hasPrefix("/etc/") || path == "/private/etc" || path.hasPrefix("/private/etc/") { return true }
        if path == "/var" || path.hasPrefix("/var/") || path == "/private/var" || path.hasPrefix("/private/var/") {
            if !path.hasPrefix("/var/folders/") && !path.hasPrefix("/private/var/folders/") {
                return true
            }
        }
        let lower = path.lowercased()
        if lower.contains("datavault") || lower.contains(".datavault") { return true }
        if path.hasPrefix("/Library/Application Support/Apple/") ||
           path.hasPrefix("/Library/Application Support/Google/GoogleUpdater/") ||
           path.hasPrefix("/Library/Tailscale") ||
           path.hasPrefix("/Library/Caches/com.apple.ane") ||
           path.hasPrefix("/Library/Caches/Desktop Pictures") ||
           path.hasPrefix("/Library/Caches/com.apple.iconservices") {
            return true
        }
        return false
    }

    public init(error: Error, url: URL? = nil) {
        var resolvedPath: String? = nil
        if let url, url.isFileURL {
            resolvedPath = url.standardizedFileURL.path
        } else {
            let nsError = error as NSError
            if let pathVal = nsError.userInfo[NSFilePathErrorKey] as? String, !pathVal.isEmpty {
                resolvedPath = URL(fileURLWithPath: pathVal).standardizedFileURL.path
            } else if let urlVal = nsError.userInfo[NSURLErrorKey] as? URL, urlVal.isFileURL {
                resolvedPath = urlVal.standardizedFileURL.path
            }
        }
        self.path = resolvedPath

        let nsError = error as NSError
        self.domain = nsError.domain
        self.code = nsError.code

        var foundPosix: Int? = nil
        if nsError.domain == NSPOSIXErrorDomain {
            foundPosix = nsError.code
        } else {
            var currentError: NSError = nsError
            var depth = 0
            while depth < 8, let underlying = currentError.userInfo[NSUnderlyingErrorKey] as? NSError {
                depth += 1
                if underlying.domain == NSPOSIXErrorDomain {
                    foundPosix = underlying.code
                    break
                }
                currentError = underlying
            }
        }
        self.posixCode = foundPosix

        let isAccessIssue: Bool
        if let pCode = foundPosix {
            isAccessIssue = (pCode == Int(EACCES) || pCode == Int(EPERM))
        } else if nsError.domain == NSCocoaErrorDomain {
            isAccessIssue = (nsError.code == NSFileReadNoPermissionError)
        } else {
            isAccessIssue = false
        }

        let isSystemProtected: Bool
        if isAccessIssue, let p = resolvedPath {
            isSystemProtected = ScanIssue.isSystemProtectedPath(p)
        } else {
            isSystemProtected = false
        }

        let resolvedCategory: ScanIssueCategory
        if isSystemProtected {
            resolvedCategory = .systemProtected
        } else if let pCode = foundPosix {
            switch pCode {
            case Int(EACCES):
                resolvedCategory = .permissionDenied
            case Int(EPERM):
                resolvedCategory = .operationDenied
            case Int(ENOENT), Int(ESTALE):
                resolvedCategory = .changed
            case Int(EIO):
                resolvedCategory = .io
            default:
                resolvedCategory = .other
            }
        } else {
            if nsError.domain == NSCocoaErrorDomain {
                switch nsError.code {
                case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
                    resolvedCategory = .changed
                case NSFileReadNoPermissionError:
                    resolvedCategory = .operationDenied
                default:
                    resolvedCategory = .other
                }
            } else {
                resolvedCategory = .other
            }
        }
        self.category = resolvedCategory

        self.message = String(error.localizedDescription.prefix(1000))
    }

    public init(path: String?, category: ScanIssueCategory, message: String) {
        self.path = path.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        self.domain = "MacEven.Scan"
        self.code = 0
        self.posixCode = nil
        self.category = category
        self.message = String(message.prefix(1000))
    }
}

internal struct ScanIssueLog {
    private var seenPaths = Set<String>()
    private(set) var issues: [ScanIssue] = []
    private(set) var count: Int = 0
    private(set) var unpathedErrors: Int = 0

    mutating func record(_ issue: ScanIssue) {
        guard let path = issue.path else {
            count += 1
            unpathedErrors += 1
            if issues.count < 100 {
                issues.append(issue)
            }
            return
        }

        if !seenPaths.contains(path) {
            seenPaths.insert(path)
            count += 1
            if issues.count < 100 {
                issues.append(issue)
            }
        } else if issue.category != .other,
                  let index = issues.firstIndex(where: { $0.path == path }),
                  issues[index].category == .other || (issues[index].posixCode == nil && issue.posixCode != nil) {
            issues[index] = issue
        }
    }
}
