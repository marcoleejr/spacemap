import CoreServices
import Foundation
import XCTest
@testable import SpaceMapCore

final class IncrementalUpdateTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("spacemap-incremental-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// root/a/b/big.bin (4096) + root/a/small.txt (100) + root/c.txt (10)
    private func fixture() throws -> (URL, DiskScanResult) {
        let root = try temporaryDirectory()
        let b = root.appendingPathComponent("a/b", isDirectory: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: b.appendingPathComponent("big.bin"))
        try Data(repeating: 2, count: 100).write(to: root.appendingPathComponent("a/small.txt"))
        try Data(repeating: 3, count: 10).write(to: root.appendingPathComponent("c.txt"))
        return (root, try DiskScanner.scan(rootURL: root))
    }

    private func assertTotalsConsistent(_ tree: DiskTree, file: StaticString = #filePath, line: UInt = #line) {
        // Every directory must equal the sum of its children.
        var stack: [UInt32] = [0]
        while let index = stack.popLast() {
            guard tree.isDirectory(index) else { continue }
            var alloc: UInt64 = 0, app: UInt64 = 0, files = 0, dirs = 0
            for child in tree.children(of: index) {
                alloc += tree.allocated[Int(child)]
                app += tree.apparent[Int(child)]
                if tree.isDirectory(child) { files += Int(tree.files[Int(child)]); dirs += Int(tree.dirs[Int(child)]) + 1 }
                else { files += 1 }
                stack.append(child)
            }
            XCTAssertEqual(tree.allocated[Int(index)], alloc, "allocated at \(tree.path(of: index))", file: file, line: line)
            XCTAssertEqual(tree.apparent[Int(index)], app, "apparent at \(tree.path(of: index))", file: file, line: line)
            XCTAssertEqual(Int(tree.files[Int(index)]), files, "files at \(tree.path(of: index))", file: file, line: line)
            XCTAssertEqual(Int(tree.dirs[Int(index)]), dirs, "dirs at \(tree.path(of: index))", file: file, line: line)
        }
    }

    func testRemovingFileSubtractsFromEveryAncestor() throws {
        let (root, result) = try fixture()
        let tree = result.root.tree
        assertTotalsConsistent(tree)
        let bigPath = root.appendingPathComponent("a/b/big.bin").path
        let big = try XCTUnwrap(tree.index(forPath: bigPath))
        let bigBytes = tree.allocated[Int(big)]
        let aIndex = try XCTUnwrap(tree.index(forPath: root.appendingPathComponent("a").path))
        let rootBefore = (tree.allocated[0], tree.apparent[0], tree.files[0])
        let aBefore = tree.allocated[Int(aIndex)]
        let versionBefore = tree.version

        XCTAssertTrue(IncrementalUpdater.remove(path: bigPath, from: tree))

        XCTAssertNil(tree.index(forPath: bigPath))
        XCTAssertEqual(tree.allocated[0], rootBefore.0 - bigBytes)
        XCTAssertEqual(tree.apparent[0], rootBefore.1 - 4096)
        XCTAssertEqual(tree.files[0], rootBefore.2 - 1)
        XCTAssertEqual(tree.allocated[Int(aIndex)], aBefore - bigBytes)
        XCTAssertGreaterThan(tree.version, versionBefore)
        XCTAssertEqual(tree.garbageNodes, 1)
        assertTotalsConsistent(tree)
    }

    func testRemovingDirectorySubtractsWholeSubtreeAndRootCannotBeRemoved() throws {
        let (root, result) = try fixture()
        let tree = result.root.tree
        let rootFiles = tree.files[0], rootDirs = tree.dirs[0]
        XCTAssertTrue(IncrementalUpdater.remove(path: root.appendingPathComponent("a").path, from: tree))
        XCTAssertEqual(tree.files[0], rootFiles - 2)
        XCTAssertEqual(tree.dirs[0], rootDirs - 2, "a and a/b are gone")
        XCTAssertEqual(tree.apparent[0], 10)
        XCTAssertFalse(IncrementalUpdater.remove(path: root.path, from: tree))
        XCTAssertFalse(IncrementalUpdater.remove(path: root.appendingPathComponent("missing").path, from: tree))
        assertTotalsConsistent(tree)
    }

    func testDirectoryRefreshAppliesAddedChangedAndDeletedEntries() throws {
        let (root, result) = try fixture()
        let tree = result.root.tree
        let a = root.appendingPathComponent("a")
        let keptB = try XCTUnwrap(tree.index(forPath: a.appendingPathComponent("b").path))
        // Outside the app: one file grows, one is deleted, a new folder appears.
        try Data(repeating: 9, count: 3000).write(to: a.appendingPathComponent("small.txt"))
        try FileManager.default.createDirectory(at: a.appendingPathComponent("new/deeper"), withIntermediateDirectories: true)
        try Data(repeating: 8, count: 500).write(to: a.appendingPathComponent("new/deeper/x.dat"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("c.txt"))

        for path in [a.path, root.path] {
            let patch = try XCTUnwrap(IncrementalUpdater.prepare(tree: tree, path: path, recursive: false, includeHidden: true))
            XCTAssertTrue(IncrementalUpdater.apply(patch))
        }

        XCTAssertEqual(tree.index(forPath: a.appendingPathComponent("b").path), keptB, "unchanged subdirectory keeps its subtree")
        XCTAssertNotNil(tree.index(forPath: a.appendingPathComponent("new/deeper/x.dat").path))
        XCTAssertNil(tree.index(forPath: root.appendingPathComponent("c.txt").path))
        XCTAssertEqual(tree.apparent[0], 4096 + 3000 + 500)
        XCTAssertEqual(tree.files[0], 3)
        XCTAssertEqual(tree.dirs[0], 4)
        assertTotalsConsistent(tree)
        // Same numbers as a scan from scratch.
        let fresh = try DiskScanner.scan(rootURL: root).root
        XCTAssertEqual(tree.root.allocatedBytes, fresh.allocatedBytes)
        XCTAssertEqual(tree.root.fileCount, fresh.fileCount)
        XCTAssertEqual(tree.root.directoryCount, fresh.directoryCount)
    }

    func testNewSubdirectoryIsKeptOnTheNextRefresh() throws {
        let (root, result) = try fixture()
        let tree = result.root.tree
        let a = root.appendingPathComponent("a")
        try FileManager.default.createDirectory(at: a.appendingPathComponent("node_modules/pkg"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 50).write(to: a.appendingPathComponent("node_modules/pkg/index.js"))
        let first = try XCTUnwrap(IncrementalUpdater.prepare(tree: tree, path: a.path, recursive: false, includeHidden: true))
        XCTAssertEqual(first.newSubtrees.count, 1)
        XCTAssertTrue(IncrementalUpdater.apply(first))
        let second = try XCTUnwrap(IncrementalUpdater.prepare(tree: tree, path: a.path, recursive: false, includeHidden: true))
        XCTAssertEqual(second.newSubtrees.count, 0, "already in the tree: no rescan")
        XCTAssertEqual(second.kept.count, 2)
    }

    func testRefreshOfDeletedDirectoryRemovesItAndMissingPathsUseNearestAncestor() throws {
        let (root, result) = try fixture()
        let tree = result.root.tree
        let b = root.appendingPathComponent("a/b")
        try FileManager.default.removeItem(at: b)
        let patch = try XCTUnwrap(IncrementalUpdater.prepare(tree: tree, path: b.path, recursive: false, includeHidden: true))
        XCTAssertTrue(IncrementalUpdater.apply(patch))
        XCTAssertNil(tree.index(forPath: b.path))
        XCTAssertEqual(tree.apparent[0], 110)

        // An event for a path the tree has never seen refreshes its deepest known ancestor.
        try FileManager.default.createDirectory(at: root.appendingPathComponent("a/z/y"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 7).write(to: root.appendingPathComponent("a/z/y/f"))
        let unseen = try XCTUnwrap(IncrementalUpdater.prepare(tree: tree, path: root.appendingPathComponent("a/z/y").path, recursive: false, includeHidden: true))
        XCTAssertEqual(unseen.path, root.appendingPathComponent("a").path)
        XCTAssertTrue(IncrementalUpdater.apply(unseen))
        XCTAssertNotNil(tree.index(forPath: root.appendingPathComponent("a/z/y/f").path))
        assertTotalsConsistent(tree)
    }

    func testStalePatchIsDroppedWhenDirectoryWasRemovedMeanwhile() throws {
        let (root, result) = try fixture()
        let tree = result.root.tree
        let a = root.appendingPathComponent("a").path
        let patch = try XCTUnwrap(IncrementalUpdater.prepare(tree: tree, path: a, recursive: false, includeHidden: true))
        XCTAssertTrue(IncrementalUpdater.remove(path: a, from: tree))
        XCTAssertFalse(IncrementalUpdater.apply(patch))
        assertTotalsConsistent(tree)
    }

    func testCompactionDropsGarbageAndKeepsTotals() throws {
        let (root, result) = try fixture()
        let tree = result.root.tree
        IncrementalUpdater.remove(path: root.appendingPathComponent("a/b").path, from: tree)
        let copy = tree.compacted()
        XCTAssertEqual(copy.garbageNodes, 0)
        XCTAssertEqual(copy.nodeCount, tree.liveNodeCount)
        XCTAssertEqual(copy.root.allocatedBytes, tree.root.allocatedBytes)
        XCTAssertNotNil(copy.index(forPath: root.appendingPathComponent("a/small.txt").path))
        assertTotalsConsistent(copy)
    }

    func testCacheRoundTripsTreeAndHeader() throws {
        let (root, result) = try fixture()
        let url = try temporaryDirectory().appendingPathComponent("cache.bin")
        let header = ScanCache.Header(rootPath: root.path, includeHidden: true, eventId: 42, volumeUUID: "V", entries: 7)
        try ScanCache.save(result.root.tree, header: header, to: url)
        XCTAssertEqual(ScanCache.readHeader(from: url)?.eventId, 42)
        let loaded = try ScanCache.load(from: url)
        XCTAssertEqual(loaded.header.rootPath, root.path)
        XCTAssertEqual(loaded.tree.nodeCount, result.root.tree.nodeCount)
        XCTAssertEqual(loaded.tree.root.allocatedBytes, result.root.allocatedBytes)
        XCTAssertEqual(loaded.tree.root.children.map(\.name).sorted(), ["a", "c.txt"])
        XCTAssertNotNil(loaded.tree.index(forPath: root.appendingPathComponent("a/b/big.bin").path))
        // A truncated file is rejected, never half-loaded.
        let data = try Data(contentsOf: url)
        try data.prefix(data.count - 10).write(to: url)
        XCTAssertThrowsError(try ScanCache.load(from: url))
    }

    // MARK: - FSEvents

    func testPlannerCoalescesEventsAndEscalates() {
        let root = "/Users/me"
        func event(_ path: String, _ flags: Int = 0) -> FileSystemEvent {
            FileSystemEvent(path: path, flags: UInt32(flags), id: 1)
        }
        XCTAssertEqual(FileSystemEventPlanner.plan([], rootPath: root), .nothing)
        XCTAssertEqual(FileSystemEventPlanner.plan([event("/elsewhere/x/")], rootPath: root), .nothing)
        XCTAssertEqual(
            FileSystemEventPlanner.plan([event("/Users/me/a/"), event("/Users/me/a"), event("/Users/me/b/c/")], rootPath: root),
            .refresh(["/Users/me/a": false, "/Users/me/b/c": false])
        )
        // A recursive rescan swallows refreshes beneath it but not siblings.
        XCTAssertEqual(
            FileSystemEventPlanner.plan([
                event("/Users/me/a/deep/"),
                event("/Users/me/a/", kFSEventStreamEventFlagMustScanSubDirs),
                event("/Users/me/ab/"),
            ], rootPath: root),
            .refresh(["/Users/me/a": true, "/Users/me/ab": false])
        )
        XCTAssertEqual(FileSystemEventPlanner.plan([event("/Users/me", kFSEventStreamEventFlagRootChanged)], rootPath: root), .fullRescan)
        XCTAssertEqual(FileSystemEventPlanner.plan([event("/Users/me/a", kFSEventStreamEventFlagKernelDropped)], rootPath: root), .fullRescan)
        XCTAssertEqual(FileSystemEventPlanner.plan([event("/Users/me/a", kFSEventStreamEventFlagHistoryDone)], rootPath: root), .nothing)
    }

    func testWatcherReportsExternalChangeAndItFlowsIntoTheTree() throws {
        let (root, result) = try fixture()
        let tree = result.root.tree
        let received = expectation(description: "fsevents")
        received.assertForOverFulfill = false
        let lock = NSLock()
        var events: [FileSystemEvent] = []
        let watcher = FileSystemWatcher(path: root.path, latency: 0.1) { batch in
            lock.lock(); events += batch; lock.unlock()
            if batch.contains(where: { $0.path.hasSuffix("/a/b") || $0.path.hasSuffix("/a/b/") }) { received.fulfill() }
        }
        defer { watcher.stop() }
        // Written by another process, as Finder would (the stream ignores our own writes).
        let target = root.appendingPathComponent("a/b/external.bin").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/dd")
        process.arguments = ["if=/dev/zero", "of=\(target)", "bs=1024", "count=64"]
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        wait(for: [received], timeout: 10)

        lock.lock(); let batch = events; lock.unlock()
        // FSEvents reports canonical paths (/private/var/...); map back to the tree's root.
        let canonicalRoot = URL(fileURLWithPath: root.path).resolvingSymlinksInPath().path
        let normalized = batch.map { FileSystemEvent(path: $0.path.replacingOccurrences(of: "/private" + root.path, with: root.path)
            .replacingOccurrences(of: canonicalRoot, with: root.path), flags: $0.flags, id: $0.id) }
        guard case let .refresh(paths) = FileSystemEventPlanner.plan(normalized, rootPath: root.path) else {
            return XCTFail("expected a refresh plan, got \(normalized)")
        }
        let before = tree.apparent[0]
        for (path, recursive) in paths {
            if let patch = IncrementalUpdater.prepare(tree: tree, path: path, recursive: recursive, includeHidden: true) {
                IncrementalUpdater.apply(patch)
            }
        }
        XCTAssertEqual(tree.apparent[0], before + 64 * 1024)
        XCTAssertNotNil(tree.index(forPath: target))
        XCTAssertGreaterThan(watcher.latestEventId, 0)
    }
}
