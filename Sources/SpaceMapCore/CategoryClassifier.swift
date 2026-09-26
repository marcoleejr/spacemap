import Foundation

public enum CategoryClassifier {
    private static let reclaimableNames: Set<String> = [
        "node_modules", "target", ".build", "deriveddata", "build", "dist",
        "__pycache__", ".gradle", ".pytest_cache", ".mypy_cache", ".next",
        ".nuxt", "pods"
    ]
    private static let agentNames: Set<String> = [".codex", ".claude", "worktrees"]
    private static let toolchainNames: Set<String> = [
        ".rustup", ".cargo", ".npm", ".pnpm-store", "xcode.app",
        "coresimulator", ".platformio", "sdks", "mise"
    ]
    private static let syncedNames: Set<String> = [
        "mobile documents", "icloud drive", "cloudstorage", "dropbox",
        "google drive", "sync", "onedrive", "creative cloud files"
    ]
    private static let mediaNames: Set<String> = [
        "movies", "music", "pictures", "photos library.photoslibrary", "steam"
    ]
    private static let documentNames: Set<String> = ["documents", "desktop", "downloads"]
    private static let documentExtensions: Set<String> = [
        "pdf", "doc", "docx", "pages", "numbers", "key", "rtf", "txt", "md", "csv"
    ]
    private static let mediaExtensions: Set<String> = [
        "mov", "mp4", "m4v", "avi", "mkv", "mp3", "wav", "flac", "aiff", "heic"
    ]
    private static let sourceExtensions: Set<String> = [
        "swift", "m", "mm", "h", "c", "cc", "cpp", "rs", "go", "py", "js",
        "jsx", "ts", "tsx", "java", "kt", "rb", "php", "sql", "sh"
    ]
    private static let codeNames: Set<String> = ["src", "code", "projects", "repos", "repositories"]

    /// Bitmask for incremental classification. Flags are ORs over every ancestor
    /// component, so a child combines its parent context with its own name in O(1).
    /// This is the hot path for the parallel scan: no path splitting, no per-component
    /// lowercasing, and early returns avoid extension work for heavy subtrees.
    struct Flags: OptionSet, Sendable {
        let rawValue: UInt32
        static let git = Flags(rawValue: 1 << 0)
        static let agent = Flags(rawValue: 1 << 1)
        static let reclaimable = Flags(rawValue: 1 << 2)
        static let toolchain = Flags(rawValue: 1 << 3)
        static let synced = Flags(rawValue: 1 << 4)
        static let media = Flags(rawValue: 1 << 5)
        static let documents = Flags(rawValue: 1 << 6)
        static let code = Flags(rawValue: 1 << 7)
        static let library = Flags(rawValue: 1 << 8)
        static let caches = Flags(rawValue: 1 << 9)
        static let cacheDot = Flags(rawValue: 1 << 10)
        static let agentWorkspace = Flags(rawValue: 1 << 11)
        static let mise = Flags(rawValue: 1 << 12)
        // Set when a `Developer` directory sits directly under `Library`:
        // only Library/Developer (and its contents) is Toolchains.
        static let libraryDeveloper = Flags(rawValue: 1 << 13)
    }

    /// Lowercase fast path: most filenames are already lowercase, so a UTF-8 scan
    /// avoids allocating a new String for them.
    static func lowerName(_ name: String) -> String {
        var hasUppercase = false
        for byte in name.utf8 {
            if byte >= 65, byte <= 90 { hasUppercase = true; break }
        }
        return hasUppercase ? name.lowercased() : name
    }

    static func singleFlags(_ lower: String) -> Flags {
        var flags = Flags()
        if lower == ".git" { flags.insert(.git) }
        if agentNames.contains(lower) { flags.insert(.agent) }
        if reclaimableNames.contains(lower) { flags.insert(.reclaimable) }
        if toolchainNames.contains(lower) { flags.insert(.toolchain) }
        if syncedNames.contains(lower) { flags.insert(.synced) }
        if mediaNames.contains(lower) { flags.insert(.media) }
        if documentNames.contains(lower) { flags.insert(.documents) }
        if codeNames.contains(lower) { flags.insert(.code) }
        if lower == "library" { flags.insert(.library) }
        if lower == "caches" { flags.insert(.caches) }
        if lower == ".cache" { flags.insert(.cacheDot) }
        return flags
    }

    static func extensionOf(_ lower: String) -> String {
        guard let dot = lower.lastIndex(of: "."), dot != lower.startIndex else { return "" }
        let after = lower.index(after: dot)
        if lower[after...].contains("/") { return "" }
        return String(lower[after...])
    }

    /// Core decision order, shared by the full-path and incremental entry points.
    /// `combined` already includes the entry's own name flags.
    static func decide(
        combined: Flags,
        name: String,
        ext: () -> String,
        parentCategory: DiskCategory?,
        hasGitDirectory: Bool
    ) -> DiskCategory {
        if combined.contains(.git) { return .git }
        if combined.contains(.agent) || combined.contains(.agentWorkspace) { return .agentScratch }
        if combined.contains(.reclaimable) { return .reclaimable }
        if combined.contains(.toolchain) || combined.contains(.mise) || combined.contains(.libraryDeveloper) { return .toolchains }
        if combined.contains(.synced) { return .synced }
        let e = ext()
        if combined.contains(.media) || mediaExtensions.contains(e) { return .media }
        if combined.contains(.library) && combined.contains(.caches)
            || combined.contains(.cacheDot) || name == "caches" { return .cache }
        if combined.contains(.documents) || documentExtensions.contains(e) { return .documents }
        if hasGitDirectory { return .code }
        if combined.contains(.code) || sourceExtensions.contains(e) { return .code }
        return parentCategory ?? .documents
    }

    /// Route/name heuristics are intentionally deterministic so users can understand why a tile was classified.
    /// This hot path scans components once and avoids allocating a normalized path array or URL per entry.
    public static func classify(path: String, parentCategory: DiskCategory? = nil, hasGitDirectory: Bool = false) -> DiskCategory {
        var hasGit = false
        var hasAgent = false
        var hasReclaimable = false
        var hasToolchain = false
        var hasSynced = false
        var hasMedia = false
        var hasDocuments = false
        var hasCode = false
        var hasLibrary = false
        var hasCaches = false
        var hasCache = false
        var hasAgentWorkspacePath = false
        var hasMisePath = false
        var hasLibraryDeveloperPath = false
        var previous: String?
        var previousPrevious: String?
        var lastComponent = ""

        for component in path.split(separator: "/") {
            let value = component.lowercased()
            lastComponent = value
            hasGit = hasGit || value == ".git"
            hasAgent = hasAgent || agentNames.contains(value)
            hasReclaimable = hasReclaimable || reclaimableNames.contains(value)
            hasToolchain = hasToolchain || toolchainNames.contains(value)
            hasSynced = hasSynced || syncedNames.contains(value)
            hasMedia = hasMedia || mediaNames.contains(value)
            hasDocuments = hasDocuments || documentNames.contains(value)
            hasCode = hasCode || codeNames.contains(value)
            hasLibrary = hasLibrary || value == "library"
            hasCaches = hasCaches || value == "caches"
            hasCache = hasCache || value == ".cache"
            hasAgentWorkspacePath = hasAgentWorkspacePath || (previous == "orca" && value == "workspaces")
            hasMisePath = hasMisePath || (previousPrevious == "local" && previous == "share" && value == "mise")
            hasLibraryDeveloperPath = hasLibraryDeveloperPath || (previous == "library" && value == "developer")
            previousPrevious = previous
            previous = value
        }

        let name = lastComponent
        let extensionStart = name.lastIndex(of: ".")
        let ext = extensionStart.map { String(name[name.index(after: $0)...]) } ?? ""

        if hasGit { return .git }
        if hasAgent || hasAgentWorkspacePath { return .agentScratch }
        if hasReclaimable { return .reclaimable }
        if hasToolchain || hasMisePath || hasLibraryDeveloperPath { return .toolchains }
        if hasSynced { return .synced }
        if hasMedia || mediaExtensions.contains(ext) { return .media }
        if hasLibrary && hasCaches || hasCache || name == "caches" { return .cache }
        if hasDocuments || documentExtensions.contains(ext) { return .documents }
        if hasGitDirectory { return .code }
        if hasCode || sourceExtensions.contains(ext) { return .code }
        return parentCategory ?? .documents
    }
}

/// Incremental classification context carried down the directory tree.
/// `flags` is the OR of every ancestor component marker; `prev1`/`prev2` are the
/// lowercased names of the last two path components (for `orca/workspaces` and
/// `local/share/mise` patterns). A child combines this with its own name in O(1).
public struct ScanCategoryContext: Sendable {
    var flags: UInt32
    var prev1: String
    var prev2: String

    public init(flags: UInt32 = 0, prev1: String = "", prev2: String = "") {
        self.flags = flags
        self.prev1 = prev1
        self.prev2 = prev2
    }
}

public enum IncrementalClassifier {
    private static let gitBit: UInt32 = 1 << 0
    private static let agentBit: UInt32 = 1 << 1
    private static let reclaimableBit: UInt32 = 1 << 2
    private static let toolchainBit: UInt32 = 1 << 3
    private static let syncedBit: UInt32 = 1 << 4
    private static let mediaBit: UInt32 = 1 << 5
    private static let documentsBit: UInt32 = 1 << 6
    private static let codeBit: UInt32 = 1 << 7
    private static let libraryBit: UInt32 = 1 << 8
    private static let cachesBit: UInt32 = 1 << 9
    private static let cacheDotBit: UInt32 = 1 << 10
    private static let agentWorkspaceBit: UInt32 = 1 << 11
    private static let miseBit: UInt32 = 1 << 12
    private static let libraryDeveloperBit: UInt32 = 1 << 13

    /// Build the context for a scan root by walking its (short) path once.
    public static func rootContext(forPath path: String) -> ScanCategoryContext {
        var flags: UInt32 = 0
        var prev1 = ""
        var prev2 = ""
        for component in path.split(separator: "/") {
            let value = CategoryClassifier.lowerName(String(component))
            flags |= CategoryClassifier.singleFlags(value).rawValue
            if prev1 == "orca", value == "workspaces" { flags |= agentWorkspaceBit }
            if prev2 == "local", prev1 == "share", value == "mise" { flags |= miseBit }
            if prev1 == "library", value == "developer" { flags |= libraryDeveloperBit }
            prev2 = prev1
            prev1 = value
        }
        return ScanCategoryContext(flags: flags, prev1: prev1, prev2: prev2)
    }

    /// Classify one entry in O(1) from its parent context plus its own name.
    /// Returns the category and the child context to use when the entry is a
    /// directory (for files the child context is still valid but unused).
    public static func classifyEntry(
        name: String,
        parent context: ScanCategoryContext,
        parentCategory: DiskCategory?,
        hasGitDirectory: Bool = false
    ) -> (category: DiskCategory, childContext: ScanCategoryContext) {
        let lower = CategoryClassifier.lowerName(name)
        var combined = context.flags | CategoryClassifier.singleFlags(lower).rawValue
        if context.prev1 == "orca", lower == "workspaces" { combined |= agentWorkspaceBit }
        if context.prev2 == "local", context.prev1 == "share", lower == "mise" { combined |= miseBit }
        if context.prev1 == "library", lower == "developer" { combined |= libraryDeveloperBit }
        let category = CategoryClassifier.decide(
            combined: CategoryClassifier.Flags(rawValue: combined),
            name: lower,
            ext: { CategoryClassifier.extensionOf(lower) },
            parentCategory: parentCategory,
            hasGitDirectory: hasGitDirectory
        )
        return (category, ScanCategoryContext(flags: combined, prev1: lower, prev2: context.prev1))
    }
}
