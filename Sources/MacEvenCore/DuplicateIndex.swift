import Foundation
import Darwin
import SQLite3

struct DuplicateBaseline: Codable {
    let signature: String
    let cursors: [String: UInt64]
    let fullScanTime: Date
}

extension DiskIndex {
    func prepareDuplicateCache() throws {
        try execute("""
            CREATE TABLE IF NOT EXISTS duplicate_hash_cache(
                path TEXT PRIMARY KEY, device INTEGER, inode INTEGER, mode INTEGER, size INTEGER,
                modified INTEGER, changed INTEGER, blocks INTEGER, sample BLOB NOT NULL, digest BLOB,
                used REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS duplicate_baseline(id INTEGER PRIMARY KEY CHECK(id=1), value BLOB NOT NULL);
            CREATE INDEX IF NOT EXISTS duplicate_paths ON nodes(path);
            """)
    }
    func duplicateBaseline() throws -> DuplicateBaseline? {
        let stmt = try statement("SELECT value FROM duplicate_baseline WHERE id=1")
        defer { sqlite3_reset(stmt) }
        let code = sqlite3_step(stmt)
        if code == SQLITE_DONE { return nil }
        guard code == SQLITE_ROW else { throw failure() }
        guard let raw = sqlite3_column_blob(stmt, 0) else { return nil }
        return try? JSONDecoder().decode(DuplicateBaseline.self, from: Data(bytes: raw, count: Int(sqlite3_column_bytes(stmt, 0))))
    }
    func invalidateDuplicateBaseline() throws { try execute("DELETE FROM duplicate_baseline") }
    func storeDuplicateBaseline(_ value: DuplicateBaseline) throws {
        let data = try JSONEncoder().encode(value)
        let stmt = try statement("INSERT OR REPLACE INTO duplicate_baseline VALUES(1,?)")
        try data.withUnsafeBytes { raw in
            guard sqlite3_bind_blob(stmt, 1, raw.baseAddress, Int32(raw.count), transient) == SQLITE_OK else { throw failure() }
        }
        try done(stmt)
    }
    func cachedDuplicateHash(_ entry: DiskEntry) throws -> (sample: Data, digest: Data?)? {
        let stmt = try statement("""
            SELECT sample,digest FROM duplicate_hash_cache WHERE path=? AND device=? AND inode=? AND mode=?
            AND size=? AND modified=? AND changed=? AND blocks=?
            """)
        defer { sqlite3_reset(stmt) }
        guard sqlite3_bind_text(stmt, 1, entry.url.path, -1, transient) == SQLITE_OK else { throw failure() }
        let i = entry.identity
        try bind([i.device,i.inode,i.mode,i.size,i.modified,i.changed,i.allocated], to: stmt, from: 2)
        let code = sqlite3_step(stmt)
        if code == SQLITE_DONE { return nil }
        guard code == SQLITE_ROW else { throw failure() }
        func data(_ n: Int32) -> Data? {
            guard sqlite3_column_bytes(stmt,n) == 32, let raw = sqlite3_column_blob(stmt,n) else { return nil }
            return Data(bytes: raw, count: 32)
        }
        guard let sample = data(0) else { return nil }
        let digest = data(1)
        if sqlite3_column_type(stmt,1) != SQLITE_NULL && digest == nil { return nil }
        return (sample,digest)
    }
    func cacheDuplicateHashes() throws {
        try execute("""
            INSERT OR REPLACE INTO duplicate_hash_cache
            SELECT n.path,n.device,n.inode,n.mode,n.size,n.modified,n.changed,n.blocks,d.sample,d.digest,
                CAST(strftime('%s','now') AS REAL)
            FROM duplicate_files d JOIN nodes n ON n.id=d.node_id WHERE length(d.sample)=32;
            DELETE FROM duplicate_hash_cache WHERE used < CAST(strftime('%s','now') AS REAL)-2592000;
            DELETE FROM duplicate_hash_cache WHERE path IN (
                SELECT path FROM duplicate_hash_cache ORDER BY used DESC,path LIMIT -1 OFFSET 200000);
            """)
    }
    func duplicateNode(at path: String) throws -> DiskEntry? {
        let stmt = try statement("SELECT \(columns) FROM nodes WHERE path=? LIMIT 1")
        defer { sqlite3_reset(stmt) }
        guard sqlite3_bind_text(stmt,1,path,-1,transient) == SQLITE_OK else { throw failure() }
        let code = sqlite3_step(stmt)
        if code == SQLITE_DONE { return nil }
        guard code == SQLITE_ROW else { throw failure() }
        return decode(stmt)
    }
    /// 只检查已知目录的身份和访问权限，不枚举其内容；时间变化补为脏目录，避免通知延迟。
    func duplicateDirectoryChanges(token: CancellationToken) throws -> [String] {
        let stmt = try statement("SELECT \(columns) FROM nodes WHERE (mode & 61440)=16384 ORDER BY length(path),path")
        defer { sqlite3_reset(stmt) }
        var changed: [String] = []
        while true {
            if token.isCancelled { throw MacEvenError(localized("扫描已取消。")) }
            let code = sqlite3_step(stmt)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw failure() }
            let old = decode(stmt)
            let fd = open(old.url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
            guard fd >= 0 else { throw MacEvenError(localized("目录已不可访问，改用完整扫描。")) }
            Darwin.close(fd)
            let actual = try FileIdentity.read(old.url)
            guard actual.isDirectory, !actual.isSymlink, actual.device == old.identity.device,
                actual.inode == old.identity.inode, actual.mode == old.identity.mode else {
                throw MacEvenError(localized("目录身份或权限已变化，改用完整扫描。"))
            }
            if actual.modified != old.identity.modified || actual.changed != old.identity.changed { changed.append(old.url.path) }
        }
        return changed
    }
    /// 临时子树先完整扫描，只有成功结果才在主库事务里替换；取消和错误不留下可复用基线。
    func replaceDuplicateSubtree(old: DiskEntry, delta: DiskIndex, token: CancellationToken) throws {
        let cursor = try delta.statement("SELECT \(delta.columns) FROM nodes ORDER BY id")
        defer { sqlite3_reset(cursor) }
        try begin()
        do {
            let maxID = try statement("SELECT COALESCE(MAX(id),0) FROM nodes")
            guard sqlite3_step(maxID) == SQLITE_ROW else { throw failure() }
            let offset = sqlite3_column_int64(maxID,0)
            sqlite3_reset(maxID)
            let remove = try statement("""
                WITH RECURSIVE tree(id) AS (SELECT ? UNION ALL SELECT n.id FROM nodes n JOIN tree t ON n.parent=t.id)
                DELETE FROM nodes WHERE id IN (SELECT id FROM tree)
                """)
            try bind([old.id],to: remove); try done(remove)
            while true {
                if token.isCancelled { throw MacEvenError(localized("扫描已取消。")) }
                let code = sqlite3_step(cursor)
                if code == SQLITE_DONE { break }
                guard code == SQLITE_ROW else { throw delta.failure() }
                let entry = delta.decode(cursor), i = entry.identity
                let stmt = try statement("""
                    INSERT INTO nodes(id,parent,path,device,inode,mode,size,modified,changed,blocks,
                        ownLogical,ownAllocated,logical,allocated,duplicate,category)
                    VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    """)
                try bind([entry.id+offset,entry.parentID == 0 ? old.parentID : entry.parentID+offset], to: stmt)
                guard sqlite3_bind_text(stmt,3,entry.url.path,-1,transient) == SQLITE_OK else { throw failure() }
                try bind([i.device,i.inode,i.mode,i.size,i.modified,i.changed,i.allocated,
                    i.isRegular && !entry.duplicate ? i.size : 0,i.isRegular && !entry.duplicate ? i.allocated : 0,
                    entry.logicalSize,entry.allocatedSize,entry.duplicate ? 1 : 0,Int64(FileCategory.classify(entry.url).rawValue)],to:stmt,from:4)
                try done(stmt)
            }
            // 重复扫描本来排除硬链接；重建 seen 防止被替换节点的旧身份影响后续扫描。
            try execute("DELETE FROM seen; INSERT OR IGNORE INTO seen SELECT device,inode FROM nodes WHERE (mode & 61440)=32768;")
            var parent = old.parentID
            while parent != 0 {
                if token.isCancelled { throw MacEvenError(localized("扫描已取消。")) }
                let stmt = try statement("""
                    UPDATE nodes SET logical=ownLogical+(SELECT COALESCE(SUM(logical),0) FROM nodes c WHERE c.parent=nodes.id),
                        allocated=ownAllocated+(SELECT COALESCE(SUM(allocated),0) FROM nodes c WHERE c.parent=nodes.id)
                    WHERE id=?
                    """)
                try bind([parent],to:stmt); try done(stmt)
                parent = try entry(id: parent)?.parentID ?? 0
            }
            try commit()
        } catch { rollback(); throw error }
    }
}
