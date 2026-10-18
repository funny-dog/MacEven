import Foundation
import Darwin
import SQLite3
import MacEvenCore

// MARK: - SQLite 独立连接辅助函数

private func openSQLite(at url: URL, readonly: Bool = false) throws -> OpaquePointer {
    var db: OpaquePointer?
    let flags = readonly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
    guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK, let db else {
        let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "打开数据库连接失败"
        if let db { sqlite3_close(db) }
        throw MacEvenError("SQLite 打开失败: \(url.path) - \(msg)")
    }
    sqlite3_busy_timeout(db, 5000)
    return db
}

private func execSQLite(db: OpaquePointer, sql: String) throws {
    var errmsg: UnsafeMutablePointer<CChar>?
    if sqlite3_exec(db, sql, nil, nil, &errmsg) != SQLITE_OK {
        let msg = errmsg.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
        sqlite3_free(errmsg)
        throw MacEvenError("SQLite 执行失败 (\(sql)): \(msg)")
    }
}

private func queryCount(url: URL, table: String = "nodes") throws -> Int64 {
    let db = try openSQLite(at: url, readonly: true)
    defer { sqlite3_close(db) }
    var stmt: OpaquePointer?
    let sql = "SELECT COUNT(*) FROM \(table);"
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
        throw MacEvenError("SQLite 准备查询失败: \(String(cString: sqlite3_errmsg(db)))")
    }
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_step(stmt) == SQLITE_ROW else {
        throw MacEvenError("SQLite 查询执行失败: \(String(cString: sqlite3_errmsg(db)))")
    }
    return sqlite3_column_int64(stmt, 0)
}

// MARK: - 文件描述符获取 (基于 proc_pidinfo)

private func descriptorCount() throws -> Int {
    var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: 4096)
    let bytes = descriptors.withUnsafeMutableBytes { buffer in
        proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
    }
    guard bytes > 0 && bytes < 4096 * MemoryLayout<proc_fdinfo>.stride else {
        throw MacEvenError("proc_pidinfo(PROC_PIDLISTFDS) 获取失败或缓冲区溢出: bytes=\(bytes)")
    }
    return Int(bytes) / MemoryLayout<proc_fdinfo>.stride
}

// MARK: - 索引项遍历辅助函数

private func allChildren(of id: Int64, in index: DiskIndex) throws -> [DiskEntry] {
    var result: [DiskEntry] = []
    var offset = 0
    while true {
        let page = try index.children(of: id, offset: offset, limit: 100)
        if page.isEmpty { break }
        result.append(contentsOf: page)
        if page.count < 100 { break }
        offset += page.count
    }
    return result
}

// MARK: - 检查点 1: 空目录最终 progress 回调取消状态

private func checkEmptyDirectoryCancellation() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("MacEven-concurrency-empty-\(UUID())")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }

    let dbURL = root.appendingPathComponent("index.sqlite")
    let index = try DiskIndex(url: dbURL)
    defer { index.close() }

    let token = CancellationToken()
    final class CallbackFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        func set() { lock.withLock { flag = true } }
        var isSet: Bool { lock.withLock { flag } }
    }
    let callbackFlag = CallbackFlag()
    let summary = try Scanner.scan(root: root, index: index, token: token) { _ in
        callbackFlag.set()
        token.cancel()
    }

    guard callbackFlag.isSet else {
        throw MacEvenError("空目录扫描未触发 progress 回调")
    }
    guard summary.cancelled else {
        throw MacEvenError("空目录在最终 progress 回调中取消后，ScanSummary.cancelled 丢失")
    }
    guard summary.visited == 0 && summary.errors == 0 else {
        throw MacEvenError("空目录扫描结果不符: visited=\(summary.visited), errors=\(summary.errors)")
    }
    print("PASS: 空目录最终 progress 回调取消状态")
}

// MARK: - 检查点 2: 多个目录预热后 20 次早期及提交后进度回调取消、大小自洽、FD 无泄漏及重扫准确

private func checkRepeatedCancellationAndFDLeak() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("MacEven-concurrency-repeat-\(UUID())")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }

    // 24 个目录，每个 4096 个文件；断言首次进度回调确实发生在扫描中途。
    let filePayload = Data([0x31])
    for i in 0..<24 {
        let dir = root.appendingPathComponent("directory-\(i)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for j in 0..<4096 {
            try filePayload.write(to: dir.appendingPathComponent("file-\(j)"))
        }
    }

    let dbURL = root.appendingPathComponent("index.sqlite")
    let index = try DiskIndex(url: dbURL)
    defer { index.close() }

    // 预热扫描
    let warm = try Scanner.scan(root: root, index: index, token: CancellationToken())
    guard !warm.cancelled && warm.visited == 98328 && warm.errors == 0 else {
        throw MacEvenError("预热扫描不符合预期: visited=\(warm.visited), errors=\(warm.errors)")
    }

    let initialFDCount = try descriptorCount()

    // 交替在首项进度及至少 10000 项后的进度取消，覆盖已提交批次。
    for iteration in 0..<20 {
        let token = CancellationToken()
        let threshold = iteration % 2 == 0 ? 1 : 10000
        let start = Date()
        let result = try Scanner.scan(root: root, index: index, token: token) { progress in
            if progress.visited >= threshold { token.cancel() }
        }
        guard result.cancelled && result.visited >= threshold && result.visited < 98328 else {
            throw MacEvenError("第 \(iteration + 1) 次扫描未在中途取消: visited=\(result.visited), cancelled=\(result.cancelled)")
        }
        guard Date().timeIntervalSince(start) < 3.0 else {
            throw MacEvenError("第 \(iteration + 1) 次取消扫描耗时超过预期")
        }

        // 部分索引大小自洽性验证
        guard let partial = try index.entry(id: 1) else {
            throw MacEvenError("根节点在第 \(iteration + 1) 次取消扫描后不存在")
        }
        let children = try allChildren(of: 1, in: index)
        let sumAllocated = children.reduce(Int64(0)) { $0 + $1.allocatedSize }
        let sumLogical = children.reduce(Int64(0)) { $0 + $1.logicalSize }
        guard sumAllocated == partial.allocatedSize else {
            throw MacEvenError("第 \(iteration + 1) 次取消扫描部分索引物理大小不自洽: root=\(partial.allocatedSize), children=\(sumAllocated)")
        }
        guard sumLogical == partial.logicalSize else {
            throw MacEvenError("第 \(iteration + 1) 次取消扫描部分索引逻辑大小不自洽: root=\(partial.logicalSize), children=\(sumLogical)")
        }

        // 验证文件描述符不增长
        let currentFD = try descriptorCount()
        guard currentFD == initialFDCount else {
            throw MacEvenError("第 \(iteration + 1) 次取消扫描泄漏文件描述符: initial=\(initialFDCount), current=\(currentFD)")
        }
    }

    // 重扫条目准确
    let restart = try Scanner.scan(root: root, index: index, token: CancellationToken())
    guard !restart.cancelled && restart.visited == 98328 && restart.errors == 0 else {
        throw MacEvenError("重扫扫描结果不准确: visited=\(restart.visited), expected=98328")
    }
    let finalFD = try descriptorCount()
    guard finalFD == initialFDCount else {
        throw MacEvenError("重扫扫描泄漏文件描述符: initial=\(initialFDCount), final=\(finalFD)")
    }
    print("PASS: 预热后 20 次早期及提交后进度回调取消、大小自洽、FD 无泄漏及重扫准确")
}

// MARK: - 检查点 3: 多个子树 SQLite 插入错误（1024条触发）时退出、事务回滚为空

private func checkSubtreeRollbackOnSQLiteError() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("MacEven-concurrency-subtree-fail-\(UUID())")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }

    // 16 个子树，每个 320 个文件 = 5120 个文件 + 16 个子树 = 5136 项，远超 1024
    let dummy = Data([0x78])
    for i in 0..<16 {
        let dir = root.appendingPathComponent("subtree-\(i)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for j in 0..<320 {
            fm.createFile(atPath: dir.appendingPathComponent("file-\(j)").path, contents: dummy)
        }
    }

    let dbURL = root.appendingPathComponent("index.sqlite")
    let index = try DiskIndex(url: dbURL)
    defer { index.close() }

    // 扫描前用独立 SQLite 连接创建触发器 (1024 条触发)
    let db = try openSQLite(at: dbURL, readonly: false)
    try execSQLite(db: db, sql: "CREATE TRIGGER injected_failure BEFORE INSERT ON nodes WHEN (SELECT COUNT(*) FROM nodes)>=1024 BEGIN SELECT RAISE(ABORT,'injected'); END;")
    sqlite3_close(db)

    let token = CancellationToken()
    var didCatchError = false
    let start = Date()
    do {
        _ = try Scanner.scan(root: root, index: index, token: token)
    } catch {
        didCatchError = true
    }

    let elapsed = Date().timeIntervalSince(start)
    guard didCatchError else {
        throw MacEvenError("预期 1024 条插入错误，但扫描正常返回而未抛出错误")
    }
    guard elapsed < 5.0 else {
        throw MacEvenError("SQLite 插入错误后退出耗时过长: \(elapsed)s")
    }

    // 扫描返回后只读查询 count，事务回滚为空
    let count = try queryCount(url: dbURL, table: "nodes")
    guard count == 0 else {
        throw MacEvenError("SQLite 插入错误后事务未回滚为空: nodes count=\(count)")
    }
    print("PASS: 1024 条 SQLite 插入错误退出且事务回滚为空")
}

// MARK: - 检查点 4: 10000 提交后的 10100 插入失败，严格保留 10001 行后去除触发器重扫成功

private func checkPostCommitFailureRetainsCommittedRows() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("MacEven-concurrency-committed-fail-\(UUID())")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }

    // 生成至少 12000 项数据 (2 个 group，12 个 leaf，12000 个文件 = 12014 项)
    let dummy = Data([0x78])
    for i in 0..<12000 {
        let groupName = String(format: "group-%03d", i / 10000)
        let leafName = String(format: "leaf-%04d", i / 1000)
        let dir = root.appendingPathComponent(groupName).appendingPathComponent(leafName)
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        fm.createFile(atPath: dir.appendingPathComponent(String(format: "file-%07d", i)).path, contents: dummy)
    }

    let dbURL = root.appendingPathComponent("index.sqlite")
    let index = try DiskIndex(url: dbURL)
    defer { index.close() }

    // 扫描前用独立 SQLite 连接创建触发器 (10100 条触发)
    let db = try openSQLite(at: dbURL, readonly: false)
    try execSQLite(db: db, sql: "CREATE TRIGGER injected_failure BEFORE INSERT ON nodes WHEN (SELECT COUNT(*) FROM nodes)>=10100 BEGIN SELECT RAISE(ABORT,'injected'); END;")
    sqlite3_close(db)

    var didCatchError = false
    do {
        _ = try Scanner.scan(root: root, index: index, token: CancellationToken())
    } catch {
        didCatchError = true
    }

    guard didCatchError else {
        throw MacEvenError("预期 10100 条插入错误，但扫描正常返回而未抛出错误")
    }

    // 扫描返回后只读查询 count，严格保留 10001 行已提交数据
    let count = try queryCount(url: dbURL, table: "nodes")
    guard count == 10001 else {
        throw MacEvenError("10100 插入失败后保留行数不正确，期望 10001，实际为 \(count)")
    }

    // 用独立 SQLite 连接去除触发器
    let writeDB = try openSQLite(at: dbURL, readonly: false)
    try execSQLite(db: writeDB, sql: "DROP TRIGGER injected_failure;")
    sqlite3_close(writeDB)

    // 重扫成功
    let restart = try Scanner.scan(root: root, index: index, token: CancellationToken())
    guard !restart.cancelled && restart.errors == 0 else {
        throw MacEvenError("去除触发器后重扫失败: visited=\(restart.visited), errors=\(restart.errors)")
    }
    guard restart.visited == 12014 else {
        throw MacEvenError("重扫条目数不符合预期: visited=\(restart.visited), expected=12014")
    }

    let finalCount = try queryCount(url: dbURL, table: "nodes")
    guard finalCount == Int64(restart.visited + 1) else {
        throw MacEvenError("重扫后数据库行数不一致: nodes=\(finalCount), visited=\(restart.visited)")
    }
    print("PASS: 10000 提交后 10100 插入失败严格保留 10001 行，去除触发器重扫成功")
}

// MARK: - 主入口

func runConcurrencyChecks() throws {
    print("--> 开始运行并发回归检查 (runConcurrencyChecks)...")
    try checkEmptyDirectoryCancellation()
    try checkRepeatedCancellationAndFDLeak()
    try checkSubtreeRollbackOnSQLiteError()
    try checkPostCommitFailureRetainsCommittedRows()
    print("PASS: 全部并发回归检查通过")
}
