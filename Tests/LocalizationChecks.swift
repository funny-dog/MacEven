import Foundation
@testable import MacEvenCore

@main
struct LocalizationChecks {
    static func main() throws {
        let chinese = Locale.preferredLanguages.first?.hasPrefix("zh") == true
        precondition(localized("取消") == (chinese ? "取消" : "Cancel"))
        precondition(localizedText("系统状态") == (chinese ? "系统状态" : "System Status"))

        let date = Date(timeIntervalSince1970: 0).formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: localizationLocale))
        precondition(chinese || date.range(of: "[\\u3400-\\u9fff]", options: .regularExpression) == nil, "English dates must follow the interface language, even in a Chinese region")

        let advisory = DeveloperCleanupActivity.processReason(.claudeCache, "/usr/local/bin/claude\n", advisory: true)!
        precondition(advisory.contains("claude"))
        precondition(chinese ? advisory.contains("不建议清理") : advisory.contains("not recommended"))

        let filename = "中文文稿 %@ $HOME.txt"
        let failure = localized("操作失败：\(filename)")
        precondition(failure.contains(filename), "Interpolation must preserve filenames and percent signs")
        precondition(chinese ? failure.hasPrefix("操作失败：") : !failure.hasPrefix("操作失败："))
        let percent = localized("已用 \(42)% · 共 \("500 GB")")
        precondition(percent.contains("42%") && percent.contains("500 GB"))
        precondition(!percent.contains("%%"), "Literal percent signs must not be doubled")
        precondition(localizedText("com.example.unknown") == "com.example.unknown")
        if !chinese {
            precondition(PurposeSafety.keep.title.range(of: "[\\u3400-\\u9fff]", options: .regularExpression) == nil)
        }
        precondition(SoftwareUpdates.inferBrewToken(name: "微信", bundleId: nil) == "wechat", "Application matching must not translate Chinese product names")
        let classifier = PurposeClassifier(home: URL(fileURLWithPath: "/Users/tester"),
            applications: [CacheApplication(id: "com.tencent.xinWeChat", name: "微信")])
        let cache = classifier.label(for: "/Users/tester/Library/Caches/com.tencent.xinWeChat", isDirectory: true)!
        precondition(cache.title.contains("微信"), "Application names are data, not translation keys")
        precondition(chinese || cache.title.replacingOccurrences(of: "微信", with: "").range(of: "[\\u3400-\\u9fff]", options: .regularExpression) == nil)
        precondition(classifier.label(for: "/Users/tester/Library/Containers/com.tencent.xinWeChat/Data/Library/Caches", isDirectory: true)?.safety == .keep,
            "Changing language must not weaken protected application data rules")
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            _ = try canonicalFileURL(missing)
            preconditionFailure("Missing paths must still fail in both languages")
        } catch {
            precondition(error.localizedDescription.contains(missing.path))
            let explanation = error.localizedDescription.replacingOccurrences(of: missing.path, with: "")
            precondition(chinese || explanation.range(of: "[\\u3400-\\u9fff]", options: .regularExpression) == nil)
        }

        let bundleURL = Bundle.main.url(forResource: "MacEven_MacEvenCore", withExtension: "bundle")
            ?? URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
                .appendingPathComponent("MacEven_MacEvenCore.bundle")
        let expressions = try NSRegularExpression(pattern: #"%(?:[0-9]+\$)?(?:[-+0 #]*[0-9]*(?:\.[0-9]+)?)?(?:ll|l|z)?[@diufsgxX]|%%"#)
        func placeholders(_ value: String) -> [String] {
            expressions.matches(in: value, range: NSRange(value.startIndex..., in: value)).map {
                let token = (value as NSString).substring(with: $0.range)
                return token.replacingOccurrences(of: #"[0-9]+\$"#, with: "", options: .regularExpression)
            }.sorted()
        }
        let template = try NSRegularExpression(pattern: #"\{[A-Za-z][A-Za-z0-9_]*\}"#)
        func fields(_ text: String) -> [String] {
            template.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { (text as NSString).substring(with: $0.range) }.sorted()
        }
        var count = 0
        for name in ["App", "Core"] {
            let data = try Data(contentsOf: bundleURL.appendingPathComponent("en.lproj/\(name).strings"))
            let entries = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: String]
            for (key, translation) in entries {
                precondition(!translation.isEmpty, "Empty translation: \(key)")
                let leading = String(key.prefix(while: { $0.isWhitespace }))
                let trailing = String(key.reversed().prefix(while: { $0.isWhitespace }).reversed())
                precondition(translation.hasPrefix(leading) && translation.hasSuffix(trailing), "Fragment spacing mismatch: \(key)")
                if key.hasPrefix("应用正在运行") { precondition(translation.hasPrefix("App is running"), "Running-reason prefix must remain recognizable") }
                precondition(placeholders(key) == placeholders(translation), "Placeholder mismatch: \(key)")
                precondition(fields(key) == fields(translation), "Purpose template mismatch: \(key)")
            }
            count += entries.count
        }
        precondition(count > 1300, "Both application and core catalogs must ship")
        print("PASS localization: \(chinese ? "Chinese" : "English"), \(count) translations, placeholders and interpolation")
    }
}
