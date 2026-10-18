import Foundation
import Darwin

/// 重复文件扫描专用的遍历条件。
struct BulkFilter: Sendable {
    let rootDevice: Int64
    let minimumFileSize: Int64
    let excludedPaths: Set<String>
    let indexURL: URL
}

extension Scanner {
    /// 与 runProducer 相同的流协议，但用 getattrlistbulk 遍历：只为目录和达到门槛的普通文件建 URL、取身份，
    /// 隐藏项、软件包、其他卷、排除路径作为边界跳过；小于门槛与共享数据块的文件只计数。
    static func runBulkProducer(
        dirPath: String,
        baseLevel: Int,
        filter: BulkFilter,
        stream: ProducerStream,
        coordinator: Coordinator,
        ancestors: [(level: Int, identity: FileIdentity)],
        isRoot: Bool
    ) {
        defer { stream.finish() }

        var batch: [StreamItem] = []
        batch.reserveCapacity(64)
        var small = 0, shared = 0
        var directoryAncestors = ancestors
        let indexPath = filter.indexURL.path

        func flush() {
            if small > 0 || shared > 0 {
                batch.append(.filtered(small: small, shared: shared))
                small = 0; shared = 0
            }
            if !batch.isEmpty {
                stream.push(batch: batch)
                batch.removeAll(keepingCapacity: true)
            }
        }
        func append(_ item: StreamItem) {
            batch.append(item)
            if batch.count >= 64 { flush() }
        }
        func issue(_ path: String, _ code: Int32) -> ScanIssue {
            let error = NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [
                NSLocalizedDescriptionKey: "\(path)：\(String(cString: strerror(code)))", NSFilePathErrorKey: path])
            return ScanIssue(error: error, url: URL(fileURLWithPath: path))
        }
        func identity(_ info: stat) -> FileIdentity {
            FileIdentity(device: Int64(info.st_dev), inode: Int64(bitPattern: UInt64(info.st_ino)),
                mode: Int64(info.st_mode), size: info.st_size,
                modified: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec),
                changed: Int64(info.st_ctimespec.tv_sec) * 1_000_000_000 + Int64(info.st_ctimespec.tv_nsec),
                allocated: Int64(info.st_blocks) * 512)
        }
        func isPackage(_ entry: BulkDirectoryWalker.Entry, _ url: URL) -> Bool {
            if entry.hasBundleBit { return true }
            let ext = url.pathExtension.lowercased()
            if ext.isEmpty { return false }
            if ext == "app" || ext == "bundle" { return true }
            return autoreleasepool { (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) == true }
        }

        guard let walker = BulkDirectoryWalker(root: dirPath) else {
            if isRoot {
                stream.pushFatal(MacEvenError(localized("无法枚举扫描入口。")))
            } else {
                stream.pushError(ScanIssue(path: dirPath, category: .other, message: localized("无法枚举目录")))
            }
            return
        }

        while !coordinator.token.isCancelled && !coordinator.isStopped {
            let next = walker.next()
            for failure in walker.takeFailures() { append(.error(issue(failure.path, failure.code), nil)) }
            guard let entry = next else { break }

            let level = baseLevel + entry.level
            while directoryAncestors.count > 1 && directoryAncestors.last!.level >= level {
                directoryAncestors.removeLast()
            }
            if entry.name.hasPrefix(".") || filter.excludedPaths.contains(entry.path) ||
                entry.path == indexPath || entry.path.hasPrefix(indexPath + "-") {
                if entry.isDirectory { walker.skipDescendants() }
                append(.boundary(level))
                continue
            }
            if entry.errorCode != 0 {
                if entry.isDirectory { walker.skipDescendants() }
                append(.error(issue(entry.path, Int32(bitPattern: entry.errorCode)), level))
                continue
            }

            if entry.isRegular {
                // 先用批量属性排除，避免为大量小文件取身份。
                guard entry.dataLength >= filter.minimumFileSize else { small += 1; continue }
                guard entry.linkCount <= 1 else { shared += 1; continue }
                guard let info = walker.status(of: entry) else {
                    append(.error(issue(entry.path, errno), level))
                    continue
                }
                let fileIdentity = identity(info)
                guard fileIdentity.isRegular, fileIdentity.device == filter.rootDevice else { continue }
                guard info.st_nlink <= 1 else { shared += 1; continue }
                guard fileIdentity.size >= filter.minimumFileSize else { small += 1; continue }
                if walker.sharesBlocks(entry, allocated: fileIdentity.allocated) == true { shared += 1; continue }
                append(.entry(URL(fileURLWithPath: entry.path, isDirectory: false), fileIdentity, level))
            } else if entry.isDirectory {
                guard let info = walker.status(of: entry) else {
                    walker.skipDescendants()
                    append(.error(issue(entry.path, errno), level))
                    continue
                }
                let directoryIdentity = identity(info)
                // 其他卷的挂载点属于另一个扫描范围，作为边界而不是错误。
                guard directoryIdentity.isDirectory, directoryIdentity.device == filter.rootDevice else {
                    walker.skipDescendants()
                    append(.boundary(level))
                    continue
                }
                let url = URL(fileURLWithPath: entry.path, isDirectory: true)
                if isPackage(entry, url) {
                    walker.skipDescendants()
                    append(.boundary(level))
                    continue
                }
                let aliasesAncestor = directoryAncestors.contains {
                    $0.identity.device == directoryIdentity.device && $0.identity.inode == directoryIdentity.inode
                }
                directoryAncestors.append((level, directoryIdentity))
                append(.entry(url, directoryIdentity, level))
                if aliasesAncestor {
                    walker.skipDescendants()
                } else if coordinator.tryAcquirePermit() {
                    let childStream = coordinator.createStream()
                    batch.append(.childStream(childStream))
                    flush()
                    walker.skipDescendants()

                    coordinator.group.enter()
                    let childAncestors = directoryAncestors
                    let childPath = entry.path
                    DispatchQueue.global(qos: .utility).async {
                        defer { coordinator.group.leave() }
                        autoreleasepool {
                            runBulkProducer(dirPath: childPath, baseLevel: level, filter: filter, stream: childStream,
                                            coordinator: coordinator, ancestors: childAncestors, isRoot: false)
                        }
                    }
                }
            }
        }
        flush()
    }
}
