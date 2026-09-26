import CoreServices
import Darwin
import Foundation

// MARK: - Directory patches

/// Result of re-reading one directory off the main thread. Applying it
/// touches only that directory's child list and its ancestors' totals.
public struct DirectoryPatch: @unchecked Sendable {
    public let tree: DiskTree
    public let directory: UInt32
    public let path: String
    let removeDirectory: Bool
    let kept: [UInt32]
    let newLeaves: [DiskTree.NodeValues]
    let newSubtrees: [DiskTree]
    let newEmptyDirectories: [DiskTree.NodeValues]
    let gitCategory: (DiskCategory, DiskCategory)?
}

public enum IncrementalUpdater {
    /// Re-reads the deepest existing directory for `path`. Existing
    /// subdirectories keep their subtrees (their own events cover changes
    /// inside them) unless `recursive`, in which case they are rescanned.
    public static func prepare(
        tree: DiskTree,
        path: String,
        recursive: Bool,
        includeHidden: Bool,
        cancellation: ScanCancellation = ScanCancellation()
    ) -> DirectoryPatch? {
        struct Existing { let index: UInt32; let isDirectory: Bool }
        let snapshot: (UInt32, String, DiskScanner.Seed, [String: Existing], UInt32?)? = tree.read {
            guard var found = tree.deepestNode(forPath: path) else { return nil }
            if !tree.isDirectory(found.index) {
                let parent = tree.parent[Int(found.index)]
                guard parent != DiskTree.none else { return nil }
                found = (parent, false)
            }
            let index = found.index
            guard tree.isAttached(index) else { return nil }
            let directoryPath = tree.path(of: index)
            let seed = DiskScanner.Seed(
                category: tree.category(of: index),
                color: tree.colorCategory(of: index),
                context: IncrementalClassifier.rootContext(forPath: directoryPath)
            )
            var existing: [String: Existing] = [:]
            for child in tree.children(of: index) {
                existing[tree.name(of: child)] = Existing(index: child, isDirectory: tree.isDirectory(child))
            }
            let parent = tree.parent[Int(index)]
            return (index, directoryPath, seed, existing, parent == DiskTree.none ? nil : parent)
        }
        guard let (directory, directoryPath, seed, existing, _) = snapshot else { return nil }

        let listing = DiskScanner.listDirectory(path: directoryPath, seed: seed)
        if let error = listing.directoryError, error == ENOENT || error == ENOTDIR {
            guard directory != 0 else { return nil }
            return DirectoryPatch(tree: tree, directory: directory, path: directoryPath, removeDirectory: true,
                                  kept: [], newLeaves: [], newSubtrees: [], newEmptyDirectories: [], gitCategory: nil)
        }
        guard listing.directoryError == nil else { return nil }

        var rootStat = stat()
        let rootDevice: UInt64? = tree.rootPath.withCString { Darwin.lstat($0, &rootStat) } == 0
            ? UInt64(truncatingIfNeeded: rootStat.st_dev) : nil
        let restricted = FullDiskAccessProbe.isRestricted()
        let skipPrefixes = restricted ? DiskScanner.tccSkipPrefixes(homePath: FileManager.default.homeDirectoryForCurrentUser.path) : []

        var kept: [UInt32] = []
        var leaves: [DiskTree.NodeValues] = []
        var subtrees: [DiskTree] = []
        var emptyDirectories: [DiskTree.NodeValues] = []
        for entry in listing.entries {
            if cancellation.isCancelled { return nil }
            guard entry.errorCode == nil, let kind = entry.kind else { continue }
            if !includeHidden && entry.name.hasPrefix(".") { continue }
            let values = DiskTree.NodeValues(
                name: entry.name, kind: kind, category: entry.category, color: entry.colorCategory,
                allocated: kind == .file ? entry.allocatedBytes : 0,
                apparent: kind == .file ? entry.apparentBytes : 0,
                files: kind == .directory ? 0 : 1,
                modifiedAt: entry.modifiedAt
            )
            guard kind == .directory else {
                leaves.append(values)
                continue
            }
            if !recursive, let old = existing[entry.name], old.isDirectory {
                kept.append(old.index)
                continue
            }
            if DiskScanner.isTCCSkipped(entry.path, prefixes: skipPrefixes, name: entry.name) { continue }
            if let rootDevice, entry.device != rootDevice {
                emptyDirectories.append(values)
                continue
            }
            let childSeed = DiskScanner.Seed(category: entry.category, color: entry.colorCategory, context: entry.childContext)
            if let scanned = try? DiskScanner.scan(
                rootURL: URL(fileURLWithPath: entry.path),
                includeHidden: includeHidden,
                cancellation: cancellation,
                seed: childSeed
            ) {
                subtrees.append(scanned.root.tree)
            }
        }
        var gitCategory: (DiskCategory, DiskCategory)?
        if listing.containsGitDirectory {
            let category = CategoryClassifier.classify(path: directoryPath, parentCategory: nil, hasGitDirectory: true)
            gitCategory = (category, category == .reclaimable ? seed.color : category)
        }
        return DirectoryPatch(tree: tree, directory: directory, path: directoryPath, removeDirectory: false,
                              kept: kept, newLeaves: leaves, newSubtrees: subtrees, newEmptyDirectories: emptyDirectories,
                              gitCategory: gitCategory)
    }

    /// Applies a patch on the thread that owns mutations. Returns false when
    /// the directory changed underneath (it was removed meanwhile).
    @discardableResult
    public static func apply(_ patch: DirectoryPatch) -> Bool {
        let tree = patch.tree
        return tree.write {
            let directory = patch.directory
            guard Int(directory) < tree.nodeCount, tree.isAttached(directory) else { return false }
            if patch.removeDirectory { return tree.removeNode(directory) }
            let kept = patch.kept.filter { tree.isAttached($0) && tree.parent[Int($0)] == directory }
            var added: [UInt32] = []
            added.reserveCapacity(patch.newLeaves.count + patch.newSubtrees.count + patch.newEmptyDirectories.count)
            for leaf in patch.newLeaves + patch.newEmptyDirectories { added.append(tree.appendNode(leaf, parent: DiskTree.none)) }
            for subtree in patch.newSubtrees { added.append(tree.copySubtree(from: subtree, at: 0)) }
            if let (category, color) = patch.gitCategory { tree.setCategory(of: directory, category: category, color: color) }
            tree.replaceChildren(of: directory, kept: kept, added: added)
            return true
        }
    }

    /// Removes the node at `path` and subtracts it from every ancestor.
    @discardableResult
    public static func remove(path: String, from tree: DiskTree) -> Bool {
        tree.write {
            guard let index = tree.index(forPath: path) else { return false }
            return tree.removeNode(index)
        }
    }
}

// MARK: - FSEvents

public struct FileSystemEvent: Sendable, Equatable {
    public let path: String
    public let flags: UInt32
    public let id: UInt64

    public init(path: String, flags: UInt32, id: UInt64) {
        self.path = path
        self.flags = flags
        self.id = id
    }
}

/// Turns a batch of FSEvents into the smallest set of directory refreshes.
public enum FileSystemEventPlanner {
    public enum Plan: Equatable {
        case nothing
        case fullRescan
        /// Directory path → rescan its subdirectories too.
        case refresh([String: Bool])
    }

    static let fullRescanFlags = UInt32(kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagEventIdsWrapped
        | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagUserDropped)

    public static func plan(_ events: [FileSystemEvent], rootPath: String) -> Plan {
        var refreshes: [String: Bool] = [:]
        let prefix = rootPath == "/" ? "/" : rootPath + "/"
        for event in events {
            if event.flags & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 { continue }
            if event.flags & fullRescanFlags != 0 { return .fullRescan }
            var path = event.path
            while path.count > 1, path.hasSuffix("/") { path.removeLast() }
            guard path == rootPath || path.hasPrefix(prefix) else { continue }
            let recursive = event.flags & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0
            refreshes[path] = (refreshes[path] ?? false) || recursive
        }
        guard !refreshes.isEmpty else { return .nothing }
        // A recursive refresh already covers every path beneath it.
        let recursiveRoots = refreshes.filter(\.value).keys.sorted()
        if !recursiveRoots.isEmpty {
            refreshes = refreshes.filter { path, _ in
                !recursiveRoots.contains { root in root != path && path.hasPrefix(root == "/" ? "/" : root + "/") }
            }
        }
        return .refresh(refreshes)
    }
}

/// Directory-level FSEvents stream (no per-file events: one callback per
/// changed directory is all the updater needs, and it keeps idle cost at zero).
public final class FileSystemWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let handler: ([FileSystemEvent]) -> Void
    private let queue = DispatchQueue(label: "SpaceMap.fsevents", qos: .utility)
    private let lock = NSLock()
    private var lastEventId: UInt64

    public init(path: String, since: UInt64? = nil, latency: TimeInterval = 1.0, handler: @escaping ([FileSystemEvent]) -> Void) {
        self.handler = handler
        self.lastEventId = since ?? FSEventsGetCurrentEventId()
        var context = FSEventStreamContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
            guard let info else { return }
            let watcher = Unmanaged<FileSystemWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            var events: [FileSystemEvent] = []
            events.reserveCapacity(count)
            for index in 0..<min(count, list.count) {
                events.append(FileSystemEvent(path: list[index], flags: flags[index], id: ids[index]))
            }
            watcher.deliver(events)
        }
        let createFlags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagIgnoreSelf)
        stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, [path] as CFArray,
            since ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, createFlags
        )
        if let stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
        }
    }

    deinit { stop() }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// Last event id seen (or the id at creation); persisted with the cache.
    public var latestEventId: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return lastEventId
    }

    private func deliver(_ events: [FileSystemEvent]) {
        lock.lock()
        if let maximum = events.map(\.id).max(), maximum > lastEventId { lastEventId = maximum }
        lock.unlock()
        handler(events)
    }

    public static var currentEventId: UInt64 { FSEventsGetCurrentEventId() }

    public static func volumeUUID(forPath path: String) -> String? {
        var status = stat()
        guard lstat(path, &status) == 0,
              let uuid = FSEventsCopyUUIDForDevice(status.st_dev) else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }
}

// MARK: - On-disk cache

/// Last scan persisted as the arena's raw arrays (lz4 compressed), so the
/// app opens with the previous map instantly and catches up via FSEvents
/// history from the saved event id.
public enum ScanCache {
    public struct Header: Codable, Sendable {
        public var formatVersion = 1
        public var rootPath: String
        public var includeHidden: Bool
        public var eventId: UInt64
        public var volumeUUID: String?
        public var entries: Int
        /// Duration of the full scan the cache descends from.
        public var scanDuration: TimeInterval = 0
        public var savedAt: Date

        public init(rootPath: String, includeHidden: Bool, eventId: UInt64, volumeUUID: String?, entries: Int, scanDuration: TimeInterval = 0, savedAt: Date = Date()) {
            self.scanDuration = scanDuration
            self.rootPath = rootPath
            self.includeHidden = includeHidden
            self.eventId = eventId
            self.volumeUUID = volumeUUID
            self.entries = entries
            self.savedAt = savedAt
        }
    }

    private static let magic: [UInt8] = Array("SMAP".utf8)

    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appending(path: "com.marcoleejr.spacemap/last-scan.bin")
    }

    /// `tree` should be compacted (no garbage); call inside `tree.read`.
    public static func save(_ tree: DiskTree, header: Header, to url: URL = defaultURL) throws {
        var body = Data()
        body.reserveCapacity(tree.approximateBytes + 64)
        func put<T>(_ array: [T]) {
            var count = UInt64(array.count)
            withUnsafeBytes(of: &count) { body.append(contentsOf: $0) }
            array.withUnsafeBytes { body.append(contentsOf: $0) }
        }
        put(tree.nameBytes); put(tree.nameStart); put(tree.nameLength)
        put(tree.nameID); put(tree.parent); put(tree.childStart); put(tree.childCount); put(tree.childList)
        put(tree.allocated); put(tree.apparent); put(tree.files); put(tree.dirs); put(tree.mtime)
        put(tree.flags); put(tree.categories)
        let compressed = try (body as NSData).compressed(using: .lz4) as Data
        let headerData = try JSONEncoder().encode(header)
        var output = Data(magic)
        var headerLength = UInt32(headerData.count)
        withUnsafeBytes(of: &headerLength) { output.append(contentsOf: $0) }
        output.append(headerData)
        output.append(compressed)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try output.write(to: url, options: .atomic)
    }

    public static func readHeader(from url: URL = defaultURL) -> Header? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let prefix = try? handle.read(upToCount: 8), prefix.count == 8, Array(prefix.prefix(4)) == magic else { return nil }
        let length = prefix.dropFirst(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        guard length < 1 << 20, let json = try? handle.read(upToCount: Int(length)) else { return nil }
        return try? JSONDecoder().decode(Header.self, from: json)
    }

    public static func load(from url: URL = defaultURL) throws -> (tree: DiskTree, header: Header) {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        guard data.count > 8, Array(data.prefix(4)) == magic else { throw CocoaError(.fileReadCorruptFile) }
        let headerLength = Int(data.dropFirst(4).prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        guard 8 + headerLength <= data.count else { throw CocoaError(.fileReadCorruptFile) }
        let header = try JSONDecoder().decode(Header.self, from: data.subdata(in: 8..<8 + headerLength))
        guard header.formatVersion == 1 else { throw CocoaError(.fileReadCorruptFile) }
        let body = try (data.subdata(in: 8 + headerLength..<data.count) as NSData).decompressed(using: .lz4) as Data
        let tree = DiskTree(rootPath: header.rootPath)
        var offset = 0
        func take<T>(_: T.Type) throws -> [T] {
            guard offset + 8 <= body.count else { throw CocoaError(.fileReadCorruptFile) }
            let count = Int(body.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self) })
            offset += 8
            let byteCount = count * MemoryLayout<T>.stride
            guard count >= 0, offset + byteCount <= body.count else { throw CocoaError(.fileReadCorruptFile) }
            let array = [T](unsafeUninitializedCapacity: count) { buffer, initialized in
                body.withUnsafeBytes { raw in
                    memcpy(UnsafeMutableRawPointer(buffer.baseAddress!), raw.baseAddress! + offset, byteCount)
                }
                initialized = count
            }
            offset += byteCount
            return array
        }
        tree.nameBytes = try take(UInt8.self)
        tree.nameStart = try take(UInt32.self)
        tree.nameLength = try take(UInt16.self)
        tree.nameID = try take(UInt32.self)
        tree.parent = try take(UInt32.self)
        tree.childStart = try take(UInt32.self)
        tree.childCount = try take(UInt32.self)
        tree.childList = try take(UInt32.self)
        tree.allocated = try take(UInt64.self)
        tree.apparent = try take(UInt64.self)
        tree.files = try take(UInt32.self)
        tree.dirs = try take(UInt32.self)
        tree.mtime = try take(UInt32.self)
        tree.flags = try take(UInt8.self)
        tree.categories = try take(UInt8.self)
        let n = tree.nameID.count
        guard n > 0, [tree.parent.count, tree.childStart.count, tree.childCount.count, tree.allocated.count, tree.apparent.count,
                      tree.files.count, tree.dirs.count, tree.mtime.count, tree.flags.count, tree.categories.count].allSatisfy({ $0 == n }),
              tree.nameStart.count == tree.nameLength.count,
              tree.nameID.allSatisfy({ Int($0) < tree.nameStart.count }),
              zip(tree.childStart, tree.childCount).allSatisfy({ Int($0) + Int($1) <= tree.childList.count }),
              tree.childList.allSatisfy({ Int($0) < n }),
              zip(tree.nameStart, tree.nameLength).allSatisfy({ Int($0) + Int($1) <= tree.nameBytes.count })
        else { throw CocoaError(.fileReadCorruptFile) }
        tree.finishBuilding()
        return (tree, header)
    }
}
