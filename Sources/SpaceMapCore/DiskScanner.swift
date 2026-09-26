import Darwin
import Dispatch
import Foundation

public final class ScanCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

public enum DiskScannerError: Error, LocalizedError {
    case cannotOpen(String, Int32)

    public var errorDescription: String? {
        switch self {
        case let .cannotOpen(path, code):
            "Could not start scanning \(path): \(String(cString: strerror(code)))"
        }
    }
}

/// Shared entry point for the app and the CLI benchmark. Both must call this so
/// the "same engine" invariant is structural, not coincidental.
public enum ScanEngine {
    public static func scan(
        rootURL: URL,
        includeHidden: Bool = true,
        cancellation: ScanCancellation = ScanCancellation(),
        workers: Int? = nil,
        progress: ((DiskScanProgress) -> Void)? = nil
    ) throws -> DiskScanResult {
        try DiskScanner.scan(
            rootURL: rootURL,
            includeHidden: includeHidden,
            cancellation: cancellation,
            workers: workers,
            progress: progress
        )
    }
}

public enum DiskScanner {
    struct FileIdentifier: Hashable, Sendable {
        let device: UInt64
        let object: UInt64
    }

    /// Sharded hardlink deduplication so parallel workers never serialize on one
    /// global lock. Files are overwhelmingly link-count 1; sharding keeps the
    /// rare duplicate check cheap under contention.
    final class HardlinkDeduplicator: @unchecked Sendable {
        private let shardCount = 32
        private var locks: [NSLock] = []
        private var sets: [Set<FileIdentifier>] = []

        init() {
            locks = (0..<shardCount).map { _ in NSLock() }
            sets = (0..<shardCount).map { _ in Set<FileIdentifier>() }
        }

        func reserveCapacity(_ capacity: Int) {
            let perShard = capacity / shardCount + 16
            for index in 0..<shardCount {
                locks[index].lock()
                sets[index].reserveCapacity(perShard)
                locks[index].unlock()
            }
        }

        /// Returns true when the identifier was newly inserted (keep the file).
        func insert(_ identifier: FileIdentifier) -> Bool {
            let shard = Int(UInt(bitPattern: identifier.hashValue) & 31)
            locks[shard].lock()
            let inserted = sets[shard].insert(identifier).inserted
            locks[shard].unlock()
            return inserted
        }
    }

    struct EntryRecord: Sendable {
        let name: String
        let path: String
        let kind: DiskItemKind?
        let device: UInt64
        let fileIdentifier: FileIdentifier?
        let allocatedBytes: UInt64
        let apparentBytes: UInt64
        let modifiedAt: Date?
        let errorCode: Int32?
        let category: DiskCategory
        let colorCategory: DiskCategory
        /// Context for this entry's children (only used when kind is directory).
        let childContext: ScanCategoryContext
    }

    struct DirectoryTask: Sendable {
        let path: String
        let node: UInt32
        let context: ScanCategoryContext
        let parentCategory: DiskCategory
        let parentColor: DiskCategory
    }

    struct DirectoryReadResult: Sendable {
        let path: String
        var node: UInt32 = 0
        let entries: [EntryRecord]
        let scannedEntries: Int
        let errors: Int
        let inaccessibleEntries: Int
        let deduplicated: Int
        let directoryError: Int32?
        let containsGitDirectory: Bool
    }

    /// Coordinates a fixed set of workers. Locks are held only while queueing one directory result,
    /// never while enumerating individual files or constructing the immutable UI tree.
    private final class WorkCoordinator: @unchecked Sendable {
        private let condition = NSCondition()
        private var pending: [DirectoryTask]
        private var pendingIndex = 0
        private var results: [DirectoryReadResult] = []
        private var resultIndex = 0
        private var outstanding = 1
        private var activeWorkers = 0
        private var isCancelled = false
        private var currentPath: String?

        init(rootTask: DirectoryTask) {
            pending = [rootTask]
        }

        func takeTask(cancellation: ScanCancellation) -> DirectoryTask? {
            condition.lock()
            defer { condition.unlock() }
            while true {
                if isCancelled || cancellation.isCancelled { return nil }
                if pendingIndex < pending.count {
                    let task = pending[pendingIndex]
                    pendingIndex += 1
                    activeWorkers += 1
                    currentPath = task.path
                    compactPendingIfNeeded()
                    return task
                }
                if outstanding == 0 { return nil }
                condition.wait()
            }
        }

        func submit(_ result: DirectoryReadResult) {
            condition.lock()
            results.append(result)
            activeWorkers -= 1
            condition.broadcast()
            condition.unlock()
        }

        func nextResult(timeout: TimeInterval) -> DirectoryReadResult? {
            let deadline = Date().addingTimeInterval(timeout)
            condition.lock()
            defer { condition.unlock() }
            while resultIndex >= results.count && outstanding > 0 {
                if !condition.wait(until: deadline) { break }
            }
            guard resultIndex < results.count else { return nil }
            let result = results[resultIndex]
            resultIndex += 1
            compactResultsIfNeeded()
            return result
        }

        func completeTask(children: [DirectoryTask], cancelled: Bool) {
            condition.lock()
            if isCancelled || cancelled {
                outstanding -= 1
            } else {
                if !children.isEmpty { pending.append(contentsOf: children) }
                outstanding += children.count - 1
            }
            condition.broadcast()
            condition.unlock()
        }

        func cancelPending() {
            condition.lock()
            guard !isCancelled else {
                condition.unlock()
                return
            }
            isCancelled = true
            let queued = pending.count - pendingIndex
            pending.removeAll(keepingCapacity: false)
            pendingIndex = 0
            outstanding -= queued
            condition.broadcast()
            condition.unlock()
        }

        var activePath: String? {
            condition.lock()
            defer { condition.unlock() }
            return currentPath
        }

        var isSettled: Bool {
            condition.lock()
            defer { condition.unlock() }
            return outstanding == 0 && resultIndex >= results.count
        }

        private func compactPendingIfNeeded() {
            guard pendingIndex > 4096, pendingIndex * 2 >= pending.count else { return }
            pending.removeFirst(pendingIndex)
            pendingIndex = 0
        }

        private func compactResultsIfNeeded() {
            guard resultIndex > 1024, resultIndex * 2 >= results.count else { return }
            results.removeFirst(resultIndex)
            resultIndex = 0
        }
    }

    private static let commonName: UInt32 = 0x00000001
    private static let commonDevice: UInt32 = 0x00000002
    private static let commonObjectType: UInt32 = 0x00000008
    private static let commonModifiedTime: UInt32 = 0x00000400
    private static let commonFileID: UInt32 = 0x02000000
    private static let commonError: UInt32 = 0x20000000
    private static let fileLinkCount: UInt32 = 0x00000001
    private static let fileDataLength: UInt32 = 0x00000200
    private static let fileDataAllocationSize: UInt32 = 0x00000400

    /// Directories that trigger cascading privacy prompts without Full Disk
    /// Access. They are skipped by path prefix before any open() call, so the
    /// scan never blocks waiting on TCC and never presents a prompt cascade.
    static func tccSkipPrefixes(homePath: String) -> [String] {
        [
            "Library/Mail",
            "Library/Messages",
            "Library/Safari",
            "Library/Photos",
            "Library/Calendars",
        ].map { (homePath as NSString).appendingPathComponent($0) }
    }

    static func isTCCSkipped(_ path: String, prefixes: [String], name: String) -> Bool {
        if !prefixes.isEmpty {
            for prefix in prefixes {
                if path == prefix || path.hasPrefix(prefix + "/") { return true }
            }
        }
        // Photos libraries are gated by Photos TCC anywhere on disk.
        return name.hasSuffix(".photoslibrary")
    }

    /// Classification of the scan root when it is a directory inside an
    /// existing tree (incremental rescans), so its subtree is classified the
    /// same way a full scan would have classified it.
    public struct Seed: Sendable {
        let category: DiskCategory
        let color: DiskCategory
        let context: ScanCategoryContext
    }

    /// Worker ceiling. Scanning is I/O bound; beyond a handful of threads APFS
    /// metadata locks turn extra workers into system time, not throughput.
    public static var maxWorkers = 8

    /// Uses getattrlistbulk on each directory with a small worker pool at
    /// utility QoS. Classification runs inside workers (O(1) per entry from
    /// the parent context); the coordinator appends each directory's entries
    /// to a compact `DiskTree` in one batch. Symlinks are leaves, hard links
    /// count once, and descent never crosses to another volume.
    public static func scan(
        rootURL: URL,
        includeHidden: Bool = true,
        cancellation: ScanCancellation = ScanCancellation(),
        seed: Seed? = nil,
        workers: Int? = nil,
        progressInterval: TimeInterval = 0.25,
        progress: ((DiskScanProgress) -> Void)? = nil
    ) throws -> DiskScanResult {
        let started = ProcessInfo.processInfo.systemUptime
        let rootPath = rootURL.standardizedFileURL.path
        var rootStat = stat()
        guard rootPath.withCString({ Darwin.lstat($0, &rootStat) }) == 0 else {
            throw DiskScannerError.cannotOpen(rootPath, errno)
        }

        let rootMode = rootStat.st_mode & S_IFMT
        let rootKind: DiskItemKind
        switch rootMode {
        case S_IFDIR: rootKind = .directory
        case S_IFLNK: rootKind = .symlink
        default: rootKind = .file
        }
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        let restricted = FullDiskAccessProbe.isRestricted()
        let skipPrefixes = restricted ? tccSkipPrefixes(homePath: homePath) : []
        let rootContext = seed?.context ?? IncrementalClassifier.rootContext(forPath: rootPath)
        let rootCategory = seed?.category ?? CategoryClassifier.classify(path: rootPath)
        let rootColor = seed?.color ?? (rootCategory == .reclaimable ? .code : rootCategory)

        var scanned = 1
        var errors = 0
        var inaccessible = 0
        var deduplicated = 0
        var skippedProtected = 0
        var currentPath = rootPath
        var lastPublished = started
        var activePathProvider: (() -> String?)?

        let tree = DiskTree(rootPath: rootPath)
        tree.reserveNodes(1 << 16)

        // Single-file roots need no worker pool.
        guard rootKind == .directory else {
            tree.appendNode(DiskTree.NodeValues(
                name: lastComponent(of: rootPath),
                kind: rootKind,
                category: rootCategory,
                color: rootColor,
                allocated: rootKind == .symlink ? 0 : allocatedBytes(from: rootStat),
                apparent: rootKind == .symlink ? 0 : apparentBytes(from: rootStat),
                files: 1,
                modifiedAt: modificationDate(from: rootStat)
            ), parent: DiskTree.none)
            tree.finishBuilding()
            let finalMetrics = ScanMetrics(
                entriesScanned: scanned,
                inaccessibleEntries: inaccessible,
                errors: errors,
                deduplicatedHardlinks: deduplicated,
                duration: ProcessInfo.processInfo.systemUptime - started,
                cancelled: cancellation.isCancelled,
                currentPath: currentPath
            )
            progress?(DiskScanProgress(root: tree.root, metrics: finalMetrics))
            return DiskScanResult(root: tree.root, metrics: finalMetrics)
        }

        tree.appendNode(DiskTree.NodeValues(
            name: lastComponent(of: rootPath),
            kind: .directory,
            category: rootCategory,
            color: rootColor,
            modifiedAt: modificationDate(from: rootStat)
        ), parent: DiskTree.none)

        func metrics(cancelled: Bool) -> ScanMetrics {
            ScanMetrics(
                entriesScanned: scanned,
                inaccessibleEntries: inaccessible + skippedProtected,
                errors: errors,
                deduplicatedHardlinks: deduplicated,
                duration: ProcessInfo.processInfo.systemUptime - started,
                cancelled: cancelled,
                currentPath: currentPath
            )
        }

        func snapshot() -> DiskNode {
            // Depth-limited, directories only: correct totals, cheap to copy.
            tree.compacted(maxDepth: 5, directoriesOnly: true).root
        }

        func publish() {
            guard let progress else { return }
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastPublished >= progressInterval else { return }
            lastPublished = now
            if let activePath = activePathProvider?() { currentPath = activePath }
            progress(DiskScanProgress(root: snapshot(), metrics: metrics(cancelled: cancellation.isCancelled)))
        }

        func finish() -> DiskScanResult {
            tree.finishBuilding()
            tree.shrinkToFit()
            let finalMetrics = metrics(cancelled: cancellation.isCancelled)
            progress?(DiskScanProgress(root: tree.root, metrics: finalMetrics))
            return DiskScanResult(root: tree.root, metrics: finalMetrics)
        }

        progress?(DiskScanProgress(root: snapshot(), metrics: metrics(cancelled: cancellation.isCancelled)))
        guard !cancellation.isCancelled else { return finish() }

        let rootDevice = UInt64(truncatingIfNeeded: rootStat.st_dev)
        let rootTask = DirectoryTask(path: rootPath, node: 0, context: rootContext, parentCategory: rootCategory, parentColor: rootColor)
        let coordinator = WorkCoordinator(rootTask: rootTask)
        activePathProvider = { coordinator.activePath }
        let deduplicator = HardlinkDeduplicator()
        let workerCount = max(1, min(workers ?? maxWorkers, ProcessInfo.processInfo.activeProcessorCount))
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "SpaceMap.directory-workers", qos: .utility, attributes: .concurrent)
        for _ in 0..<workerCount {
            queue.async(group: group) {
                // One reusable 256 KiB transfer buffer per worker thread: no
                // per-directory malloc or bzero on the hot path.
                var buffer = [UInt8](unsafeUninitializedCapacity: 256 * 1024) { _, count in
                    count = 256 * 1024
                }
                while let task = coordinator.takeTask(cancellation: cancellation) {
                    coordinator.submit(readDirectory(
                        task: task,
                        cancellation: cancellation,
                        deduplicator: deduplicator,
                        buffer: &buffer
                    ))
                }
            }
        }

        var childIndices: [UInt32] = []
        var childTasks: [DirectoryTask] = []
        while true {
            if cancellation.isCancelled { coordinator.cancelPending() }
            if let result = coordinator.nextResult(timeout: progressInterval) {
                currentPath = result.path
                scanned += result.scannedEntries
                errors += result.errors
                inaccessible += result.inaccessibleEntries
                deduplicated += result.deduplicated
                if let error = result.directoryError {
                    errors += 1
                    if error == EACCES || error == EPERM { inaccessible += 1 }
                }

                childTasks.removeAll(keepingCapacity: true)
                childIndices.removeAll(keepingCapacity: true)
                let directory = result.node
                if result.containsGitDirectory {
                    let parentIndex = tree.parent[Int(directory)]
                    let parentCategory = parentIndex == DiskTree.none ? nil : tree.category(of: parentIndex)
                    let parentColor = parentIndex == DiskTree.none ? nil : tree.colorCategory(of: parentIndex)
                    let category = CategoryClassifier.classify(path: result.path, parentCategory: parentCategory, hasGitDirectory: true)
                    tree.setCategory(of: directory, category: category, color: category == .reclaimable ? (parentColor ?? .code) : category)
                }
                var addedAllocated: UInt64 = 0
                var addedApparent: UInt64 = 0
                var addedFiles: Int64 = 0
                var addedDirs: Int64 = 0
                var newest: UInt32 = 0
                for entry in result.entries {
                    if let error = entry.errorCode {
                        errors += 1
                        if error == EACCES || error == EPERM { inaccessible += 1 }
                        continue
                    }
                    if !includeHidden && entry.name.hasPrefix(".") { continue }
                    guard let kind = entry.kind else { continue }
                    let seconds = DiskTree.seconds(entry.modifiedAt)
                    newest = max(newest, seconds)
                    if kind == .directory {
                        if entry.device == rootDevice, !cancellation.isCancelled,
                           isTCCSkipped(entry.path, prefixes: skipPrefixes, name: entry.name) {
                            // Skipped subtree: counted as inaccessible, not shown.
                            skippedProtected += 1
                            continue
                        }
                        let child = tree.appendNode(DiskTree.NodeValues(
                            name: entry.name, kind: .directory, category: entry.category, color: entry.colorCategory,
                            modifiedAt: entry.modifiedAt
                        ), parent: directory)
                        childIndices.append(child)
                        addedDirs += 1
                        if entry.device == rootDevice, !cancellation.isCancelled {
                            childTasks.append(DirectoryTask(
                                path: entry.path,
                                node: child,
                                context: entry.childContext,
                                parentCategory: entry.category,
                                parentColor: entry.colorCategory
                            ))
                        }
                    } else {
                        let child = tree.appendNode(DiskTree.NodeValues(
                            name: entry.name, kind: kind, category: entry.category, color: entry.colorCategory,
                            allocated: entry.allocatedBytes, apparent: entry.apparentBytes, files: 1,
                            modifiedAt: entry.modifiedAt
                        ), parent: directory)
                        childIndices.append(child)
                        addedAllocated &+= entry.allocatedBytes
                        addedApparent &+= entry.apparentBytes
                        addedFiles += 1
                    }
                }
                if !childIndices.isEmpty {
                    tree.setChildren(of: directory, childIndices)
                    tree.applyDelta(
                        from: directory,
                        allocated: Int64(bitPattern: addedAllocated),
                        apparent: Int64(bitPattern: addedApparent),
                        files: addedFiles,
                        dirs: addedDirs,
                        newest: newest
                    )
                }
                coordinator.completeTask(children: childTasks, cancelled: cancellation.isCancelled)
            } else if coordinator.isSettled {
                break
            }
            publish()
        }

        group.wait()
        if let activePath = coordinator.activePath { currentPath = activePath }
        return finish()
    }

    /// Lists one directory without descending, for incremental updates.
    static func listDirectory(path: String, seed: Seed) -> DirectoryReadResult {
        var buffer = [UInt8](unsafeUninitializedCapacity: 256 * 1024) { _, count in count = 256 * 1024 }
        let task = DirectoryTask(path: path, node: 0, context: seed.context, parentCategory: seed.category, parentColor: seed.color)
        return readDirectory(task: task, cancellation: ScanCancellation(), deduplicator: HardlinkDeduplicator(), buffer: &buffer)
    }

    private static func readDirectory(
        task: DirectoryTask,
        cancellation: ScanCancellation,
        deduplicator: HardlinkDeduplicator,
        buffer: inout [UInt8]
    ) -> DirectoryReadResult {
        let path = task.path
        let descriptor = path.withCString { Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY) }
        guard descriptor >= 0 else {
            let error = errno
            return DirectoryReadResult(path: path, node: task.node, entries: [], scannedEntries: 0, errors: 0, inaccessibleEntries: 0, deduplicated: 0, directoryError: error, containsGitDirectory: false)
        }
        defer { Darwin.close(descriptor) }

        var attributes = attrlist()
        attributes.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = 0xA200040B // returned attrs, name, device, type, mtime, file ID, per-entry error
        attributes.fileattr = 0x00000601 // link count, data length and allocated data size
        var entries: [EntryRecord] = []
        var scannedEntries = 0
        var errors = 0
        var deduplicated = 0
        var directoryError: Int32?

        while !cancellation.isCancelled {
            errno = 0
            let count = buffer.withUnsafeMutableBytes { rawBuffer -> Int32 in
                guard let baseAddress = rawBuffer.baseAddress else { return -1 }
                return getattrlistbulk(descriptor, &attributes, baseAddress, rawBuffer.count, UInt64(FSOPT_NOFOLLOW))
            }
            if count < 0 {
                let error = errno
                if entries.isEmpty && (error == EINVAL || error == ENOTSUP || error == ENOSYS) {
                    return readDirectoryFallback(
                        descriptor: descriptor,
                        task: task,
                        cancellation: cancellation,
                        deduplicator: deduplicator
                    )
                }
                directoryError = error
                break
            }
            if count == 0 { break }
            scannedEntries += Int(count)

            buffer.withUnsafeBytes { rawBuffer in
                var offset = 0
                for _ in 0..<Int(count) {
                    guard offset + 4 <= rawBuffer.count else {
                        errors += 1
                        break
                    }
                    let recordLength = Int(rawBuffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                    guard recordLength >= 24, offset + recordLength <= rawBuffer.count else {
                        errors += 1
                        break
                    }
                    if let entry = parseEntry(
                        rawBuffer,
                        recordOffset: offset,
                        recordLength: recordLength,
                        task: task,
                        descriptor: descriptor,
                        errors: &errors
                    ) {
                        if let identifier = entry.fileIdentifier, entry.kind == .file {
                            if deduplicator.insert(identifier) {
                                entries.append(entry)
                            } else {
                                deduplicated += 1
                            }
                        } else {
                            entries.append(entry)
                        }
                    }
                    offset += recordLength
                }
            }
        }

        let containsGitDirectory = entries.contains { $0.name == ".git" && $0.kind != nil && $0.errorCode == nil }
        return DirectoryReadResult(
            path: path,
            node: task.node,
            entries: entries,
            scannedEntries: scannedEntries,
            errors: errors,
            inaccessibleEntries: 0,
            deduplicated: deduplicated,
            directoryError: directoryError,
            containsGitDirectory: containsGitDirectory
        )
    }

    private static func classifyForEntry(
        name: String,
        task: DirectoryTask
    ) -> (category: DiskCategory, color: DiskCategory, context: ScanCategoryContext) {
        let (category, childContext) = IncrementalClassifier.classifyEntry(
            name: name,
            parent: task.context,
            parentCategory: task.parentCategory
        )
        let color = category == .reclaimable ? task.parentColor : category
        return (category, color, childContext)
    }

    private static func parseEntry(
        _ bytes: UnsafeRawBufferPointer,
        recordOffset: Int,
        recordLength: Int,
        task: DirectoryTask,
        descriptor: Int32,
        errors: inout Int
    ) -> EntryRecord? {
        let directoryPath = task.path
        let common = bytes.loadUnaligned(fromByteOffset: recordOffset + 4, as: UInt32.self)
        let fileAttributes = bytes.loadUnaligned(fromByteOffset: recordOffset + 16, as: UInt32.self)
        var cursor = recordOffset + 24
        var name: String?
        var device: UInt64?
        var objectType: UInt32?
        var modifiedAt: Date?
        var fileIdentifier: FileIdentifier?
        var errorCode: Int32?
        var dataLength: UInt64?
        var allocationLength: UInt64?
        var linkCount: UInt32 = 1

        for bit in [commonName, commonDevice, commonObjectType, commonModifiedTime, commonFileID, commonError] where common & bit != 0 {
            switch bit {
            case commonName:
                guard cursor + 8 <= recordOffset + recordLength else { errors += 1; return nil }
                let relativeOffset = Int(bytes.loadUnaligned(fromByteOffset: cursor, as: Int32.self))
                let nameLength = Int(bytes.loadUnaligned(fromByteOffset: cursor + 4, as: UInt32.self))
                let dataOffset = cursor + relativeOffset
                guard nameLength > 0, dataOffset >= recordOffset, dataOffset + nameLength <= recordOffset + recordLength else { errors += 1; return nil }
                let namePointer = bytes.baseAddress!.advanced(by: dataOffset).assumingMemoryBound(to: CChar.self)
                name = namePointer.withMemoryRebound(to: UInt8.self, capacity: nameLength) { pointer in
                    let rawName = UnsafeBufferPointer<UInt8>(start: pointer, count: nameLength)
                    let visibleLength = rawName.firstIndex(of: 0) ?? rawName.count
                    return String(decoding: rawName.prefix(visibleLength), as: UTF8.self)
                }
                cursor += 8
            case commonDevice:
                guard cursor + MemoryLayout<dev_t>.size <= recordOffset + recordLength else { errors += 1; return nil }
                let value = bytes.loadUnaligned(fromByteOffset: cursor, as: dev_t.self)
                device = UInt64(truncatingIfNeeded: value)
                cursor += MemoryLayout<dev_t>.size
            case commonObjectType:
                guard cursor + MemoryLayout<UInt32>.size <= recordOffset + recordLength else { errors += 1; return nil }
                objectType = bytes.loadUnaligned(fromByteOffset: cursor, as: UInt32.self)
                cursor += MemoryLayout<UInt32>.size
            case commonModifiedTime:
                guard cursor + MemoryLayout<timespec>.size <= recordOffset + recordLength else { errors += 1; return nil }
                let value = bytes.loadUnaligned(fromByteOffset: cursor, as: timespec.self)
                modifiedAt = Date(timeIntervalSince1970: TimeInterval(value.tv_sec) + TimeInterval(value.tv_nsec) / 1_000_000_000)
                cursor += MemoryLayout<timespec>.size
            case commonFileID:
                guard cursor + 8 <= recordOffset + recordLength else { errors += 1; return nil }
                let object = bytes.loadUnaligned(fromByteOffset: cursor, as: UInt32.self)
                let generation = bytes.loadUnaligned(fromByteOffset: cursor + 4, as: UInt32.self)
                if let device { fileIdentifier = FileIdentifier(device: device, object: (UInt64(object) << 32) | UInt64(generation)) }
                cursor += 8
            case commonError:
                guard cursor + MemoryLayout<Int32>.size <= recordOffset + recordLength else { errors += 1; return nil }
                let value = bytes.loadUnaligned(fromByteOffset: cursor, as: Int32.self)
                if value != 0 { errorCode = value }
                cursor += MemoryLayout<Int32>.size
            default:
                break
            }
        }

        if fileAttributes & fileLinkCount != 0 {
            guard cursor + 4 <= recordOffset + recordLength else { errors += 1; return nil }
            linkCount = bytes.loadUnaligned(fromByteOffset: cursor, as: UInt32.self)
            cursor += 4
        }
        for bit in [fileDataLength, fileDataAllocationSize] where fileAttributes & bit != 0 {
            guard cursor + MemoryLayout<off_t>.size <= recordOffset + recordLength else { errors += 1; return nil }
            let value = bytes.loadUnaligned(fromByteOffset: cursor, as: off_t.self)
            if bit == fileDataLength { dataLength = UInt64(max(0, Int64(value))) }
            else { allocationLength = UInt64(max(0, Int64(value))) }
            cursor += MemoryLayout<off_t>.size
        }

        guard let name, !name.isEmpty else { errors += 1; return nil }
        if name == "." || name == ".." { return nil }
        let classified = classifyForEntry(name: name, task: task)
        if let errorCode {
            return EntryRecord(name: name, path: childPath(directoryPath, name), kind: nil, device: device ?? 0, fileIdentifier: nil, allocatedBytes: 0, apparentBytes: 0, modifiedAt: nil, errorCode: errorCode, category: classified.category, colorCategory: classified.color, childContext: classified.context)
        }

        if device == nil || objectType == nil || modifiedAt == nil || (objectType == 1 && (dataLength == nil || allocationLength == nil)) {
            var status = stat()
            let result = name.withCString { fstatat(descriptor, $0, &status, AT_SYMLINK_NOFOLLOW) }
            if result == 0 {
                if device == nil { device = UInt64(truncatingIfNeeded: status.st_dev) }
                if objectType == nil { objectType = Self.objectType(from: status.st_mode) }
                if modifiedAt == nil { modifiedAt = modificationDate(from: status) }
                if fileAttributes & fileLinkCount == 0 { linkCount = UInt32(status.st_nlink) }
                if objectType == 1 {
                    if dataLength == nil { dataLength = apparentBytes(from: status) }
                    if allocationLength == nil { allocationLength = allocatedBytes(from: status) }
                }
                if fileIdentifier == nil, let device {
                    fileIdentifier = FileIdentifier(device: device, object: UInt64(status.st_ino))
                }
            } else {
                let error = errno
                return EntryRecord(name: name, path: childPath(directoryPath, name), kind: nil, device: device ?? 0, fileIdentifier: nil, allocatedBytes: 0, apparentBytes: 0, modifiedAt: nil, errorCode: error, category: classified.category, colorCategory: classified.color, childContext: classified.context)
            }
        }

        guard let objectType, let device else { errors += 1; return nil }
        let kind: DiskItemKind?
        switch objectType {
        case 1: kind = .file // VREG
        case 2: kind = .directory // VDIR
        case 5: kind = .symlink // VLNK
        default: kind = nil
        }
        return EntryRecord(
            name: name,
            path: childPath(directoryPath, name),
            kind: kind,
            device: device,
            // Only multi-link files need deduplication; skipping the rest keeps
            // the shared set tiny instead of one entry per file on disk.
            fileIdentifier: kind == .file && linkCount > 1 ? fileIdentifier : nil,
            allocatedBytes: kind == .file ? (allocationLength ?? 0) : 0,
            apparentBytes: kind == .file ? (dataLength ?? 0) : 0,
            modifiedAt: modifiedAt,
            errorCode: nil,
            category: classified.category,
            colorCategory: classified.color,
            childContext: classified.context
        )
    }

    private static func readDirectoryFallback(
        descriptor: Int32,
        task: DirectoryTask,
        cancellation: ScanCancellation,
        deduplicator: HardlinkDeduplicator
    ) -> DirectoryReadResult {
        let path = task.path
        let duplicate = dup(descriptor)
        guard duplicate >= 0, let stream = fdopendir(duplicate) else {
            if duplicate >= 0 { close(duplicate) }
            let error = errno
            return DirectoryReadResult(path: path, node: task.node, entries: [], scannedEntries: 0, errors: 0, inaccessibleEntries: 0, deduplicated: 0, directoryError: error, containsGitDirectory: false)
        }
        defer { closedir(stream) }
        var entries: [EntryRecord] = []
        var scanned = 0
        var errors = 0
        var inaccessible = 0
        var deduplicated = 0
        while !cancellation.isCancelled, let rawEntry = readdir(stream) {
            let name = withUnsafePointer(to: &rawEntry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: rawEntry.pointee.d_name)) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            scanned += 1
            var status = stat()
            let result = name.withCString { fstatat(descriptor, $0, &status, AT_SYMLINK_NOFOLLOW) }
            guard result == 0 else {
                errors += 1
                if errno == EACCES || errno == EPERM { inaccessible += 1 }
                continue
            }
            let rawType = status.st_mode & S_IFMT
            let kind: DiskItemKind?
            switch rawType {
            case S_IFDIR: kind = .directory
            case S_IFREG: kind = .file
            case S_IFLNK: kind = .symlink
            default: kind = nil
            }
            let device = UInt64(truncatingIfNeeded: status.st_dev)
            let classified = classifyForEntry(name: name, task: task)
            let identifier = kind == .file && status.st_nlink > 1 ? FileIdentifier(device: device, object: UInt64(status.st_ino)) : nil
            if let identifier, !deduplicator.insert(identifier) {
                deduplicated += 1
                continue
            }
            entries.append(EntryRecord(
                name: name,
                path: childPath(path, name),
                kind: kind,
                device: device,
                fileIdentifier: identifier,
                allocatedBytes: kind == .file ? allocatedBytes(from: status) : 0,
                apparentBytes: kind == .file ? apparentBytes(from: status) : 0,
                modifiedAt: modificationDate(from: status),
                errorCode: nil,
                category: classified.category,
                colorCategory: classified.color,
                childContext: classified.context
            ))
        }
        return DirectoryReadResult(
            path: path,
            node: task.node,
            entries: entries,
            scannedEntries: scanned,
            errors: errors,
            inaccessibleEntries: inaccessible,
            deduplicated: deduplicated,
            directoryError: nil,
            containsGitDirectory: entries.contains { $0.name == ".git" && $0.kind != nil }
        )
    }

    private static func objectType(from mode: mode_t) -> UInt32? {
        switch mode & S_IFMT {
        case S_IFREG: 1
        case S_IFDIR: 2
        case S_IFLNK: 5
        default: nil
        }
    }

    private static func childPath(_ parent: String, _ name: String) -> String {
        parent == "/" ? "/\(name)" : "\(parent)/\(name)"
    }

    private static func lastComponent(of path: String) -> String {
        path == "/" ? "/" : (path as NSString).lastPathComponent
    }

    private static func allocatedBytes(from status: stat) -> UInt64 {
        UInt64(max(0, Int64(status.st_blocks))) &* 512
    }

    private static func apparentBytes(from status: stat) -> UInt64 {
        UInt64(max(0, Int64(status.st_size)))
    }

    private static func modificationDate(from status: stat) -> Date {
        Date(timeIntervalSince1970: TimeInterval(status.st_mtimespec.tv_sec) + TimeInterval(status.st_mtimespec.tv_nsec) / 1_000_000_000)
    }
}

public enum FullDiskAccessProbe {
    public enum Status: Equatable { case granted, denied, unknown }

    /// Result of actually opening a path: 0 on success, otherwise errno.
    public typealias Opener = (_ path: String, _ isDirectory: Bool) -> Int32

    /// TCC is enforced at open(), not by access() or fileExists, so the only
    /// reliable signal is a real open of a Full Disk Access protected item.
    /// EPERM/EACCES means denied, success means granted, and a missing item
    /// is inconclusive, so the next candidate is tried.
    public static func candidates(home: String) -> [(path: String, isDirectory: Bool)] {
        [
            ("Library/Application Support/com.apple.TCC/TCC.db", false),
            ("Library/Safari", true),
            ("Library/Mail", true),
            ("Library/Messages", true),
        ].map { ((home as NSString).appendingPathComponent($0.0), $0.1) }
    }

    public static func status(
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        opener: Opener = realOpen
    ) -> Status {
        for candidate in candidates(home: home) {
            switch opener(candidate.path, candidate.isDirectory) {
            case 0: return .granted
            case EPERM, EACCES: return .denied
            default: continue
            }
        }
        return .unknown
    }

    public static func isRestricted() -> Bool { status() == .denied }

    public static func realOpen(_ path: String, _ isDirectory: Bool) -> Int32 {
        if isDirectory {
            guard let dir = opendir(path) else { return errno }
            closedir(dir)
            return 0
        }
        let fd = Darwin.open(path, O_RDONLY)
        if fd < 0 { return errno }
        Darwin.close(fd)
        return 0
    }
}
