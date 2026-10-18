import Foundation
import Darwin
import MacEvenCore

final class CoreTests {
    func withTree(_ body: (URL, DiskIndex) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacEven-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let index = try DiskIndex(url: root.appendingPathComponent("index.sqlite"))
        try body(root, index)
    }

    func testLargeFilesCleanableScopeAndPaging() throws {
        try withTree { rawRoot, index in
            let parent = rawRoot.appendingPathComponent("tree")
            let home = parent.appendingPathComponent("home")
            let fm = FileManager.default
            func write(_ relative: String, _ size: Int) throws {
                let url = home.appendingPathComponent(relative)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(repeating: 3, count: size).write(to: url)
            }
            try write("Downloads/big.bin", 40)
            try write("Desktop/clean.bin", 20)
            try write("Movies/clean2.bin", 10)
            try write("Library/huge.bin", 70)
            try write(".cache/hidden.bin", 80)
            try write("Downloads/Small.app/Contents/bundle.bin", 50)
            try write("Downloads/Thing.app.bundle/x", 60)
            // 主目录外大文件：进索引但必须被可清理粗筛排除。
            try Data(repeating: 3, count: 100).write(to: parent.appendingPathComponent("outside.bin"))
            _ = try Scanner.scan(root: parent, index: index, token: CancellationToken())
            let canonical = try canonicalFileURL(home)

            XCTAssertEqual(try index.largestCleanableFiles(homePath: canonical.path).map(\.name),
                ["big.bin", "clean.bin", "clean2.bin"])
            XCTAssertEqual(try index.largestCleanableFiles(homePath: canonical.path, limit: 1).map(\.name), ["big.bin"])
            XCTAssertEqual(try index.largestCleanableFiles(homePath: canonical.path, limit: 1, offset: 1).map(\.name), ["clean.bin"])

            let all = try index.largestFiles()
            XCTAssertEqual(all.count, 8)
            XCTAssertEqual(try index.largestFiles(limit: 2, offset: 2).count, 2)
            let bundles = all.filter { BundlePath.containsBundleAncestor($0.url.path) }
            XCTAssertEqual(Set(bundles.map(\.name)), ["bundle.bin", "x"])
            XCTAssertTrue(BundlePath.containsBundleAncestor("/Users/me/Foo.app/Contents/MacOS/Foo"))
            XCTAssertTrue(BundlePath.containsBundleAncestor("/Users/me/Foo.app.bundle/Contents/x"))
            XCTAssertFalse(BundlePath.containsBundleAncestor("/Users/me/Foo.app"))
            XCTAssertFalse(BundlePath.containsBundleAncestor("/Users/me/Notes.app.backup/x"))
            XCTAssertFalse(BundlePath.containsBundleAncestor("/Users/me/application/x"))
            XCTAssertFalse(BundlePath.containsBundleAncestor("/Users/me/FOO.APP/Contents/x"))
        }
    }

    func testDirectoryTotalsAndRanking() throws {
        try withTree { root, index in
            let folder = root.appendingPathComponent("目录'")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data([1, 2, 3]).write(to: folder.appendingPathComponent("a"))
            try Data(repeating: 2, count: 7).write(to: root.appendingPathComponent("b"))
            let summary = try Scanner.scan(root: root, index: index, token: CancellationToken())
            XCTAssertFalse(summary.cancelled)
            XCTAssertEqual(summary.errors, 0)
            XCTAssertEqual(try index.entry(id: 1)?.logicalSize, 10)
            let files = try index.largestFiles(limit: 100)
            XCTAssertEqual(files.map(\.logicalSize), [7, 3])
            XCTAssertEqual(try index.children(of: 1, offset: 0, limit: 100).count, 2)
        }
    }

    func testHardLinksAndSymlinkDoNotDoubleCount() throws {
        try withTree { root, index in
            let a = root.appendingPathComponent("a")
            try Data(repeating: 1, count: 10).write(to: a)
            try FileManager.default.linkItem(at: a, to: root.appendingPathComponent("b"))
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("loop"), withDestinationURL: root)
            _ = try Scanner.scan(root: root, index: index, token: CancellationToken())
            XCTAssertEqual(try index.entry(id: 1)?.logicalSize, 10)
            XCTAssertEqual(try index.children(of: 1, offset: 0, limit: 100).count, 3)
            XCTAssertEqual(try index.largestFiles(limit: 100).count, 1)
        }
    }

    func testSparseFilesRankByDiskUsage() throws {
        try withTree { root, index in
            let sparseDirectory = root.appendingPathComponent("sparse")
            let denseDirectory = root.appendingPathComponent("dense")
            for directory in [sparseDirectory, denseDirectory] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            let sparse = sparseDirectory.appendingPathComponent("sparse-file")
            XCTAssertTrue(FileManager.default.createFile(atPath: sparse.path, contents: nil))
            let handle = try FileHandle(forWritingTo: sparse)
            defer { try? handle.close() }
            try handle.truncate(atOffset: 64 * 1024 * 1024)
            let dense = denseDirectory.appendingPathComponent("dense-file")
            try Data(repeating: 1, count: 64 * 1024).write(to: dense)
            let sparseInfo = try FileIdentity.read(sparse)
            let denseInfo = try FileIdentity.read(dense)
            XCTAssertGreaterThan(sparseInfo.size, denseInfo.size)
            XCTAssertGreaterThan(denseInfo.allocated, sparseInfo.allocated)
            try FileManager.default.linkItem(at: sparse, to: sparseDirectory.appendingPathComponent("hardlink"))
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: denseDirectory)
            let expectedAllocated = denseInfo.allocated + sparseInfo.allocated
            let summary = try Scanner.scan(root: root, index: index, token: CancellationToken()) { progress in
                if progress.visited == 6 {
                    XCTAssertEqual(progress.allocatedSize, expectedAllocated)
                    XCTAssertEqual(progress.logicalSize, denseInfo.size + sparseInfo.size)
                }
            }
            XCTAssertEqual(summary.visited, 6)
            XCTAssertEqual(try index.children(of: 1).map(\.name), ["dense", "sparse", "link"])
            XCTAssertEqual(try index.largestFiles(limit: 1).first?.name, "dense-file")
            XCTAssertEqual(try index.largestFiles().count, 2)
            XCTAssertEqual(try index.entry(id: 1)?.allocatedSize, denseInfo.allocated + sparseInfo.allocated)
            XCTAssertEqual(try index.entry(id: 1)?.logicalSize, denseInfo.size + sparseInfo.size)
        }
    }

    func testPagingAndEmptyDirectories() throws {
        try withTree { root, index in
            for i in 0..<105 { try Data([1]).write(to: root.appendingPathComponent("file-\(i)")) }
            try FileManager.default.createDirectory(at: root.appendingPathComponent("empty"), withIntermediateDirectories: true)
            _ = try Scanner.scan(root: root, index: index, token: CancellationToken())
            XCTAssertEqual(try index.children(of: 1, offset: 0, limit: 100).count, 100)
            XCTAssertEqual(try index.children(of: 1, offset: 100, limit: 100).count, 6)
            XCTAssertEqual(try index.entry(id: 1)?.logicalSize, 105)
        }
    }

    func testCancellationLeavesQueryablePartialIndex() throws {
        try withTree { root, index in
            try Data([1]).write(to: root.appendingPathComponent("a"))
            let token = CancellationToken()
            token.cancel()
            let result = try Scanner.scan(root: root, index: index, token: token)
            XCTAssertTrue(result.cancelled)
            XCTAssertEqual(try index.entry(id: 1)?.logicalSize, 0)
            XCTAssertEqual(try index.entry(id: 1)?.allocatedSize, 0)
        }
    }

    func testRejectMissingRootAndSymlinkRoot() throws {
        try withTree { root, index in
            XCTAssertThrowsError(try Scanner.scan(root: root.appendingPathComponent("missing"), index: index, token: CancellationToken()))
            let link = root.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
            XCTAssertThrowsError(try Scanner.scan(root: link, index: index, token: CancellationToken()))
        }
    }

    func testPermissionErrorsAreVisible() throws {
        try withTree { root, index in
            let locked = root.appendingPathComponent("locked")
            try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
            try Data([1]).write(to: locked.appendingPathComponent("a"))
            chmod(locked.path, 0)
            defer { chmod(locked.path, 0o700) }
            let result = try Scanner.scan(root: root, index: index, token: CancellationToken())
            XCTAssertGreaterThan(result.errors, 0)
            XCTAssertFalse(result.errorExamples.isEmpty)
        }
    }

    func testRestartAfterMidScanCancellation() throws {
        try withTree { root, index in
            for i in 0..<200 { try Data([1]).write(to: root.appendingPathComponent("file-\(i)")) }
            let token = CancellationToken()
            let cancelled = try Scanner.scan(root: root, index: index, token: token) { _ in token.cancel() }
            XCTAssertTrue(cancelled.cancelled)
            XCTAssertGreaterThan(cancelled.visited, 0)
            XCTAssertTrue(cancelled.visited < 200)
            let complete = try Scanner.scan(root: root, index: index, token: CancellationToken())
            XCTAssertFalse(complete.cancelled)
            XCTAssertEqual(try index.entry(id: 1)?.logicalSize, 200)
            XCTAssertEqual(try index.largestFiles(limit: Int.max).count, 100)
        }
    }
}

func requireTest(_ condition: Bool, _ message: String = "condition failed", file: StaticString = #file, line: UInt = #line) {
    if !condition { fputs("FAIL: \(file):\(line): \(message)\n", stderr); exit(EXIT_FAILURE) }
}
func XCTAssertEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #file, line: UInt = #line) {
    requireTest(actual == expected, "expected \(expected), got \(actual)", file: file, line: line)
}
func XCTAssertTrue(_ value: Bool, _ message: String = "condition failed", file: StaticString = #file, line: UInt = #line) { requireTest(value, message, file: file, line: line) }
func XCTAssertFalse(_ value: Bool, _ message: String = "condition failed", file: StaticString = #file, line: UInt = #line) { requireTest(!value, message, file: file, line: line) }
func XCTAssertGreaterThan<T: Comparable>(_ actual: T, _ expected: T, file: StaticString = #file, line: UInt = #line) { requireTest(actual > expected, file: file, line: line) }
func XCTAssertNotNil<T>(_ value: T?, _ message: String = "condition failed", file: StaticString = #file, line: UInt = #line) { requireTest(value != nil, message, file: file, line: line) }
func XCTAssertNil<T>(_ value: T?, _ message: String = "expected nil", file: StaticString = #file, line: UInt = #line) { requireTest(value == nil, message, file: file, line: line) }
func XCTAssertThrowsError(_ body: @autoclosure () throws -> Any, file: StaticString = #file, line: UInt = #line) {
    do { _ = try body(); requireTest(false, "expected error", file: file, line: line) } catch { }
}

@main struct Checks {
    static func main() throws {
        if CommandLine.arguments.contains("--cache-only") {
            let cache = CacheTests()
            try cache.testMetadataDiscoveryWithoutAppRegistry()
            try cache.testNamedAndApplicationSupportCaches()
            try cache.testCacheAliasOwnershipAndIsolation()
            try cache.testNamedCacheLinksAndChanges()
            try cache.testGroupingAndScope()
            try cache.testOwnCacheIndexDoesNotInvalidateOtherCaches()
            try cache.testNestedChangeAndLinkAncestor()
            try cache.testRescanAfterQuitKeepsScopeAndIdentity()
            try cache.testHardLinksCancellationAndNativeTrash()
            try cache.testRunningBetweenRootsAndBounds()
            try cache.testTrashNamedCacheDescendantsAreValidated()
            try cache.testRunningRecheckedAfterValidation()
            try cache.testInaccessibleSandboxDoesNotBecomePartialEligibleGroup()
            print("PASS: targeted cache path, ownership, protection and cleanup checks")
            return
        }
        if CommandLine.arguments.contains("--cleanup-only") {
            try CacheTests().testGroupingAndScope()
            try CacheTests().testOwnCacheIndexDoesNotInvalidateOtherCaches()
            try CacheTests().testInaccessibleSandboxDoesNotBecomePartialEligibleGroup()
            try CacheTests().testNestedChangeAndLinkAncestor()
            try ApplicationDataTests().testCompleteRemovalAndSafety()
            try ApplicationDataTests().testLinksCopiesAndPartialFailure()
            try ApplicationDataTests().testRetainedDataDoesNotBlockRemoval()
            try ApplicationDiscoveryTests().testPreviewScopeSizesAndIsolation()
            print("PASS: targeted cache statistics and application data removal checks")
            return
        }
        try runScanIssueChecks()
        try runConcurrencyChecks()
        let tests = CoreTests()
        try tests.testDirectoryTotalsAndRanking()
        try tests.testHardLinksAndSymlinkDoNotDoubleCount()
        try tests.testSparseFilesRankByDiskUsage()
        try tests.testPagingAndEmptyDirectories()
        try tests.testCancellationLeavesQueryablePartialIndex()
        try tests.testRejectMissingRootAndSymlinkRoot()
        try tests.testPermissionErrorsAreVisible()
        try tests.testRestartAfterMidScanCancellation()
        try tests.testLargeFilesCleanableScopeAndPaging()
        print("PASS: 9 core behavior checks")
        let trash = TrashTests()
        try trash.testProtectionAndReplacement()
        try trash.testBlockKindMirrorsCleanupRules()
        try trash.testNativeTrashAndHardlinkReassignment()
        try trash.testParentChildAndPartialFailure()
        print("PASS: 4 trash behavior checks (only generated test files)")
        let cache = CacheTests()
        try cache.testMetadataDiscoveryWithoutAppRegistry()
        try cache.testNamedAndApplicationSupportCaches()
        try cache.testCacheAliasOwnershipAndIsolation()
        try cache.testNamedCacheLinksAndChanges()
        try cache.testGroupingAndScope()
        try cache.testOwnCacheIndexDoesNotInvalidateOtherCaches()
        try cache.testNestedChangeAndLinkAncestor()
        try cache.testRescanAfterQuitKeepsScopeAndIdentity()
        try cache.testHardLinksCancellationAndNativeTrash()
        try cache.testRunningBetweenRootsAndBounds()
        try cache.testTrashNamedCacheDescendantsAreValidated()
        try cache.testRunningRecheckedAfterValidation()
        try cache.testInaccessibleSandboxDoesNotBecomePartialEligibleGroup()
        print("PASS: cache grouping, exact scope, running checks, nested changes, owned native trash, bounds")
        let applications = ApplicationTests()
        try applications.testRemovalScopeAndChanges()
        try applications.testAncestryDiscoveryAndBounds()
        try applications.testIndexFailureAfterSuccessfulMove()
        print("PASS: application scope, copies, running recheck, deep changes, owned native trash, retained cache, incomplete discovery")
        let applicationData = ApplicationDataTests()
        try applicationData.testCompleteRemovalAndSafety()
        try applicationData.testLinksCopiesAndPartialFailure()
        try applicationData.testRetainedDataDoesNotBlockRemoval()
        try applicationData.testHomeLevelAndIdentifierSuffixData()
        try ApplicationDiscoveryTests().testPreviewScopeSizesAndIsolation()
        try ApplicationDiscoveryTests().testBulkInspectionMatchesSingleAppAndSkips()
        print("PASS: complete uninstall exact data scope, frozen validation, new copies, symlinks, cancellation, access refusal, partial results, home-level and identifier-suffix data, bulk inspection consistency")
        let duplicate = DuplicateTests()
        try duplicate.testRootBoundaryRejections()
        try duplicate.testContentMatchingAndExclusions()
        try duplicate.testCandidateStatisticsCallback()
        try duplicate.testSparseFilesRankAndGroupCorrectly()
        try duplicate.testPaging()
        try duplicate.testCancellationLeavesQueryableSummary()
        try duplicate.testIdentityAndAncestorChangesDuringHashing()
        try duplicate.testMoveProtection()
        try duplicate.testMoveExactByteComparisonRejectsHashCollision()
        try duplicate.testMoveIndexFailureAfterSuccessfulMove()
        try duplicate.testMovePartialCancellation()
        try duplicate.testMoveRejectsAncestorSymlink()
        print("PASS: duplicate files candidate, hash, paging, protection, byte check, trigger failure, cancellation")
        let safety = DuplicateSafetyTests()
        try safety.testPackageAncestorAndFailedRescan()
        try safety.testRetainedAncestorReplacement()
        try safety.testDuplicateQueryCancellation()
        print("PASS: failed rescan invalidation, package ancestor exclusion and retained ancestor identity and cancellable SQL pages")
        try DuplicateIncrementalTests().testPersistentHashReuse()
        try DuplicateIncrementalTests().testLocalEventsAndPolicyFallback()
        try DuplicateIncrementalTests().testEventsDuringScanAndExpiredBaseline()
        try DuplicateIncrementalTests().testHiddenEventsDoNotInvalidateBaseline()
        DuplicateIncrementalTests().testEventBufferRootFlagsAndAtomicCursor()
        print("PASS: persistent duplicate hashes and real FSEvents incremental scan, local updates match full scan, policy fallback")
        try DuplicateIncrementalSafetyTests().run()
        print("PASS: duplicate cached hash ctime invalidation, sample is not digest, poisoned cache cannot bypass byte comparison, cancellation and permission recovery")
        let progress = ProgressTests()
        try progress.testEstimateBoundaries()
        try progress.testCandidateScansReportUnits()
        try progress.testDuplicatePhasesReportBoundedProgress()
        print("PASS: progress estimate bounds, candidate scans reach unit totals, duplicate sampling and hashing phase progress")
        let fastScan = DuplicateFastScanTests()
        try fastScan.testStagedHashingPrunesBySamples()
        try fastScan.testMinimumSizeAndClonesAreFiltered()
        try fastScan.testStartupScopeExcludesLibraryHiddenAndKeepsCleanable()
        try fastScan.testExternalVolumeScanTrashAndRules()
        print("PASS: duplicate staged sample hashing, size and clone filters, startup scope exclusions, skipped errors stay cleanable, external volume scan and trash rules")
        let space = SpaceInsightsTests()
        space.testCategoryClassification()
        try space.testSpaceFilterValidation()
        try space.testDirectoryBoundaryAndScope()
        try space.testSpaceStatsAndPage100Paging()
        try space.testDuplicateAndSparseAndFilterConditions()
        try space.testExactBoundariesAndBinaryRootScope()
        try space.testSmallQueryHonorsAlreadyCancelledToken()
        try space.testSQLCancellationAndRecovery()
        print("PASS: space insights classification, scope bounds, 100 paging, filtering and cancellable SQL recovery")
        let protection = ProtectionTests()
        try protection.testStoreMatchingAndFailClosed()
        try protection.testDiskTrashHonorsProtection()
        try protection.testCacheCleanupHonorsProtection()
        try protection.testApplicationRemovalHonorsProtection()
        try protection.testDuplicateKeeperMayBeProtected()
        print("PASS: user protection store, path and bundle matching, fail-closed file, late protection at move time, cache, uninstall data plan, duplicate keeper")
        let operationLog = OperationLogTests()
        try operationLog.testAppendRotateAndRecent()
        try operationLog.testRejectsLinkedLocations()
        print("PASS: operation log append, 0600, rotation, recent across files, damaged lines, symlink refusal")
        let leftovers = OrphanLeftoversTests()
        try leftovers.testDiscoveryOwnershipAndScope()
        try leftovers.testChangesProtectionAndLinks()
        try leftovers.testIndependentDataPlansForBatchRemoval()
        print("PASS: orphan leftovers fixed locations, ownership, reinstall at move time, protection, links, changes, cancellation, independent batch data plans")
        try OtherStorageTests().testMeasurementBoundsAndIssues()
        print("PASS: other storage read-only measurement, links not followed, missing locations, limits, cancellation, permission issues")
        let purpose = PurposeTests()
        try purpose.testRuleTableAndExamples()
        try purpose.testApplicationResolutionAndNormalization()
        try purpose.testKeepCapsDescendantsAndOpaqueStopsMatching()
        try purpose.testPageLabelsAndSpeed()
        try purpose.testScanSummary()
        print("PASS: purpose rules table, every rule has a positive example, markers, inheritance, keep cap, opaque, app resolution, normalization, page speed, incremental trail, scan summary, recompute after trash")
        let updateIntegrityTests = UpdateIntegrityTests()
        try updateIntegrityTests.testParseChecksum()
        try updateIntegrityTests.testParseAssetDigest()
        try updateIntegrityTests.testSigningRequirements()
        try updateIntegrityTests.testCodeSignatureCheck()
        print("PASS: update integrity checksum, asset digest, signing requirements, code signature check")
        let permissionsTests = PermissionsTests()
        try permissionsTests.testFullDiskAccessChecker()
        try permissionsTests.testAccessibilityChecker()
        try permissionsTests.testSettingsURLs()
        print("PASS: permissions checks (FDA, Accessibility, settings URLs)")
    }
}

