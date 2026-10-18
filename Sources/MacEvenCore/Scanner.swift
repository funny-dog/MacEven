import Foundation

public enum Scanner {
    private struct Directory {
        var id: Int64
        var level: Int
        var logical: Int64 = 0
        var allocated: Int64 = 0
        /// 用途扫描时才有：本目录的分类状态、作为用途边界的标记，以及尚未归属的字节。
        var trail: PurposeClassifier.Trail? = nil
        var tag: PurposeTag? = nil
        var carry: Int64 = 0
    }

    enum StreamItem: Sendable {
        case entry(URL, FileIdentity, Int)
        case error(ScanIssue, Int?)
        case boundary(Int)
        case fatal(MacEvenError)
        case childStream(ProducerStream)
        /// 批量遍历时被过滤的文件数：小于门槛、共享数据块（硬链接或 APFS 克隆）。
        case filtered(small: Int, shared: Int)
    }

    final class ProducerStream: @unchecked Sendable {
        private let condition = NSCondition()
        private var batches: [[StreamItem]] = []
        private let maxBatches = 2
        private var isFinished = false
        private unowned let coordinator: Coordinator

        private var currentBatch: [StreamItem] = []
        private var currentIndex: Int = 0

        init(coordinator: Coordinator) {
            self.coordinator = coordinator
        }

        func push(batch: [StreamItem]) {
            guard !batch.isEmpty else { return }
            condition.lock()
            defer { condition.unlock() }

            while batches.count >= maxBatches && !coordinator.isStopped && !coordinator.token.isCancelled {
                condition.wait(until: Date(timeIntervalSinceNow: 0.05))
            }

            if coordinator.isStopped || coordinator.token.isCancelled {
                return
            }

            batches.append(batch)
            condition.signal()
        }

        func pushError(_ issue: ScanIssue) {
            push(batch: [.error(issue, nil)])
        }

        func pushFatal(_ error: MacEvenError) {
            push(batch: [.fatal(error)])
        }

        func finish() {
            condition.lock()
            isFinished = true
            condition.broadcast()
            condition.unlock()
        }

        func wakeUp() {
            condition.lock()
            condition.broadcast()
            condition.unlock()
        }

        func popNextItem() -> StreamItem? {
            if currentIndex < currentBatch.count {
                let item = currentBatch[currentIndex]
                currentIndex += 1
                return item
            }

            condition.lock()
            defer { condition.unlock() }

            while batches.isEmpty && !isFinished && !coordinator.isStopped && !coordinator.token.isCancelled {
                condition.wait(until: Date(timeIntervalSinceNow: 0.05))
            }

            if coordinator.isStopped || coordinator.token.isCancelled {
                return nil
            }

            if batches.isEmpty {
                return nil
            }

            let nextBatch = batches.removeFirst()
            condition.signal()

            currentBatch = nextBatch
            currentIndex = 0

            if currentIndex < currentBatch.count {
                let item = currentBatch[currentIndex]
                currentIndex += 1
                return item
            }
            return nil
        }
    }

    final class Coordinator: @unchecked Sendable {
        // A permit stays owned until its stream is consumed, bounding queued subtrees.
        private let workers = 2
        let token: CancellationToken
        let group = DispatchGroup()
        private let lock = NSLock()
        private var _activePermits: Int = 0
        private var _isStopped: Bool = false
        private var streams: [ProducerStream] = []

        init(token: CancellationToken) {
            self.token = token
        }

        var isStopped: Bool {
            lock.withLock { _isStopped }
        }

        func tryAcquirePermit() -> Bool {
            lock.withLock {
                guard !_isStopped, !token.isCancelled else { return false }
                if _activePermits < workers {
                    _activePermits += 1
                    return true
                }
                return false
            }
        }

        func releasePermit() {
            lock.withLock {
                _activePermits = max(0, _activePermits - 1)
            }
        }

        func acquireRootPermit() {
            lock.withLock {
                _activePermits = 1
            }
        }

        func createStream() -> ProducerStream {
            let s = ProducerStream(coordinator: self)
            lock.withLock {
                streams.append(s)
            }
            return s
        }

        func unregisterStream(_ stream: ProducerStream) {
            lock.withLock {
                streams.removeAll { $0 === stream }
            }
        }

        func stop() {
            var toWake: [ProducerStream] = []
            lock.withLock {
                guard !_isStopped else { return }
                _isStopped = true
                toWake = streams
            }
            for s in toWake {
                s.wakeUp()
            }
        }

        func wait() {
            group.wait()
        }
    }

    private static func runProducer(
        dirURL: URL,
        baseLevel: Int,
        rootDevice: Int64,
        requireCompleteTraversal: Bool,
        indexURL: URL,
        stream: ProducerStream,
        coordinator: Coordinator,
        ancestors: [(level: Int, identity: FileIdentity)],
        isRoot: Bool
    ) {
        defer {
            stream.finish()
        }

        var localBatch: [StreamItem] = []
        var directoryAncestors = ancestors
        localBatch.reserveCapacity(64)

        func flushBatch() {
            if !localBatch.isEmpty {
                stream.push(batch: localBatch)
                localBatch.removeAll(keepingCapacity: true)
            }
        }

        guard let enumerator = FileManager.default.enumerator(
            at: dirURL,
            includingPropertiesForKeys: [],
            options: [],
            errorHandler: { url, error in
                let issue = ScanIssue(error: error, url: url)
                flushBatch()
                stream.pushError(issue)
                return !coordinator.token.isCancelled && !coordinator.isStopped
            }
        ) else {
            if isRoot {
                stream.pushFatal(MacEvenError(localized("无法枚举扫描入口。")))
            } else {
                let issue = ScanIssue(path: dirURL.path, category: .other, message: localized("无法枚举目录"))
                stream.pushError(issue)
            }
            return
        }

        while !coordinator.token.isCancelled && !coordinator.isStopped {
            let next = autoreleasepool { enumerator.nextObject() as? URL }
            guard let url = next else { break }

            autoreleasepool {
                let level = enumerator.level
                let absoluteLevel = baseLevel + level
                while directoryAncestors.count > 1 && directoryAncestors.last!.level >= absoluteLevel {
                    directoryAncestors.removeLast()
                }
                let path = url.path

                if path == indexURL.path || path.hasPrefix(indexURL.path + "-") ||
                    path == "/System/Volumes" || path == "/Volumes" ||
                    (!requireCompleteTraversal && (url.lastPathComponent == ".Trash" || url.lastPathComponent == ".Trashes")) {
                    if requireCompleteTraversal {
                        let issue = ScanIssue(path: path, category: .excluded, message: localized("扫描范围包含不可遍历路径：\(path)"))
                        localBatch.append(.error(issue, absoluteLevel))
                    } else {
                        localBatch.append(.boundary(absoluteLevel))
                    }
                    if localBatch.count >= 64 { flushBatch() }
                    if (try? FileIdentity.read(url).isDirectory) == true {
                        enumerator.skipDescendants()
                    }
                    return
                }

                let info: FileIdentity
                do {
                    info = try FileIdentity.read(url)
                } catch {
                    let issue = ScanIssue(error: error, url: url)
                    localBatch.append(.error(issue, absoluteLevel))
                    if localBatch.count >= 64 {
                        flushBatch()
                    }
                    return
                }

                if info.device != rootDevice {
                    if requireCompleteTraversal {
                        let issue = ScanIssue(path: path, category: .excluded, message: localized("扫描范围包含其他卷：\(path)"))
                        localBatch.append(.error(issue, absoluteLevel))
                    } else {
                        localBatch.append(.boundary(absoluteLevel))
                    }
                    if localBatch.count >= 64 { flushBatch() }
                    if info.isDirectory {
                        enumerator.skipDescendants()
                    }
                    return
                }

                if info.isDirectory {
                    let aliasesAncestor = directoryAncestors.contains {
                        $0.identity.device == info.device && $0.identity.inode == info.inode
                    }
                    directoryAncestors.append((absoluteLevel, info))
                    localBatch.append(.entry(url, info, absoluteLevel))
                    if localBatch.count >= 64 { flushBatch() }

                    // Preserve ancestor-cycle handling when starting a fresh enumerator.
                    if !aliasesAncestor && coordinator.tryAcquirePermit() {
                        let childStream = coordinator.createStream()
                        localBatch.append(.childStream(childStream))
                        flushBatch()

                        enumerator.skipDescendants()

                        coordinator.group.enter()
                        let childAncestors = directoryAncestors
                        DispatchQueue.global(qos: .utility).async {
                            defer { coordinator.group.leave() }
                            // Drain Foundation enumeration resources before notifying waiters.
                            autoreleasepool {
                                runProducer(
                                    dirURL: url,
                                    baseLevel: absoluteLevel,
                                    rootDevice: rootDevice,
                                    requireCompleteTraversal: requireCompleteTraversal,
                                    indexURL: indexURL,
                                    stream: childStream,
                                    coordinator: coordinator,
                                    ancestors: childAncestors,
                                    isRoot: false
                                )
                            }
                        }
                    } else {
                        if localBatch.count >= 64 {
                            flushBatch()
                        }
                    }
                } else {
                    localBatch.append(.entry(url, info, absoluteLevel))
                    if localBatch.count >= 64 {
                        flushBatch()
                    }
                }
            }
        }

        flushBatch()
    }

    private static func lastComponent(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    public static func scan(
        root: URL,
        index: DiskIndex,
        token: CancellationToken,
        // 仅对 ordinaryFilesOnly 生效：小于门槛的普通文件只计数不入索引；排除路径整棵跳过且不算错误。
        minimumFileSize: Int64 = 0,
        excludedPaths: [String] = [],
        resetIndex: Bool = true,
        requireCompleteTraversal: Bool = false,
        ordinaryFilesOnly: Bool = false,
        purposes: PurposeClassifier? = nil,
        progress: @Sendable (ScanProgress) -> Void = { _ in }
    ) throws -> ScanSummary {
        let identity = try FileIdentity.read(root.standardizedFileURL)
        guard identity.isDirectory && !identity.isSymlink else {
            throw MacEvenError(localized("扫描入口必须是实际目录，不能是符号链接。"))
        }
        if ordinaryFilesOnly && ((try? root.resourceValues(forKeys: [.isPackageKey]).isPackage) == true || root.pathExtension == "app" || root.pathExtension == "bundle") {
            throw MacEvenError(localized("扫描入口不能是软件包。"))
        }
        let root = try canonicalFileURL(root)
        let start = Date()
        var lastUpdate = Date.distantPast
        var visited = 0
        var logicalTotal: Int64 = 0
        var allocatedTotal: Int64 = 0
        var issueLog = ScanIssueLog()
        var filteredSmall = 0, filteredShared = 0

        if resetIndex { try index.reset() }
        try index.begin()

        let coordinator = Coordinator(token: token)
        coordinator.acquireRootPermit()
        let rootStream = coordinator.createStream()

        do {
            // 扫描根即使只有继承来的标签也算用途边界，代表扫描范围之外的祖先目录。
            let rootTrail = purposes?.trail(for: root.path, isDirectory: true)
            let rootTag = rootTrail?.tag
            let rootNode = try index.insert(parent: 0, url: root, identity: identity, purpose: rootTag?.rawValue ?? 0)
            var stack = [Directory(id: rootNode.id, level: 0, trail: rootTrail, tag: rootTag)]

            // 未归属的字节交给父目录；不可继承的用途边界不接收（与列表标签一致，其下内容算“未识别”）。
            func pass(_ bytes: Int64) {
                guard purposes != nil, bytes > 0, let last = stack.indices.last, stack[last].tag?.heritable ?? true else { return }
                stack[last].carry += bytes
            }

            func finishDirectory() throws {
                let dir = stack.removeLast()
                try index.setTotals(id: dir.id, logical: dir.logical, allocated: dir.allocated, purposeBytes: dir.tag == nil ? nil : dir.carry)
                if !stack.isEmpty {
                    stack[stack.count - 1].logical += dir.logical
                    stack[stack.count - 1].allocated += dir.allocated
                    if dir.tag == nil { pass(dir.carry) }
                }
            }

            func consume(stream: ProducerStream) throws {
                while let item = stream.popNextItem() {
                    if token.isCancelled || coordinator.isStopped {
                        break
                    }
                    switch item {
                    case .entry(let url, let info, let level):
                        while stack.count > 1 && stack.last!.level >= level {
                            try finishDirectory()
                        }
                        // 名称取自路径字符串：消费端没有 autorelease 池，避免为每个条目留下桥接对象。
                        let trail = stack.last!.trail.flatMap { parent in
                            purposes?.child(of: parent, name: Self.lastComponent(url.path), isDirectory: info.isDirectory)
                        }
                        let tag = trail?.ownTag
                        let node = try index.insert(parent: stack.last!.id, url: url, identity: info, purpose: tag?.rawValue ?? 0)
                        visited += 1
                        logicalTotal += node.logical
                        allocatedTotal += node.allocated
                        if info.isDirectory {
                            stack.append(Directory(id: node.id, level: level, trail: trail, tag: tag))
                        } else {
                            stack[stack.count - 1].logical += node.logical
                            stack[stack.count - 1].allocated += node.allocated
                            if tag == nil { pass(node.allocated) }
                        }
                        if visited % 10000 == 0 {
                            try index.commit()
                            try index.begin()
                        }
                        if Date().timeIntervalSince(lastUpdate) >= 0.25 {
                            lastUpdate = Date()
                            progress(ScanProgress(
                                visited: visited + filteredSmall + filteredShared,
                                logicalSize: logicalTotal,
                                allocatedSize: allocatedTotal,
                                currentPath: String(url.path.prefix(1000)),
                                elapsed: Date().timeIntervalSince(start),
                                errors: issueLog.count,
                                unpathedErrors: issueLog.unpathedErrors
                            ))
                        }

                    case .boundary(let level):
                        while stack.count > 1 && stack.last!.level >= level {
                            try finishDirectory()
                        }

                    case .filtered(let small, let shared):
                        filteredSmall += small
                        filteredShared += shared

                    case .error(let issue, let level):
                        if let level {
                            while stack.count > 1 && stack.last!.level >= level {
                                try finishDirectory()
                            }
                        }
                        issueLog.record(issue)

                    case .fatal(let fatalError):
                        throw fatalError

                    case .childStream(let childStream):
                        defer {
                            coordinator.unregisterStream(childStream)
                            coordinator.releasePermit()
                        }
                        try consume(stream: childStream)
                    }
                }
            }

            // The caller alone owns SQLite; producers only read metadata.
            let indexURL = index.url
            coordinator.group.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { coordinator.group.leave() }
                // Drain Foundation enumeration resources before notifying waiters.
                autoreleasepool {
                    if ordinaryFilesOnly {
                        let filter = BulkFilter(rootDevice: identity.device, minimumFileSize: max(1, minimumFileSize),
                                                excludedPaths: Set(excludedPaths), indexURL: indexURL)
                        runBulkProducer(dirPath: root.path, baseLevel: 0, filter: filter, stream: rootStream,
                                        coordinator: coordinator, ancestors: [(0, identity)], isRoot: true)
                    } else {
                        runProducer(
                            dirURL: root,
                            baseLevel: 0,
                            rootDevice: identity.device,
                            requireCompleteTraversal: requireCompleteTraversal,
                            indexURL: indexURL,
                            stream: rootStream,
                            coordinator: coordinator,
                            ancestors: [(0, identity)],
                            isRoot: true
                        )
                    }
                }
            }

            try consume(stream: rootStream)
            coordinator.unregisterStream(rootStream)
            coordinator.releasePermit()

            if token.isCancelled {
                coordinator.stop()
                coordinator.wait()
                while !stack.isEmpty { try finishDirectory() }
                try index.commit()
                progress(ScanProgress(
                    visited: visited,
                    logicalSize: logicalTotal,
                    allocatedSize: allocatedTotal,
                    currentPath: root.path,
                    elapsed: Date().timeIntervalSince(start),
                    errors: issueLog.count,
                    unpathedErrors: issueLog.unpathedErrors
                ))
                return ScanSummary(
                    rootID: rootNode.id,
                    visited: visited,
                    cancelled: true,
                    errors: issueLog.count,
                    errorExamples: issueLog.issues.map(\.formattedText),
                    elapsed: Date().timeIntervalSince(start),
                    unpathedErrors: issueLog.unpathedErrors,
                    issues: issueLog.issues,
                    filteredSmall: filteredSmall,
                    filteredShared: filteredShared
                )
            }

            coordinator.wait()
            while !stack.isEmpty { try finishDirectory() }
            try index.commit()
            progress(ScanProgress(
                visited: visited,
                logicalSize: logicalTotal,
                allocatedSize: allocatedTotal,
                currentPath: root.path,
                elapsed: Date().timeIntervalSince(start),
                errors: issueLog.count,
                unpathedErrors: issueLog.unpathedErrors
            ))
            return ScanSummary(
                rootID: rootNode.id,
                visited: visited,
                cancelled: token.isCancelled,
                errors: issueLog.count,
                errorExamples: issueLog.issues.map(\.formattedText),
                elapsed: Date().timeIntervalSince(start),
                unpathedErrors: issueLog.unpathedErrors,
                issues: issueLog.issues,
                filteredSmall: filteredSmall,
                filteredShared: filteredShared
            )

        } catch {
            coordinator.stop()
            coordinator.wait()
            index.rollback()
            throw error
        }
    }
}
