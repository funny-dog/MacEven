import Foundation
import MacEvenCore

func require(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { fatalError(message) }
}
final class UpgradeFixture: @unchecked Sendable {
    let lock = NSLock(); var reads = 0
    func inventory(_ before: SoftwareEntry, _ after: SoftwareEntry) -> SoftwareScanResult { lock.lock(); defer { lock.unlock() }; reads += 1; return SoftwareScanResult(entries: [reads == 1 ? before : after]) }
}
@main struct SoftwareChecks {
    static func main() async throws {
        require(SoftwareUpdates.compareVersions("1.2", "1.2.0") == .orderedSame, "zero suffix equality")
        require(SoftwareUpdates.compareVersions("1.9", "1.10") == .orderedAscending, "numeric version ordering")
        require(SoftwareUpdates.compareVersions("1.2-beta", "1.3") == nil, "unknown format must remain unknown")
        let feed = Data("""
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
        <item><enclosure sparkle:version="11" sparkle:shortVersionString="1.1"/></item>
        <item><sparkle:minimumSystemVersion>99.0</sparkle:minimumSystemVersion><enclosure sparkle:version="99" sparkle:shortVersionString="9.9"/></item>
        <item><sparkle:channel>beta</sparkle:channel><enclosure sparkle:version="12"/></item>
        </channel></rss>
        """.utf8)
        let version = try SoftwareUpdates.sparkleVersion(feed, systemVersion: "14.0")
        require(version?.build == "11" && version?.display == "1.1", "select compatible stable feed item")
        let childFeed = Data("<rss xmlns:sparkle=\"http://www.andymatuschak.org/xml-namespaces/sparkle\"><channel><item><sparkle:version>24</sparkle:version><sparkle:shortVersionString>2.0.0</sparkle:shortVersionString><enclosure url=\"https://example.com/app.zip\"/><sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion></item></channel></rss>".utf8)
        let childVersion = try SoftwareUpdates.sparkleVersion(childFeed, systemVersion: "27.0")
        require(childVersion?.build == "24" && childVersion?.display == "2.0.0", "enclosure without version attributes must preserve item version elements")
        do { _ = try SoftwareUpdates.sparkleVersion(Data("<rss><broken>".utf8), systemVersion: "14.0"); fatalError("malformed feed accepted") } catch {}
        // build 号格式不兼容时，fallback 用 display 版本号比较
        require(SoftwareUpdates.compareVersions("1.2-beta", "1.2") == nil, "non-numeric build must not be comparable")
        // compareVersions 降级逻辑（模拟 check() 中的 ?? 链）
        let buildCmp = SoftwareUpdates.compareVersions("3.6.11-beta", "3.6.11") ?? SoftwareUpdates.compareVersions("3.6.11", "3.7.6")
        require(buildCmp == .orderedAscending, "fallback display comparison must detect update when build incompatible")
        // 测试 inferBrewToken 智能推断与中英文别名匹配
        require(SoftwareUpdates.inferBrewToken(name: "雷神加速器", bundleId: "com.leigod.macacc") == "leigod", "infer leigod")
        require(SoftwareUpdates.inferBrewToken(name: "aDrive", bundleId: "com.alicloud.smartdrive") == "adrive", "infer adrive")
        require(SoftwareUpdates.inferBrewToken(name: "Google Chrome", bundleId: "com.google.Chrome") == "google-chrome", "infer google-chrome")
        require(SoftwareUpdates.inferBrewToken(name: "百度网盘", bundleId: "com.baidu.BaiduNetdisk-mac") == "baidunetdisk", "infer baidunetdisk")
        require(SoftwareUpdates.inferBrewToken(name: "Visual Studio Code", bundleId: "com.microsoft.VSCode") == "visual-studio-code", "infer vscode")
        // 公开 cask 目录：按安装后的 app 文件名与退出包标识精确匹配，同名不同应用不得误配
        let catalogData = Data(#"""
        [{"token":"gemini","version":"2.10.1,406","artifacts":[{"app":["Gemini 2.app"],"target":"/Applications/Gemini 2.app"}]},
         {"token":"google-gemini","version":"1.131.4.1198","artifacts":[{"uninstall":[{"quit":["com.google.GeminiMacOS"]}]},{"app":["Gemini.app"],"target":"/Applications/Gemini.app"}]},
         {"token":"wechat","version":"4.1.15.55,270135","artifacts":[{"uninstall":[{"quit":"com.tencent.xinWeChat"}]},{"app":["WeChat.app"]}]},
         {"token":"thorium","version":"1.0","artifacts":[{"app":["Thorium.app",{"target":"Thorium Browser.app"}]}]},
         {"token":"dup-a","version":"1.0","artifacts":[{"app":["Dup.app"]}]},{"token":"dup-b","version":"2.0","artifacts":[{"app":["Dup.app"]}]},
         {"token":"nightly","version":"latest","artifacts":[{"app":["Nightly.app"]}]},
         {"token":"pkgapp","version":"5.0","artifacts":[{"uninstall":[{"pkgutil":["com.example.pkgapp"],"delete":"/Applications/PkgApp.app"}]}]},
         {"token":"renamed","version":"3.0","artifacts":[{"uninstall":[{"quit":"com.example.renamed"}]},{"app":["Renamed.app"]}]},
         {"token":"term","version":"3.0","artifacts":[{"app":["Term.app"]}]},{"token":"term@beta","version":"3.1-beta","artifacts":[{"app":["Term.app"]}]}]
        """#.utf8)
        let casks = try SoftwareUpdates.CaskCatalog.parse(catalogData)
        require(casks.match(appFileName: "Gemini.app", bundleIdentifier: "com.google.GeminiMacOS")?.token == "google-gemini", "match by installed app name")
        require(casks.match(appFileName: "Gemini.app", bundleIdentifier: "com.other.gemini") == nil, "declared quit identifiers must reject a same-named app")
        require(casks.match(appFileName: "WeChat.app", bundleIdentifier: "com.tencent.xinWeChat")?.version == "4.1.15.55", "strip build suffix from cask version")
        require(casks.match(appFileName: "Thorium Browser.app", bundleIdentifier: nil)?.token == "thorium", "renamed app target")
        require(casks.match(appFileName: "Dup.app", bundleIdentifier: "x") == nil, "ambiguous app name must not guess")
        require(casks.match(appFileName: "Nightly.app", bundleIdentifier: nil) == nil, "unversioned cask is not comparable")
        require(casks.match(appFileName: "PkgApp.app", bundleIdentifier: "com.example.pkgapp")?.token == "pkgapp", "pkg-installed cask matches by receipt identifier")
        require(casks.match(appFileName: "Renamed Copy.app", bundleIdentifier: "com.example.renamed")?.token == "renamed", "renamed app matches by quit identifier")
        require(casks.match(appFileName: "Unknown.app", bundleIdentifier: "com.example.pkgapp.helper") == nil, "identifier match must be exact")
        require(casks.match(appFileName: "Term.app", bundleIdentifier: nil)?.token == "term", "prefer the single stable variant")
        let googleGemini = SoftwareEntry(id: "/Applications/Gemini.app", name: "Gemini", url: URL(fileURLWithPath: "/Applications/Gemini.app"), bundleIdentifier: "com.google.GeminiMacOS", version: "1.131.4.1198")
        var stranger = SoftwareEntry(id: "/Applications/Other.app", name: "Gemini 2", url: URL(fileURLWithPath: "/Applications/Other.app"), bundleIdentifier: "com.example.other", version: "1.0")
        stranger.note = "尚未检查"
        let resolved = SoftwareUpdates.resolveCasks([googleGemini, stranger], catalog: casks)
        require(resolved[0].source == .homebrewCask && resolved[0].caskToken == "google-gemini" && resolved[0].latestVersion == "1.131.4.1198" && resolved[0].brewToken == nil, "catalog match records lookup token only")
        require(resolved[1].source == .unknown && resolved[1].caskToken == nil, "unmatched app must stay unknown instead of name guessing")
        let checkedGemini = try await SoftwareUpdates.check(resolved[0], token: CancellationToken())
        require(!checkedGemini.hasUpdate && !checkedGemini.canUpgrade, "same version must be current")
        var olderWeChat = SoftwareUpdates.resolveCasks([SoftwareEntry(id: "/Applications/WeChat.app", name: "微信", url: URL(fileURLWithPath: "/Applications/WeChat.app"), bundleIdentifier: "com.tencent.xinWeChat", version: "4.1.12")], catalog: casks)[0]
        olderWeChat = try await SoftwareUpdates.check(olderWeChat, token: CancellationToken())
        require(olderWeChat.hasUpdate && !olderWeChat.canUpgrade, "non-brew install must report update without offering brew upgrade")
        var special = SoftwareEntry(id: "special", name: "Special", version: "5.8.3", source: .homebrewCask); special.latestVersion = "5.8.3.413-db0e"
        special = try await SoftwareUpdates.check(special, token: CancellationToken())
        require(!special.hasUpdate && special.note.contains("版本格式特殊"), "incomparable cask version must be labeled after check")
        let fallback = SoftwareUpdates.resolveCasks([SoftwareEntry(id: "/Applications/Google Chrome.app", name: "Google Chrome", url: URL(fileURLWithPath: "/Applications/Google Chrome.app"), bundleIdentifier: "com.google.Chrome", version: "1")], catalog: nil)
        require(fallback[0].caskToken == "google-chrome" && fallback[0].latestVersion == nil && fallback[0].brewToken == nil, "without catalog fall back to inferred token for per-cask verification")
        // electron-updater 配置换算更新源
        require(SoftwareUpdates.electronFeedURL("provider: generic\nurl: https://dl.example.com/releases/\nupdaterCacheDirName: x\n")?.absoluteString == "https://dl.example.com/releases/latest-mac.yml", "generic feed")
        require(SoftwareUpdates.electronFeedURL("provider: generic\nurl: 'https://dl.example.com/app'\nchannel: beta\n")?.absoluteString == "https://dl.example.com/app/beta-mac.yml", "generic channel feed")
        require(SoftwareUpdates.electronFeedURL("owner: mifi\nrepo: lossless-cut\nprovider: github\n")?.absoluteString == "https://github.com/mifi/lossless-cut/releases/latest/download/latest-mac.yml", "github feed")
        require(SoftwareUpdates.electronFeedURL("provider: generic\nurl: ''\n") == nil, "empty url")
        require(SoftwareUpdates.electronFeedURL("provider: generic\nurl: http://insecure.example.com/\n") == nil, "insecure url")
        require(SoftwareUpdates.electronFeedURL("provider: github\nowner: ../x\nrepo: y\n") == nil, "unsafe github path")
        require(SoftwareUpdates.electronFeedURL("provider: s3\nbucket: x\n") == nil, "unsupported provider")
        require(SoftwareUpdates.electronFeedURL("provider: generic\nurl: https://dl.example.com/\nchannel: ../x\n") == nil, "unsafe channel")
        let electronLatest = try SoftwareUpdates.electronVersion(Data("version: 3.69.0\nfiles:\n  - url: a.zip\n    version: 9.9.9\nreleaseDate: '2026-06-03'\n".utf8))
        require(electronLatest == "3.69.0", "top-level version only")
        do { _ = try SoftwareUpdates.electronVersion(Data("files: []\n".utf8)); fatalError("missing version accepted") } catch {}
        let nonIPadEntry = SoftwareEntry(id: "test", name: "Test", version: "1.0", isIPadApp: false)
        require(!nonIPadEntry.isIPadApp, "default non-ipad app")
        let iPadEntry = SoftwareEntry(id: "ipad", name: "IPad", version: "1.0", isIPadApp: true)
        require(iPadEntry.isIPadApp, "ipad app flag")
        let emptyBrew = Data(#"{"formulae":[],"casks":[]}"#.utf8)
        let emptyRows = try SoftwareUpdates.brewEntries(emptyBrew, caskroom: URL(fileURLWithPath: "/nonexistent"), applications: [])
        require(emptyRows.isEmpty, "empty brew")
        let brew = Data(#"{"formulae":[{"name":"tool","full_name":"tool","versions":{"stable":"2.0"},"installed":[{"version":"1.0"}],"outdated":true,"pinned":true}],"casks":[]}"#.utf8)
        let rows = try SoftwareUpdates.brewEntries(brew, caskroom: URL(fileURLWithPath: "/nonexistent"), applications: [])
        require(rows.count == 1 && !rows[0].canUpgrade && rows[0].hasUpdate, "pinned package must not upgrade")
        do { _ = try SoftwareUpdates.brewEntries(Data(#"{"formulae":{}}"#.utf8), caskroom: URL(fileURLWithPath: "/"), applications: []); fatalError("bad brew shape") } catch {}
        if SoftwareUpdates.brewExecutable != nil {
            var before = SoftwareEntry(id: "formula:tool", name: "Tool", version: "1.0", source: .homebrewFormula)
            before.brewToken = "tool"; before.latestVersion = "2.0"; before.hasUpdate = true
            var after = SoftwareEntry(id: "formula:tool", name: "Tool", version: "2.0", source: .homebrewFormula)
            after.brewToken = "tool"; after.latestVersion = "2.0"
            let original = before, updated = after, fixture = UpgradeFixture()
            let installed = try SoftwareUpdates.upgrade(original, token: CancellationToken(), inventory: { _ in fixture.inventory(original, updated) }, command: { _, args in
                guard args == ["upgrade", "--formula", "--no-ask", "tool"] else { throw MacEvenError("unsafe target arguments") }
                return SoftwareCommandResult(status: 0, output: "", error: "")
            })
            require(installed.version == "2.0", "upgrade must reread actual installed version")
            do {
                _ = try SoftwareUpdates.upgrade(original, token: CancellationToken(), inventory: { _ in SoftwareScanResult(entries: [original]) }, command: { _, _ in SoftwareCommandResult(status: 0, output: "", error: "") })
                fatalError("exit zero without installed change was accepted")
            } catch {}
        }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("MacEven-software-checks-\(UUID())")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let app = home.appendingPathComponent("Sample.app/Contents")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let info: [String: String] = ["CFBundlePackageType":"APPL","CFBundleIdentifier":"test.software","CFBundleName":"Sample","CFBundleShortVersionString":"1.0","CFBundleVersion":"10","SUFeedURL":"https://example.com/appcast.xml"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Info.plist"))
        let apps = try SoftwareUpdates.applications(roots: [try canonicalFileURL(home)], token: CancellationToken())
        require(apps.entries.count == 1 && apps.entries[0].source == .sparkle && apps.entries[0].version == "1.0" && apps.errors.isEmpty, "metadata catalog")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Broken.app"), withIntermediateDirectories: true)
        // 带 app-update.yml 的 Electron 应用识别为 Electron 更新源
        let electronApp = home.appendingPathComponent("Electronic.app/Contents")
        try FileManager.default.createDirectory(at: electronApp.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundlePackageType":"APPL","CFBundleIdentifier":"test.electron","CFBundleName":"Electronic","CFBundleShortVersionString":"1.0"], format: .xml, options: 0).write(to: electronApp.appendingPathComponent("Info.plist"))
        try Data("provider: generic\nurl: https://dl.example.com/\n".utf8).write(to: electronApp.appendingPathComponent("Resources/app-update.yml"))
        let withElectron = try SoftwareUpdates.applications(roots: [try canonicalFileURL(home)], token: CancellationToken())
        require(withElectron.entries.first { $0.bundleIdentifier == "test.electron" }.map { $0.source == .electron && $0.feedURL?.absoluteString == "https://dl.example.com/latest-mac.yml" } == true, "electron updater source")
        try FileManager.default.removeItem(at: electronApp.deletingLastPathComponent())
        let partial = try SoftwareUpdates.applications(roots: [try canonicalFileURL(home)], token: CancellationToken())
        require(partial.entries.count == 1 && partial.errors.count == 1, "broken application must preserve catalog and report warning")
        let caskroom = home.appendingPathComponent("Caskroom")
        let caskInstall = caskroom.appendingPathComponent("sample/1.0")
        try FileManager.default.createDirectory(at: caskInstall, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: caskInstall.appendingPathComponent("Sample.app"), withDestinationURL: try canonicalFileURL(app.deletingLastPathComponent()))
        let caskData = Data(#"{"formulae":[],"casks":[{"token":"sample","installed":"1.0","version":"2.0","outdated":true,"bundle_version":"10","artifacts":[{"app":["Sample.app"]}]}]}"#.utf8)
        let caskRows = try SoftwareUpdates.brewEntries(caskData, caskroom: caskroom, applications: apps.entries)
        require(caskRows.count == 1 && caskRows[0].id == apps.entries[0].id && caskRows[0].canUpgrade, "cask must match its real installed application path")
        let unlinked = try SoftwareUpdates.brewEntries(caskData, caskroom: home.appendingPathComponent("Missing"), applications: apps.entries)
        require(!unlinked[0].canUpgrade && unlinked[0].url == nil, "unmatched cask must be read only")
        var newerApp = SoftwareEntry(id: apps.entries[0].id, name: "Sample", url: apps.entries[0].url, bundleIdentifier: "test.software", version: "1.1", buildVersion: "11")
        newerApp.source = .sparkle
        let protected = try SoftwareUpdates.brewEntries(caskData, caskroom: caskroom, applications: [newerApp])
        require(!protected[0].canUpgrade, "self-updated application must not be replaced from older brew record")
        if SoftwareUpdates.brewExecutable != nil {
            let original = caskRows[0]
            var changed = original; changed.latestVersion = nil; changed.hasUpdate = false
            let changedTarget = changed
            do {
                _ = try SoftwareUpdates.upgrade(original, token: CancellationToken(), inventory: { _ in SoftwareScanResult(entries: [changedTarget]) }, command: { _, _ in fatalError("changed target executed") })
                fatalError("changed cask target accepted")
            } catch {}
            var installed = SoftwareEntry(id: original.id, name: "Sample", url: original.url, bundleIdentifier: "test.software", version: "2.0", buildVersion: "20", source: .homebrewCask)
            installed.brewToken = "sample"; installed.latestVersion = "2.0"
            let fixture = UpgradeFixture(), updated = installed
            _ = try SoftwareUpdates.upgrade(original, token: CancellationToken(), inventory: { _ in fixture.inventory(original, updated) }, command: { _, args in
                require(args == ["upgrade", "--cask", "--no-ask", "--no-quit", "--require-sha", "--greedy-auto-updates", "sample"], "cask checksum and no-quit arguments")
                return SoftwareCommandResult(status: 0, output: "", error: "")
            })
        }
        let result = try SoftwareCommand.run(URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["%s", "a;$(touch nope)"])
        require(result.output == "a;$(touch nope)" && !FileManager.default.fileExists(atPath: home.appendingPathComponent("nope").path), "arguments must not become shell code")
        let token = CancellationToken(); token.cancel()
        do { _ = try SoftwareCommand.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], token: token); fatalError("cancelled command ran") } catch {}
        let activeCancellation = CancellationToken(), started = ProcessInfo.processInfo.systemUptime
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { activeCancellation.cancel() }
        do { _ = try SoftwareCommand.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], token: activeCancellation); fatalError("active cancellation ignored") } catch {}
        require(ProcessInfo.processInfo.systemUptime - started < 2, "cancelled child did not finish promptly")
        do { _ = try SoftwareCommand.run(URL(fileURLWithPath: "/usr/bin/yes"), arguments: [], timeout: 0.1); fatalError("unbounded output accepted") } catch {}
        if ProcessInfo.processInfo.arguments.contains("--live") {
            let actual = try SoftwareUpdates.discover(token: CancellationToken(), refreshBrew: false)
            print("Live read-only catalog: \(actual.entries.count) entries, \(actual.errors.count) warnings")
            let startup = try StartupItems().scan(token: CancellationToken())
            print("Live read-only startup: \(startup.items.count) entries, \(startup.errors.count) warnings, \(startup.items.filter { $0.blockedReason == nil }.count) manageable")
        }
        print("Software checks passed")
    }
}
