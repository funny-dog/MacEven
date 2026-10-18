import AppKit

@main struct MacEvenMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        // 进度估算记在用户偏好里；检查程序不传入，只用内存。
        let estimates = ScanEstimates(defaults: .standard)
        let delegate = AppDelegate(model: AppModel(estimates: estimates, historyDefaults: .standard), monitor: MonitorModel(), cache: CacheModel(), removal: ApplicationRemovalModel(),
            duplicate: DuplicateModel(estimates: estimates, historyDefaults: .standard))
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}
