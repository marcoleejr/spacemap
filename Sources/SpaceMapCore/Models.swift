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

public struct DiskNode: Identifiable, Sendable {
    public let path: String
    public let name: String
    public let kind: DiskItemKind
    public let category: DiskCategory
    /// Reclaimable nodes use their container's hue and a hatch overlay.
    public let colorCategory: DiskCategory
    public let allocatedBytes: UInt64
    public let apparentBytes: UInt64
    public let fileCount: Int
    public let directoryCount: Int
    public let modifiedAt: Date?
    public let children: [DiskNode]

    public var id: String { path }
    public var isDirectory: Bool { kind == .directory }

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
        self.path = path
        self.name = name
        self.kind = kind
        self.category = category
        self.colorCategory = colorCategory ?? (category == .reclaimable ? .code : category)
        self.allocatedBytes = allocatedBytes
        self.apparentBytes = apparentBytes
        self.fileCount = fileCount
        self.directoryCount = directoryCount
        self.modifiedAt = modifiedAt
        self.children = children
    }

    public func bytes(apparent: Bool) -> UInt64 {
        apparent ? apparentBytes : allocatedBytes
    }

    /// Follows path components instead of searching the full subtree, which keeps selection and hover lookup
    /// responsive even when the scan contains millions of nodes.
    public func descendant(at targetPath: String) -> DiskNode? {
        if path == targetPath { return self }
        guard let component = nextPathComponent(toward: targetPath) else { return nil }
        let name = String(component)
        guard let child = children.first(where: { $0.name == name }) else { return nil }
        return child.descendant(at: targetPath)
    }

    public func ancestors(of targetPath: String) -> [DiskNode]? {
        if path == targetPath { return [self] }
        guard let component = nextPathComponent(toward: targetPath) else { return nil }
        let name = String(component)
        guard let child = children.first(where: { $0.name == name }),
              let chain = child.ancestors(of: targetPath) else { return nil }
        return [self] + chain
    }

    private func nextPathComponent(toward targetPath: String) -> Substring? {
        let prefix = path == "/" ? "/" : path + "/"
        guard targetPath.hasPrefix(prefix) else { return nil }
        let remainder = targetPath.dropFirst(prefix.count)
        guard let component = remainder.split(separator: "/", maxSplits: 1).first, !component.isEmpty else { return nil }
        return component
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

    public var id: String { node.path }
}

/// Shared cleanup-candidate mining used by the app inspector. Regenerable
/// items (build outputs, caches, agent workspaces, large repositories) come
/// first; stale leftovers follow, with old media explicitly marked "old".
/// Anything untouched for more than 90 days counts as stale.
public enum CleanupCandidates {
    public static let staleDays = 90
    public static let largeRepositoryBytes: UInt64 = 1 << 30
    public static let visibleLimit = 6

    public static func collect(root: DiskNode, rootPath: String, now: Date = Date()) -> (items: [CleanupCandidate], totalBytes: UInt64) {
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
        func visit(_ node: DiskNode, ancestorIsCandidate: Bool) {
            let stale = node.modifiedAt.map { $0 < cutoff } ?? false
            let largeRepo = node.category == .git && node.allocatedBytes >= largeRepositoryBytes
            let isRegenerable = node.category == .reclaimable
                || node.category == .agentScratch
                || node.category == .cache
                || largeRepo
            let qualifies = isRegenerable || stale
            if node.path != rootPath, qualifies, !ancestorIsCandidate, node.allocatedBytes > 0 {
                let kind: CleanupCandidate.Kind
                let subtitle: String
                if node.category == .reclaimable { kind = .buildOutput; subtitle = "build output · safe to review" }
                else if node.category == .cache { kind = .cache; subtitle = "regenerable cache" }
                else if node.category == .agentScratch { kind = .agentWorkspace; subtitle = "agent workspace" }
                else if largeRepo { kind = .largeRepository; subtitle = "large repository" }
                else if node.category == .media { kind = .oldMedia; subtitle = "old media" }
                else { kind = .oldOther(node.modifiedAt); subtitle = "old · last write \(ByteFormatter.relativeAge(from: node.modifiedAt, now: now))" }
                let candidate = CleanupCandidate(node: node, kind: kind, subtitle: subtitle, bytes: node.allocatedBytes)
                totalBytes &+= node.allocatedBytes
                if isRegenerable { insert(candidate, into: &regenerable) }
                else { insert(candidate, into: &leftovers) }
            }
            for child in node.children { visit(child, ancestorIsCandidate: ancestorIsCandidate || qualifies) }
        }
        visit(root, ancestorIsCandidate: false)
        let items = (regenerable.sorted { $0.bytes > $1.bytes } + leftovers.sorted { $0.bytes > $1.bytes })
            .prefix(visibleLimit).map { $0 }
        return (items, totalBytes)
    }
}
