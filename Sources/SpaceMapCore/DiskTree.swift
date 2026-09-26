import Foundation

/// Compact arena for the scanned tree. Every node lives in parallel arrays
/// (struct-of-arrays), names are interned into one UTF-8 byte pool, and no
/// node owns a String, an NSString or a child array. A home-directory scan
/// with millions of entries costs ~50 bytes per node instead of the ~400 a
/// value tree with per-node path strings needs.
///
/// Threading: the scanner owns a tree while building it. Once handed to the
/// app, only the main thread mutates it (through `write`) and background
/// passes read it through `read`, so a reader never sees a half-applied delta.
public final class DiskTree: @unchecked Sendable {
    public static let none = UInt32.max

    // Name pool.
    var nameBytes: [UInt8] = []
    var nameStart: [UInt32] = []
    var nameLength: [UInt16] = []
    private var interner: [String: UInt32]? = [:]

    // Nodes.
    var nameID: [UInt32] = []
    var parent: [UInt32] = []
    var childStart: [UInt32] = []
    var childCount: [UInt32] = []
    var childList: [UInt32] = []
    var allocated: [UInt64] = []
    var apparent: [UInt64] = []
    var files: [UInt32] = []
    var dirs: [UInt32] = []
    /// Seconds since 1970; 0 means unknown.
    var mtime: [UInt32] = []
    /// Bits 0-1 kind, bit 7 detached.
    var flags: [UInt8] = []
    /// Low nibble category, high nibble color category.
    var categories: [UInt8] = []

    /// Files with more than one hard link. Only one link (`counted`) is a
    /// node in the tree; `others` are directories holding the uncounted
    /// links, so the space is never counted twice and can move to another
    /// link when the counted one goes away.
    struct LinkRecord {
        var counted: UInt32
        var others: [UInt32]
    }
    var links: [DiskScanner.FileIdentifier: LinkRecord] = [:]
    /// Indexes over `links` so updates touch only the records involved.
    private var countedByNode: [UInt32: DiskScanner.FileIdentifier] = [:]
    private var uncountedByDirectory: [UInt32: Set<DiskScanner.FileIdentifier>] = [:]
    /// Counted links detached since the last orphan sweep.
    private var orphanCandidates = Set<DiskScanner.FileIdentifier>()

    /// Full path of node 0.
    public let rootPath: String
    /// Bumped by every mutation so views can cache layouts per version.
    public private(set) var version: UInt64 = 0
    /// Nodes no longer reachable from the root (removed or replaced).
    public private(set) var garbageNodes = 0

    private var rwlock = pthread_rwlock_t()

    public init(rootPath: String) {
        self.rootPath = rootPath
        pthread_rwlock_init(&rwlock, nil)
    }

    deinit { pthread_rwlock_destroy(&rwlock) }

    public var nodeCount: Int { nameID.count }
    public var uniqueNameCount: Int { nameStart.count }
    public var namePoolBytes: Int { nameBytes.count }
    public var liveNodeCount: Int { nodeCount - garbageNodes }
    public var root: DiskNode { DiskNode(tree: self, index: 0) }

    // MARK: Locking

    public func read<T>(_ body: () throws -> T) rethrows -> T {
        pthread_rwlock_rdlock(&rwlock)
        defer { pthread_rwlock_unlock(&rwlock) }
        return try body()
    }

    public func write<T>(_ body: () throws -> T) rethrows -> T {
        pthread_rwlock_wrlock(&rwlock)
        defer {
            version &+= 1
            pthread_rwlock_unlock(&rwlock)
        }
        return try body()
    }

    /// Drops the interning table once bulk building is over; later appends
    /// (incremental updates) are rare enough to store names unshared.
    public func finishBuilding() { interner = nil }

    /// Growth by doubling leaves up to half of each array unused; copying into
    /// exact-size buffers one array at a time returns that memory.
    public func shrinkToFit() {
        func exact<T>(_ array: inout [T]) {
            guard array.capacity > array.count + 1024 else { return }
            array = array.withUnsafeBufferPointer { Array($0) }
        }
        exact(&nameBytes); exact(&nameStart); exact(&nameLength)
        exact(&nameID); exact(&parent); exact(&childStart); exact(&childCount); exact(&childList)
        exact(&allocated); exact(&apparent); exact(&files); exact(&dirs); exact(&mtime)
        exact(&flags); exact(&categories)
    }

    // MARK: Names

    func internName(_ name: String) -> UInt32 {
        if let existing = interner?[name] { return existing }
        let id = UInt32(nameStart.count)
        var utf8 = Array(name.utf8)
        if utf8.count > Int(UInt16.max) { utf8 = Array(utf8.prefix(Int(UInt16.max))) }
        nameStart.append(UInt32(nameBytes.count))
        nameLength.append(UInt16(utf8.count))
        nameBytes.append(contentsOf: utf8)
        interner?[name] = id
        return id
    }

    func name(of index: UInt32) -> String {
        let id = Int(nameID[Int(index)])
        let start = Int(nameStart[id])
        let length = Int(nameLength[id])
        return nameBytes.withUnsafeBufferPointer {
            String(decoding: UnsafeBufferPointer(rebasing: $0[start..<start + length]), as: UTF8.self)
        }
    }

    func nameEquals(_ index: UInt32, _ candidate: Substring) -> Bool {
        let id = Int(nameID[Int(index)])
        let start = Int(nameStart[id])
        let length = Int(nameLength[id])
        let utf8 = candidate.utf8
        guard utf8.count == length else { return false }
        var offset = start
        for byte in utf8 {
            if nameBytes[offset] != byte { return false }
            offset += 1
        }
        return true
    }

    // MARK: Hard links

    /// True when `index` and every ancestor are still attached to the root.
    func isReachable(_ index: UInt32) -> Bool {
        var cursor = index
        while Int(cursor) < nodeCount {
            if !isAttached(cursor) { return false }
            if cursor == 0 { return true }
            cursor = parent[Int(cursor)]
        }
        return false
    }

    func recordCountedLink(_ id: DiskScanner.FileIdentifier, at index: UInt32) {
        var record = links[id, default: LinkRecord(counted: DiskTree.none, others: [])]
        if record.counted != DiskTree.none { countedByNode[record.counted] = nil }
        record.counted = index
        links[id] = record
        countedByNode[index] = id
    }

    func recordUncountedLink(_ id: DiskScanner.FileIdentifier, in directory: UInt32) {
        var record = links[id, default: LinkRecord(counted: DiskTree.none, others: [])]
        if !record.others.contains(directory) { record.others.append(directory) }
        links[id] = record
        uncountedByDirectory[directory, default: []].insert(id)
    }

    func forgetUncountedLink(_ id: DiskScanner.FileIdentifier, in directory: UInt32) {
        links[id]?.others.removeAll { $0 == directory }
        uncountedByDirectory[directory]?.remove(id)
        if uncountedByDirectory[directory]?.isEmpty == true { uncountedByDirectory[directory] = nil }
        if let record = links[id], record.counted == DiskTree.none, record.others.isEmpty { links[id] = nil }
    }

    /// Uncounted links currently recorded for `directory`.
    func uncountedLinks(in directory: UInt32) -> Set<DiskScanner.FileIdentifier> {
        uncountedByDirectory[directory] ?? []
    }

    private func dropLinkRecord(_ id: DiskScanner.FileIdentifier) {
        guard let record = links.removeValue(forKey: id) else { return }
        if record.counted != DiskTree.none, countedByNode[record.counted] == id { countedByNode[record.counted] = nil }
        for directory in record.others {
            uncountedByDirectory[directory]?.remove(id)
            if uncountedByDirectory[directory]?.isEmpty == true { uncountedByDirectory[directory] = nil }
        }
    }

    /// Queues counted links inside a subtree that is leaving the tree.
    private func noteDetachedLinks(under index: UInt32) {
        guard !countedByNode.isEmpty else { return }
        guard isDirectory(index) else {
            if let id = countedByNode[index] { orphanCandidates.insert(id) }
            return
        }
        var stack = [index]
        while let node = stack.popLast() {
            for child in children(of: node) {
                if isDirectory(child) { stack.append(child) }
                else if let id = countedByNode[child] { orphanCandidates.insert(id) }
            }
        }
    }

    func rebuildLinkIndexes() {
        countedByNode = [:]
        uncountedByDirectory = [:]
        orphanCandidates = []
        for (id, record) in links {
            if record.counted != DiskTree.none { countedByNode[record.counted] = id }
            for directory in record.others { uncountedByDirectory[directory, default: []].insert(id) }
        }
    }

    /// Identifiers whose counted link is in the tree (orphans are swept
    /// after every update, so a counted index is a live one).
    func countedLinkIdentifiers() -> Set<DiskScanner.FileIdentifier> {
        Set(countedByNode.values)
    }

    /// Links whose counted copy just left the tree while other links remain
    /// on disk: returns the directories to reread so one of them is counted.
    /// Only links detached since the last sweep are examined, and each is
    /// reported once (its record is then marked uncounted), so a directory
    /// that cannot be read is never requested in a loop.
    public func orphanedLinkDirectories() -> [UInt32] {
        guard !orphanCandidates.isEmpty else { return [] }
        var directories = Set<UInt32>()
        for id in orphanCandidates {
            guard let record = links[id], record.counted != DiskTree.none, !isReachable(record.counted) else { continue }
            let live = record.others.filter { isReachable($0) }
            if live.isEmpty {
                dropLinkRecord(id)
                continue
            }
            countedByNode[record.counted] = nil
            links[id] = LinkRecord(counted: DiskTree.none, others: live)
            directories.formUnion(live)
        }
        orphanCandidates = []
        return directories.sorted()
    }

    // MARK: Accessors

    func kind(of index: UInt32) -> DiskItemKind {
        switch flags[Int(index)] & 0x3 {
        case 0: .directory
        case 1: .file
        default: .symlink
        }
    }

    func isDirectory(_ index: UInt32) -> Bool { flags[Int(index)] & 0x3 == 0 }
    func isAttached(_ index: UInt32) -> Bool { flags[Int(index)] & 0x80 == 0 }
    func category(of index: UInt32) -> DiskCategory { DiskCategory.fromCode(categories[Int(index)] & 0xF) }
    func colorCategory(of index: UInt32) -> DiskCategory { DiskCategory.fromCode(categories[Int(index)] >> 4) }

    func modified(of index: UInt32) -> Date? {
        let seconds = mtime[Int(index)]
        return seconds == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    /// Nodes in the subtree including itself (files count symlinks, like the scanner).
    func subtreeNodeCount(_ index: UInt32) -> Int {
        isDirectory(index) ? Int(files[Int(index)]) + Int(dirs[Int(index)]) + 1 : 1
    }

    @inline(__always)
    func children(of index: UInt32) -> ArraySlice<UInt32> {
        let start = Int(childStart[Int(index)])
        return childList[start..<start + Int(childCount[Int(index)])]
    }

    func path(of index: UInt32) -> String {
        if index == 0 { return rootPath }
        var chain: [UInt32] = []
        var cursor = index
        while cursor != 0, cursor != DiskTree.none {
            chain.append(cursor)
            cursor = parent[Int(cursor)]
        }
        var path = rootPath == "/" ? "" : rootPath
        for node in chain.reversed() {
            path += "/"
            path += name(of: node)
        }
        return path
    }

    func child(of index: UInt32, named component: Substring) -> UInt32? {
        for child in children(of: index) where nameEquals(child, component) { return child }
        return nil
    }

    /// Walks path components from the root. Returns the deepest existing node
    /// and whether it matched the whole path.
    public func deepestNode(forPath target: String) -> (index: UInt32, exact: Bool)? {
        if target == rootPath { return (0, true) }
        let prefix = rootPath == "/" ? "/" : rootPath + "/"
        guard target.hasPrefix(prefix) else { return nil }
        var cursor: UInt32 = 0
        for component in target.dropFirst(prefix.count).split(separator: "/") {
            guard let next = child(of: cursor, named: component) else { return (cursor, false) }
            cursor = next
        }
        return (cursor, true)
    }

    public func index(forPath target: String) -> UInt32? {
        guard let found = deepestNode(forPath: target), found.exact else { return nil }
        return found.index
    }

    // MARK: Building

    struct NodeValues {
        var name: String
        var kind: DiskItemKind
        var category: DiskCategory
        var color: DiskCategory
        var allocated: UInt64 = 0
        var apparent: UInt64 = 0
        var files: UInt32 = 0
        var dirs: UInt32 = 0
        var modifiedAt: Date?
        /// Set for files with more than one hard link.
        var link: DiskScanner.FileIdentifier?
        /// Another link to the same file was already seen in this listing.
        var duplicateLink = false
    }

    @discardableResult
    func appendNode(_ values: NodeValues, parent parentIndex: UInt32) -> UInt32 {
        appendRaw(
            nameID: internName(values.name),
            parent: parentIndex,
            kindBits: values.kind.code,
            categoryByte: values.category.code | (values.color.code << 4),
            allocated: values.allocated,
            apparent: values.apparent,
            files: values.files,
            dirs: values.dirs,
            mtime: DiskTree.seconds(values.modifiedAt)
        )
    }

    func appendRaw(nameID id: UInt32, parent parentIndex: UInt32, kindBits: UInt8, categoryByte: UInt8,
                   allocated alloc: UInt64, apparent app: UInt64, files fileCount: UInt32, dirs dirCount: UInt32, mtime seconds: UInt32) -> UInt32 {
        let index = UInt32(nameID.count)
        nameID.append(id)
        parent.append(parentIndex)
        childStart.append(0)
        childCount.append(0)
        allocated.append(alloc)
        apparent.append(app)
        files.append(fileCount)
        dirs.append(dirCount)
        mtime.append(seconds)
        flags.append(kindBits)
        categories.append(categoryByte)
        return index
    }

    /// Writes a fresh contiguous child range for `index`; the old range is left behind.
    func setChildren(of index: UInt32, _ children: [UInt32]) {
        childStart[Int(index)] = UInt32(childList.count)
        childCount[Int(index)] = UInt32(children.count)
        childList.append(contentsOf: children)
        for child in children { parent[Int(child)] = index }
    }

    func setCategory(of index: UInt32, category: DiskCategory, color: DiskCategory) {
        categories[Int(index)] = category.code | (color.code << 4)
    }

    /// Adds a signed delta to `index` and every ancestor. Newer mtimes also bubble up.
    func applyDelta(from index: UInt32, allocated dAlloc: Int64, apparent dApp: Int64, files dFiles: Int64, dirs dDirs: Int64, newest: UInt32 = 0) {
        var cursor = index
        while cursor != DiskTree.none {
            let i = Int(cursor)
            allocated[i] = DiskTree.add(allocated[i], dAlloc)
            apparent[i] = DiskTree.add(apparent[i], dApp)
            files[i] = UInt32(clamping: Int64(files[i]) + dFiles)
            dirs[i] = UInt32(clamping: Int64(dirs[i]) + dDirs)
            if newest > mtime[i] { mtime[i] = newest }
            cursor = parent[i]
        }
    }

    // MARK: Mutation (call inside `write`)

    /// Detaches `index` from its parent and subtracts its totals from every
    /// ancestor up to the root. Returns false for the root or a detached node.
    @discardableResult
    public func removeNode(_ index: UInt32) -> Bool {
        guard index != 0, Int(index) < nodeCount, isAttached(index) else { return false }
        let parentIndex = parent[Int(index)]
        guard parentIndex != DiskTree.none else { return false }
        let start = Int(childStart[Int(parentIndex)])
        let count = Int(childCount[Int(parentIndex)])
        guard let slot = (start..<start + count).first(where: { childList[$0] == index }) else { return false }
        childList[slot] = childList[start + count - 1]
        childCount[Int(parentIndex)] = UInt32(count - 1)
        let i = Int(index)
        applyDelta(
            from: parentIndex,
            allocated: -Int64(allocated[i]),
            apparent: -Int64(apparent[i]),
            files: -Int64(files[i]),
            dirs: -(Int64(dirs[i]) + (isDirectory(index) ? 1 : 0))
        )
        detach(index)
        return true
    }

    private func detach(_ index: UInt32) {
        noteDetachedLinks(under: index)
        garbageNodes += subtreeNodeCount(index)
        flags[Int(index)] |= 0x80
        parent[Int(index)] = DiskTree.none
    }

    /// Copies `source`'s subtree at `sourceIndex` into this tree (unattached)
    /// and returns the new index. Used to graft rescanned directories.
    func copySubtree(from source: DiskTree, at sourceIndex: UInt32) -> UInt32 {
        let tracksLinks = !source.links.isEmpty
        var remap: [UInt32: UInt32] = [:]
        func copyNode(_ s: UInt32, parent newParent: UInt32) -> UInt32 {
            let i = Int(s)
            return appendRaw(
                nameID: internName(source.name(of: s)),
                parent: newParent,
                kindBits: source.flags[i] & 0x3,
                categoryByte: source.categories[i],
                allocated: source.allocated[i],
                apparent: source.apparent[i],
                files: source.files[i],
                dirs: source.dirs[i],
                mtime: source.mtime[i]
            )
        }
        let newRoot = copyNode(sourceIndex, parent: DiskTree.none)
        remap[sourceIndex] = newRoot
        var stack = [sourceIndex]
        while let s = stack.popLast() {
            let children = source.children(of: s)
            guard !children.isEmpty else { continue }
            let target = remap[s]!
            var copied: [UInt32] = []
            copied.reserveCapacity(children.count)
            for child in children {
                let newChild = copyNode(child, parent: target)
                copied.append(newChild)
                if source.childCount[Int(child)] > 0 {
                    remap[child] = newChild
                    stack.append(child)
                } else if tracksLinks {
                    remap[child] = newChild
                }
            }
            setChildren(of: target, copied)
        }
        if tracksLinks {
            for (id, record) in source.links {
                if let counted = remap[record.counted] {
                    let existing = links[id]?.counted ?? DiskTree.none
                    // The scan was seeded with this tree's counted links, so a
                    // counted copy here means the id was free.
                    if existing == DiskTree.none || !isReachable(existing) { recordCountedLink(id, at: counted) }
                }
                for other in record.others { if let directory = remap[other] { recordUncountedLink(id, in: directory) } }
            }
        }
        return newRoot
    }

    /// Replaces the children of directory `index` with `kept` (existing
    /// attached children) plus `added` (new unattached subtrees), recomputes
    /// its totals and pushes the difference to every ancestor.
    public func replaceChildren(of index: UInt32, kept: [UInt32], added: [UInt32], newestModified: Date? = nil) {
        let keptSet = Set(kept)
        for old in children(of: index) where !keptSet.contains(old) { detach(old) }
        let all = kept + added
        setChildren(of: index, all)
        var sumAlloc: UInt64 = 0, sumApp: UInt64 = 0
        var sumFiles: Int64 = 0, sumDirs: Int64 = 0
        var newest: UInt32 = DiskTree.seconds(newestModified)
        for child in all {
            let c = Int(child)
            sumAlloc &+= allocated[c]
            sumApp &+= apparent[c]
            if isDirectory(child) {
                sumFiles += Int64(files[c])
                sumDirs += Int64(dirs[c]) + 1
            } else {
                sumFiles += 1
            }
            newest = max(newest, mtime[c])
        }
        let i = Int(index)
        applyDelta(
            from: index,
            allocated: Int64(bitPattern: sumAlloc &- allocated[i]),
            apparent: Int64(bitPattern: sumApp &- apparent[i]),
            files: sumFiles - Int64(files[i]),
            dirs: sumDirs - Int64(dirs[i]),
            newest: newest
        )
    }

    // MARK: Copies

    /// Reachable-only copy. Used for depth-limited progress snapshots and to
    /// drop garbage left by incremental updates before saving.
    public func compacted(maxDepth: Int = .max, directoriesOnly: Bool = false) -> DiskTree {
        let copy = DiskTree(rootPath: rootPath)
        copy.nameBytes.reserveCapacity(maxDepth == .max ? nameBytes.count : 0)
        let reserve = maxDepth == .max && !directoriesOnly ? liveNodeCount : 0
        copy.reserveNodes(reserve)
        // Names are copied through the interner so shared names stay shared.
        var nameMap = [UInt32](repeating: DiskTree.none, count: maxDepth == .max ? nameStart.count : 0)
        func mappedName(_ s: UInt32) -> UInt32 {
            let id = nameID[Int(s)]
            if !nameMap.isEmpty {
                if nameMap[Int(id)] == DiskTree.none {
                    let newID = UInt32(copy.nameStart.count)
                    let start = Int(nameStart[Int(id)]), length = Int(nameLength[Int(id)])
                    copy.nameStart.append(UInt32(copy.nameBytes.count))
                    copy.nameLength.append(UInt16(length))
                    copy.nameBytes.append(contentsOf: nameBytes[start..<start + length])
                    nameMap[Int(id)] = newID
                }
                return nameMap[Int(id)]
            }
            return copy.internName(name(of: s))
        }
        func copyNode(_ s: UInt32, parent newParent: UInt32) -> UInt32 {
            let i = Int(s)
            return copy.appendRaw(nameID: mappedName(s), parent: newParent, kindBits: flags[i] & 0x3, categoryByte: categories[i],
                                  allocated: allocated[i], apparent: apparent[i], files: files[i], dirs: dirs[i], mtime: mtime[i])
        }
        // Nodes referenced by hard-link records, to carry the records over.
        var linkTargets: [UInt32: UInt32] = [:]
        if maxDepth == .max, !directoriesOnly {
            for record in links.values {
                linkTargets[record.counted] = DiskTree.none
                for other in record.others { linkTargets[other] = DiskTree.none }
            }
        }
        let copyRoot = copyNode(0, parent: DiskTree.none)
        if linkTargets[0] != nil { linkTargets[0] = copyRoot }
        // Breadth-first keeps each directory's children contiguous and in order.
        var queue: [(source: UInt32, target: UInt32, depth: Int)] = [(0, 0, 0)]
        var head = 0
        while head < queue.count {
            let (s, t, depth) = queue[head]
            head += 1
            guard depth < maxDepth else { continue }
            var copied: [UInt32] = []
            for child in children(of: s) where !directoriesOnly || isDirectory(child) {
                let newChild = copyNode(child, parent: t)
                copied.append(newChild)
                if !linkTargets.isEmpty, linkTargets[child] != nil { linkTargets[child] = newChild }
                if isDirectory(child), childCount[Int(child)] > 0 { queue.append((child, newChild, depth + 1)) }
            }
            if !copied.isEmpty { copy.setChildren(of: t, copied) }
            if queue.count > 4096, head > queue.count / 2 {
                queue.removeFirst(head)
                head = 0
            }
        }
        for (id, record) in links {
            let counted = linkTargets[record.counted] ?? DiskTree.none
            let others = record.others.compactMap { linkTargets[$0] }.filter { $0 != DiskTree.none }
            if counted == DiskTree.none && others.isEmpty { continue }
            copy.links[id] = LinkRecord(counted: counted, others: others)
        }
        copy.rebuildLinkIndexes()
        if maxDepth == .max { copy.finishBuilding() }
        return copy
    }

    func reserveNodes(_ count: Int) {
        guard count > 0 else { return }
        nameID.reserveCapacity(count)
        parent.reserveCapacity(count)
        childStart.reserveCapacity(count)
        childCount.reserveCapacity(count)
        childList.reserveCapacity(count)
        allocated.reserveCapacity(count)
        apparent.reserveCapacity(count)
        files.reserveCapacity(count)
        dirs.reserveCapacity(count)
        mtime.reserveCapacity(count)
        flags.reserveCapacity(count)
        categories.reserveCapacity(count)
    }

    /// Approximate resident bytes of the arrays (for diagnostics).
    public var approximateBytes: Int {
        nameBytes.capacity + nameStart.capacity * 4 + nameLength.capacity * 2
            + nameID.capacity * 4 + parent.capacity * 4 + childStart.capacity * 4 + childCount.capacity * 4
            + childList.capacity * 4 + allocated.capacity * 8 + apparent.capacity * 8 + files.capacity * 4
            + dirs.capacity * 4 + mtime.capacity * 4 + flags.capacity + categories.capacity
    }

    // MARK: Helpers

    static func seconds(_ date: Date?) -> UInt32 {
        guard let date else { return 0 }
        return UInt32(clamping: Int64(max(1, date.timeIntervalSince1970)))
    }

    public static func lastComponent(of path: String) -> String {
        if path == "/" { return "/" }
        return path.split(separator: "/").last.map(String.init) ?? path
    }

    @inline(__always)
    static func add(_ value: UInt64, _ delta: Int64) -> UInt64 {
        delta >= 0 ? value &+ UInt64(delta) : (value >= delta.magnitude ? value - delta.magnitude : 0)
    }
}

extension DiskItemKind {
    var code: UInt8 {
        switch self {
        case .directory: 0
        case .file: 1
        case .symlink: 2
        }
    }
}

extension DiskCategory {
    private static let ordered = DiskCategory.allCases
    var code: UInt8 {
        switch self {
        case .reclaimable: 0
        case .agentScratch: 1
        case .toolchains: 2
        case .synced: 3
        case .git: 4
        case .media: 5
        case .documents: 6
        case .cache: 7
        case .code: 8
        }
    }
    static func fromCode(_ code: UInt8) -> DiskCategory {
        Int(code) < ordered.count ? ordered[Int(code)] : .documents
    }
}
