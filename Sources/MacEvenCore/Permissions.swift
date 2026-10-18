import Foundation
import ApplicationServices

public enum FullDiskAccessChecker: Sendable {
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    public static func check() -> Bool {
        let fileManager = FileManager.default
        let home = NSHomeDirectory()
        let protectedPaths = [
            (home as NSString).appendingPathComponent("Library/Application Support/com.apple.TCC"),
            (home as NSString).appendingPathComponent("Library/Safari"),
            (home as NSString).appendingPathComponent("Library/Mail")
        ]

        for path in protectedPaths {
            guard fileManager.fileExists(atPath: path) else {
                continue
            }
            do {
                _ = try fileManager.contentsOfDirectory(atPath: path)
                return true
            } catch {
                continue
            }
        }
        return false
    }
}

public enum AccessibilityChecker: Sendable {
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    public static func check() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
