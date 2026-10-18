import SwiftUI

// 界面模式：false 为简洁模式（默认），true 为高级模式。只依赖 SwiftUI，由 ContentView 根视图按 StatusSettings 注入。
private struct AdvancedModeKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var advancedMode: Bool {
        get { self[AdvancedModeKey.self] }
        set { self[AdvancedModeKey.self] = newValue }
    }
}
