import Foundation

public enum DiskCategory: String, CaseIterable, Sendable {
    case reclaimable
    case agentScratch
    case toolchains
    case synced
    case git
    case media
    case documents
    case cache
    case code

    public var title: String {
        switch self {
        case .reclaimable: "Reclaimable"
        case .agentScratch: "Agent scratch"
        case .toolchains: "Toolchains"
        case .synced: "Synced"
        case .git: "Git"
        case .media: "Media"
        case .documents: "Documents"
        case .cache: "Cache"
        case .code: "Code"
        }
    }

    public var colorHex: UInt32 {
        switch self {
        case .reclaimable: 0xB6844F
        case .agentScratch: 0xB8794E
        case .toolchains: 0x47A77D
        case .synced: 0x4D9EAA
        case .git: 0xA95169
        case .media: 0x8758B3
        case .documents: 0x747B88
        case .cache: 0xB49B50
        case .code: 0x5575A9
        }
    }
}

public enum DiskItemKind: String, Sendable {
    case directory
    case file
    case symlink
}

public enum TreemapMode: String, CaseIterable, Sendable {
    case size
    case files
    case age

    public var title: String { rawValue.capitalized }
}

/// Lightweight handle into a `DiskTree` arena. It owns nothing per node;
/// every property reads the tree's parallel arrays, and `path` is rebuilt
/// from parent links only when asked for.
public struct DiskNode: Identifiable, Sendable, Equatable {
    public let tree: DiskTree
    public let index: UInt32

    public init(tree: DiskTree, index: UInt32) {
        self.tree = tree
        self.index = index
    }

    /// Standalone node (tests, placeholders). Children are copied into a
    /// fresh tree, keeping their stored totals.
    public init(
        path: String,
        name: String,
        kind: DiskItemKind,
        category: DiskCategory,
        colorCategory: DiskCategory? = nil,
        allocatedBytes: UInt64,
        apparentBytes: UInt64,
        fileCount: Int,
        directoryCount: Int,
        modifiedAt: Date? = nil,
        children: [DiskNode] = []
    ) {
        let tree = DiskTree(rootPath: path)
        tree.appendNode(DiskTree.NodeValues(
            name: name,
            kind: kind,
            category: category,
            color: colorCategory ?? (category == .reclaimable ? .code : category),
            allocated: allocatedBytes,
            apparent: apparentBytes,
            files: UInt32(clamping: fileCount),
            dirs: UInt32(clamping: directoryCount),
            modifiedAt: modifiedAt
        ), parent: DiskTree.none)
        if !children.isEmpty {
            let copied = children.map { tree.copySubtree(from: $0.tree, at: $0.index) }
            tree.setChildren(of: 0, copied)
        }
        self.init(tree: tree, index: 0)
    }

    public static func == (lhs: DiskNode, rhs: DiskNode) -> Bool {
        lhs.tree === rhs.tree && lhs.index == rhs.index
    }

    public var path: String { tree.path(of: index) }
    public var id: String { path }
    public var name: String { index == 0 ? DiskTree.lastComponent(of: tree.rootPath) : tree.name(of: index) }
    public var kind: DiskItemKind { tree.kind(of: index) }
    public var isDirectory: Bool { tree.isDirectory(index) }
    public var category: DiskCategory { tree.category(of: index) }
    /// Reclaimable nodes use their container's hue and a hatch overlay.
    public var colorCategory: DiskCategory { tree.colorCategory(of: index) }
    public var allocatedBytes: UInt64 { tree.allocated[Int(index)] }
    public var apparentBytes: UInt64 { tree.apparent[Int(index)] }
    public var fileCount: Int { Int(tree.files[Int(index)]) }
    public var directoryCount: Int { Int(tree.dirs[Int(index)]) }
    public var modifiedAt: Date? { tree.modified(of: index) }
    public var childCount: Int { Int(tree.childCount[Int(index)]) }
    public var children: [DiskNode] { tree.children(of: index).map { DiskNode(tree: tree, index: $0) } }
    public var parentNode: DiskNode? {
        let p = tree.parent[Int(index)]
        return p == DiskTree.none ? nil : DiskNode(tree: tree, index: p)
    }

    public func bytes(apparent: Bool) -> UInt64 {
        apparent ? apparentBytes : allocatedBytes
    }

    /// Follows path components instead of searching the full subtree, which keeps selection and hover lookup
    /// responsive even when the scan contains millions of nodes.
    public func descendant(at targetPath: String) -> DiskNode? {
        ancestors(of: targetPath)?.last
    }

    public func ancestors(of targetPath: String) -> [DiskNode]? {
        let base = path
        if base == targetPath { return [self] }
        let prefix = base == "/" ? "/" : base + "/"
        guard targetPath.hasPrefix(prefix) else { return nil }
        var chain = [self]
        var cursor = index
        for component in targetPath.dropFirst(prefix.count).split(separator: "/") {
            guard let next = tree.child(of: cursor, named: component) else { return nil }
            cursor = next
            chain.append(DiskNode(tree: tree, index: cursor))
        }
        return chain
    }
}

public struct ScanMetrics: Sendable {
    public let entriesScanned: Int
    public let inaccessibleEntries: Int
    public let errors: Int
    public let deduplicatedHardlinks: Int
    public let duration: TimeInterval
    public let cancelled: Bool
    public let currentPath: String?

    public init(
        entriesScanned: Int,
        inaccessibleEntries: Int,
        errors: Int,
        deduplicatedHardlinks: Int,
        duration: TimeInterval,
        cancelled: Bool,
        currentPath: String? = nil
    ) {
        self.entriesScanned = entriesScanned
        self.inaccessibleEntries = inaccessibleEntries
        self.errors = errors
        self.deduplicatedHardlinks = deduplicatedHardlinks
        self.duration = duration
        self.cancelled = cancelled
        self.currentPath = currentPath
    }
}

public struct DiskScanProgress: Sendable {
    public let root: DiskNode
    public let metrics: ScanMetrics

    public init(root: DiskNode, metrics: ScanMetrics) {
        self.root = root
        self.metrics = metrics
    }
}

public struct DiskScanResult: Sendable {
    public let root: DiskNode
    public let metrics: ScanMetrics

    public init(root: DiskNode, metrics: ScanMetrics) {
        self.root = root
        self.metrics = metrics
    }
}

public struct CleanupCandidate: Identifiable, Sendable {
    public enum Kind: Sendable, Equatable {
        case buildOutput
        case cache
        case agentWorkspace
        case largeRepository
        case oldMedia
        /// Stale non-media leftovers; the date renders a localized age.
        case oldOther(Date?)
    }

    public let node: DiskNode
    public let kind: Kind
    public let subtitle: String
    public let bytes: UInt64

    public init(node: DiskNode, kind: Kind, subtitle: String, bytes: UInt64) {
        self.node = node
        self.kind = kind
        self.subtitle = subtitle
        self.bytes = bytes
    }

    public var id: UInt32 { node.index }
}

public extension DiskTree {
    /// Leaf bytes per category for the legend (each byte counted once).
    func footprint(from start: UInt32 = 0) -> [DiskCategory: UInt64] {
        var totals = [UInt64](repeating: 0, count: DiskCategory.allCases.count)
        var stack = [start]
        while let index = stack.popLast() {
            if isDirectory(index) { stack.append(contentsOf: children(of: index)) }
            else { totals[Int(categories[Int(index)] & 0xF)] &+= allocated[Int(index)] }
        }
        var result: [DiskCategory: UInt64] = [:]
        for (code, bytes) in totals.enumerated() where bytes > 0 { result[DiskCategory.fromCode(UInt8(code))] = bytes }
        return result
    }
}

/// Shared cleanup-candidate mining used by the app inspector. Regenerable
/// items (build outputs, caches, agent workspaces, large repositories) come
/// first; stale leftovers follow, with old media explicitly marked "old".
/// Anything untouched for more than 90 days counts as stale.
public enum CleanupCandidates {
    public static let staleDays = 90
    public static let largeRepositoryBytes: UInt64 = 1 << 30
    public static let visibleLimit = 6

    public static func collect(root: DiskNode, rootPath: String = "", now: Date = Date()) -> (items: [CleanupCandidate], totalBytes: UInt64) {
        let cutoff = now.addingTimeInterval(-Double(staleDays) * 24 * 60 * 60)
        var regenerable: [CleanupCandidate] = []
        var leftovers: [CleanupCandidate] = []
        var totalBytes: UInt64 = 0
        func insert(_ candidate: CleanupCandidate, into list: inout [CleanupCandidate]) {
            if list.count < visibleLimit {
                list.append(candidate)
            } else if let smallestIndex = list.indices.min(by: { list[$0].bytes < list[$1].bytes }),
                      candidate.bytes > list[smallestIndex].bytes {
                list[smallestIndex] = candidate
            }
        }
        let tree = root.tree
        let cutoffSeconds = DiskTree.seconds(cutoff)
        // Iterative walk over the arena: no handle or child array per node.
        var stack: [(UInt32, Bool)] = [(root.index, false)]
        while let (index, ancestorIsCandidate) = stack.popLast() {
            let i = Int(index)
            let category = tree.category(of: index)
            let bytes = tree.allocated[i]
            let seconds = tree.mtime[i]
            let stale = seconds != 0 && seconds < cutoffSeconds
            let largeRepo = category == .git && bytes >= largeRepositoryBytes
            let isRegenerable = category == .reclaimable || category == .agentScratch || category == .cache || largeRepo
            let qualifies = isRegenerable || stale
            if index != root.index, qualifies, !ancestorIsCandidate, bytes > 0 {
                let node = DiskNode(tree: tree, index: index)
                let kind: CleanupCandidate.Kind
                let subtitle: String
                if category == .reclaimable { kind = .buildOutput; subtitle = "build output · safe to review" }
                else if category == .cache { kind = .cache; subtitle = "regenerable cache" }
                else if category == .agentScratch { kind = .agentWorkspace; subtitle = "agent workspace" }
                else if largeRepo { kind = .largeRepository; subtitle = "large repository" }
                else if category == .media { kind = .oldMedia; subtitle = "old media" }
                else { kind = .oldOther(node.modifiedAt); subtitle = "old · last write \(ByteFormatter.relativeAge(from: node.modifiedAt, now: now))" }
                let candidate = CleanupCandidate(node: node, kind: kind, subtitle: subtitle, bytes: bytes)
                totalBytes &+= bytes
                if isRegenerable { insert(candidate, into: &regenerable) }
                else { insert(candidate, into: &leftovers) }
            }
            // Nothing below a candidate can become one, so skip its subtree.
            guard !(ancestorIsCandidate || qualifies) else { continue }
            for child in tree.children(of: index) { stack.append((child, false)) }
        }
        let items = (regenerable.sorted { $0.bytes > $1.bytes } + leftovers.sorted { $0.bytes > $1.bytes })
            .prefix(visibleLimit).map { $0 }
        return (items, totalBytes)
    }
}
