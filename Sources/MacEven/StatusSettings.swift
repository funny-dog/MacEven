import Foundation
import MacEvenCore
import Combine
import ServiceManagement

public enum StatusMetric: String, CaseIterable, Identifiable, Codable, Sendable {
    case none = "none"
    case cpu = "cpu"
    case ram = "ram"
    case gpu = "gpu"
    case battery = "battery"
    case thermal = "thermal"
    case download = "download"
    case upload = "upload"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .none: return localized("不显示")
        case .cpu: return localized("CPU 使用率")
        case .ram: return localized("内存占用")
        case .gpu: return localized("GPU 使用率")
        case .battery: return localized("电池电量")
        case .thermal: return localized("温度传感器")
        case .download: return localized("下载网速")
        case .upload: return localized("上传网速")
        }
    }

    public var shortName: String {
        switch self {
        case .none: return ""
        case .cpu: return "CPU"
        case .ram: return "RAM"
        case .gpu: return "GPU"
        case .battery: return "BAT"
        case .thermal: return "TEMP"
        case .download: return "DL"
        case .upload: return "UL"
        }
    }
}

public enum StatusLayoutStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    case horizontal = "horizontal"
    case stacked = "stacked"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .horizontal: return localized("横排显示")
        case .stacked: return localized("堆叠显示")
        }
    }
}

@MainActor
public final class StatusSettings: ObservableObject {
    public static let defaultPrimaryMetric: StatusMetric = .cpu
    public static let defaultSecondaryMetric: StatusMetric = .ram
    public static let defaultShowNetworkSpeed: Bool = false
    // 新安装默认堆叠显示：两行分别显示 CPU 与内存，占位更窄且不挤压其他菜单栏图标。
    public static let defaultLayoutStyle: StatusLayoutStyle = .stacked
    public static let defaultMenuBarOnly: Bool = false
    public static let defaultGlobalHotkeyEnabled: Bool = false
    public static let defaultAdvancedMode: Bool = false
    public static let defaultSidebarCollapsed: Bool = false

    private enum Keys {
        static let primaryMetric = "maceven.status.primaryMetric"
        static let secondaryMetric = "maceven.status.secondaryMetric"
        static let showNetworkSpeed = "maceven.status.showNetworkSpeed"
        static let layoutStyle = "maceven.status.layoutStyle"
        static let menuBarOnly = "maceven.status.menuBarOnly"
        static let globalHotkeyEnabled = "maceven.status.globalHotkeyEnabled"
        static let pinnedExecutablePaths = "maceven.status.pinnedExecutablePaths"
        static let advancedMode = "maceven.ui.advancedMode"
        static let sidebarCollapsed = "maceven.ui.sidebarCollapsed"
    }

    private let defaults: UserDefaults

    @Published public var primaryMetric: StatusMetric {
        didSet {
            defaults.set(primaryMetric.rawValue, forKey: Keys.primaryMetric)
        }
    }

    @Published public var secondaryMetric: StatusMetric {
        didSet {
            defaults.set(secondaryMetric.rawValue, forKey: Keys.secondaryMetric)
        }
    }

    @Published public var showNetworkSpeed: Bool {
        didSet {
            defaults.set(showNetworkSpeed, forKey: Keys.showNetworkSpeed)
        }
    }

    @Published public var layoutStyle: StatusLayoutStyle {
        didSet {
            defaults.set(layoutStyle.rawValue, forKey: Keys.layoutStyle)
        }
    }

    @Published public var menuBarOnly: Bool {
        didSet {
            defaults.set(menuBarOnly, forKey: Keys.menuBarOnly)
        }
    }

    @Published public var globalHotkeyEnabled: Bool {
        didSet {
            defaults.set(globalHotkeyEnabled, forKey: Keys.globalHotkeyEnabled)
        }
    }

    // 界面模式：默认简洁模式，高级模式显示专业指标、说明文字与进阶功能。
    @Published public var advancedMode: Bool {
        didSet {
            defaults.set(advancedMode, forKey: Keys.advancedMode)
        }
    }

    // 侧栏折叠状态：默认展开，折叠后仅显示可点击图标。
    @Published public var sidebarCollapsed: Bool {
        didSet {
            defaults.set(sidebarCollapsed, forKey: Keys.sidebarCollapsed)
        }
    }

    @Published public private(set) var pinnedExecutablePaths: Set<String> {
        didSet {
            defaults.set(Array(pinnedExecutablePaths).sorted(), forKey: Keys.pinnedExecutablePaths)
        }
    }

    @Published public private(set) var loginItemStatus: SMAppService.Status

    @Published public private(set) var loginItemError: String?
    @Published var hotkeyError: String?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        primaryMetric = defaults.string(forKey: Keys.primaryMetric).flatMap(StatusMetric.init(rawValue:)) ?? Self.defaultPrimaryMetric
        secondaryMetric = defaults.string(forKey: Keys.secondaryMetric).flatMap(StatusMetric.init(rawValue:)) ?? Self.defaultSecondaryMetric
        showNetworkSpeed = defaults.bool(forKey: Keys.showNetworkSpeed)
        layoutStyle = defaults.string(forKey: Keys.layoutStyle).flatMap(StatusLayoutStyle.init(rawValue:)) ?? Self.defaultLayoutStyle
        menuBarOnly = defaults.bool(forKey: Keys.menuBarOnly)
        globalHotkeyEnabled = defaults.bool(forKey: Keys.globalHotkeyEnabled)
        advancedMode = defaults.bool(forKey: Keys.advancedMode)
        sidebarCollapsed = defaults.object(forKey: Keys.sidebarCollapsed) as? Bool ?? Self.defaultSidebarCollapsed

        if let paths = defaults.stringArray(forKey: Keys.pinnedExecutablePaths) {
            let valid = paths.lazy.filter { Self.isValidExecutablePath($0) }
            self.pinnedExecutablePaths = Set(valid.prefix(256).map { URL(fileURLWithPath: $0).standardized.path })
        } else {
            self.pinnedExecutablePaths = []
        }

        self.loginItemStatus = SMAppService.mainApp.status
        self.loginItemError = nil
    }


    public static func isValidExecutablePath(_ candidate: String) -> Bool {
        candidate.hasPrefix("/") && candidate.utf8.count <= 4096 && !candidate.contains("\0")
    }

    public func isPinned(path: String) -> Bool {
        let standard = standardize(path)
        return pinnedExecutablePaths.contains(standard)
    }

    @discardableResult
    public func pin(path: String) -> Bool {
        guard Self.isValidExecutablePath(path) else { return false }
        let standard = standardize(path)
        guard pinnedExecutablePaths.count < 256 || pinnedExecutablePaths.contains(standard) else { return false }
        pinnedExecutablePaths.insert(standard)
        return true
    }

    public func unpin(path: String) {
        let standard = standardize(path)
        pinnedExecutablePaths.remove(standard)
    }

    @discardableResult
    public func togglePin(path: String) -> Bool {
        if isPinned(path: path) {
            unpin(path: path)
            return false
        } else {
            return pin(path: path)
        }
    }

    private func standardize(_ path: String) -> String {
        return URL(fileURLWithPath: path).standardized.path
    }


    public func refreshLoginItemStatus() {
        let actual = SMAppService.mainApp.status
        if loginItemStatus != actual { loginItemStatus = actual }
    }

    public func setLaunchAtLogin(enabled: Bool) throws {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            self.loginItemError = nil
            refreshLoginItemStatus()
        } catch {
            self.loginItemError = error.localizedDescription
            refreshLoginItemStatus()
            throw error
        }
    }

    public func toggleSidebar() {
        sidebarCollapsed.toggle()
    }

    public func resetToDefaults() {
        primaryMetric = Self.defaultPrimaryMetric
        secondaryMetric = Self.defaultSecondaryMetric
        showNetworkSpeed = Self.defaultShowNetworkSpeed
        layoutStyle = Self.defaultLayoutStyle
        menuBarOnly = Self.defaultMenuBarOnly
        globalHotkeyEnabled = Self.defaultGlobalHotkeyEnabled
        advancedMode = Self.defaultAdvancedMode
        sidebarCollapsed = Self.defaultSidebarCollapsed
        pinnedExecutablePaths.removeAll()
    }
}
