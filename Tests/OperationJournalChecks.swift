import Foundation
import MacEvenCore

// 防止的问题：重试被当作重复丢弃、日志不可写时静默或被读取清除、损坏的保护列表被界面当作空列表。
@main struct OperationJournalChecks {
    @MainActor static func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            precondition(Date() < deadline, "journal did not settle in 10 seconds")
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor static func main() async throws {
        let fm = FileManager.default
        let base = try canonicalFileURL(fm.temporaryDirectory).appendingPathComponent("MacEven-journal-\(UUID())")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        let journal = OperationJournal(log: OperationLog(directory: base.appendingPathComponent("Logs")))
        let moved = TrashResult(id: 1, path: "/test/a", destination: URL(fileURLWithPath: "/trash/a"), error: nil, allocatedSize: 10)
        let kept = TrashResult(id: 2, path: "/test/b", destination: nil, error: "已在保护列表中：/test")
        // 记录器在模型的后台队列上同步写入；同一失败操作重试两次要记两次。
        let disk = journal.recorder(source: "disk"), cache = journal.recorder(source: "cache")
        let background = DispatchQueue(label: "journal-check")
        background.sync { disk([moved, kept]); disk([]); cache([kept]); cache([kept]) }
        let written = try journal.log.recent().records.count
        precondition(written == 4, "recorder did not write synchronously or skipped a retry")
        try await waitUntil { journal.recent.count == 4 }
        precondition(journal.recent.map(\.source) == ["cache", "cache", "disk", "disk"] && journal.failure == nil)
        precondition(journal.recent.last?.allocatedSize == 10)
        precondition(OperationJournal.sourceName("duplicates") == "重复文件")

        // 日志目录被替换为符号链接：写入失败可见，内存中的旧记录保持。
        let linked = base.appendingPathComponent("Linked")
        try fm.createSymbolicLink(at: linked, withDestinationURL: base)
        let broken = OperationJournal(log: OperationLog(directory: linked))
        background.sync { broken.recorder(source: "disk")([moved]) }
        try await waitUntil { broken.failure != nil }
        precondition(broken.failure?.contains("操作日志不可写") == true)
        broken.reload(); broken.flush()
        try await Task.sleep(for: .milliseconds(100))
        precondition(broken.failure?.contains("操作日志不可写") == true, "a read cleared the write failure")
        print("PASS: operation journal synchronous background recording, retries kept, source names, sticky unwritable log")

        let store = ProtectionStore(url: base.appendingPathComponent("protection.json"))
        let protection = ProtectionModel(store: store)
        precondition(protection.entries.isEmpty && protection.loadError == nil)
        precondition(!protection.addIdentifier("bad"), "invalid identifier accepted")
        precondition(protection.message != nil)
        precondition(protection.addIdentifier("com.example.keep") && protection.message == nil && protection.entries.count == 1)
        protection.addPaths([base.appendingPathComponent("Keep")])
        precondition(protection.entries.count == 2)
        protection.remove(protection.entries[0])
        precondition(protection.entries.count == 1)
        try Data("{".utf8).write(to: store.url)
        protection.reload()
        precondition(protection.loadError != nil && protection.entries.isEmpty, "damaged protection list shown as empty without error")
        protection.reset()
        precondition(protection.loadError == nil && protection.entries.isEmpty)
        print("PASS: protection model add, validation message, remove, damaged file error and reset")
    }
}
