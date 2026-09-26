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
} catch {
    fputs("spacemap-bench: \(error.localizedDescription)\n", stderr)
    exit(EXIT_FAILURE)
}
