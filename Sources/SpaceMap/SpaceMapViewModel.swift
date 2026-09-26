import AppKit
import SpaceMapCore
import Foundation
import SwiftUI

@MainActor
final class SpaceMapViewModel: ObservableObject {
    @Published private(set) var rootNode: DiskNode?
    @Published private(set) var metrics = ScanMetrics(entriesScanned: 0, inaccessibleEntries: 0, errors: 0, deduplicatedHardlinks: 0, duration: 0, cancelled: false)
    @Published private(set) var isScanning = false
    @Published private(set) var fullDiskAccessRestricted = false
    @Published private(set) var selectedPath: String?
    @Published private(set) var focusedRootPath: String?
    @Published var mode: TreemapMode = .size
    @Published var includeHiddenFiles = true
    @Published var useApparentSize = false
    @Published var depth = 4
    @Published var filterText = ""
    @Published private(set) var markedPaths = Set<String>()
    @Published private(set) var cleanupCandidates: [CleanupCandidate] = []
    @Published private(set) var cleanupTotalBytes: UInt64 = 0
    @Published private(set) var categoryFootprint: [DiskCategory: UInt64] = [:]
    @Published private(set) var rootURL: URL
    @Published var statusMessage: String?

    private var cancellation: ScanCancellation?
    private var scanGeneration = UUID()
    private var scopedURL: URL?
    private var activationObserver: NSObjectProtocol?

    init() {
        if let configured = ProcessInfo.processInfo.environment["SPACEMAP_ROOT"], !configured.isEmpty {
            rootURL = URL(fileURLWithPath: configured).standardizedFileURL
        } else {
            rootURL = FileManager.default.homeDirectoryForCurrentUser
        }
        focusedRootPath = rootURL.path
        selectedPath = rootURL.path
        // Re-check Full Disk Access whenever the app comes back to the front,
        // e.g. after the user toggles it in System Settings: no restart needed.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshFullDiskAccess() }
        }
    }

    /// True when access was just granted after a scan that ran restricted,
    /// so the banner can offer a rescan of the previously skipped folders.
    @Published private(set) var fullDiskAccessNewlyGranted = false

    func refreshFullDiskAccess() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let restricted = FullDiskAccessProbe.isRestricted()
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.fullDiskAccessRestricted && !restricted { self.fullDiskAccessNewlyGranted = true }
                self.fullDiskAccessRestricted = restricted
            }
        }
    }

    var scanRoot: DiskNode? {
        guard let rootNode, let focusedRootPath else { return rootNode }
        return rootNode.descendant(at: focusedRootPath) ?? rootNode
    }

    var selectedNode: DiskNode? {
        guard let rootNode, let selectedPath else { return scanRoot ?? rootNode }
        return rootNode.descendant(at: selectedPath) ?? scanRoot ?? rootNode
    }

    var breadcrumbs: [DiskNode] {
        guard let rootNode, let focusedRootPath else { return [] }
        return rootNode.ancestors(of: focusedRootPath) ?? [rootNode]
    }

    var markedNodes: [DiskNode] {
        guard let rootNode else { return [] }
        return markedPaths.compactMap { rootNode.descendant(at: $0) }.sorted { $0.path < $1.path }
    }

    var rootName: String { rootURL.lastPathComponent.isEmpty ? "/" : rootURL.lastPathComponent }

    func startScan() {
        scan(at: rootURL)
    }

    func scanHome() {
        scan(at: FileManager.default.homeDirectoryForCurrentUser)
    }

    func scan(at url: URL) {
        cancellation?.cancel()
        if let scopedURL { scopedURL.stopAccessingSecurityScopedResource() }
        scopedURL = nil
        let standardized = url.standardizedFileURL
        if standardized.startAccessingSecurityScopedResource() { scopedURL = standardized }
        rootURL = standardized
        focusedRootPath = standardized.path
        selectedPath = standardized.path
        filterText = ""
        scanGeneration = UUID()
        let generation = scanGeneration
        let token = ScanCancellation()
        let hiddenFiles = includeHiddenFiles
        cancellation = token
        isScanning = true
        fullDiskAccessNewlyGranted = false
        cleanupCandidates = []
        cleanupTotalBytes = 0
        categoryFootprint = [:]
        metrics = ScanMetrics(entriesScanned: 0, inaccessibleEntries: 0, errors: 0, deduplicatedHardlinks: 0, duration: 0, cancelled: false)
        statusMessage = nil

        let placeholder = DiskNode(
            path: standardized.path,
            name: standardized.lastPathComponent.isEmpty ? "/" : standardized.lastPathComponent,
            kind: .directory,
            category: .documents,
            allocatedBytes: 0,
            apparentBytes: 0,
            fileCount: 0,
            directoryCount: 0
        )
        rootNode = placeholder

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let restricted = FullDiskAccessProbe.isRestricted()
            Task { @MainActor [weak self] in
                guard let self, self.scanGeneration == generation else { return }
                self.fullDiskAccessRestricted = restricted
            }
            do {
                // Same engine as the CLI benchmark: ScanEngine.scan is the only
                // scan entry point for both (see testAppAndBenchShareSameEngine).
                let result = try ScanEngine.scan(rootURL: standardized, includeHidden: hiddenFiles, cancellation: token) { update in
                    Task { @MainActor [weak self] in
                        guard let self, self.scanGeneration == generation else { return }
                        self.rootNode = update.root
                        self.metrics = update.metrics
                    }
                }
                let cleanup = CleanupCandidates.collect(root: result.root, rootPath: standardized.path)
                let footprint = SpaceMapViewModel.footprint(of: result.root)
                Task { @MainActor [weak self] in
                    guard let self, self.scanGeneration == generation else { return }
                    self.rootNode = result.root
                    self.metrics = result.metrics
                    self.cleanupCandidates = cleanup.items
                    self.cleanupTotalBytes = cleanup.totalBytes
                    self.categoryFootprint = footprint
                    self.isScanning = false
                    self.selectedPath = self.initialSelection(in: result.root) ?? result.root.path
                }
            } catch {
                Task { @MainActor [weak self] in
                    guard let self, self.scanGeneration == generation else { return }
                    self.isScanning = false
                    self.statusMessage = error.localizedDescription
                }
            }
        }
    }

    private func initialSelection(in root: DiskNode) -> String? {
        guard let target = ProcessInfo.processInfo.environment["SPACEMAP_SELECT"], !target.isEmpty else { return nil }
        func search(_ node: DiskNode) -> String? {
            if node.name.localizedCaseInsensitiveContains(target) { return node.path }
            for child in node.children {
                if let found = search(child) { return found }
            }
            return nil
        }
        return search(root)
    }

    func cancelScan() {
        cancellation?.cancel()
        isScanning = false
    }

    func select(_ path: String) {
        selectedPath = path
    }

    func select(_ node: DiskNode) {
        select(node.path)
    }

    func zoomTo(_ node: DiskNode) {
        guard node.isDirectory else { return }
        focusedRootPath = node.path
        selectedPath = node.path
    }

    func focus(at path: String) {
        guard let node = rootNode?.descendant(at: path) else { return }
        zoomTo(node)
    }

    func openSelected() {
        guard let selectedNode else { return }
        if selectedNode.isDirectory { zoomTo(selectedNode) }
        else { revealInFinder(selectedNode) }
    }

    func goUp() {
        guard let currentPath = focusedRootPath, currentPath != rootURL.path else { return }
        let parentPath = URL(fileURLWithPath: currentPath).deletingLastPathComponent().path
        focusedRootPath = parentPath
        selectedPath = parentPath
    }

    func resetToRoot() {
        focusedRootPath = rootURL.path
        selectedPath = rootURL.path
    }

    func moveSelection(_ delta: Int) {
        guard let selectedNode, let rootNode else { return }
        let parentPath = URL(fileURLWithPath: selectedNode.path).deletingLastPathComponent().path
        let siblings = (rootNode.descendant(at: parentPath)?.children ?? scanRoot?.children ?? [])
            .sorted { lhs, rhs in
                let left = lhs.bytes(apparent: useApparentSize)
                let right = rhs.bytes(apparent: useApparentSize)
                return left == right ? lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending : left > right
            }
        guard !siblings.isEmpty else { return }
        let index = siblings.firstIndex(where: { $0.path == selectedNode.path }) ?? 0
        let next = (index + delta % siblings.count + siblings.count) % siblings.count
        selectedPath = siblings[next].path
    }

    func toggleMarked() {
        guard let selectedPath else { return }
        if markedPaths.contains(selectedPath) { markedPaths.remove(selectedPath) }
        else { markedPaths.insert(selectedPath) }
    }

    func isMarked(_ node: DiskNode) -> Bool { markedPaths.contains(node.path) }

    func revealInFinder(_ node: DiskNode? = nil) {
        guard let node = node ?? selectedNode else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: node.path)])
    }

    func moveToTrash(_ node: DiskNode? = nil) throws {
        guard let node = node ?? selectedNode else { return }
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: URL(fileURLWithPath: node.path), resultingItemURL: &resultingURL)
        markedPaths.remove(node.path)
        scan(at: rootURL)
    }

    /// Leaf file bytes per category for the legend. Directories aggregate
    /// their children, so only leaves are counted (each byte exactly once).
    nonisolated static func footprint(of root: DiskNode) -> [DiskCategory: UInt64] {
        var totals: [DiskCategory: UInt64] = [:]
        var stack = [root]
        while let node = stack.popLast() {
            if node.isDirectory { stack.append(contentsOf: node.children) }
            else { totals[node.category, default: 0] &+= node.allocatedBytes }
        }
        return totals
    }

    func volumeDetails() -> (name: String, free: UInt64?, total: UInt64?) {
        let values = try? rootURL.resourceValues(forKeys: [.volumeNameKey, .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        let free = values?.volumeAvailableCapacityForImportantUsage.map { UInt64(max(0, $0)) }
        let total = values?.volumeTotalCapacity.map { UInt64(max(0, $0)) }
        return (values?.volumeName ?? rootURL.path, free, total)
    }
}
