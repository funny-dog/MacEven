import Foundation
import Darwin
import MacEvenCore

/// 0.21 重复文件加速：分级哈希、门槛与克隆过滤、按磁盘扫描、外接卷移到废纸篓。
final class DuplicateFastScanTests {
    private let fm = FileManager.default

    private func withFakeHome(_ body: (URL, DiskIndex) throws -> Void) throws {
        let base = fm.temporaryDirectory.appendingPathComponent("MacEven-dup-fast-\(UUID())")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let home = try canonicalFileURL(base)
        let index = try DiskIndex(url: home.appendingPathComponent("index.sqlite"))
        defer {
            index.close()
            try? fm.removeItem(at: base)
        }
        try body(home, index)
    }

    /// 可复现的伪随机内容，避免全零数据让抽样失去区分度。
    private func payload(_ count: Int, seed: UInt64) -> Data {
        var state = seed &* 6364136223846793005 &+ 1442695040888963407
        var data = Data(count: count)
        data.withUnsafeMutableBytes { raw in
            for i in 0..<count {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                raw[i] = UInt8(truncatingIfNeeded: state >> 33)
            }
        }
        return data
    }

    private func write(_ data: Data, to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func changed(_ data: Data, at offset: Int) -> Data {
        var copy = data
        copy[offset] ^= 0xff
        return copy
    }

    func testStagedHashingPrunesBySamples() throws {
        try withFakeHome { home, index in
            let dir = home.appendingPathComponent("Media")
            let base = payload(200_000, seed: 1)
            try write(base, to: dir.appendingPathComponent("a.bin"))
            try write(base, to: dir.appendingPathComponent("b.bin"))
            try write(changed(base, at: 0), to: dir.appendingPathComponent("head.bin"))
            try write(changed(base, at: 100_000), to: dir.appendingPathComponent("middle.bin"))
            try write(changed(base, at: 199_999), to: dir.appendingPathComponent("tail.bin"))
            // 不在三块抽样范围内的差异：抽样相同，完整哈希才能排除。
            try write(changed(base, at: 50_000), to: dir.appendingPathComponent("unsampled.bin"))
            let small = payload(1_000, seed: 2)
            try write(small, to: dir.appendingPathComponent("small-1.bin"))
            try write(small, to: dir.appendingPathComponent("small-2.bin"))

            let service = DuplicateFiles(index: index, home: home)
            let summary = try service.scan(root: dir, token: CancellationToken())
            XCTAssertFalse(summary.incomplete)
            XCTAssertEqual(summary.errors, 0)
            XCTAssertTrue(service.isValid)
            let groups = try service.groups()
            XCTAssertEqual(groups.map(\.logicalSize), [200_000, 1_000])
            XCTAssertEqual(try service.members(groupID: groups[0].id).map(\.name).sorted(), ["a.bin", "b.bin"])
            // 6 个大文件各抽样 3 × 16 KiB；只有抽样相同的 a、b、unsampled 完整读取；小文件整读一次。
            let sampledBytes: Int64 = 6 * 3 * 16 * 1024, fullBytes: Int64 = 3 * 200_000 + 2 * 1_000
            XCTAssertEqual(summary.readBytes, sampledBytes + fullBytes)
            XCTAssertEqual(summary.hashed, 5)
            XCTAssertEqual(summary.sampled, 3)
        }
    }

    func testMinimumSizeAndClonesAreFiltered() throws {
        try withFakeHome { home, index in
            let dir = home.appendingPathComponent("Downloads")
            let tiny = payload(100, seed: 3), big = payload(300_000, seed: 4), cloned = payload(300_001, seed: 5)
            try write(tiny, to: dir.appendingPathComponent("tiny-1"))
            try write(tiny, to: dir.appendingPathComponent("tiny-2"))
            try write(big, to: dir.appendingPathComponent("big-1"))
            try write(big, to: dir.appendingPathComponent("big-2"))
            let original = dir.appendingPathComponent("original")
            try write(cloned, to: original)
            // 强制 APFS 克隆：克隆与原文件共享数据块，移走任一份都不释放空间。
            let cloneResult = original.path.withCString { src in
                dir.appendingPathComponent("clone").path.withCString { dst in copyfile(src, dst, nil, copyfile_flags_t(COPYFILE_CLONE_FORCE)) }
            }
            XCTAssertEqual(cloneResult, 0)
            try write(cloned, to: dir.appendingPathComponent("independent"))

            let service = DuplicateFiles(index: index, home: home)
            let summary = try service.scan(root: dir, minimumSize: 200_000, token: CancellationToken())
            XCTAssertFalse(summary.incomplete)
            XCTAssertEqual(summary.filteredSmall, 2)
            XCTAssertEqual(summary.filteredShared, 2)
            let groups = try service.groups()
            XCTAssertEqual(groups.count, 1)
            XCTAssertEqual(try service.members(groupID: groups[0].id).map(\.name).sorted(), ["big-1", "big-2"])
        }
    }

    func testStartupScopeExcludesLibraryHiddenAndKeepsCleanable() throws {
        try withFakeHome { home, index in
            let content = payload(4_096, seed: 6)
            try write(content, to: home.appendingPathComponent("Documents/a.bin"))
            try write(content, to: home.appendingPathComponent("Pictures/b.bin"))
            try write(content, to: home.appendingPathComponent("Library/Caches/c.bin"))
            try write(content, to: home.appendingPathComponent(".hidden/d.bin"))
            try write(content, to: home.appendingPathComponent("Tool.app/Contents/e.bin"))
            // 读不了的目录只计为错误，其余结果仍可清理。
            let locked = home.appendingPathComponent("Locked")
            try write(content, to: locked.appendingPathComponent("f.bin"))
            XCTAssertEqual(chmod(locked.path, 0), 0)
            defer { chmod(locked.path, 0o755) }

            let service = DuplicateFiles(index: index, home: home)
            let startup = DuplicateVolume(name: "启动磁盘", mountURL: URL(fileURLWithPath: "/"), isStartup: true)
            let summary = try service.scan(scope: .volumes([startup]), token: CancellationToken())
            XCTAssertFalse(summary.incomplete)
            XCTAssertGreaterThan(summary.errors, 0)
            XCTAssertTrue(service.isValid)
            let groups = try service.groups()
            XCTAssertEqual(groups.count, 1)
            let members = try service.members(groupID: groups[0].id)
            XCTAssertEqual(members.map(\.url.path).sorted(), [home.appendingPathComponent("Documents/a.bin").path,
                                                              home.appendingPathComponent("Pictures/b.bin").path])
            let keeper = members.first { $0.name == "a.bin" }!, copy = members.first { $0.name == "b.bin" }!
            let moved = service.move(groupID: groups[0].id, keeperID: keeper.id, ids: [copy.id], token: CancellationToken())
            for destination in moved.compactMap(\.destination) { try? fm.removeItem(at: destination) }
            XCTAssertTrue(moved.count == 1 && moved[0].error == nil && moved[0].destination != nil)
        }
    }

    private func hdiutil(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw MacEvenError("hdiutil \(arguments.first ?? "") failed") }
    }

    func testExternalVolumeScanTrashAndRules() throws {
        try withFakeHome { home, index in
            // 测试自建的 APFS 磁盘映像，nobrowse 挂载到临时目录，结束时卸载并删除。
            let work = fm.temporaryDirectory.appendingPathComponent("MacEven-dup-volume-\(UUID())")
            let image = work.appendingPathComponent("volume.dmg"), mountPoint = work.appendingPathComponent("mnt")
            try fm.createDirectory(at: mountPoint, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: work) }
            try hdiutil(["create", "-size", "20m", "-fs", "APFS", "-volname", "MacEvenDupTest", "-quiet", image.path])
            try hdiutil(["attach", "-nobrowse", "-noverify", "-noautoopen", "-mountpoint", mountPoint.path, "-quiet", image.path])
            defer { try? hdiutil(["detach", "-force", "-quiet", mountPoint.path]) }
            let volume = try canonicalFileURL(mountPoint)

            let content = payload(65_536, seed: 7)
            try write(content, to: home.appendingPathComponent("Documents/home.bin"))
            try write(content, to: volume.appendingPathComponent("Photos/a.bin"))
            try write(content, to: volume.appendingPathComponent("Backup/copy.bin"))
            try write(content, to: volume.appendingPathComponent(".hidden/h.bin"))

            let service = DuplicateFiles(index: index, home: home)
            let volumes = [DuplicateVolume(name: "启动磁盘", mountURL: URL(fileURLWithPath: "/"), isStartup: true),
                           DuplicateVolume(name: "测试盘", mountURL: volume, isStartup: false)]
            let summary = try service.scan(scope: .volumes(volumes), token: CancellationToken())
            XCTAssertFalse(summary.incomplete)
            XCTAssertEqual(summary.errors, 0)
            let groups = try service.groups()
            XCTAssertEqual(groups.count, 1)
            let members = try service.members(groupID: groups[0].id)
            XCTAssertEqual(Set(members.map(\.name)), ["home.bin", "a.bin", "copy.bin"])
            let keeper = members.first { $0.name == "home.bin" }!
            let copy = members.first { $0.name == "copy.bin" }!, photo = members.first { $0.name == "a.bin" }!

            // 跨磁盘：保留主目录副本，把外接卷上的副本移到该卷的废纸篓。
            let moved = service.move(groupID: groups[0].id, keeperID: keeper.id, ids: [copy.id], token: CancellationToken())
            for destination in moved.compactMap(\.destination) { try? fm.removeItem(at: destination) }
            XCTAssertTrue(moved.count == 1 && moved[0].error == nil && moved[0].destination != nil)
            XCTAssertFalse(fm.fileExists(atPath: volume.appendingPathComponent("Backup/copy.bin").path))

            // 卷内祖先被换成符号链接：拒绝，文件保留。
            let photos = volume.appendingPathComponent("Photos"), movedPhotos = volume.appendingPathComponent("Photos-real")
            try fm.moveItem(at: photos, to: movedPhotos)
            try fm.createSymbolicLink(at: photos, withDestinationURL: movedPhotos)
            let refused = service.move(groupID: groups[0].id, keeperID: keeper.id, ids: [photo.id], token: CancellationToken())
            for destination in refused.compactMap(\.destination) { try? fm.removeItem(at: destination) }
            XCTAssertTrue(refused.allSatisfy { $0.destination == nil && $0.error != nil })
            XCTAssertTrue(fm.fileExists(atPath: movedPhotos.appendingPathComponent("a.bin").path))

            // 文件夹模式：卷内普通子目录可扫；卷根本身、隐藏路径、符号链接不可作为入口。
            XCTAssertFalse((try? service.scan(root: movedPhotos, token: CancellationToken()))?.incomplete ?? true)
            XCTAssertThrowsError(try service.scan(root: volume, token: CancellationToken()))
            XCTAssertThrowsError(try service.scan(root: volume.appendingPathComponent(".hidden"), token: CancellationToken()))
            XCTAssertThrowsError(try service.scan(root: photos, token: CancellationToken()))

            // 未扫描的卷不在允许范围内：只扫主目录时，卷上的路径一律拒绝。
            try write(content, to: home.appendingPathComponent("Documents/home-2.bin"))
            _ = try service.scan(scope: .volumes([volumes[0]]), token: CancellationToken())
            XCTAssertTrue(try service.groups().count == 1 && service.members(groupID: service.groups()[0].id).count == 2)
            let available = DuplicateFiles.availableVolumes(home: home)
            XCTAssertTrue(available.first?.isStartup == true)
        }
    }
}
