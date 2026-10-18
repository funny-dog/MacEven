import Foundation
import Combine
import MacEvenCore

// 设置页对保护列表的读写；核心层各清理入口直接读取同一个 ProtectionStore。
@MainActor final class ProtectionModel: ObservableObject {
    @Published private(set) var entries: [ProtectionEntry] = []
    @Published private(set) var loadError: String?
    @Published var message: String?
    let store: ProtectionStore

    init(store: ProtectionStore = .shared) {
        self.store = store
        reload()
    }

    func reload() {
        do { entries = try store.entries(); loadError = nil }
        catch { entries = []; loadError = localized("保护列表无法读取，所有清理已暂停：\(error.localizedDescription)") }
    }

    func addPaths(_ urls: [URL]) {
        perform { for url in urls { try store.addPath(url) } }
    }

    func addApplications(_ urls: [URL]) {
        perform {
            for url in urls {
                guard let identifier = Bundle(url: url)?.bundleIdentifier else { throw MacEvenError(localized("无法读取应用标识：\(url.lastPathComponent)")) }
                try store.addBundleIdentifier(identifier)
            }
        }
    }

    /// 成功时返回 true，供界面清空输入框。
    @discardableResult func addIdentifier(_ value: String) -> Bool {
        perform { try store.addBundleIdentifier(value) }
    }

    func remove(_ entry: ProtectionEntry) {
        perform { try store.remove(id: entry.id) }
    }

    func reset() {
        perform { try store.reset() }
    }

    @discardableResult private func perform(_ body: () throws -> Void) -> Bool {
        defer { reload() }
        do { try body(); message = nil; return true }
        catch { message = error.localizedDescription; return false }
    }
}
