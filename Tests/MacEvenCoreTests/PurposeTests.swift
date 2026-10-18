import Foundation
import MacEvenCore

// 防止的问题：规则漏测、同名目录误判、深层规则被祖先盖住、“勿动”被下层放开、应用标识解析说过头、翻页变慢。
final class PurposeTests {
    private let apps = [CacheApplication(id: "com.tencent.xinWeChat", name: "微信"), CacheApplication(id: "com.google.Chrome", name: "Google Chrome"),
        CacheApplication(id: "com.microsoft.Word", name: "Microsoft Word"), CacheApplication(id: "com.apple.Safari", name: "Safari"),
        CacheApplication(id: "com.example.cafe", name: "Café")]

    private func expect(_ classifier: PurposeClassifier, _ path: String, directory: Bool = true, _ rule: String?, inherited: Bool = false,
        hits: inout Set<String>, file: StaticString = #file, line: UInt = #line) {
        let label = classifier.label(for: path, isDirectory: directory)
        requireTest(label?.ruleID == rule, "\(path)：期望 \(rule ?? "nil")，实际 \(label?.ruleID ?? "nil")", file: file, line: line)
        // 扫描时逐层前进的结果必须与整条路径计算一致（含安全等级、继承与说明文字）。
        let incremental = Self.incremental(classifier, path, directory: directory)
        requireTest(classifier.label(of: incremental) == label, "\(path)：逐层计算结果与整路径不一致", file: file, line: line)
        if let label, rule != nil {
            requireTest(label.inherited == inherited, "\(path)：继承标记应为 \(inherited)", file: file, line: line)
            requireTest(!label.title.contains("{") && !label.detail.contains("{"), "\(path)：模板未填充", file: file, line: line)
            if !label.inherited { hits.insert(label.ruleID) }
        }
    }

    static func incremental(_ classifier: PurposeClassifier, _ path: String, directory: Bool) -> PurposeClassifier.Trail {
        let parts = path.split(separator: "/").map(String.init)
        var trail = classifier.trail(for: "/", isDirectory: true)
        for (offset, name) in parts.enumerated() {
            trail = classifier.child(of: trail, name: name, isDirectory: offset == parts.count - 1 ? directory : true)
        }
        return trail
    }

    func testRuleTableAndExamples() throws {
        XCTAssertEqual(Set(PurposeRule.builtIn.map(\.id)).count, PurposeRule.builtIn.count)
        for rule in PurposeRule.builtIn { requireTest(PurposeClassifier.problem(rule) == nil, PurposeClassifier.problem(rule) ?? "") }
        XCTAssertNotNil(PurposeClassifier.problem(PurposeRule(id: "bad.anchor", match: .path("Library"), category: .cache, safety: .regenerable, title: "", detail: "")))
        XCTAssertNotNil(PurposeClassifier.problem(PurposeRule(id: "bad.wild", match: .name("*"), category: .cache, safety: .regenerable, title: "", detail: "")))
        XCTAssertNotNil(PurposeClassifier.problem(PurposeRule(id: "bad.capture", match: .path("~/{bundle}"), category: .cache, safety: .regenerable, title: "", detail: "")))

        try CoreTests().withTree { raw, _ in
            let fm = FileManager.default
            let home = try canonicalFileURL(raw).appendingPathComponent("home"), h = home.path
            func make(_ relative: String, file: Bool = false) throws {
                let url = home.appendingPathComponent(relative)
                if file { try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true); try Data([1]).write(to: url) }
                else { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
            }
            for dir in ["code/web/node_modules/react", "code/web/dist", "code/web/.next", "code/rs/target", "code/sw/.build", "code/ios/Pods",
                "code/cpp/build", "code/py/__pycache__", "code/py/.git/objects", "Downloads/node_modules", "Documents/build"] { try make(dir) }
            for file in ["code/web/package.json", "code/rs/Cargo.toml", "code/sw/Package.swift", "code/ios/Podfile", "code/cpp/CMakeLists.txt",
                "code/py/.venv/pyvenv.cfg", "code/py/venv/pyvenv.cfg", "code/tool-cache/CACHEDIR.TAG"] { try make(file, file: true) }

            var hits = Set<String>()
            // 系统路径与真实主目录无关；临时目录位于 /private/var/folders，主目录示例用去掉这两条规则的表，避免一切都继承系统目录标签。
            let full = PurposeClassifier(home: home, applications: apps)
            let c = PurposeClassifier(rules: PurposeRule.builtIn.filter { !["sys.folders", "sys.private"].contains($0.id) }, home: home, applications: apps)
            expect(full, "/System", "sys.system", hits: &hits)
            expect(full, "/System/Library/Kernels/kernel", directory: false, "sys.system", inherited: true, hits: &hits)
            expect(full, "/usr", "sys.usr", hits: &hits)
            expect(full, "/usr/local", "app.usrlocal", hits: &hits)
            XCTAssertEqual(full.label(for: "/usr/local", isDirectory: true)?.safety, .keep)
            for (path, rule) in [("/bin", "sys.bin"), ("/sbin", "sys.sbin"), ("/private/var/vm", "sys.vm"), ("/private/var/db", "sys.db"),
                ("/private/var/folders", "sys.folders"), ("/private/var/log", "sys.log"), ("/cores", "sys.cores"),
                ("/Library/Developer/CoreSimulator", "sys.simruntimes"), ("/Volumes", "sys.volumes"),
                ("/Library", "sys.library"), ("/Library/Application Support", "sys.library.as"), ("/Library/Caches", "sys.library.caches"),
                ("/Library/Logs", "sys.library.logs"), ("/Library/Fonts", "sys.library.fonts"), ("/Library/Developer/CommandLineTools", "sys.clt"),
                ("/Applications", "app.applications"), ("/Applications/Xcode.app", "app.bundle"), ("/opt/homebrew", "app.homebrew"),
                ("/opt/homebrew/Cellar", "app.homebrew.cellar"), ("/Users", "sys.users"), ("/private", "sys.private"), ("/private/tmp", "sys.tmp"),
                ("/private/etc", "sys.etc"), ("/opt", "sys.opt")] { expect(full, path, rule, hits: &hits) }
            expect(full, "/private/var/vm/sleepimage", directory: false, "sys.vm", inherited: true, hits: &hits)
            expect(full, "/Applications/Xcode.app/Contents/MacOS/Xcode", directory: false, "app.bundle", inherited: true, hits: &hits)
            expect(full, "/dev", nil, hits: &hits)
            // /Users 只标注自身，主目录及其中未识别的文件夹不继承。
            expect(full, "/Users/someone", nil, hits: &hits)
            expect(full, "/Users/someone/code/app", nil, hits: &hits)
            expect(full, "/Volumes/Backup/photos", nil, hits: &hits)
            // 临时目录里的项目仍能被更深的规则识别（sys.folders 不是 opaque）。
            expect(full, h + "/code/web/node_modules", "proj.node_modules", hits: &hits)

            for (relative, rule) in [("Desktop", "home.desktop"), ("Documents", "home.documents"), ("Downloads", "home.downloads"),
                ("Pictures", "home.pictures"), ("Movies", "home.movies"), ("Music", "home.music"), (".Trash", "home.trash"),
                ("Pictures/Photos Library.photoslibrary", "home.photos"), ("Applications", "app.user"),
                ("Library", "lib.root"), ("Library/Caches", "lib.caches"), ("Library/Caches/com.tencent.xinWeChat", "lib.caches.app"),
                ("Library/Application Support", "lib.as"), ("Library/Application Support/Microsoft Word", "lib.as.app"),
                ("Library/Containers", "lib.containers"), ("Library/Containers/com.example.cafe", "lib.containers.app"), ("Library/Containers/com.tencent.xinWeChat", "lib.wechat"),
                ("Library/Containers/com.example.cafe/Data/Library/Caches", "lib.containers.cache"),
                ("Library/Group Containers", "lib.group"), ("Library/Group Containers/UBF8T346G9.com.microsoft", "lib.group.app"),
                ("Library/Preferences", "lib.prefs"), ("Library/Logs", "lib.logs"), ("Library/Logs/DiagnosticReports", "lib.crash"),
                ("Library/Saved Application State", "lib.state"), ("Library/HTTPStorages", "lib.http"), ("Library/WebKit", "lib.webkit"),
                ("Library/Mail", "lib.mail"), ("Library/Messages", "lib.messages"), ("Library/Mobile Documents", "lib.icloud"),
                ("Library/CloudStorage", "lib.cloudstorage"), ("Library/Application Support/MobileSync/Backup", "lib.mobilesync"),
                ("Library/Application Support/Google/Chrome", "lib.chrome"), ("Library/Developer", "lib.developer"),
                ("Library/Developer/Xcode/Archives", "dev.archives"), ("Library/Developer/CoreSimulator/Devices", "dev.simdevices"),
                (".cargo", "dev.cargo"), (".rustup", "dev.rustup"), (".npm", "dev.npm"), (".m2/repository", "dev.m2"), (".cache", "dev.cache"),
                (".nvm", "dev.nvm"), (".cache/huggingface", "dev.huggingface"), (".gradle/wrapper/dists", "dev.gradlewrapper"), (".orbstack", "dev.orbstack"), (".pyenv", "dev.pyenv"), ("go/pkg/mod", "dev.gomod"), (".docker", "dev.docker"),
                ("Library/Containers/com.docker.docker", "dev.dockervm"), (".ollama/models", "dev.ollama"), (".vscode/extensions", "dev.vscode"),
                ("code/web/node_modules", "proj.node_modules"), ("code/web/dist", "proj.dist"), ("code/web/.next", "proj.next"),
                ("code/rs/target", "proj.cargo"), ("code/sw/.build", "proj.swiftpm"), ("code/ios/Pods", "proj.pods"), ("code/cpp/build", "proj.build"),
                ("code/py/.venv", "proj.venv"), ("code/py/venv", "proj.venv2"), ("code/py/__pycache__", "proj.pycache"), ("code/py/.git", "proj.git"),
                ("code/tool-cache", "proj.cachedir"), ("Documents/Vault.sparsebundle", "file.sparsebundle"), ("Documents/App.xcarchive", "file.xcarchive")] {
                expect(c, h + "/" + relative, rule, hits: &hits)
            }
            for rule in DeveloperCleanupRule.allCases { expect(c, h + "/" + rule.relativePath, "dev.cleanup.\(rule.rawValue)", hits: &hits) }
            for (relative, rule) in [("Downloads/.DS_Store", "file.dsstore"), ("Downloads/Xcode.dmg", "file.dmg"), ("Downloads/Tool.pkg", "file.pkg"),
                ("Downloads/iPhone.ipsw", "file.ipsw"), ("Downloads/Xcode_17.xip", "file.xip"), ("Downloads/ubuntu.iso", "file.iso")] {
                expect(c, h + "/" + relative, directory: false, rule, hits: &hits)
            }
            let missing = Set(PurposeRule.builtIn.map(\.id)).subtracting(hits)
            requireTest(missing.isEmpty, "以下规则没有正例：\(missing.sorted())")

            // 继承与反例：缺少标志文件的同名目录不命中，只继承所在位置的标签。
            expect(c, h + "/code/web/node_modules/react", "proj.node_modules", inherited: true, hits: &hits)
            expect(c, h + "/code/py/.git/objects", "proj.git", inherited: true, hits: &hits)
            XCTAssertEqual(c.label(for: h + "/code/py/.git/objects", isDirectory: true)?.safety, .keep)
            expect(c, h + "/Downloads/node_modules", "home.downloads", inherited: true, hits: &hits)
            expect(c, h + "/Documents/build", "home.documents", inherited: true, hits: &hits)
            expect(c, h + "/code/web", nil, hits: &hits)
            expect(c, h, nil, hits: &hits)
            // 深层覆盖祖先：沙盒（谨慎）里的缓存是可重建。
            XCTAssertEqual(c.label(for: h + "/Library/Containers/com.example.cafe/Data/Library/Caches/x", isDirectory: true)?.safety, .regenerable)
            XCTAssertEqual(c.label(for: h + "/Library/Containers/com.example.cafe/Data/Documents", isDirectory: true)?.ruleID, "lib.containers.app")
            // 同一深度上精确路径胜过捕获：Homebrew 缓存不是“未识别应用 缓存”。
            XCTAssertEqual(c.label(for: h + "/Library/Caches/Homebrew", isDirectory: true)?.ruleID, "dev.cleanup.homebrew")
        }
    }

    func testApplicationResolutionAndNormalization() throws {
        let home = URL(fileURLWithPath: "/Users/tester")
        let c = PurposeClassifier(home: home, applications: apps)
        func title(_ relative: String) -> String? { c.label(for: "/Users/tester/" + relative, isDirectory: true)?.title }
        XCTAssertEqual(title("Library/Caches/com.tencent.xinWeChat"), "微信 缓存")
        XCTAssertEqual(title("Library/Group Containers/UBF8T346G9.com.microsoft"), "Microsoft Word 共享数据")
        XCTAssertEqual(title("Library/Group Containers/group.com.apple.notes"), "系统组件 共享数据")
        XCTAssertEqual(title("Library/Containers/com.apple.Safari"), "Safari 沙盒数据")
        XCTAssertEqual(title("Library/Caches/com.unknown.tool"), "未识别应用 缓存")
        let unknown = c.label(for: "/Users/tester/Library/Caches/com.unknown.tool", isDirectory: true)!
        XCTAssertTrue(unknown.evidence.contains("com.unknown.tool") && unknown.evidence.contains("未在应用目录中找到") && !unknown.evidence.contains("卸载"))
        XCTAssertEqual(title("Library/Application Support/Google"), "Google 数据")
        // 普通名字的缓存目录：先按应用名匹配，否则原样显示，而不是“未识别应用”。
        XCTAssertEqual(title("Library/Caches/Google Chrome"), "Google Chrome 缓存")
        XCTAssertEqual(title("Library/Caches/Doubao"), "Doubao 缓存")
        // 一个前缀对应多个应用时不随意归给其中一个；同一开发商的辅助标识归到该开发商的应用。
        let suite = PurposeClassifier(home: home, applications: apps + [CacheApplication(id: "com.tencent.WorkBuddy", name: "WorkBuddy")])
        XCTAssertEqual(suite.label(for: "/Users/tester/Library/Group Containers/FN2V63AD2J.com.tencent", isDirectory: true)?.title, "WorkBuddy 等 共享数据")
        XCTAssertEqual(title("Library/Group Containers/UBF8T346G9.com.microsoft.oneauth"), "Microsoft Word 共享数据")
        XCTAssertEqual(title("Library/Group Containers/243LU875E5.groups.com.apple.Safari"), "Safari 共享数据")
        XCTAssertEqual(title("Library/Containers/com.tencent.xinWeChat.WeChatMacShare"), "微信 沙盒数据")
        // 微信聊天数据整体勿动，其中的缓存也不单独放开。
        XCTAssertEqual(c.label(for: "/Users/tester/Library/Containers/com.tencent.xinWeChat/Data/Library/Caches", isDirectory: true)?.safety, .keep)
        XCTAssertEqual(title("Library/Containers/com.github.someone.tool"), "未识别应用 沙盒数据")
        XCTAssertTrue(c.label(for: "/Users/tester/Library/Application Support/Microsoft Word", isDirectory: true)!.evidence.contains("Microsoft Word"))
        // 大小写与 Unicode 规范化：NFD 文件夹名能对上 NFC 应用名，大写路径也能命中。
        XCTAssertEqual(title("Library/Application Support/Cafe\u{301}"), "Café 数据")
        XCTAssertEqual(c.label(for: "/Users/tester/LIBRARY/caches", isDirectory: true)?.ruleID, "lib.caches")
        // 继承说明指向来源目录。
        let inherited = c.label(for: "/Users/tester/Library/Caches/com.tencent.xinWeChat/a/b.db", isDirectory: false)!
        XCTAssertTrue(inherited.inherited && inherited.evidence.contains("/Users/tester/Library/Caches/com.tencent.xinWeChat"))
        // 没有应用目录时照常标注，只是不解析名称。
        XCTAssertEqual(PurposeClassifier(home: home).label(for: "/Users/tester/Library/Caches/com.tencent.xinWeChat", isDirectory: true)?.title, "未识别应用 缓存")
    }

    func testKeepCapsDescendantsAndOpaqueStopsMatching() throws {
        let rules = [PurposeRule(id: "t.keep", match: .path("/keep"), category: .system, safety: .keep, title: "保留", detail: "d"),
            PurposeRule(id: "t.cache", match: .path("/keep/cache"), category: .cache, safety: .regenerable, title: "缓存", detail: "d"),
            PurposeRule(id: "t.opaque", match: .path("/sealed"), category: .system, safety: .caution, title: "封闭", detail: "d", opaque: true),
            PurposeRule(id: "t.inner", match: .path("/sealed/inner"), category: .cache, safety: .regenerable, title: "内部", detail: "d"),
            PurposeRule(id: "t.both1", match: .path("/both"), category: .cache, safety: .regenerable, title: "甲", detail: "d"),
            PurposeRule(id: "t.both2", match: .name("both"), category: .system, safety: .caution, title: "乙", detail: "d")]
        let c = PurposeClassifier(rules: rules, home: URL(fileURLWithPath: "/Users/tester"))
        let capped = c.label(for: "/keep/cache", isDirectory: true)!
        XCTAssertEqual(capped.ruleID, "t.cache"); XCTAssertEqual(capped.safety, .keep)
        XCTAssertEqual(c.label(for: "/sealed/inner", isDirectory: true)?.ruleID, "t.opaque")
        XCTAssertEqual(c.label(for: "/sealed/inner", isDirectory: true)?.inherited, true)
        // 同节点多条命中：标题取最具体的，安全等级取最保守的。
        let both = c.label(for: "/both", isDirectory: true)!
        XCTAssertEqual(both.ruleID, "t.both1"); XCTAssertEqual(both.safety, .caution)
    }

    func testPageLabelsAndSpeed() throws {
        try CoreTests().withTree { raw, index in
            let fm = FileManager.default
            let home = try canonicalFileURL(raw).appendingPathComponent("home")
            let project = home.appendingPathComponent("code/web")
            try fm.createDirectory(at: project.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
            try Data([1]).write(to: project.appendingPathComponent("package.json"))
            for n in 0..<100 { try fm.createDirectory(at: project.appendingPathComponent("node_modules/pkg\(n)/lib"), withIntermediateDirectories: true) }
            _ = try Scanner.scan(root: home, index: index, token: CancellationToken())
            func child(_ parent: Int64, _ name: String) throws -> DiskEntry {
                try index.children(of: parent, limit: 100).first { $0.name == name }!
            }
            let code = try child(1, "code"), web = try child(code.id, "web"), modules = try child(web.id, "node_modules")
            let c = PurposeClassifier(rules: PurposeRule.builtIn.filter { !["sys.folders", "sys.private"].contains($0.id) }, home: home)
            let top = c.labels(for: try index.children(of: web.id), directory: web.url.path)
            XCTAssertEqual(top.entries[modules.id]?.ruleID, "proj.node_modules")
            XCTAssertEqual(top.directory, nil)
            let page = try index.children(of: modules.id)
            XCTAssertEqual(page.count, 100)
            let start = Date()
            for _ in 0..<200 {
                let result = c.labels(for: page, directory: modules.url.path)
                requireTest(result.entries.count == 100 && result.entries.values.allSatisfy { $0.inherited && $0.ruleID == "proj.node_modules" })
                requireTest(result.directory?.ruleID == "proj.node_modules" && result.directory?.inherited == false)
            }
            let average = Date().timeIntervalSince(start) / 200
            requireTest(average < 0.02, "每页用途标签平均耗时 \(Int(average * 1000)) ms，超过 20 ms")
        }
    }

    /// 扫描时写入的用途：各用途合计与手算一致，加上未识别等于根占用；移到废纸篓后的重算与重新扫描一致。
    func testScanSummary() throws {
        try CoreTests().withTree { raw, index in
            let fm = FileManager.default
            let home = try canonicalFileURL(raw).appendingPathComponent("home")
            var sizes: [String: Int64] = [:]
            func file(_ relative: String, _ count: Int) throws {
                let url = home.appendingPathComponent(relative)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(repeating: 7, count: count).write(to: url)
                sizes[relative] = try FileIdentity.read(url).allocated
            }
            try file("Library/Caches/com.x/a.bin", 9000)
            try file("Library/Containers/com.y/Data/Library/Caches/b.bin", 20000)
            try file("Library/Containers/com.y/Data/Documents/c.bin", 30000)
            try file("code/web/package.json", 10)
            try file("code/web/node_modules/m/index.js", 50000)
            try file("Downloads/x.dmg", 70000)
            try file("Downloads/notes/n.txt", 5000)
            try file("misc/u.bin", 6000)
            try file("cut/y.bin", 8000)
            try file("cut/inner/z.bin", 12000)
            // 不可继承的规则：只标注 cut 自身，其中内容算“未识别”。
            let rules = PurposeRule.builtIn.filter { !["sys.folders", "sys.private"].contains($0.id) }
                + [PurposeRule(id: "t.cut", match: .name("cut"), category: .backup, safety: .caution, title: "切断", detail: "d", heritable: false)]
            let c = PurposeClassifier(rules: rules, home: home)
            _ = try Scanner.scan(root: home, index: index, token: CancellationToken(), purposes: c)
            func summary(_ index: DiskIndex) throws -> PurposeSummary {
                PurposeSummary(totals: try index.purposeTotals(), total: try index.entry(id: 1)!.allocatedSize, rules: rules)
            }
            let s = try summary(index)
            func group(_ category: PurposeCategory) -> Int64 { s.groups.first { $0.category == category }?.bytes ?? 0 }
            func sum(_ keys: [String]) -> Int64 { keys.reduce(0) { $0 + sizes[$1]! } }
            XCTAssertEqual(group(.cache), sum(["Library/Caches/com.x/a.bin", "Library/Containers/com.y/Data/Library/Caches/b.bin"]))
            XCTAssertEqual(group(.appData), sum(["Library/Containers/com.y/Data/Documents/c.bin"]))
            XCTAssertEqual(group(.buildArtifact), sum(["code/web/node_modules/m/index.js"]))
            XCTAssertEqual(group(.installer), sum(["Downloads/x.dmg"]))
            XCTAssertEqual(group(.userFiles), sum(["Downloads/notes/n.txt"]))
            XCTAssertEqual(group(.backup), 0)
            XCTAssertEqual(s.unlabeled, sum(["code/web/package.json", "misc/u.bin", "cut/y.bin", "cut/inner/z.bin"]))
            XCTAssertEqual(s.labeled + s.unlabeled, s.total)
            XCTAssertEqual(s.safetyBytes[.regenerable], group(.cache) + group(.buildArtifact))
            // 汇总口径与列表标签一致：每个文件的标签所属类别就是它被计入的用途。
            for relative in sizes.keys {
                let label = c.label(for: home.appendingPathComponent(relative).path, isDirectory: false)
                let expected: PurposeCategory? = relative.hasPrefix("Library/Caches") || relative.contains("Data/Library/Caches") ? .cache
                    : relative.contains("Documents") ? .appData : relative.contains("node_modules") ? .buildArtifact
                    : relative.hasSuffix(".dmg") ? .installer : relative.hasPrefix("Downloads") ? .userFiles : nil
                requireTest(label?.category == expected, "\(relative)：标签类别 \(String(describing: label?.category)) 与汇总口径不一致")
            }
            // 分页按归属字节降序；沙盒文件夹只列归它的部分，不含其中的缓存。
            let caches = try index.purposePage(tags: s.groups.first { $0.category == .cache }!.tags)
            XCTAssertEqual(caches.entries.map(\.name), ["Caches", "com.x"])
            XCTAssertFalse(caches.hasNext)
            let container = try index.purposePage(tags: s.groups.first { $0.category == .appData }!.tags).entries.first!
            XCTAssertEqual(container.name, "com.y")
            XCTAssertTrue(container.allocatedSize > sum(["Library/Containers/com.y/Data/Documents/c.bin"]))

            // 移走一个边界和一个非边界目录后，重算结果与重新扫描一致。
            func id(_ relative: String) throws -> Int64 {
                var current: Int64 = 1
                for name in relative.split(separator: "/") { current = try index.children(of: current).first { $0.name == name }!.id }
                return current
            }
            let results = TrashService(index: index, home: home).move(ids: [try id("code/web/node_modules"), try id("Downloads/notes")])
            requireTest(results.allSatisfy { $0.error == nil }, "移到废纸篓失败：\(results.compactMap(\.error))")
            let after = try summary(index)
            XCTAssertEqual(after.groups.first { $0.category == .buildArtifact }, nil)
            XCTAssertEqual(after.groups.first { $0.category == .userFiles }, nil)
            let fresh = try DiskIndex(url: raw.appendingPathComponent("fresh.sqlite"))
            defer { fresh.close() }
            _ = try Scanner.scan(root: home, index: fresh, token: CancellationToken(), purposes: c)
            XCTAssertEqual(after, try summary(fresh))
            // 不带分类器的扫描不写入任何用途。
            _ = try Scanner.scan(root: home, index: fresh, token: CancellationToken())
            XCTAssertEqual(try fresh.purposeTotals(), [])
        }
    }
}
