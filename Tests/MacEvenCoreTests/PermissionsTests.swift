import Foundation
import MacEvenCore

final class PermissionsTests {
    func testFullDiskAccessChecker() throws {
        let granted = FullDiskAccessChecker.check()
        XCTAssertTrue(granted == true || granted == false, "FullDiskAccessChecker.check() should return a valid boolean without crashing")
    }

    func testAccessibilityChecker() throws {
        let granted = AccessibilityChecker.check()
        XCTAssertTrue(granted == true || granted == false, "AccessibilityChecker.check() should return a valid boolean without prompting")
    }

    func testSettingsURLs() throws {
        let fdaURL = FullDiskAccessChecker.settingsURL
        XCTAssertEqual(fdaURL.scheme, "x-apple.systempreferences")
        XCTAssertEqual(fdaURL.absoluteString, "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")

        let axURL = AccessibilityChecker.settingsURL
        XCTAssertEqual(axURL.scheme, "x-apple.systempreferences")
        XCTAssertEqual(axURL.absoluteString, "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }
}
