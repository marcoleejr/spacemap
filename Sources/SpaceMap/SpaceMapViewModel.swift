import AppKit
import SpaceMapCore
import Foundation
import OSLog
import SwiftUI

private let log = Logger(subsystem: "com.marcoleejr.spacemap", category: "incremental")

private func trace(_ message: String) {
    log.notice("\(message, privacy: .public)")
    if ProcessInfo.processInfo.environment["SPACEMAP_TRACE"] != nil { FileHandle.standardError.write(Data((message + "\n").utf8)) }
}

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

    /// Bumped whenever the tree changes in place (trash, FSEvents), so views
    /// that cache layouts know to rebuild them.
    @Published private(set) var treeVersion = 0
    /// Entries of the previous scan of this root, for a real progress fraction.
    @Published private(set) var expectedEntries: Int?
    @Published private(set) var volumeName = ""
    @Published private(set) var volumeFree: UInt64?
    @Published private(set) var volumeTotal: UInt64?

    private var cancellation: ScanCancellation?
    private var watcher: FileSystemWatcher?
    /// Highest FSEvents id whose changes are already in the tree.
    private var appliedEventId: UInt64 = 0
    private var cacheDirty = false
    private var cacheSaveWork: DispatchWorkItem?
    private var derivedWork: DispatchWorkItem?
    /// Serial utility queue for directory rereads, compaction and cache writes.
    private let updateQueue = DispatchQueue(label: "SpaceMap.incremental", qos: .utility)
    private var terminationObserver: NSObjectProtocol?
    /// Background churn (logs, browser caches) is folded into the tree right
    /// away but shown only once it adds up, so a busy home folder does not
    /// keep the map redrawing while the app sits idle.
    private var pendingBackgroundBytes: UInt64 = 0
    private var pendingBackgroundFlush: DispatchWorkItem?
    private var lastDerivedAt: Date = .distantPast
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
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveCacheNow() }
        }
        refreshVolume()
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

    /// First appearance: reopen the previous map from the on-disk cache and
    /// catch up through FSEvents history; scan from scratch only when the
    /// cache is missing, for another root, or its event history is unusable.
    func launch() {
        let root = rootURL.standardizedFileURL
        let hidden = includeHiddenFiles
        guard let header = ScanCache.readHeader(), header.rootPath == root.path, header.includeHidden == hidden,
              header.volumeUUID != nil, header.volumeUUID == FileSystemWatcher.volumeUUID(forPath: root.path) else {
            trace("launch: no usable cache, full scan")
            scan(at: root)
            return
        }
        isScanning = true
        expectedEntries = header.entries
        let generation = UUID()
        scanGeneration = generation
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let loaded = try? ScanCache.load()
            Task { @MainActor [weak self] in
                guard let self, self.scanGeneration == generation else { return }
                guard let loaded, loaded.header.rootPath == root.path else {
                    self.scan(at: root)
                    return
                }
                self.install(tree: loaded.tree, metrics: ScanMetrics(
                    entriesScanned: loaded.header.entries, inaccessibleEntries: 0, errors: 0,
                    deduplicatedHardlinks: 0, duration: loaded.header.scanDuration, cancelled: false
                ))
                self.isScanning = false
                if let initial = self.initialSelection(in: loaded.tree.root) { self.selectedPath = initial }
                trace("launch: opened cached map (\(loaded.header.entries) entries), replaying FSEvents since \(loaded.header.eventId)")
                self.appliedEventId = loaded.header.eventId
                // Replays every change since the cached scan, then keeps watching.
                self.startWatching(since: loaded.header.eventId)
            }
        }
    }

    func scanHome() {
        scan(at: FileManager.default.homeDirectoryForCurrentUser)
    }

    func scan(at url: URL) {
        cancellation?.cancel()
        verification?.cancel()
        verification = nil
        stopWatching()
        pendingPaths = [:]
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
        if let header = ScanCache.readHeader(), header.rootPath == standardized.path { expectedEntries = header.entries }
        else { expectedEntries = nil }
        // Events during the scan are replayed from here once it finishes.
        let eventIdAtStart = FileSystemWatcher.currentEventId

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

        DispatchQueue.global(qos: .utility).async { [weak self] in
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
                Task { @MainActor [weak self] in
                    guard let self, self.scanGeneration == generation else { return }
                    self.install(tree: result.root.tree, metrics: result.metrics)
                    self.isScanning = false
                    self.selectedPath = self.initialSelection(in: result.root) ?? result.root.path
                    guard !result.metrics.cancelled else { return }
                    self.appliedEventId = eventIdAtStart
                    self.startWatching(since: eventIdAtStart)
                    self.cacheDirty = true
                    self.scheduleCacheSave(after: 2)
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

    // MARK: - Incremental updates

    private var verification: ScanCancellation?

    /// FSEvents lost track (dropped events): rescan quietly with a few
    /// threads while the current map stays usable, then swap it in.
    private func verifyInBackground() {
        guard verification == nil, !isScanning else { return }
        stopWatching()
        pendingPaths = [:]
        let token = ScanCancellation()
        verification = token
        let root = rootURL
        let hidden = includeHiddenFiles
        let generation = scanGeneration
        let eventIdAtStart = FileSystemWatcher.currentEventId
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = try? ScanEngine.scan(rootURL: root, includeHidden: hidden, cancellation: token, workers: 3)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.verification = nil
                guard let result, !result.metrics.cancelled, self.scanGeneration == generation else { return }
                trace("background verification done: \(result.metrics.entriesScanned) entries in \(Int(result.metrics.duration)) s")
                self.install(tree: result.root.tree, metrics: result.metrics)
                if let selectedPath = self.selectedPath, result.root.tree.index(forPath: selectedPath) == nil { self.selectedPath = root.path }
                if let focus = self.focusedRootPath, result.root.tree.index(forPath: focus) == nil { self.focusedRootPath = root.path }
                self.appliedEventId = eventIdAtStart
                self.startWatching(since: eventIdAtStart)
                self.cacheDirty = true
                self.scheduleCacheSave(after: 2)
            }
        }
    }

    private func install(tree: DiskTree, metrics: ScanMetrics) {
        rootNode = tree.root
        self.metrics = metrics
        treeVersion &+= 1
        refreshVolume()
        recomputeDerived(delay: 0)
    }

    /// Cleanup candidates and the legend footprint, recomputed off the main
    /// thread (read-locked) after the tree changes.
    private func recomputeDerived(delay: TimeInterval = 0.5) {
        if let pending = derivedWork, !pending.isCancelled, delay > 1 { return } // a queued pass picks this change up
        derivedWork?.cancel()
        guard let tree = rootNode?.tree else { return }
        let rootPath = rootURL.path
        let work = DispatchWorkItem { [weak self] in
            let (cleanup, footprint) = tree.read {
                (CleanupCandidates.collect(root: tree.root, rootPath: rootPath), tree.footprint())
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.derivedWork = nil
                self.lastDerivedAt = Date()
                guard self.rootNode?.tree === tree else { return }
                self.cleanupCandidates = cleanup.items
                self.cleanupTotalBytes = cleanup.totalBytes
                self.categoryFootprint = footprint
            }
        }
        derivedWork = work
        updateQueue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func startWatching(since eventId: UInt64) {
        stopWatching()
        let rootPath = rootURL.path
        // FSEvents reports canonical paths (/private/tmp for /tmp).
        let canonical = URL(fileURLWithPath: rootPath).resolvingSymlinksInPath().path
        watcher = FileSystemWatcher(path: rootPath, since: eventId, latency: 2.0) { [weak self] raw in
            let events = canonical == rootPath ? raw : raw.map {
                FileSystemEvent(path: $0.path.hasPrefix(canonical) ? rootPath + $0.path.dropFirst(canonical.count) : $0.path, flags: $0.flags, id: $0.id)
            }
            let plan = FileSystemEventPlanner.plan(events, rootPath: rootPath)
            let latest = events.map(\.id).max() ?? 0
            Task { @MainActor [weak self] in self?.handle(plan, latestEventId: latest) }
        }
    }

    private func stopWatching() {
        watcher?.stop()
        watcher = nil
    }

    private func handle(_ plan: FileSystemEventPlanner.Plan, latestEventId: UInt64) {
        guard !isScanning, let tree = rootNode?.tree else { return }
        switch plan {
        case .nothing:
            appliedEventId = max(appliedEventId, latestEventId)
        case .fullRescan:
            trace("FSEvents dropped events or the root changed: verifying in the background")
            verifyInBackground()
        case let .refresh(paths):
            refresh(paths: paths, in: tree, latestEventId: latestEventId)
        }
    }

    /// Directories waiting to be reread. Events that arrive while a pass is
    /// running merge here, so a folder that changes every second is reread
    /// once per pass instead of piling up stale work.
    private var pendingPaths: [String: Bool] = [:]
    private var pendingEventId: UInt64 = 0
    private var pendingUserInitiated = false
    private var draining = false

    /// Rereads only the directories that changed and applies each delta up
    /// to the root. Nothing else in the tree is touched.
    private func refresh(paths: [String: Bool], in tree: DiskTree, latestEventId: UInt64 = 0, userInitiated: Bool = false) {
        for (path, recursive) in paths { pendingPaths[path] = (pendingPaths[path] ?? false) || recursive }
        pendingEventId = max(pendingEventId, latestEventId)
        pendingUserInitiated = pendingUserInitiated || userInitiated
        drainPending()
    }

    private func drainPending() {
        guard !draining, !pendingPaths.isEmpty, let tree = rootNode?.tree else { return }
        draining = true
        let batch = pendingPaths
        let eventId = pendingEventId
        let userInitiated = pendingUserInitiated
        pendingPaths = [:]
        pendingUserInitiated = false
        let hidden = includeHiddenFiles
        let before = tree.root.allocatedBytes
        updateQueue.async { [weak self] in
            var changed = false
            // Parents first, and each patch lands before the next directory is
            // read, so every read sees the tree as it is now.
            for path in batch.keys.sorted() {
                guard let patch = IncrementalUpdater.prepare(tree: tree, path: path, recursive: batch[path] ?? false, includeHidden: hidden) else { continue }
                let applied = DispatchQueue.main.sync {
                    MainActor.assumeIsolated { () -> Bool in
                        guard self?.rootNode?.tree === tree else { return false }
                        return IncrementalUpdater.apply(patch)
                    }
                }
                changed = changed || applied
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.draining = false
                self.appliedEventId = max(self.appliedEventId, eventId)
                if changed, self.rootNode?.tree === tree { self.noteChange(in: tree, bytesBefore: before, userInitiated: userInitiated) }
                self.drainPending()
            }
        }
    }

    private func noteChange(in tree: DiskTree, bytesBefore before: UInt64, userInitiated: Bool) {
        let after = tree.root.allocatedBytes
        cacheDirty = true
        scheduleCacheSave(after: 120)
        if userInitiated { treeDidChange(); return }
        pendingBackgroundBytes &+= after > before ? after - before : before - after
        // Visible change (≥0.1% of the scan, e.g. a download landing): show it now.
        if pendingBackgroundBytes >= max(64 << 20, after / 1000) { treeDidChange(userInitiated: false); return }
        if pendingBackgroundFlush == nil {
            let work = DispatchWorkItem { [weak self] in
                Task { @MainActor [weak self] in self?.treeDidChange(userInitiated: false) }
            }
            pendingBackgroundFlush = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: work)
        }
    }

    private func treeDidChange(userInitiated: Bool = true) {
        pendingBackgroundFlush?.cancel()
        pendingBackgroundFlush = nil
        pendingBackgroundBytes = 0
        guard let tree = rootNode?.tree else { return }
        rootNode = tree.root
        treeVersion &+= 1
        metrics = ScanMetrics(entriesScanned: tree.liveNodeCount, inaccessibleEntries: metrics.inaccessibleEntries,
                              errors: metrics.errors, deduplicatedHardlinks: metrics.deduplicatedHardlinks,
                              duration: metrics.duration, cancelled: false)
        if let selectedPath, tree.index(forPath: selectedPath) == nil {
            // Keep the user where they were: the nearest folder that still exists.
            self.selectedPath = tree.deepestNode(forPath: selectedPath).map { DiskNode(tree: tree, index: $0.index).path } ?? rootURL.path
        }
        if let focusedRootPath, tree.index(forPath: focusedRootPath) == nil { self.focusedRootPath = rootURL.path }
        markedPaths = markedPaths.filter { tree.index(forPath: $0) != nil }
        refreshVolume()
        // The candidate walk touches every node: right away after the user's
        // own action, at most once a minute for background churn.
        recomputeDerived(delay: max(0.3, (userInitiated ? 0 : 60) - Date().timeIntervalSince(lastDerivedAt)))
        cacheDirty = true
        scheduleCacheSave(after: 120)
        compactIfNeeded(tree)
    }

    /// Removed and replaced subtrees leave unreachable nodes behind; once
    /// they are a sizeable share, rebuild the arena without them.
    private func compactIfNeeded(_ tree: DiskTree) {
        guard tree.garbageNodes > max(100_000, tree.liveNodeCount / 3) else { return }
        updateQueue.async { [weak self] in
            let (copy, version) = tree.read { (tree.compacted(), tree.version) }
            Task { @MainActor [weak self] in
                guard let self, self.rootNode?.tree === tree, tree.version == version else { return }
                self.rootNode = copy.root
                self.treeVersion &+= 1
                self.recomputeDerived(delay: 0)
            }
        }
    }

    private func scheduleCacheSave(after delay: TimeInterval) {
        // Never postpone a save that is already due: steady churn would starve it.
        if cacheSaveWork != nil, !(cacheSaveWork?.isCancelled ?? true) { return }
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.cacheSaveWork = nil
                self?.saveCache(synchronously: false)
            }
        }
        cacheSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func saveCacheNow() { saveCache(synchronously: true) }

    private func saveCache(synchronously: Bool) {
        guard cacheDirty, !isScanning, let tree = rootNode?.tree, !metrics.cancelled else { return }
        cacheDirty = false
        let header = ScanCache.Header(
            rootPath: tree.rootPath,
            includeHidden: includeHiddenFiles,
            eventId: appliedEventId,
            volumeUUID: FileSystemWatcher.volumeUUID(forPath: tree.rootPath),
            entries: max(metrics.entriesScanned, tree.liveNodeCount),
            scanDuration: metrics.duration
        )
        let work = {
            tree.read {
                let source = tree.garbageNodes == 0 ? tree : tree.compacted()
                try? ScanCache.save(source, header: header)
            }
        }
        if synchronously { work() } else { updateQueue.async(execute: work) }
    }

    func refreshVolume() {
        // A fresh URL each time: URL instances cache resource values.
        let url = URL(fileURLWithPath: rootURL.path)
        let values = try? url.resourceValues(forKeys: [.volumeNameKey, .volumeAvailableCapacityKey, .volumeTotalCapacityKey])
        volumeName = values?.volumeName ?? rootURL.path
        volumeFree = values?.volumeAvailableCapacity.map { UInt64(max(0, $0)) }
        volumeTotal = values?.volumeTotalCapacity.map { UInt64(max(0, $0)) }
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
        let path = node.path
        let started = ProcessInfo.processInfo.systemUptime
        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &resultingURL)
        markedPaths.remove(path)
        // No rescan: drop the node and subtract it from every ancestor.
        let trashed = ProcessInfo.processInfo.systemUptime
        guard let tree = rootNode?.tree, IncrementalUpdater.remove(path: path, from: tree) else { return }
        treeDidChange()
        let updated = ProcessInfo.processInfo.systemUptime
        trace(String(format: "trash: moved in %.1f ms, tree + totals + volume updated in %.1f ms (no rescan)", (trashed - started) * 1000, (updated - trashed) * 1000))
        // Our own FSEvents are ignored, so pick up the item's new home in the
        // Trash (inside the scan root for ~) explicitly.
        if let destination = (resultingURL as URL?)?.deletingLastPathComponent().standardizedFileURL.path,
           tree.index(forPath: destination) != nil {
            refresh(paths: [destination: false], in: tree, userInitiated: true)
        }
    }

    /// Leaf file bytes per category for the legend. Directories aggregate
    /// their children, so only leaves are counted (each byte exactly once).
    nonisolated static func footprint(of root: DiskNode) -> [DiskCategory: UInt64] {
        root.tree.read { root.tree.footprint(from: root.index) }
    }

    func volumeDetails() -> (name: String, free: UInt64?, total: UInt64?) {
        (volumeName, volumeFree, volumeTotal)
    }
}
