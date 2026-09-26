import Darwin
import SpaceMapCore
import Foundation

func scanRoot(from argument: String?) -> URL {
    let home = FileManager.default.homeDirectoryForCurrentUser
    guard let argument, !argument.isEmpty || argument == "~" else { return home }
    if argument == "~" { return home }
    if argument.hasPrefix("~/") { return home.appending(path: String(argument.dropFirst(2))).standardizedFileURL }
    return URL(fileURLWithPath: argument).standardizedFileURL
}

let requestedPath = CommandLine.arguments.dropFirst().first
let rootURL = scanRoot(from: requestedPath)
let wallStart = Date()
let startUptime = ProcessInfo.processInfo.systemUptime
var lastProgressTime = startUptime
var progressSnapshots = 0

if let workers = ProcessInfo.processInfo.environment["SPACEMAP_WORKERS"].flatMap(Int.init) {
    DiskScanner.maxWorkers = workers
}

do {
    // Same engine as the app: ScanEngine.scan is the only scan entry point
    // for both (see testAppAndBenchShareSameEngine).
    // SPACEMAP_NOPROGRESS=1 measures the raw engine without snapshot costs.
    let wantProgress = ProcessInfo.processInfo.environment["SPACEMAP_NOPROGRESS"] == nil
    let result = try ScanEngine.scan(rootURL: rootURL, progress: wantProgress ? { update in
        progressSnapshots += 1
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastProgressTime >= 2 {
            let elapsed = now - startUptime
            let rate = elapsed > 0 ? Double(update.metrics.entriesScanned) / elapsed : 0
            fputs(String(format: "progress elapsed=%.1fs entries=%d entries_per_second=%.0f errors=%d\n", elapsed, update.metrics.entriesScanned, rate, update.metrics.errors), stderr)
            fflush(stderr)
            lastProgressTime = now
        }
    } : nil)
    let wallElapsed = Date().timeIntervalSince(wallStart)
    let entriesPerSecond = wallElapsed > 0 ? Double(result.metrics.entriesScanned) / wallElapsed : 0
    print(String(format: "root=%@ elapsed=%.3fs entries=%d entries_per_second=%.0f files=%d directories=%d bytes=%llu errors=%d inaccessible=%d hardlinks_deduplicated=%d snapshots=%d cancelled=%@",
        rootURL.path,
        wallElapsed,
        result.metrics.entriesScanned,
        entriesPerSecond,
        result.root.fileCount,
        result.root.directoryCount,
        result.root.allocatedBytes,
        result.metrics.errors,
        result.metrics.inaccessibleEntries,
        result.metrics.deduplicatedHardlinks,
        progressSnapshots,
        String(result.metrics.cancelled)
    ))
    let tree = result.root.tree
    print(String(format: "tree_nodes=%d unique_names=%d name_pool=%.1fMB tree_bytes=%.1fMB", tree.nodeCount, tree.uniqueNameCount, Double(tree.namePoolBytes) / 1_048_576, Double(tree.approximateBytes) / 1_048_576))

    // Incremental path: remove the largest file and time the delta propagation.
    if ProcessInfo.processInfo.environment["SPACEMAP_INCREMENTAL"] != nil {
        var largest: UInt32 = 0
        var largestBytes: UInt64 = 0
        var stack: [DiskNode] = [result.root]
        while let node = stack.popLast() {
            if node.isDirectory { stack.append(contentsOf: node.children) }
            else if node.allocatedBytes > largestBytes { largest = node.index; largestBytes = node.allocatedBytes }
        }
        let path = DiskNode(tree: tree, index: largest).path
        let before = tree.root.allocatedBytes
        let removeStart = ProcessInfo.processInfo.systemUptime
        IncrementalUpdater.remove(path: path, from: tree)
        let removeElapsed = ProcessInfo.processInfo.systemUptime - removeStart
        print(String(format: "remove_largest_file=%.3fms bytes=%llu root_delta_ok=%@", removeElapsed * 1000, largestBytes,
                     String(before - tree.root.allocatedBytes == largestBytes)))
        let parentPath = (path as NSString).deletingLastPathComponent
        let refreshStart = ProcessInfo.processInfo.systemUptime
        if let patch = IncrementalUpdater.prepare(tree: tree, path: parentPath, recursive: false, includeHidden: true) {
            IncrementalUpdater.apply(patch)
        }
        print(String(format: "refresh_parent_dir=%.3fms", (ProcessInfo.processInfo.systemUptime - refreshStart) * 1000))
        let cacheURL = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "spacemap-bench-cache.bin")
        let saveStart = ProcessInfo.processInfo.systemUptime
        let compact = tree.compacted()
        print(String(format: "compact=%.2fs", ProcessInfo.processInfo.systemUptime - saveStart))
        try ScanCache.save(compact, header: .init(rootPath: compact.rootPath, includeHidden: true, eventId: 0, volumeUUID: nil, entries: 0), to: cacheURL)
        let saveElapsed = ProcessInfo.processInfo.systemUptime - saveStart
        let loadStart = ProcessInfo.processInfo.systemUptime
        let loaded = try ScanCache.load(from: cacheURL)
        let loadElapsed = ProcessInfo.processInfo.systemUptime - loadStart
        let size = (try? FileManager.default.attributesOfItem(atPath: cacheURL.path)[.size] as? Int) ?? 0
        print(String(format: "cache_save=%.2fs cache_load=%.2fs cache_file=%.1fMB loaded_nodes=%d", saveElapsed, loadElapsed, Double(size) / 1_048_576, loaded.tree.nodeCount))
        try? FileManager.default.removeItem(at: cacheURL)
    }
} catch {
    fputs("spacemap-bench: \(error.localizedDescription)\n", stderr)
    exit(EXIT_FAILURE)
}
