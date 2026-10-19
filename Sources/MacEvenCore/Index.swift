import Foundation
import SQLite3

// Owned by one worker queue. Never pass the connection to the main thread.
public final class DiskIndex {
    public let url: URL
    private var db: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(url: URL) throws {
        self.url = try canonicalFileURL(url.deletingLastPathComponent()).appendingPathComponent(url.lastPathComponent)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            let error = failure(); if let db { sqlite3_close(db) }; self.db = nil; throw error
        }
        do {
            try execute("PRAGMA cache_size=-16384; PRAGMA mmap_size=0; PRAGMA temp_store=FILE; PRAGMA journal_mode=DELETE; PRAGMA synchronous=NORMAL;")
            try execute("""
                CREATE TABLE IF NOT EXISTS nodes(
                    id INTEGER PRIMARY KEY, parent INTEGER NOT NULL, path TEXT NOT NULL,
                    device INTEGER, inode INTEGER, mode INTEGER, size INTEGER, modified INTEGER, changed INTEGER, blocks INTEGER,
                    ownLogical INTEGER, ownAllocated INTEGER, logical INTEGER, allocated INTEGER, duplicate INTEGER,
                    category INTEGER NOT NULL DEFAULT 0, purpose INTEGER NOT NULL DEFAULT 0, purposeBytes INTEGER NOT NULL DEFAULT 0);
                CREATE INDEX IF NOT EXISTS children ON nodes(parent, allocated DESC, logical DESC, id);
                CREATE INDEX IF NOT EXISTS purposes ON nodes(purpose, purposeBytes DESC) WHERE purpose<>0;
                CREATE INDEX IF NOT EXISTS identity ON nodes(device,inode);
                CREATE INDEX IF NOT EXISTS file_ranking ON nodes(allocated DESC,logical DESC,id) WHERE (mode & 61440)=32768 AND duplicate=0;
                CREATE INDEX IF NOT EXISTS file_paths ON nodes(path) WHERE (mode & 61440)=32768 AND duplicate=0;
                CREATE TABLE IF NOT EXISTS seen(device INTEGER,inode INTEGER,PRIMARY KEY(device,inode)) WITHOUT ROWID;
                CREATE TABLE IF NOT EXISTS duplicate_files(
                    node_id INTEGER PRIMARY KEY, size INTEGER NOT NULL, digest BLOB, sample BLOB);
                CREATE INDEX IF NOT EXISTS duplicate_size ON duplicate_files(size, node_id);
                CREATE INDEX IF NOT EXISTS duplicate_sample ON duplicate_files(size, sample);
                CREATE INDEX IF NOT EXISTS duplicate_digest ON duplicate_files(size, digest, node_id);
                """)
        } catch { close(); throw error }
    }

    deinit { close() }
    public func close() {
        statements.values.forEach { sqlite3_finalize($0) }; statements.removeAll()
        if let db { sqlite3_close(db) }; db = nil
    }
    func failure() -> MacEvenError {
        MacEvenError(localized("磁盘索引：\(db.map { String(cString: sqlite3_errmsg($0)) } ?? localized("连接失败"))"))
    }
    func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    func statement(_ sql: String) throws -> OpaquePointer {
        if let cached = statements[sql] { sqlite3_reset(cached); sqlite3_clear_bindings(cached); return cached }
        var result: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &result, nil) == SQLITE_OK, let result else { throw failure() }
        statements[sql] = result; return result
    }
    func bind(_ values: [Int64], to stmt: OpaquePointer, from: Int32 = 1) throws {
        for (offset, value) in values.enumerated() {
            guard sqlite3_bind_int64(stmt, from + Int32(offset), value) == SQLITE_OK else { throw failure() }
        }
    }
    func done(_ stmt: OpaquePointer) throws {
        defer { sqlite3_reset(stmt) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
    }
    func reset() throws { try execute("DELETE FROM nodes; DELETE FROM seen; DELETE FROM duplicate_files;") }
    func begin() throws { try execute("BEGIN IMMEDIATE") }
    func commit() throws { try execute("COMMIT") }
    func rollback() { try? execute("ROLLBACK") }

    /// purpose 非 0 表示用途边界；文件边界的用途占用就是它自己，目录边界在 setTotals 时写入。
    func insert(parent: Int64, url: URL, identity: FileIdentity, purpose: Int64 = 0) throws -> (id: Int64, logical: Int64, allocated: Int64) {
        var duplicate = false
        if identity.isRegular {
            let seen = try statement("INSERT OR IGNORE INTO seen VALUES(?,?)")
            try bind([identity.device, identity.inode], to: seen); try done(seen)
            duplicate = sqlite3_changes(db) == 0
        }
        let logical = identity.isRegular && !duplicate ? identity.size : 0
        let allocated = identity.isRegular && !duplicate ? identity.allocated : 0
        let category: Int64 = identity.isRegular ? Int64(FileCategory.classify(url).rawValue) : Int64(FileCategory.other.rawValue)
        let stmt = try statement("""
            INSERT INTO nodes(
                parent, path, device, inode, mode, size, modified, changed, blocks,
                ownLogical, ownAllocated, logical, allocated, duplicate, category, purpose, purposeBytes
            ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """)
        try bind([parent], to: stmt)
        guard sqlite3_bind_text(stmt, 2, url.path, -1, transient) == SQLITE_OK else { throw failure() }
        try bind([identity.device, identity.inode, identity.mode, identity.size, identity.modified, identity.changed,
            identity.allocated, logical, allocated, logical, allocated, duplicate ? 1 : 0, category, purpose, purpose == 0 ? 0 : allocated], to: stmt, from: 3)
        try done(stmt)
        return (sqlite3_last_insert_rowid(db), logical, allocated)
    }
    func setTotals(id: Int64, logical: Int64, allocated: Int64, purposeBytes: Int64? = nil) throws {
        if let purposeBytes {
            let stmt = try statement("UPDATE nodes SET logical=?,allocated=?,purposeBytes=? WHERE id=?")
            try bind([logical,allocated,purposeBytes,id], to: stmt); try done(stmt)
        } else {
            let stmt = try statement("UPDATE nodes SET logical=?,allocated=? WHERE id=?")
            try bind([logical,allocated,id], to: stmt); try done(stmt)
        }
    }
    let columns = "id,parent,path,device,inode,mode,size,modified,changed,blocks,logical,allocated,duplicate"
    private let nodeColumns = "n.id,n.parent,n.path,n.device,n.inode,n.mode,n.size,n.modified,n.changed,n.blocks,n.logical,n.allocated,n.duplicate"
    func decode(_ s: OpaquePointer) -> DiskEntry {
        func n(_ column: Int32) -> Int64 { sqlite3_column_int64(s, column) }
        let path = String(cString: sqlite3_column_text(s, 2))
        return DiskEntry(id: n(0), parentID: n(1), url: URL(fileURLWithPath: path),
            identity: FileIdentity(device: n(3), inode: n(4), mode: n(5), size: n(6), modified: n(7), changed: n(8), allocated: n(9)),
            logicalSize: n(10), allocatedSize: n(11), duplicate: n(12) != 0)
    }
    private func rows(_ sql: String, values: [Int64]) throws -> [DiskEntry] {
        let stmt = try statement(sql); try bind(values, to: stmt)
        defer { sqlite3_reset(stmt) }
        return try decodeRows(stmt)
    }
    private func rows(_ sql: String, texts: [String], values: [Int64]) throws -> [DiskEntry] {
        let stmt = try statement(sql)
        for (offset, text) in texts.enumerated() {
            guard sqlite3_bind_text(stmt, Int32(offset + 1), text, -1, transient) == SQLITE_OK else { throw failure() }
        }
        try bind(values, to: stmt, from: Int32(texts.count + 1))
        defer { sqlite3_reset(stmt) }
        return try decodeRows(stmt)
    }
    private func decodeRows(_ stmt: OpaquePointer) throws -> [DiskEntry] {
        var result: [DiskEntry] = []
        while true {
            let code = sqlite3_step(stmt)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw failure() }
            result.append(decode(stmt))
        }
        return result
    }
    public func entry(id: Int64) throws -> DiskEntry? {
        try rows("SELECT \(columns) FROM nodes WHERE id=?", values: [id]).first
    }
    public func children(of id: Int64, offset: Int = 0, limit: Int = 100) throws -> [DiskEntry] {
        try rows("SELECT \(columns) FROM nodes WHERE parent=? ORDER BY allocated DESC,logical DESC,id LIMIT ? OFFSET ?",
            values: [id,Int64(max(0,min(limit,100))),Int64(max(0,offset))])
    }
    public func largestFiles(limit: Int = 100, offset: Int = 0) throws -> [DiskEntry] {
        try rows("SELECT \(columns) FROM nodes WHERE (mode & 61440)=32768 AND duplicate=0 ORDER BY allocated DESC,logical DESC,id LIMIT ? OFFSET ?",
            values: [Int64(max(0,min(limit,100))), Int64(max(0,offset))])
    }

    /// 可清理范围粗筛：普通文件、位于主目录内、非 Library、无隐藏组件、不在应用包内部。
    /// 最终是否可清理仍由 TrashService.blockKind 逐项复核，索引查询只负责缩小候选集。
    public func largestCleanableFiles(homePath: String, limit: Int = 100, offset: Int = 0) throws -> [DiskEntry] {
        let base = homePath.hasSuffix("/") ? String(homePath.dropLast()) : homePath
        let homePrefix = base + "/"
        let libraryPrefix = base + "/Library/"
        return try rows("""
            SELECT \(columns) FROM nodes
            WHERE (mode & 61440)=32768 AND duplicate=0
            AND instr(path, ?) = 1
            AND instr(path, ?) = 0
            AND instr(path, '/.') = 0
            AND instr(path, '.app/') = 0
            AND instr(path, '.bundle/') = 0
            ORDER BY allocated DESC,logical DESC,id LIMIT ? OFFSET ?
            """, texts: [homePrefix, libraryPrefix],
            values: [Int64(max(0,min(limit,100))), Int64(max(0,offset))])
    }

    public func ancestors(of id: Int64) throws -> [DiskEntry] {
        var result: [DiskEntry] = []; var current = try entry(id: id)
        while let item = current { result.append(item); current = item.parentID == 0 ? nil : try entry(id: item.parentID) }
        return result.reversed()
    }

    public func validateSubtree(id: Int64) throws {
        let cursor = try statement("WITH RECURSIVE tree(id) AS (SELECT ? UNION ALL SELECT nodes.id FROM nodes JOIN tree ON nodes.parent=tree.id) SELECT \(columns) FROM nodes JOIN tree USING(id)")
        try bind([id], to: cursor)
        defer { sqlite3_reset(cursor) }
        var count = 0
        while true {
            let code = sqlite3_step(cursor)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw failure() }
            let item = decode(cursor)
            guard try FileIdentity.read(item.url) == item.identity else { throw MacEvenError(localized("文件或目录已变化，请重新扫描：\(item.url.path)")) }
            count += 1
        }
        guard count > 0 else { throw MacEvenError(localized("扫描索引已失效，请重新扫描。")) }
    }

    // 应用正常退出后的写入可重新统计；目录入口仍必须是原来的实际目录。
    func rescanAfterApplicationQuit(id: Int64, token: CancellationToken) throws -> Int64 {
        guard !token.isCancelled, let old = try entry(id: id) else { throw MacEvenError(localized("操作已取消或索引失效，请重新扫描。")) }
        let fresh = try FileIdentity.read(old.url)
        guard fresh.device == old.identity.device, fresh.mode == old.identity.mode,
            old.isDirectory ? fresh.inode == old.identity.inode : fresh.isRegular else { throw MacEvenError(localized("清理入口已被替换，请重新扫描。")) }
        try removeSubtree(id: id)
        let newID: Int64
        if fresh.isDirectory {
            let summary = try Scanner.scan(root: old.url, index: self, token: token, resetIndex: false, requireCompleteTraversal: true)
            guard !summary.cancelled, summary.errors == 0 else { throw MacEvenError(localized("退出后未能完整统计，请重新扫描：\(old.url.path)")) }
            newID = summary.rootID
        } else { newID = try insert(parent: 0, url: old.url, identity: fresh).id }
        let current = try FileIdentity.read(old.url)
        guard !token.isCancelled, current.device == fresh.device, current.inode == fresh.inode, current.mode == fresh.mode else { throw MacEvenError(localized("清理入口再次变化，内容已保留。")) }
        try validateSubtree(id: newID)
        return newID
    }

    func removeSubtree(id: Int64) throws {
        guard let removed = try entry(id: id) else { return }
        try begin()
        do {
            try execute("""
                CREATE TEMP TABLE IF NOT EXISTS removal_nodes(id INTEGER PRIMARY KEY);
                CREATE TEMP TABLE IF NOT EXISTS removal_identities(device INTEGER,inode INTEGER,PRIMARY KEY(device,inode)) WITHOUT ROWID;
                DELETE FROM removal_nodes; DELETE FROM removal_identities;
                """)
            let collect = try statement("WITH RECURSIVE tree(id) AS (SELECT ? UNION ALL SELECT n.id FROM nodes n JOIN tree t ON n.parent=t.id) INSERT INTO removal_nodes SELECT id FROM tree")
            try bind([id], to: collect); try done(collect)
            try execute("INSERT OR IGNORE INTO removal_identities SELECT device,inode FROM nodes WHERE id IN removal_nodes AND (mode & 61440)=32768 AND duplicate=0")
            // 只有未遇到用途边界的字节会继续归给被删目录之外的祖先。
            let carry = try statement("""
                WITH RECURSIVE carry(id) AS (
                    SELECT id FROM nodes WHERE id=? AND purpose=0
                    UNION ALL SELECT n.id FROM nodes n JOIN carry c ON n.parent=c.id WHERE n.purpose=0
                ) SELECT COALESCE(SUM(ownAllocated),0) FROM nodes WHERE id IN carry
                """)
            try bind([id], to: carry)
            guard sqlite3_step(carry) == SQLITE_ROW else { throw failure() }
            let unassigned = sqlite3_column_int64(carry, 0)
            sqlite3_reset(carry)
            try execute("DELETE FROM duplicate_files WHERE node_id IN removal_nodes; DELETE FROM nodes WHERE id IN removal_nodes;")
            try adjustAncestors(from: removed.parentID, logical: -removed.logicalSize, allocated: -removed.allocatedSize)
            try adjustPurpose(from: removed.parentID, bytes: -unassigned)

            // 只为失去计数所有者的硬链接寻找下一份；其他文件及目录不重写。
            let owners = try statement("""
                SELECT MIN(n.id) FROM removal_identities r JOIN nodes n ON n.device=r.device AND n.inode=r.inode
                WHERE (n.mode & 61440)=32768 GROUP BY r.device,r.inode
                """)
            defer { sqlite3_reset(owners) }
            while true {
                let code = sqlite3_step(owners)
                if code == SQLITE_DONE { break }
                guard code == SQLITE_ROW, let owner = try entry(id: sqlite3_column_int64(owners, 0)) else { throw failure() }
                guard owner.duplicate else { continue }
                let update = try statement("UPDATE nodes SET duplicate=0,ownLogical=size,ownAllocated=blocks,logical=size,allocated=blocks WHERE id=?")
                try bind([owner.id], to: update); try done(update)
                try adjustAncestors(from: owner.parentID, logical: owner.identity.size, allocated: owner.identity.allocated)
                try adjustPurpose(from: owner.id, bytes: owner.identity.allocated, ownBoundary: true)
            }
            try execute("""
                DELETE FROM seen WHERE (device,inode) IN (SELECT device,inode FROM removal_identities)
                AND NOT EXISTS (SELECT 1 FROM nodes n WHERE n.device=seen.device AND n.inode=seen.inode AND (n.mode & 61440)=32768);
                DELETE FROM removal_nodes; DELETE FROM removal_identities;
                """)
            try commit()
        } catch { rollback(); throw error }
    }

    private func adjustAncestors(from id: Int64, logical: Int64, allocated: Int64) throws {
        var current = id
        while current != 0 {
            guard let node = try entry(id: current) else { throw failure() }
            let update = try statement("UPDATE nodes SET logical=logical+?,allocated=allocated+? WHERE id=?")
            try bind([logical, allocated, current], to: update); try done(update)
            current = node.parentID
        }
    }

    private func adjustPurpose(from id: Int64, bytes: Int64, ownBoundary: Bool = false) throws {
        guard bytes != 0 else { return }
        var current = id
        while current != 0 {
            let cursor = try statement("SELECT parent,purpose FROM nodes WHERE id=?")
            try bind([current], to: cursor)
            guard sqlite3_step(cursor) == SQLITE_ROW else { throw failure() }
            let parent = sqlite3_column_int64(cursor, 0), tag = sqlite3_column_int64(cursor, 1)
            sqlite3_reset(cursor)
            if tag != 0 {
                if (current == id && ownBoundary) || PurposeTag.isHeritable(tag) {
                    let update = try statement("UPDATE nodes SET purposeBytes=purposeBytes+? WHERE id=?")
                    try bind([bytes, current], to: update); try done(update)
                }
                return
            }
            current = parent
        }
    }

    /// 按用途标记汇总：每种标记有归属字节的边界数量与归属字节数。没有用途扫描时为空。
    public func purposeTotals() throws -> [PurposeTotal] {
        let stmt = try statement("SELECT purpose,SUM(purposeBytes>0),COALESCE(SUM(purposeBytes),0) FROM nodes WHERE purpose<>0 GROUP BY purpose")
        defer { sqlite3_reset(stmt) }
        var result: [PurposeTotal] = []
        while true {
            let code = sqlite3_step(stmt)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw failure() }
            if let tag = PurposeTag(rawValue: sqlite3_column_int64(stmt, 0)) {
                result.append(PurposeTotal(tag: tag, count: sqlite3_column_int64(stmt, 1), bytes: sqlite3_column_int64(stmt, 2)))
            }
        }
        return result
    }

    /// 某几种用途下归属字节最多的位置，每页最多 100 项；归属为 0 的边界不列出。
    public func purposePage(tags: [PurposeTag], offset: Int = 0, limit: Int = 100) throws -> PurposePage {
        guard !tags.isEmpty else { return PurposePage(entries: [], bytes: [:], hasNext: false) }
        let cappedLimit = Int64(max(0, min(limit, 100)))
        let placeholders = Array(repeating: "?", count: tags.count).joined(separator: ",")
        let stmt = try statement("SELECT \(columns),purposeBytes FROM nodes WHERE purpose IN (\(placeholders)) AND purposeBytes>0 ORDER BY purposeBytes DESC,id LIMIT ? OFFSET ?")
        try bind(tags.map(\.rawValue) + [cappedLimit + 1, Int64(max(0, offset))], to: stmt)
        defer { sqlite3_reset(stmt) }
        var entries: [DiskEntry] = [], bytes: [Int64: Int64] = [:]
        while true {
            let code = sqlite3_step(stmt)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw failure() }
            let entry = decode(stmt)
            entries.append(entry); bytes[entry.id] = sqlite3_column_int64(stmt, 13)
        }
        let hasNext = entries.count > Int(cappedLimit)
        if hasNext { bytes[entries.removeLast().id] = nil }
        return PurposePage(entries: entries, bytes: bytes, hasNext: hasNext)
    }

    public func setCancelHandler(token: CancellationToken?) {
        guard let db else { return }
        if let token {
            let unmanaged = Unmanaged.passUnretained(token).toOpaque()
            sqlite3_progress_handler(db, 100, { context in
                guard let context else { return 0 }
                let t = Unmanaged<CancellationToken>.fromOpaque(context).takeUnretainedValue()
                return t.isCancelled ? 1 : 0
            }, unmanaged)
        } else {
            sqlite3_progress_handler(db, 0, nil, nil)
        }
    }

    public func prepareDuplicateCandidates(token: CancellationToken) throws {
        setCancelHandler(token: token)
        defer { setCancelHandler(token: nil) }
        try begin()
        do {
            try execute("DELETE FROM duplicate_files;")
            try execute("""
                INSERT INTO duplicate_files(node_id, size)
                SELECT n.id, n.size
                FROM nodes n
                WHERE (n.mode & 61440) = 32768
                  AND n.size > 0
                  AND n.duplicate = 0
                  AND n.size IN (
                      SELECT size FROM nodes
                      WHERE (mode & 61440) = 32768 AND size > 0 AND duplicate = 0
                      GROUP BY size HAVING COUNT(*) >= 2
                  );
            """)
            try commit()
        } catch {
            rollback()
            throw error
        }
    }

    /// 进度分母：尚未抽样的候选数。
    public func duplicateSampleCount() throws -> Int64 {
        let stmt = try statement("SELECT COUNT(*) FROM duplicate_files WHERE sample IS NULL AND digest IS NULL")
        defer { sqlite3_reset(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw failure() }
        return sqlite3_column_int64(stmt, 0)
    }

    /// 进度分母：尚无最终摘要的候选合计字节数。
    public func duplicatePendingBytes() throws -> Int64 {
        let stmt = try statement("SELECT COALESCE(SUM(size), 0) FROM duplicate_files WHERE digest IS NULL")
        defer { sqlite3_reset(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw failure() }
        return sqlite3_column_int64(stmt, 0)
    }

    /// 实时统计：按（大小, 摘要或抽样）聚类且成员 ≥2 的候选组数、文件数与占用估算。
    /// 物化候选后摘要均为 NULL（按大小聚类）；抽样剪枝后小文件已有最终摘要、大文件回退抽样值；
    /// 扫描结束后与 duplicateGroups() 口径一致（按大小与摘要聚类）。
    public func duplicateCandidateStats() throws -> (groups: Int64, files: Int64, bytes: Int64) {
        let stmt = try statement("""
            SELECT COUNT(*), COALESCE(SUM(files), 0), COALESCE(SUM(bytes), 0) FROM (
                SELECT COUNT(*) AS files, SUM(n.allocated) AS bytes
                FROM duplicate_files d JOIN nodes n ON n.id = d.node_id
                GROUP BY d.size, COALESCE(d.digest, d.sample)
                HAVING COUNT(*) >= 2
            )
            """)
        defer { sqlite3_reset(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw failure() }
        return (sqlite3_column_int64(stmt, 0), sqlite3_column_int64(stmt, 1), sqlite3_column_int64(stmt, 2))
    }

    /// needingSample 为 true 时只返回尚未抽样的候选，否则返回尚无最终摘要的候选。
    public func duplicateCandidatePage(afterID: Int64, limit: Int = 100, needingSample: Bool = false) throws -> [DiskEntry] {
        let pending = needingSample ? "d.sample IS NULL AND d.digest IS NULL" : "d.digest IS NULL"
        let sql = "SELECT \(nodeColumns) FROM duplicate_files d JOIN nodes n ON n.id=d.node_id WHERE d.node_id > ? AND \(pending) ORDER BY d.node_id LIMIT ?"
        let stmt = try statement(sql)
        try bind([afterID, Int64(max(0, min(limit, 100)))], to: stmt)
        defer { sqlite3_reset(stmt) }
        var result: [DiskEntry] = []
        while true {
            let code = sqlite3_step(stmt)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw failure() }
            result.append(decode(stmt))
        }
        return result
    }

    public func storeDuplicateDigests(batch: [(id: Int64, digest: Data)]) throws {
        guard !batch.isEmpty else { return }
        try begin()
        do {
            let stmt = try statement("UPDATE duplicate_files SET digest=? WHERE node_id=?")
            for item in batch {
                sqlite3_reset(stmt); sqlite3_clear_bindings(stmt)
                try item.digest.withUnsafeBytes { raw in
                    guard sqlite3_bind_blob(stmt, 1, raw.baseAddress, Int32(raw.count), transient) == SQLITE_OK else { throw failure() }
                }
                guard sqlite3_bind_int64(stmt, 2, item.id) == SQLITE_OK else { throw failure() }
                try done(stmt)
            }
            try commit()
        } catch {
            rollback()
            throw error
        }
    }

    /// 抽样哈希批量写入；小文件整读时 digest 同时给出最终摘要。
    public func storeDuplicateSamples(batch: [(id: Int64, sample: Data, digest: Data?)]) throws {
        guard !batch.isEmpty else { return }
        try begin()
        do {
            let stmt = try statement("UPDATE duplicate_files SET sample=?, digest=? WHERE node_id=?")
            for item in batch {
                sqlite3_reset(stmt); sqlite3_clear_bindings(stmt)
                try item.sample.withUnsafeBytes { raw in
                    guard sqlite3_bind_blob(stmt, 1, raw.baseAddress, Int32(raw.count), transient) == SQLITE_OK else { throw failure() }
                }
                if let digest = item.digest {
                    try digest.withUnsafeBytes { raw in
                        guard sqlite3_bind_blob(stmt, 2, raw.baseAddress, Int32(raw.count), transient) == SQLITE_OK else { throw failure() }
                    }
                } else {
                    guard sqlite3_bind_null(stmt, 2) == SQLITE_OK else { throw failure() }
                }
                guard sqlite3_bind_int64(stmt, 3, item.id) == SQLITE_OK else { throw failure() }
                try done(stmt)
            }
            try commit()
        } catch {
            rollback()
            throw error
        }
    }

    /// 抽样后剪枝：未抽样的候选，以及（大小, 抽样）组内只剩 1 个的候选都不可能重复。返回剩余候选数。
    @discardableResult
    public func pruneDuplicateSamples(token: CancellationToken) throws -> Int64 {
        setCancelHandler(token: token)
        defer { setCancelHandler(token: nil) }
        try begin()
        do {
            try execute("""
                DELETE FROM duplicate_files WHERE sample IS NULL OR node_id IN (
                    SELECT d.node_id FROM duplicate_files d JOIN (
                        SELECT size, sample FROM duplicate_files WHERE sample IS NOT NULL
                        GROUP BY size, sample HAVING COUNT(*) < 2
                    ) u ON u.size = d.size AND u.sample = d.sample
                );
            """)
            try commit()
        } catch {
            rollback()
            throw error
        }
        let stmt = try statement("SELECT COUNT(*) FROM duplicate_files WHERE digest IS NULL")
        defer { sqlite3_reset(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw failure() }
        return sqlite3_column_int64(stmt, 0)
    }

    public func removeDuplicateCandidate(id: Int64) throws {
        let stmt = try statement("DELETE FROM duplicate_files WHERE node_id=?")
        try bind([id], to: stmt)
        try done(stmt)
    }

    public func duplicateGroups(offset: Int = 0, limit: Int = 100, token: CancellationToken? = nil) throws -> [DuplicateGroup] {
        setCancelHandler(token: token)
        defer { withExtendedLifetime(token) { setCancelHandler(token: nil) } }
        let cappedLimit = max(0, min(limit, 100))
        let safeOffset = max(0, offset)
        let sql = """
            SELECT d.size, hex(d.digest) as hex_digest, COUNT(*) as member_count, SUM(n.allocated) as total_allocated
            FROM duplicate_files d
            JOIN nodes n ON n.id = d.node_id
            WHERE d.digest IS NOT NULL
            GROUP BY d.size, d.digest
            HAVING COUNT(*) >= 2
            ORDER BY d.size DESC, member_count DESC, hex_digest ASC
            LIMIT ? OFFSET ?
        """
        let stmt = try statement(sql)
        try bind([Int64(cappedLimit), Int64(safeOffset)], to: stmt)
        defer { sqlite3_reset(stmt) }
        var result: [DuplicateGroup] = []
        while true {
            let code = sqlite3_step(stmt)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw failure() }
            let size = sqlite3_column_int64(stmt, 0)
            guard let hexCString = sqlite3_column_text(stmt, 1) else { continue }
            let hexStr = String(cString: hexCString).lowercased()
            let count = Int(sqlite3_column_int64(stmt, 2))
            let allocated = sqlite3_column_int64(stmt, 3)
            let groupID = "\(size):\(hexStr)"
            result.append(DuplicateGroup(id: groupID, memberCount: count, logicalSize: size, allocatedSize: allocated))
        }
        return result
    }

    public static func parseGroupID(_ groupID: String) throws -> (size: Int64, digest: Data) {
        guard let colonIndex = groupID.firstIndex(of: ":") else {
            throw MacEvenError(localized("无效的重复文件组标识：\(groupID)"))
        }
        let sizeStr = groupID[..<colonIndex]
        let hexStr = groupID[groupID.index(after: colonIndex)...]
        guard let size = Int64(sizeStr), size > 0, hexStr.count == 64 else {
            throw MacEvenError(localized("无效的重复文件组格式：\(groupID)"))
        }
        var data = Data()
        data.reserveCapacity(32)
        var index = hexStr.startIndex
        while index < hexStr.endIndex {
            let nextIndex = hexStr.index(index, offsetBy: 2)
            guard let byte = UInt8(hexStr[index..<nextIndex], radix: 16) else {
                throw MacEvenError(localized("无效的哈希格式：\(hexStr)"))
            }
            data.append(byte)
            index = nextIndex
        }
        return (size, data)
    }

    public func duplicateMembers(groupID: String, offset: Int = 0, limit: Int = 100, token: CancellationToken? = nil) throws -> [DiskEntry] {
        setCancelHandler(token: token)
        defer { withExtendedLifetime(token) { setCancelHandler(token: nil) } }
        let parsed = try DiskIndex.parseGroupID(groupID)
        let cappedLimit = max(0, min(limit, 100))
        let safeOffset = max(0, offset)
        let sql = "SELECT \(nodeColumns) FROM duplicate_files d JOIN nodes n ON n.id=d.node_id WHERE d.size=? AND d.digest=? ORDER BY n.id ASC LIMIT ? OFFSET ?"
        let stmt = try statement(sql)
        defer { sqlite3_reset(stmt) }
        guard sqlite3_bind_int64(stmt, 1, parsed.size) == SQLITE_OK else { throw failure() }
        try parsed.digest.withUnsafeBytes { raw in
            guard sqlite3_bind_blob(stmt, 2, raw.baseAddress, Int32(raw.count), transient) == SQLITE_OK else { throw failure() }
        }
        guard sqlite3_bind_int64(stmt, 3, Int64(cappedLimit)) == SQLITE_OK else { throw failure() }
        guard sqlite3_bind_int64(stmt, 4, Int64(safeOffset)) == SQLITE_OK else { throw failure() }
        var result: [DiskEntry] = []
        while true {
            let code = sqlite3_step(stmt)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw failure() }
            result.append(decode(stmt))
        }
        return result
    }

    public func duplicateGroupMember(nodeID: Int64, groupID: String) throws -> DiskEntry? {
        let parsed = try DiskIndex.parseGroupID(groupID)
        let sql = "SELECT \(nodeColumns) FROM duplicate_files d JOIN nodes n ON n.id=d.node_id WHERE d.node_id=? AND d.size=? AND d.digest=?"
        let stmt = try statement(sql)
        defer { sqlite3_reset(stmt) }
        guard sqlite3_bind_int64(stmt, 1, nodeID) == SQLITE_OK else { throw failure() }
        guard sqlite3_bind_int64(stmt, 2, parsed.size) == SQLITE_OK else { throw failure() }
        try parsed.digest.withUnsafeBytes { raw in
            guard sqlite3_bind_blob(stmt, 3, raw.baseAddress, Int32(raw.count), transient) == SQLITE_OK else { throw failure() }
        }
        let code = sqlite3_step(stmt)
        if code == SQLITE_ROW {
            return decode(stmt)
        } else if code == SQLITE_DONE {
            return nil
        } else {
            throw failure()
        }
    }

    private func scopeBounds(for path: String) -> (prefix: String, upper: String) {
        let cleanPath = path == "/" ? "/" : (path.hasSuffix("/") ? String(path.dropLast()) : path)
        let prefix = cleanPath == "/" ? "/" : cleanPath + "/"
        let upper = cleanPath == "/" ? "0" : cleanPath + "0"
        return (prefix, upper)
    }

    public func spaceStats(directoryID: Int64, token: CancellationToken) throws -> [SpaceCategoryStat] {
        guard !token.isCancelled else { throw MacEvenError(localized("查询已取消。")) }
        guard let dirEntry = try entry(id: directoryID) else {
            throw MacEvenError(localized("目录未找到：\(directoryID)"))
        }
        setCancelHandler(token: token)
        defer { withExtendedLifetime(token) { setCancelHandler(token: nil) } }

        let (prefix, upper) = scopeBounds(for: dirEntry.url.path)
        let sql = """
            SELECT category, COUNT(*), COALESCE(SUM(allocated), 0)
            FROM nodes
            WHERE (mode & 61440) = 32768
              AND duplicate = 0
              AND path >= ?
              AND path < ?
            GROUP BY category
        """
        let stmt = try statement(sql)
        defer { sqlite3_reset(stmt) }
        guard sqlite3_bind_text(stmt, 1, prefix, -1, transient) == SQLITE_OK else { throw failure() }
        guard sqlite3_bind_text(stmt, 2, upper, -1, transient) == SQLITE_OK else { throw failure() }

        var counts: [FileCategory: (count: Int64, allocated: Int64)] = [:]
        while true {
            let code = sqlite3_step(stmt)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw failure() }
            let catRaw = Int(sqlite3_column_int64(stmt, 0))
            let count = sqlite3_column_int64(stmt, 1)
            let allocated = sqlite3_column_int64(stmt, 2)
            if let category = FileCategory(rawValue: catRaw) {
                counts[category] = (count, allocated)
            }
        }

        return FileCategory.allCases.map { cat in
            let item = counts[cat] ?? (0, 0)
            return SpaceCategoryStat(category: cat, count: item.count, allocatedSize: item.allocated)
        }
    }

    public func spacePage(
        directoryID: Int64,
        filter: SpaceFilter,
        offset: Int = 0,
        limit: Int = 100,
        token: CancellationToken
    ) throws -> SpacePage {
        guard !token.isCancelled else { throw MacEvenError(localized("查询已取消。")) }
        guard let dirEntry = try entry(id: directoryID) else {
            throw MacEvenError(localized("目录未找到：\(directoryID)"))
        }
        setCancelHandler(token: token)
        defer { withExtendedLifetime(token) { setCancelHandler(token: nil) } }

        let cappedLimit = max(0, min(limit, 100))
        let safeOffset = max(0, offset)
        let (prefix, upper) = scopeBounds(for: dirEntry.url.path)

        var whereClauses = [
            "(mode & 61440) = 32768",
            "duplicate = 0",
            "path >= ?",
            "path < ?"
        ]

        if filter.category != nil {
            whereClauses.append("category = ?")
        }
        if filter.minAllocated != nil {
            whereClauses.append("allocated >= ?")
        }
        if filter.maxAllocated != nil {
            whereClauses.append("allocated <= ?")
        }
        if filter.notModifiedSince != nil {
            whereClauses.append("modified > 0")
            whereClauses.append("modified <= ?")
        }

        let whereSQL = whereClauses.joined(separator: " AND ")

        let countSQL = "SELECT COUNT(*), COALESCE(SUM(allocated), 0) FROM nodes WHERE \(whereSQL)"
        let countStmt = try statement(countSQL)
        defer { sqlite3_reset(countStmt) }

        var bindIdx: Int32 = 1
        guard sqlite3_bind_text(countStmt, bindIdx, prefix, -1, transient) == SQLITE_OK else { throw failure() }
        bindIdx += 1
        guard sqlite3_bind_text(countStmt, bindIdx, upper, -1, transient) == SQLITE_OK else { throw failure() }
        bindIdx += 1

        if let category = filter.category {
            guard sqlite3_bind_int64(countStmt, bindIdx, Int64(category.rawValue)) == SQLITE_OK else { throw failure() }
            bindIdx += 1
        }
        if let minAllocated = filter.minAllocated {
            guard sqlite3_bind_int64(countStmt, bindIdx, minAllocated) == SQLITE_OK else { throw failure() }
            bindIdx += 1
        }
        if let maxAllocated = filter.maxAllocated {
            guard sqlite3_bind_int64(countStmt, bindIdx, maxAllocated) == SQLITE_OK else { throw failure() }
            bindIdx += 1
        }
        if let notModifiedSince = filter.notModifiedSince {
            guard sqlite3_bind_int64(countStmt, bindIdx, notModifiedSince) == SQLITE_OK else { throw failure() }
            bindIdx += 1
        }

        var totalCount: Int64 = 0
        var totalAllocated: Int64 = 0
        let countStep = sqlite3_step(countStmt)
        if countStep == SQLITE_ROW {
            totalCount = sqlite3_column_int64(countStmt, 0)
            totalAllocated = sqlite3_column_int64(countStmt, 1)
        } else if countStep != SQLITE_DONE {
            throw failure()
        }

        let pageSQL = """
            SELECT \(columns) FROM nodes
            WHERE \(whereSQL)
            ORDER BY allocated DESC, logical DESC, id ASC
            LIMIT ? OFFSET ?
        """
        let pageStmt = try statement(pageSQL)
        defer { sqlite3_reset(pageStmt) }

        bindIdx = 1
        guard sqlite3_bind_text(pageStmt, bindIdx, prefix, -1, transient) == SQLITE_OK else { throw failure() }
        bindIdx += 1
        guard sqlite3_bind_text(pageStmt, bindIdx, upper, -1, transient) == SQLITE_OK else { throw failure() }
        bindIdx += 1

        if let category = filter.category {
            guard sqlite3_bind_int64(pageStmt, bindIdx, Int64(category.rawValue)) == SQLITE_OK else { throw failure() }
            bindIdx += 1
        }
        if let minAllocated = filter.minAllocated {
            guard sqlite3_bind_int64(pageStmt, bindIdx, minAllocated) == SQLITE_OK else { throw failure() }
            bindIdx += 1
        }
        if let maxAllocated = filter.maxAllocated {
            guard sqlite3_bind_int64(pageStmt, bindIdx, maxAllocated) == SQLITE_OK else { throw failure() }
            bindIdx += 1
        }
        if let notModifiedSince = filter.notModifiedSince {
            guard sqlite3_bind_int64(pageStmt, bindIdx, notModifiedSince) == SQLITE_OK else { throw failure() }
            bindIdx += 1
        }

        guard sqlite3_bind_int64(pageStmt, bindIdx, Int64(cappedLimit)) == SQLITE_OK else { throw failure() }
        bindIdx += 1
        guard sqlite3_bind_int64(pageStmt, bindIdx, Int64(safeOffset)) == SQLITE_OK else { throw failure() }

        var entries: [DiskEntry] = []
        while true {
            let code = sqlite3_step(pageStmt)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw failure() }
            entries.append(decode(pageStmt))
        }

        let hasNext = Int64(safeOffset) < totalCount - Int64(entries.count)
        return SpacePage(entries: entries, hasNext: hasNext, totalCount: totalCount, allocatedSize: totalAllocated)
    }

    public func treemap(of id: Int64, limit: Int = 64) throws -> TreemapSnapshot {
        guard let directory = try entry(id: id), directory.isDirectory else {
            throw MacEvenError(localized("目录尚未扫描或索引已失效，请重新扫描。"))
        }
        let clampedLimit = max(0, min(limit, 64))

        let entries: [DiskEntry]
        if clampedLimit > 0 {
            entries = try rows(
                "SELECT \(columns) FROM nodes WHERE parent=? ORDER BY allocated DESC,logical DESC,id ASC LIMIT ?",
                values: [id, Int64(clampedLimit)]
            )
        } else {
            entries = []
        }

        let statsSQL = "SELECT allocated,logical FROM nodes WHERE parent=? ORDER BY allocated DESC,logical DESC,id ASC"
        let stmt = try statement(statsSQL)
        try bind([id], to: stmt)
        defer { sqlite3_reset(stmt) }

        var totalCount: Int64 = 0
        var totalAllocatedSize: Int64 = 0
        var totalLogicalSize: Int64 = 0
        var otherCount: Int64 = 0
        var otherAllocatedSize: Int64 = 0
        var otherLogicalSize: Int64 = 0
        var invalidSizeCount: Int64 = 0
        var zeroAllocatedCount: Int64 = 0
        var rowIndex: Int = 0

        while true {
            let code = sqlite3_step(stmt)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw failure() }

            let allocated = sqlite3_column_int64(stmt, 0)
            let logical = sqlite3_column_int64(stmt, 1)
            totalCount += 1

            let isInvalid = sqlite3_column_type(stmt, 0) != SQLITE_INTEGER || sqlite3_column_type(stmt, 1) != SQLITE_INTEGER || allocated < 0 || logical < 0
            if isInvalid {
                invalidSizeCount += 1
            } else if allocated == 0 {
                zeroAllocatedCount += 1
            }

            if !isInvalid {
                let (nextAlloc, allocOverflow) = totalAllocatedSize.addingReportingOverflow(allocated)
                if allocOverflow {
                    invalidSizeCount += 1
                } else {
                    totalAllocatedSize = nextAlloc
                }

                let (nextLogic, logicOverflow) = totalLogicalSize.addingReportingOverflow(logical)
                if logicOverflow {
                    invalidSizeCount += 1
                } else {
                    totalLogicalSize = nextLogic
                }
            }

            if rowIndex >= clampedLimit {
                otherCount += 1
                if !isInvalid {
                    let (nextOtherAlloc, otherAllocOverflow) = otherAllocatedSize.addingReportingOverflow(allocated)
                    if otherAllocOverflow {
                        invalidSizeCount += 1
                    } else {
                        otherAllocatedSize = nextOtherAlloc
                    }

                    let (nextOtherLogic, otherLogicOverflow) = otherLogicalSize.addingReportingOverflow(logical)
                    if otherLogicOverflow {
                        invalidSizeCount += 1
                    } else {
                        otherLogicalSize = nextOtherLogic
                    }
                }
            }

            rowIndex += 1
        }

        return TreemapSnapshot(
            entries: entries,
            totalCount: totalCount,
            totalAllocatedSize: totalAllocatedSize,
            totalLogicalSize: totalLogicalSize,
            otherCount: otherCount,
            otherAllocatedSize: otherAllocatedSize,
            otherLogicalSize: otherLogicalSize,
            invalidSizeCount: invalidSizeCount,
            zeroAllocatedCount: zeroAllocatedCount
        )
    }
}
