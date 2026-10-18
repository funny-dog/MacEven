import Foundation
import Combine
import MacEvenCore

// 把各页面的移到废纸篓结果写入持久操作日志；写入失败不影响已完成的移动。
@MainActor final class OperationJournal: ObservableObject {
    @Published private(set) var recent: [OperationRecord] = []
    @Published private(set) var skippedLines = 0
    @Published private(set) var failure: String?
    let log: OperationLog
    private let queue = DispatchQueue(label: "MacEven.operation-log")

    init(log: OperationLog = OperationLog()) {
        self.log = log
        reload()
    }

    /// 交给模型在后台队列同步调用：每次移动只写一次，退出流程等待模型队列时日志已落盘。
    nonisolated func recorder(source: String) -> @Sendable ([TrashResult]) -> Void {
        let log = log
        return { [weak self] results in
            guard !results.isEmpty else { return }
            var writeError: String?
            do { try log.append(OperationRecord.batch(results, source: source)) } catch { writeError = localized("操作日志不可写：\(error.localizedDescription)") }
            let page = Result { try log.recent() }
            Task { @MainActor [weak self] in self?.apply(page, write: .some(writeError)) }
        }
    }

    func reload() {
        let log = log
        queue.async { [weak self] in
            let page = Result { try log.recent() }
            Task { @MainActor [weak self] in self?.apply(page, write: nil) }
        }
    }

    /// 等待已排队的读取完成（检查使用）。
    func flush() { queue.sync {} }

    /// write 为 nil 表示仅读取：读取成功不能证明日志可写，不清除写入失败提示。
    private func apply(_ page: Result<OperationLogPage, any Error>, write: String??) {
        if let write { failure = write }
        switch page {
        case .success(let value):
            recent = value.records; skippedLines = value.skippedLines
        case .failure(let error):
            failure = failure ?? localized("无法读取操作日志：\(error.localizedDescription)")
        }
    }

    static func sourceName(_ source: String) -> String {
        switch source {
        case "disk": localized("磁盘分析")
        case "cache": localized("应用缓存")
        case "developer": localized("开发与浏览器缓存")
        case "aiwork": localized("AI 会话与工作记录")
        case "applications": localized("应用卸载")
        case "leftovers": localized("卸载残留")
        case "duplicates": localized("重复文件")
        default: source
        }
    }
}
