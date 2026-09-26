import Foundation
import XCTest
@testable import SpaceMapCore

final class SpaceMapCoreTests: XCTestCase {
    private func node(_ name: String, bytes: UInt64 = 1, kind: DiskItemKind = .file, children: [DiskNode] = []) -> DiskNode {
        DiskNode(
            path: "/\(name)", name: name, kind: kind, category: .code,
            allocatedBytes: bytes, apparentBytes: bytes,
            fileCount: kind == .file ? 1 : children.reduce(0) { $0 + $1.fileCount },
            directoryCount: kind == .directory ? children.count : 0,
            children: children
        )
    }

    // MARK: - Squarify

    func testSquarifyFillsRectWithoutOverlapsAndKeepsReasonableRatios() {
        let nodes = (0..<80).map { node("item-\($0)") }
        let weights = (1...80).map(Double.init)
        let bounds = CGRect(x: 13, y: 7, width: 1200, height: 700)
        let tiles = Squarifier.layout(nodes: nodes, weights: weights, in: bounds)

        XCTAssertEqual(tiles.count, nodes.count)
        XCTAssertEqual(tiles.reduce(0) { $0 + $1.rect.width * $1.rect.height }, bounds.width * bounds.height, accuracy: 0.1)
        for tile in tiles {
            XCTAssertGreaterThanOrEqual(tile.rect.minX, bounds.minX - 0.001)
            XCTAssertGreaterThanOrEqual(tile.rect.minY, bounds.minY - 0.001)
            XCTAssertLessThanOrEqual(tile.rect.maxX, bounds.maxX + 0.001)
            XCTAssertLessThanOrEqual(tile.rect.maxY, bounds.maxY + 0.001)
            XCTAssertGreaterThan(tile.rect.width, 0)
            XCTAssertGreaterThan(tile.rect.height, 0)
        }
        for i in tiles.indices {
            for j in tiles.indices where j > i {
                XCTAssertFalse(tiles[i].rect.intersects(tiles[j].rect), "\(tiles[i].node.name) overlaps \(tiles[j].node.name)")
            }
        }
        let worstAspect = tiles.map { max($0.rect.width / $0.rect.height, $0.rect.height / $0.rect.width) }.max() ?? 0
        let worstTile = tiles.max { tileAspect($0.rect) < tileAspect($1.rect) }
        XCTAssertLessThan(worstAspect, 35, "worst tile: \(worstTile?.node.name ?? "?") \(String(describing: worstTile?.rect))")
    }

    func testSquarifyEmptySingleAndZeroWeights() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 60)
        XCTAssertTrue(Squarifier.layout(nodes: [], weights: [], in: rect).isEmpty)
        let one = node("only", bytes: 0)
        let onlyTile = Squarifier.layout(nodes: [one], weights: [0], in: rect)
        XCTAssertEqual(onlyTile.count, 1)
        XCTAssertEqual(onlyTile[0].rect.width * onlyTile[0].rect.height, 6000, accuracy: 0.001)

        let zeroNodes = [node("a", bytes: 0), node("b", bytes: 0), node("c", bytes: 0)]
        let zeroTiles = Squarifier.layout(nodes: zeroNodes, weights: [0, 0, 0], in: rect)
        XCTAssertEqual(zeroTiles.count, 3)
        XCTAssertEqual(zeroTiles.reduce(0) { $0 + $1.rect.width * $1.rect.height }, 6000, accuracy: 0.01)
    }

    func testSquarifyAreasAreProportionalToWeights() {
        let nodes = [node("big", bytes: 60), node("mid", bytes: 30), node("small", bytes: 10)]
        let weights = [60.0, 30.0, 10.0]
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let tiles = Squarifier.layout(nodes: nodes, weights: weights, in: bounds)
        XCTAssertEqual(tiles.count, 3)
        var areaByName: [String: CGFloat] = [:]
        for tile in tiles { areaByName[tile.node.name] = tile.rect.width * tile.rect.height }
        XCTAssertEqual(areaByName["big"] ?? 0, 6000, accuracy: 2)
        XCTAssertEqual(areaByName["mid"] ?? 0, 3000, accuracy: 2)
        XCTAssertEqual(areaByName["small"] ?? 0, 1000, accuracy: 2)
    }

    func testSquarifyEqualWeightsAreStableAndDeterministic() {
        let nodes = (0..<12).map { node(String(format: "tile-%02d", $0)) }
        let weights = [Double](repeating: 5, count: nodes.count)
        let bounds = CGRect(x: 0, y: 0, width: 480, height: 320)
        let first = Squarifier.layout(nodes: nodes, weights: weights, in: bounds)
        let second = Squarifier.layout(nodes: nodes, weights: weights, in: bounds)
        XCTAssertEqual(first.count, nodes.count)
        for (a, b) in zip(first, second) {
            XCTAssertEqual(a.rect, b.rect, "layout must be deterministic for \(a.node.name)")
        }
        let names = first.map(\.node.name)
        XCTAssertEqual(names, names.sorted(), "equal weights fall back to path order")
    }

    func testSquarifyFileModeWeightsUseFileCounts() {
        let leaf = DiskNode(path: "/leaf", name: "leaf", kind: .file, category: .code,
                            allocatedBytes: 10, apparentBytes: 10, fileCount: 1, directoryCount: 0)
        let roomy = DiskNode(path: "/roomy", name: "roomy", kind: .directory, category: .code,
                             allocatedBytes: 10, apparentBytes: 10, fileCount: 400, directoryCount: 0,
                             children: [leaf])
        let weights = Squarifier.weights(for: [leaf, roomy], mode: .files, apparentSize: false)
        XCTAssertEqual(weights.count, 2)
        XCTAssertGreaterThan(weights[1], weights[0], "files mode must weight by file count, not bytes")
    }

    // MARK: - Classifier

    func testCategoryClassifierHeuristicsAndInheritance() {
        let cases: [(String, DiskCategory)] = [
            ("/Users/a/project/node_modules/react", .reclaimable),
            ("/Users/a/project/target/debug", .reclaimable),
            ("/Users/a/project/.build/checkouts", .reclaimable),
            ("/Applications/Xcode.app/Contents/Developer/DerivedData", .reclaimable),
            ("/Users/a/Library/Developer/Xcode/DerivedData/app-abc", .reclaimable),
            ("/Users/a/project/build", .reclaimable),
            ("/Users/a/project/__pycache__/m.pyc", .reclaimable),
            ("/Users/a/project/.gradle/caches", .reclaimable),
            ("/Users/a/project/Pods", .reclaimable),
            ("/Users/a/.codex/sessions", .agentScratch),
            ("/Users/a/.claude/projects", .agentScratch),
            ("/Users/a/worktrees/feature-x", .agentScratch),
            ("/Users/a/orca/workspaces/demo", .agentScratch),
            ("/Users/a/.rustup/toolchains/stable", .toolchains),
            ("/Users/a/.cargo/registry", .toolchains),
            ("/Users/a/.npm/_cacache", .toolchains),
            ("/Users/a/.pnpm-store/v3", .toolchains),
            ("/Users/a/.local/share/mise/installs", .toolchains),
            ("/Applications/Xcode.app", .toolchains),
            ("/Users/a/Library/Developer/CoreSimulator", .toolchains),
            ("/Users/a/Library/Developer/Xcode", .toolchains),
            ("/Users/a/Library/Developer", .toolchains),
            ("/Users/a/.platformio/packages", .toolchains),
            ("/Users/a/Developer/sdks", .toolchains),
            ("/Users/a/Library/Mobile Documents/com~apple~CloudDocs", .synced),
            ("/Users/a/Library/CloudStorage/Dropbox/team", .synced),
            ("/Users/a/Creative Cloud Files/user@example.com/movie.mp4", .synced),
            ("/Users/a/Google Drive/shared", .synced),
            ("/Users/a/project/.git/objects", .git),
            ("/Users/a/Movies/movie.mov", .media),
            ("/Users/a/Music/track.mp3", .media),
            ("/Users/a/Pictures/photo.heic", .media),
            ("/Users/a/Steam/steamapps/common/game", .media),
            ("/Users/a/Documents/report.pdf", .documents),
            ("/Users/a/Library/Application Support/Spotify/Persist", .documents),
            ("/Users/a/Library/Containers/com.docker.docker/Data", .documents),
            ("/Users/a/Desktop/todo.txt", .documents),
            ("/Users/a/Downloads/manual.docx", .documents),
            ("/Users/a/Library/Caches/app/cache.db", .cache),
            ("/Users/a/.cache/tool/data", .cache),
            ("/Users/a/Library/Caches/com.apple.tv/blob", .cache),
            ("/Users/a/Projects/product/src/main.swift", .code),
            ("/Users/a/Code/tool/main.py", .code),
        ]
        XCTAssertGreaterThanOrEqual(cases.count, 20)
        for (path, expected) in cases {
            XCTAssertEqual(CategoryClassifier.classify(path: path), expected, path)
        }
        XCTAssertEqual(CategoryClassifier.classify(path: "/Users/a/unknown", parentCategory: .synced), .synced)
        XCTAssertEqual(CategoryClassifier.classify(path: "/Users/a/worktree", hasGitDirectory: true), .code)
    }

    func testIncrementalClassifierMatchesFullPathClassification() {
        let paths = [
            "/Users/a/project/node_modules/react/index.js",
            "/Users/a/project/target/debug/app",
            "/Users/a/.codex/sessions/log.json",
            "/Users/a/orca/workspaces/demo/state.db",
            "/Users/a/worktrees/feature-x/src/main.swift",
            "/Users/a/.local/share/mise/installs/node/22/bin/node",
            "/Users/a/.cargo/registry/cache/index.crate",
            "/Users/a/Library/Mobile Documents/com~apple~CloudDocs/file.txt",
            "/Users/a/Library/CloudStorage/Dropbox/team/spec.pdf",
            "/Users/a/Movies/clip.mov",
            "/Users/a/Music/track.mp3",
            "/Users/a/Pictures/photo.heic",
            "/Users/a/Documents/report.pdf",
            "/Users/a/Desktop/todo.txt",
            "/Users/a/Library/Caches/app/cache.db",
            "/Users/a/.cache/tool/data",
            "/Users/a/Library/Developer",
            "/Users/a/Creative Cloud Files/user/file.mp4",
            "/Users/a/Projects/product/src/main.swift",
            "/Users/a/Developer/sdks/sdk.h",
            "/Users/a/project/.git/objects/pack/file.pack",
            "/Users/a/Library/Developer/Xcode/DerivedData/app-abc/Build/products/app",
            "/Users/someone",
            "/",
        ]
        XCTAssertGreaterThanOrEqual(paths.count, 20)
        for path in paths {
            let expected = CategoryClassifier.classify(path: path)
            var context = IncrementalClassifier.rootContext(forPath: "/")
            var category: DiskCategory = .documents
            for component in path.split(separator: "/") {
                let step = IncrementalClassifier.classifyEntry(
                    name: String(component), parent: context, parentCategory: nil)
                category = step.category
                context = step.childContext
            }
            XCTAssertEqual(category, expected, path)
        }
    }

    // MARK: - DiskNode lookup

    func testDiskNodePathLookupFollowsExactAncestors() {
        let leaf = DiskNode(path: "/root/folder/nested/file.txt", name: "file.txt", kind: .file, category: .code,
                            allocatedBytes: 4, apparentBytes: 4, fileCount: 1, directoryCount: 0)
        let nested = DiskNode(path: "/root/folder/nested", name: "nested", kind: .directory, category: .code,
                              allocatedBytes: 4, apparentBytes: 4, fileCount: 1, directoryCount: 0, children: [leaf])
        let folder = DiskNode(path: "/root/folder", name: "folder", kind: .directory, category: .code,
                              allocatedBytes: 4, apparentBytes: 4, fileCount: 1, directoryCount: 1, children: [nested])
        let sibling = DiskNode(path: "/root/other", name: "other", kind: .file, category: .code,
                               allocatedBytes: 1, apparentBytes: 1, fileCount: 1, directoryCount: 0)
        let root = DiskNode(path: "/root", name: "root", kind: .directory, category: .code,
                            allocatedBytes: 5, apparentBytes: 5, fileCount: 2, directoryCount: 2, children: [sibling, folder])

        XCTAssertEqual(root.descendant(at: leaf.path)?.path, leaf.path)
        XCTAssertNil(root.descendant(at: "/rootish/folder"))
        XCTAssertEqual(root.ancestors(of: leaf.path)?.map(\.path), [root.path, folder.path, nested.path, leaf.path])
        XCTAssertNil(root.ancestors(of: "/root/missing/file"))
    }

    // MARK: - Scanner

    func testScannerCountsFilesDirectoriesHiddenSymlinkAndHardlinkOnce() throws {
        let root = try temporaryDirectory()
        let folder = root.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("payload.bin")
        try Data(repeating: 0x41, count: 8193).write(to: file)
        try FileManager.default.linkItem(at: file, to: folder.appendingPathComponent("hardlink.bin"))
        try Data(repeating: 0x42, count: 73).write(to: root.appendingPathComponent(".secret"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("shortcut").path, withDestinationPath: file.path)

        let result = try DiskScanner.scan(rootURL: root)
        XCTAssertEqual(result.root.fileCount, 3, "hardlink is deduplicated; symlink is not followed")
        XCTAssertEqual(result.root.directoryCount, 1)
        XCTAssertEqual(result.root.children.map(\.name).sorted(), [".secret", "folder", "shortcut"])
        XCTAssertEqual(result.root.children.first(where: { $0.name == "folder" })?.children.count, 1)
        XCTAssertEqual(result.root.children.first(where: { $0.name == "folder" })?.apparentBytes, 8193)
        XCTAssertEqual(result.root.children.first(where: { $0.name == "shortcut" })?.kind, .symlink)
        XCTAssertEqual(result.metrics.deduplicatedHardlinks, 1)
        XCTAssertGreaterThanOrEqual(result.root.allocatedBytes, 0)
        XCTAssertGreaterThanOrEqual(result.root.apparentBytes, 8266)

        let withoutHidden = try DiskScanner.scan(rootURL: root, includeHidden: false)
        XCTAssertNil(withoutHidden.root.children.first(where: { $0.name == ".secret" }))
        XCTAssertEqual(withoutHidden.root.fileCount, 2)
    }

    func testScannerDoesNotFollowSymlinkToAncestor() throws {
        let root = try temporaryDirectory()
        let sub = root.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data(repeating: 0x43, count: 100).write(to: sub.appendingPathComponent("inner.txt"))
        // Symlink inside sub pointing back at the scan root: must stay a leaf.
        try FileManager.default.createSymbolicLink(atPath: sub.appendingPathComponent("up").path, withDestinationPath: root.path)

        let result = try DiskScanner.scan(rootURL: root)
        XCTAssertEqual(result.root.directoryCount, 1)
        let subNode = try XCTUnwrap(result.root.children.first(where: { $0.name == "sub" }))
        XCTAssertEqual(subNode.children.map(\.name).sorted(), ["inner.txt", "up"])
        XCTAssertEqual(subNode.children.first(where: { $0.name == "up" })?.kind, .symlink)
        XCTAssertEqual(result.root.fileCount, 2, "inner.txt plus the symlink leaf itself")
    }

    func testScannerDetectsRepositoryRootEvenWhenHiddenAreExcluded() throws {
        let root = try temporaryDirectory()
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        let gitDir = repo.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try Data(repeating: 0x44, count: 16).write(to: gitDir.appendingPathComponent("HEAD"))
        try Data(repeating: 0x45, count: 32).write(to: repo.appendingPathComponent("main.swift"))

        let result = try DiskScanner.scan(rootURL: root, includeHidden: false)
        let repoNode = try XCTUnwrap(result.root.children.first(where: { $0.name == "repo" }))
        XCTAssertEqual(repoNode.category, .code, ".git presence must mark the repo root as code")
        XCTAssertNil(repoNode.children.first(where: { $0.name == ".git" }), ".git itself stays hidden")
    }

    func testScannerCanBeCancelled() throws {
        let root = try temporaryDirectory()
        let cancellation = ScanCancellation()
        let result = try DiskScanner.scan(rootURL: root, cancellation: cancellation) { _ in
            cancellation.cancel()
        }
        XCTAssertTrue(result.metrics.cancelled)
        XCTAssertEqual(result.metrics.entriesScanned, 1, "cancellation during the initial snapshot prevents directory work")
    }

    func testScannerCountsInaccessibleDirectories() throws {
        let root = try temporaryDirectory()
        let locked = root.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data(repeating: 0x46, count: 64).write(to: locked.appendingPathComponent("secret.txt"))
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)

        let result = try DiskScanner.scan(rootURL: root)
        XCTAssertGreaterThanOrEqual(result.metrics.inaccessibleEntries, 1, "EACCES directories are skipped and counted")
        XCTAssertFalse(result.metrics.cancelled)
    }

    func testScannerSkipsTCCProtectedPaths() {
        let prefixes = DiskScanner.tccSkipPrefixes(homePath: "/Users/someone")
        XCTAssertTrue(DiskScanner.isTCCSkipped("/Users/someone/Library/Mail/V10/INBOX.mbox", prefixes: prefixes, name: "INBOX.mbox"))
        XCTAssertTrue(DiskScanner.isTCCSkipped("/Users/someone/Library/Messages/chat.db", prefixes: prefixes, name: "chat.db"))
        XCTAssertTrue(DiskScanner.isTCCSkipped("/Users/someone/Library/Safari/History.db", prefixes: prefixes, name: "History.db"))
        XCTAssertTrue(DiskScanner.isTCCSkipped("/Users/someone/Library/Mail", prefixes: prefixes, name: "Mail"))
        XCTAssertTrue(DiskScanner.isTCCSkipped("/Users/someone/Pictures/Photos Library.photoslibrary/originals/a.jpg", prefixes: [], name: "a.jpg") == false)
        XCTAssertTrue(DiskScanner.isTCCSkipped("/Users/someone/Pictures/Photos Library.photoslibrary", prefixes: [], name: "Photos Library.photoslibrary"))
        XCTAssertFalse(DiskScanner.isTCCSkipped("/Users/someone/Movies/clip.mov", prefixes: prefixes, name: "clip.mov"))
        XCTAssertFalse(DiskScanner.isTCCSkipped("/Users/someone/Library/Caches/app/x", prefixes: prefixes, name: "x"))
        XCTAssertTrue(DiskScanner.isTCCSkipped("/Other/volume/Library/Mail", prefixes: [], name: "Mail") == false)
    }

    func testScannerRootStaysNeutralForMixedContainers() throws {
        let root = try temporaryDirectory()
        let movies = root.appendingPathComponent("Movies", isDirectory: true)
        try FileManager.default.createDirectory(at: movies, withIntermediateDirectories: true)
        try Data(repeating: 0x47, count: 2_000_000).write(to: movies.appendingPathComponent("clip.mov"))
        try Data(repeating: 0x48, count: 1_000).write(to: root.appendingPathComponent("note.txt"))

        let result = try DiskScanner.scan(rootURL: root)
        XCTAssertEqual(result.root.category, .documents, "mixed containers without their own category stay neutral")
        XCTAssertEqual(result.root.colorCategory, .documents)
        XCTAssertEqual(result.root.children.first(where: { $0.name == "Movies" })?.category, .media)
    }

    // MARK: - Cleanup candidates

    func testCleanupCandidatesFindExpectedKinds() {
        let now = Date(timeIntervalSince1970: 3_000_000)
        func leaf(_ path: String, _ name: String, _ category: DiskCategory, _ bytes: UInt64, modified: Date) -> DiskNode {
            DiskNode(path: path, name: name, kind: .directory, category: category,
                     allocatedBytes: bytes, apparentBytes: bytes,
                     fileCount: 3, directoryCount: 1, modifiedAt: modified)
        }
        let recent = now.addingTimeInterval(-60 * 60)
        let old = now.addingTimeInterval(-100 * 24 * 60 * 60)
        let modules = leaf("/r/node_modules", "node_modules", .reclaimable, 500 << 20, modified: recent)
        let cache = leaf("/r/.cache", ".cache", .cache, 200 << 20, modified: recent)
        let worktrees = leaf("/r/worktrees", "worktrees", .agentScratch, 300 << 20, modified: recent)
        let bigRepo = leaf("/r/huge", "huge", .git, 1_500_000_000, modified: recent)
        let oldFile = DiskNode(path: "/r/old.zip", name: "old.zip", kind: .file, category: .documents,
                               allocatedBytes: 10 << 20, apparentBytes: 10 << 20,
                               fileCount: 1, directoryCount: 0, modifiedAt: old)
        let fresh = DiskNode(path: "/r/app.swift", name: "app.swift", kind: .file, category: .code,
                             allocatedBytes: 1024, apparentBytes: 1024,
                             fileCount: 1, directoryCount: 0, modifiedAt: recent)
        let root = DiskNode(path: "/r", name: "r", kind: .directory, category: .documents,
                            allocatedBytes: 2_010_000_000, apparentBytes: 2_010_000_000,
                            fileCount: 8, directoryCount: 4, modifiedAt: recent,
                            children: [modules, cache, worktrees, bigRepo, oldFile, fresh])

        let cleaned = CleanupCandidates.collect(root: root, rootPath: "/r", now: now)
        let names = cleaned.items.map(\.node.name)
        for expected in ["node_modules", ".cache", "worktrees", "huge", "old.zip"] {
            XCTAssertTrue(names.contains(expected), "missing candidate \(expected) in \(names)")
        }
        XCTAssertFalse(names.contains("app.swift"))
        XCTAssertFalse(names.contains("r"), "the scan root itself is never a candidate")
        XCTAssertEqual(cleaned.items.first?.node.name, "huge", "largest candidate first")
        XCTAssertEqual(cleaned.totalBytes, (500 << 20) + (200 << 20) + (300 << 20) + 1_500_000_000 + (10 << 20))
    }

    func testCleanupCandidatesPrioritizeRegenerableOverOldMedia() {
        let now = Date(timeIntervalSince1970: 3_000_000)
        let recent = now.addingTimeInterval(-60 * 60)
        let old = now.addingTimeInterval(-400 * 24 * 60 * 60)
        // Old media is 10x bigger than the cache, yet regenerable wins.
        let oldMovie = DiskNode(path: "/r/old-movie.mp4", name: "old-movie.mp4", kind: .file, category: .media,
                                allocatedBytes: 2_000 << 20, apparentBytes: 2_000 << 20,
                                fileCount: 1, directoryCount: 0, modifiedAt: old)
        let cache = DiskNode(path: "/r/Library/Caches", name: "Caches", kind: .directory, category: .cache,
                             allocatedBytes: 200 << 20, apparentBytes: 200 << 20,
                             fileCount: 9, directoryCount: 2, modifiedAt: recent)
        let root = DiskNode(path: "/r", name: "r", kind: .directory, category: .documents,
                            allocatedBytes: 2_200 << 20, apparentBytes: 2_200 << 20,
                            fileCount: 10, directoryCount: 1, modifiedAt: recent,
                            children: [oldMovie, cache])
        let cleaned = CleanupCandidates.collect(root: root, rootPath: "/r", now: now)
        XCTAssertEqual(cleaned.items.map(\.node.name), ["Caches", "old-movie.mp4"])
        XCTAssertEqual(cleaned.items.last?.subtitle, "old media")
        XCTAssertEqual(cleaned.items.last?.kind, .oldMedia)
        XCTAssertEqual(cleaned.items.first?.kind, .cache)
    }

    func testCleanupCandidatesIgnoreZeroByteAndFreshSmallNodes() {
        let now = Date(timeIntervalSince1970: 3_000_000)
        let recent = now.addingTimeInterval(-3600)
        let empty = DiskNode(path: "/r/empty", name: "empty", kind: .directory, category: .cache,
                             allocatedBytes: 0, apparentBytes: 0, fileCount: 0, directoryCount: 0, modifiedAt: recent)
        let tiny = DiskNode(path: "/r/tiny.txt", name: "tiny.txt", kind: .file, category: .documents,
                            allocatedBytes: 12, apparentBytes: 12, fileCount: 1, directoryCount: 0, modifiedAt: recent)
        let root = DiskNode(path: "/r", name: "r", kind: .directory, category: .documents,
                            allocatedBytes: 12, apparentBytes: 12, fileCount: 1, directoryCount: 1,
                            modifiedAt: recent, children: [empty, tiny])
        let cleaned = CleanupCandidates.collect(root: root, rootPath: "/r", now: now)
        XCTAssertTrue(cleaned.items.isEmpty)
        XCTAssertEqual(cleaned.totalBytes, 0)
    }

    // MARK: - Localization catalog

    func testStringCatalogCoversAllLocales() throws {
        let packageRoot = URL(fileURLWithPath: #file)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let catalogURL = packageRoot.appendingPathComponent("Sources/SpaceMap/Resources/Localizable.xcstrings")
        let data = try Data(contentsOf: catalogURL)
        let catalog = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(catalog?["sourceLanguage"] as? String, "en")
        let strings = try XCTUnwrap(catalog?["strings"] as? [String: Any])
        XCTAssertGreaterThanOrEqual(strings.count, 90, "every UI string must live in the catalog")
        let required: Set<String> = ["en", "es", "pt", "fr", "de", "ja"]
        var failures: [String] = []
        for (key, raw) in strings {
            guard let entry = raw as? [String: Any],
                  let localizations = entry["localizations"] as? [String: Any] else {
                failures.append("\(key): malformed entry")
                continue
            }
            if Set(localizations.keys) != required {
                failures.append("\(key): locales \(Set(localizations.keys).sorted())")
                continue
            }
            for locale in required {
                guard let loc = localizations[locale] as? [String: Any] else {
                    failures.append("\(key)[\(locale)]: missing")
                    continue
                }
                if let unit = loc["stringUnit"] as? [String: Any] {
                    let value = (unit["value"] as? String) ?? ""
                    if unit["state"] as? String != "translated" || value.isEmpty {
                        failures.append("\(key)[\(locale)]: untranslated")
                    }
                } else if let variations = loc["variations"] as? [String: Any],
                          let plural = variations["plural"] as? [String: Any], !plural.isEmpty {
                    for (category, rawUnit) in plural {
                        let value = ((rawUnit as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String ?? ""
                        if value.isEmpty { failures.append("\(key)[\(locale).\(category)]: empty") }
                    }
                } else {
                    failures.append("\(key)[\(locale)]: neither stringUnit nor plural variations")
                }
            }
        }
        XCTAssertTrue(failures.isEmpty, "catalog gaps:\n" + failures.sorted().joined(separator: "\n"))
    }

    // MARK: - Shared engine

    func testAppAndBenchShareSameEngine() throws {
        let packageRoot = URL(fileURLWithPath: #file)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let viewModelSource = try String(contentsOf: packageRoot.appendingPathComponent("Sources/SpaceMap/SpaceMapViewModel.swift"), encoding: .utf8)
        let benchSource = try String(contentsOf: packageRoot.appendingPathComponent("Sources/SpaceMapBench/main.swift"), encoding: .utf8)
        for (label, source) in [("app ViewModel", viewModelSource), ("bench", benchSource)] {
            XCTAssertTrue(source.contains("ScanEngine.scan"), "\(label) must scan through the shared ScanEngine entry point")
            XCTAssertFalse(source.contains("DiskScanner.scan"), "\(label) must not bypass ScanEngine via DiskScanner directly")
        }

        // Functional equivalence: the shared engine is deterministic on a fixture.
        let root = try temporaryDirectory()
        try Data(repeating: 0x49, count: 2048).write(to: root.appendingPathComponent("a.bin"))
        let first = try ScanEngine.scan(rootURL: root)
        let second = try ScanEngine.scan(rootURL: root)
        XCTAssertEqual(first.root.fileCount, second.root.fileCount)
        XCTAssertEqual(first.root.apparentBytes, second.root.apparentBytes)
        XCTAssertEqual(first.root.children.map(\.name).sorted(), second.root.children.map(\.name).sorted())
    }

    // MARK: - Formatting

    func testByteAndRelativeAgeFormatting() {
        XCTAssertEqual(ByteFormatter.string(1024 * 1024 * 3 / 2), "1.5 MiB")
        XCTAssertEqual(ByteFormatter.string(1024 * 1024 * 1024), "1 GiB")
        let now = Date(timeIntervalSince1970: 2_000_000)
        XCTAssertEqual(ByteFormatter.relativeAge(from: now.addingTimeInterval(-32 * 60), now: now), "32 minutes ago")
        XCTAssertEqual(ByteFormatter.relativeAge(from: now, now: now), "just now")
    }

    func testFullDiskAccessProbeUsesRealOpenResults() {
        func status(_ results: [Int32]) -> FullDiskAccessProbe.Status {
            var queue = results
            return FullDiskAccessProbe.status(home: "/Users/test") { _, _ in queue.isEmpty ? ENOENT : queue.removeFirst() }
        }
        XCTAssertEqual(status([0]), .granted)
        XCTAssertEqual(status([EPERM]), .denied)
        XCTAssertEqual(status([EACCES]), .denied)
        // A missing TCC.db or folder is inconclusive: the next candidate decides.
        XCTAssertEqual(status([ENOENT, ENOENT, 0]), .granted)
        XCTAssertEqual(status([ENOENT, EPERM]), .denied)
        XCTAssertEqual(status([ENOENT, ENOENT, ENOENT, ENOENT]), .unknown)
        XCTAssertEqual(FullDiskAccessProbe.candidates(home: "/Users/test").first?.path,
                       "/Users/test/Library/Application Support/com.apple.TCC/TCC.db")
    }

    private func tileAspect(_ rect: CGRect) -> CGFloat {
        max(rect.width / rect.height, rect.height / rect.width)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SpaceMapTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}
