import Foundation
import Darwin
@testable import MacEvenCore

func runScanIssueChecks() throws {
    let path = URL(fileURLWithPath: "/fixture/失败目录")
    let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
    let cocoa = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError,
                        userInfo: [NSUnderlyingErrorKey: posix, NSFilePathErrorKey: path.path])
    let enumeratorIssue = ScanIssue(error: cocoa)
    let metadataIssue = ScanIssue(error: posix, url: URL(fileURLWithPath: "/fixture/./失败目录"))
    precondition(enumeratorIssue.domain == NSCocoaErrorDomain && enumeratorIssue.code == NSFileReadNoPermissionError)
    precondition(enumeratorIssue.posixCode == Int(EACCES) && enumeratorIssue.category == .permissionDenied)
    precondition(metadataIssue.domain == NSPOSIXErrorDomain && metadataIssue.path == path.path)

    var log = ScanIssueLog()
    log.record(enumeratorIssue)
    log.record(metadataIssue)
    precondition(log.count == 1 && log.issues.count == 1, "two error sources counted the same path twice")
    log.record(ScanIssue(error: posix, url: URL(fileURLWithPath: "/fixture/另一个目录")))
    precondition(log.count == 2, "different paths were merged")

    for (code, expected) in [(EPERM, ScanIssueCategory.operationDenied), (ENOENT, .changed), (ESTALE, .changed), (EIO, .io), (EINVAL, .other)] {
        let issue = ScanIssue(error: NSError(domain: NSPOSIXErrorDomain, code: Int(code)), url: path)
        precondition(issue.category == expected && issue.posixCode == Int(code))
    }
    let unknown = ScanIssue(error: NSError(domain: "UnknownProvider", code: 257,
                                           userInfo: [NSLocalizedDescriptionKey: "Permission denied is only text"]))
    precondition(unknown.path == nil && unknown.category == .other, "unknown domain classified from its message")
    let largeCode = ScanIssue(error: NSError(domain: NSPOSIXErrorDomain, code: Int.max))
    precondition(largeCode.category == .other && largeCode.posixCode == Int.max, "unknown error code was narrowed")
    let fileURLIssue = ScanIssue(error: NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError,
                                                userInfo: [NSURLErrorKey: path]))
    precondition(fileURLIssue.path == path.path)
    precondition(ScanIssue(error: NSError(domain: "Provider", code: 1,
                                          userInfo: [NSURLErrorKey: URL(string: "https://example.invalid/file")!])).path == nil)
    log.record(unknown)
    log.record(unknown)
    precondition(log.count == 4 && log.unpathedErrors == 2, "unlocated errors were dropped or merged")
    let progress = ScanProgress(visited: 0, logicalSize: 0, allocatedSize: 0, currentPath: "/fixture", elapsed: 0,
                                errors: log.count, unpathedErrors: log.unpathedErrors)
    precondition(progress.failedPathCount == 2 && progress.errorCountDescription == "2 个失败路径 · 2 个未定位错误")
    precondition(ScanIssue(error: NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)).category == .changed)
    precondition(ScanIssue(error: NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)).category == .operationDenied)
    precondition(ScanIssue(error: posix, url: URL(fileURLWithPath: "/fixture/名字：包含分隔符")).path == "/fixture/名字：包含分隔符")

    var capped = ScanIssueLog()
    for i in 0..<105 { capped.record(ScanIssue(error: posix, url: URL(fileURLWithPath: "/fixture/\(i)"))) }
    capped.record(ScanIssue(error: cocoa, url: URL(fileURLWithPath: "/fixture/104")))
    precondition(capped.count == 105 && capped.issues.count == 100, "sample cap changed totals or deduplication")
    var upgraded = ScanIssueLog()
    upgraded.record(ScanIssue(path: path.path, category: .other, message: "无法枚举目录"))
    upgraded.record(metadataIssue)
    precondition(upgraded.count == 1 && upgraded.issues.first?.category == .permissionDenied)
    var clarified = ScanIssueLog()
    clarified.record(ScanIssue(error: NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError), url: path))
    clarified.record(metadataIssue)
    precondition(clarified.count == 1 && clarified.issues.first?.posixCode == Int(EACCES))
    precondition(clarified.issues.first?.category == .permissionDenied, "generic permission message hid a more precise cause")

    let sysPaths = [
        "/usr/sbin/authserver",
        "/Library/Caches/com.apple.amsengagementd.classicdatavault",
        "/System/Library/Templates/Data/private/var/spool/postfix/saved",
        "/Library/Application Support/Apple/Screen Sharing/Keys",
        "/var/networkd/db"
    ]
    for sysPath in sysPaths {
        let sysURL = URL(fileURLWithPath: sysPath)
        let issueEACCES = ScanIssue(error: posix, url: sysURL)
        precondition(issueEACCES.category == .systemProtected, "system path was not classified as systemProtected: \(sysPath)")
        precondition(issueEACCES.formattedText.hasPrefix("[系统保护]"), "systemProtected label mismatch: \(issueEACCES.formattedText)")
        let issueEPERM = ScanIssue(error: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM)), url: sysURL)
        precondition(issueEPERM.category == .systemProtected)
    }

    print("PASS: scan issue source deduplication, path normalization, classification, unknown errors and sample cap")

    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("MacEven-issues-\(UUID())")
    let root = base.appendingPathComponent("root")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    var locked: [URL] = []
    defer {
        for directory in locked { chmod(directory.path, 0o700) }
        try? fm.removeItem(at: base)
    }
    let index = try DiskIndex(url: base.appendingPathComponent("index.sqlite"))
    defer { index.close() }
    for i in 0..<105 {
        let directory = root.appendingPathComponent("locked-\(i)")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data([1]).write(to: directory.appendingPathComponent("file"))
        locked.append(directory)
        precondition(chmod(directory.path, 0) == 0)
    }
    let token = CancellationToken()
    let cancelled = try Scanner.scan(root: root, index: index, token: token) { progress in
        if progress.errors > 0 { token.cancel() }
    }
    precondition(cancelled.cancelled && cancelled.errors > 0 && !cancelled.issues.isEmpty)
    precondition(Set(cancelled.issues.compactMap(\.path)).count == cancelled.issues.count)
    for directory in locked { precondition(chmod(directory.path, 0o700) == 0) }
    let recovered = try Scanner.scan(root: root, index: index, token: CancellationToken())
    precondition(!recovered.cancelled && recovered.errors == 0 && recovered.unpathedErrors == 0)
    precondition(recovered.issues.isEmpty && recovered.errorExamples.isEmpty && recovered.visited == 210)
    for directory in locked { precondition(chmod(directory.path, 0) == 0) }
    let complete = try Scanner.scan(root: root, index: index, token: CancellationToken())
    precondition(complete.errors == 105 && complete.failedPathCount == 105 && complete.unpathedErrors == 0)
    precondition(complete.issues.count == 100 && complete.errorExamples.count == 100)
    precondition(complete.issues.allSatisfy { $0.category == .permissionDenied || $0.category == .operationDenied })
    precondition(complete.errorCountDescription == "105 个失败路径")
    print("PASS: real permission failures, 100 bounded samples and fresh state after cancelled rescan")
}
