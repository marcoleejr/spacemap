import SpaceMapCore
import SwiftUI

private struct RenderTile {
    let node: DiskNode
    let frame: CGRect
    let pill: CGRect?
    let level: Int
}

/// Layout inputs; the tiles are recomputed only when one of these changes.
private struct LayoutKey: Equatable {
    let tree: ObjectIdentifier
    let version: Int
    let focus: String?
    let size: CGSize
    let mode: TreemapMode
    let depth: Int
    let filter: String
    let apparent: Bool
}

/// Holds the last layout (and the previous one while a change animates).
/// A reference type so hover and selection never trigger a relayout.
@MainActor
private final class TreemapLayoutCache {
    var key: LayoutKey?
    var tree: DiskTree?
    var tiles: [RenderTile] = []
    var generation = 0
    /// Frames before an in-place tree change, keyed by node index.
    var previousFrames: [UInt32: CGRect] = [:]
    var departing: [RenderTile] = []
    var animationStart: Date?
    static let duration: TimeInterval = 0.32

    func isAnimating(at date: Date) -> Bool {
        guard let animationStart else { return false }
        return date.timeIntervalSince(animationStart) < TreemapLayoutCache.duration
    }

    /// Exponential ease-out progress in 0...1.
    func progress(at date: Date) -> Double {
        guard let animationStart else { return 1 }
        let t = min(1, max(0, date.timeIntervalSince(animationStart) / TreemapLayoutCache.duration))
        return t >= 1 ? 1 : 1 - pow(2, -10 * t)
    }
}

struct TreemapCanvas: View {
    @ObservedObject var model: SpaceMapViewModel
    @Environment(\.colorScheme) private var scheme
    @State private var hoverPoint: CGPoint?
    @State private var hoveredIndex: UInt32?
    @State private var cache = TreemapLayoutCache()
    @State private var settledGeneration = 0

    private var onLight: Bool { scheme == .light }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let boxes = layout(in: size)
            let animating = cache.animationStart != nil && settledGeneration != cache.generation
            let hoveredTile = hoveredIndex.flatMap { index in boxes.last(where: { $0.node.index == index }) }
            ZStack(alignment: .topLeading) {
                TimelineView(.animation(minimumInterval: nil, paused: !animating)) { timeline in
                    TreemapTilesLayer(
                        tiles: boxes,
                        generation: cache.generation,
                        progress: animating ? cache.progress(at: timeline.date) : 1,
                        previousFrames: animating ? cache.previousFrames : [:],
                        departing: animating ? cache.departing : [],
                        selectedIndex: model.selectedPath.flatMap { model.rootNode?.tree.index(forPath: $0) },
                        onLight: onLight,
                        mode: model.mode,
                        apparent: model.useApparentSize
                    )
                    .equatable()
                }
                .task(id: cache.generation) {
                    // Pause the timeline once the change has settled: zero redraws at rest.
                    guard animating else { return }
                    try? await Task.sleep(for: .milliseconds(Int(TreemapLayoutCache.duration * 1000) + 30))
                    settledGeneration = cache.generation
                }

                // Hover outline lives in its own layer so moving the pointer
                // redraws one rectangle, not the whole map.
                if let hoveredTile, hoveredTile.node.path != model.selectedPath, !animating {
                    Canvas { context, _ in
                        let rect = hoveredTile.frame
                        let path = Path(roundedRect: rect, cornerRadius: min(7, min(rect.width, rect.height) * 0.18))
                        context.stroke(path, with: .color(Theme.text.opacity(0.7)), lineWidth: 1)
                    }
                    .allowsHitTesting(false)
                }

                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { point in
                        if let tile = tile(at: point, in: boxes) {
                            model.select(tile.node)
                            model.openSelected()
                        }
                    }
                    .onTapGesture { point in
                        if let tile = tile(at: point, in: boxes) { model.select(tile.node) }
                    }
                    .onContinuousHover { phase in
                        switch phase {
                        case let .active(point):
                            hoverPoint = point
                            let index = tile(at: point, in: boxes)?.node.index
                            if index != hoveredIndex { hoveredIndex = index }
                        case .ended:
                            hoverPoint = nil
                            hoveredIndex = nil
                        }
                    }
                    .contextMenu {
                        Button(L10n.string("action.reveal")) { model.revealInFinder() }
                        Button(L10n.string("action.trash"), role: .destructive) { NotificationCenter.default.post(name: .spaceMapRequestTrash, object: nil) }
                    }

                if boxes.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: model.isScanning ? "circle.dotted.circle" : "tray")
                            .font(.system(size: 28, weight: .light))
                            .foregroundStyle(Theme.secondary)
                        Text(model.isScanning ? L10n.string("canvas.loading_title") : L10n.string("canvas.empty_title"))
                            .font(.system(size: 14, weight: .semibold))
                        Text(model.isScanning ? L10n.string("canvas.loading_hint") : L10n.string("canvas.empty_hint"))
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
                }

                if let hoverPoint, let node = hoveredTile?.node {
                    HStack(spacing: 7) {
                        Circle().fill(Theme.category(node.colorCategory)).frame(width: 8, height: 8)
                        Text(node.name).font(.system(size: 11, weight: .semibold))
                        Text(ByteFormatter.string(node.bytes(apparent: model.useApparentSize))).font(.system(size: 11).monospacedDigit())
                    }
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Theme.surface.opacity(0.97), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line, lineWidth: 1))
                    .position(x: min(max(hoverPoint.x + 88, 92), size.width - 92), y: min(max(hoverPoint.y - 18, 18), size.height - 18))
                    .allowsHitTesting(false)
                }
            }
            .background(Theme.sunken)
        }
        .accessibilityLabel(L10n.string("canvas.accessibility"))
    }

    /// Returns cached tiles unless a layout input changed. An in-place change
    /// of the same tree (trash, FSEvents) keeps the old frames so the map can
    /// glide to the new layout instead of jumping.
    private func layout(in size: CGSize) -> [RenderTile] {
        guard let tree = model.rootNode?.tree else {
            cache.key = nil
            cache.tree = nil
            cache.tiles = []
            return []
        }
        let key = LayoutKey(
            tree: ObjectIdentifier(tree),
            version: model.treeVersion,
            focus: model.focusedRootPath,
            size: size,
            mode: model.mode,
            depth: model.depth,
            filter: model.filterText,
            apparent: model.useApparentSize
        )
        if cache.key == key, cache.tree === tree { return cache.tiles }
        let tiles = renderTiles(in: CGRect(origin: .zero, size: size))
        let inPlaceChange = cache.tree === tree && cache.key.map {
            $0.version != key.version && $0.focus == key.focus && $0.size == key.size && $0.mode == key.mode
                && $0.depth == key.depth && $0.filter == key.filter && $0.apparent == key.apparent
        } == true
        if inPlaceChange, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, !model.isScanning {
            var previous: [UInt32: CGRect] = [:]
            previous.reserveCapacity(cache.tiles.count)
            for tile in cache.tiles { previous[tile.node.index] = tile.frame }
            let remaining = Set(tiles.map(\.node.index))
            cache.previousFrames = previous
            cache.departing = cache.tiles.filter { !remaining.contains($0.node.index) }
            cache.animationStart = Date()
        } else {
            cache.previousFrames = [:]
            cache.departing = []
            cache.animationStart = nil
        }
        cache.generation &+= 1
        cache.key = key
        cache.tree = tree
        cache.tiles = tiles
        return tiles
    }

    private func renderTiles(in bounds: CGRect) -> [RenderTile] {
        guard let root = model.scanRoot else { return [] }
        var output: [RenderTile] = []
        func children(of parent: DiskNode) -> [DiskNode] {
            guard !model.filterText.isEmpty else { return parent.children }
            let query = model.filterText.localizedLowercase
            func contains(_ node: DiskNode) -> Bool {
                node.name.localizedLowercase.contains(query) || node.children.contains(where: contains)
            }
            return parent.children.filter(contains)
        }
        func lay(_ parent: DiskNode, in rect: CGRect, level: Int) {
            let childNodes = children(of: parent)
            guard !childNodes.isEmpty, rect.width > 3, rect.height > 3 else { return }
            let weights = Squarifier.weights(for: childNodes, mode: model.mode, apparentSize: model.useApparentSize)
            for tile in Squarifier.layout(nodes: childNodes, weights: weights, in: rect) {
                let frame = tile.rect.insetBy(dx: 1.5, dy: 1.5)
                guard frame.width > 1, frame.height > 1 else { continue }
                let pill: CGRect? = tile.node.isDirectory && frame.width > 64 && frame.height > 34
                    ? CGRect(x: frame.minX + 5, y: frame.minY + 5, width: min(frame.width - 10, 220), height: 22)
                    : nil
                output.append(RenderTile(node: tile.node, frame: frame, pill: pill, level: level))
                guard tile.node.isDirectory, level < model.depth, frame.width > 40, frame.height > 40 else { continue }
                let inset = frame.insetBy(dx: 4, dy: 4)
                let childTop = min(inset.maxY, (pill?.maxY ?? inset.minY) + 4)
                let childRect = CGRect(x: inset.minX, y: childTop, width: inset.width, height: max(0, inset.maxY - childTop))
                lay(tile.node, in: childRect, level: level + 1)
            }
        }
        lay(root, in: bounds.insetBy(dx: 3, dy: 3), level: 1)
        return output
    }

    private func tile(at point: CGPoint, in tiles: [RenderTile]) -> RenderTile? {
        tiles.reversed().first(where: { $0.frame.contains(point) })
    }
}

/// The map itself. Equatable on its inputs, so hover, tooltips and
/// unrelated model updates never redraw the tiles.
private struct TreemapTilesLayer: View, Equatable {
    let tiles: [RenderTile]
    let generation: Int
    let progress: Double
    let previousFrames: [UInt32: CGRect]
    let departing: [RenderTile]
    let selectedIndex: UInt32?
    let onLight: Bool
    let mode: TreemapMode
    let apparent: Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.generation == rhs.generation && lhs.progress == rhs.progress && lhs.selectedIndex == rhs.selectedIndex
            && lhs.onLight == rhs.onLight && lhs.mode == rhs.mode && lhs.apparent == rhs.apparent
    }

    var body: some View {
        Canvas { context, _ in
            if progress < 1 {
                // Removed tiles collapse toward their centers as they fade.
                for tile in departing {
                    let scale = 1 - progress
                    let frame = tile.frame.insetBy(dx: tile.frame.width * (1 - scale) / 2, dy: tile.frame.height * (1 - scale) / 2)
                    var faded = context
                    faded.opacity = scale
                    draw([RenderTile(node: tile.node, frame: frame, pill: nil, level: tile.level)], in: &faded)
                }
                draw(tiles.map(interpolated), in: &context)
            } else {
                draw(tiles, in: &context)
            }
        }
    }

    private func interpolated(_ tile: RenderTile) -> RenderTile {
        guard let from = previousFrames[tile.node.index] else { return tile }
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * progress }
        let to = tile.frame
        let frame = CGRect(x: mix(from.minX, to.minX), y: mix(from.minY, to.minY), width: mix(from.width, to.width), height: mix(from.height, to.height))
        let pill = tile.pill.map { CGRect(x: frame.minX + 5, y: frame.minY + 5, width: min(frame.width - 10, $0.width), height: $0.height) }
        return RenderTile(node: tile.node, frame: frame, pill: pill, level: tile.level)
    }

    private func tileFill(_ node: DiskNode) -> Color {
        let hue = mode == .age ? ageColor(node.modifiedAt) : Theme.category(node.colorCategory)
        let base: Double = node.isDirectory ? 0.30 : 0.38
        return hue.opacity(onLight ? base * 0.62 : base)
    }

    private func draw(_ tiles: [RenderTile], in context: inout GraphicsContext) {
        for tile in tiles {
            let rect = tile.frame
            let path = Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height), cornerRadius: min(7, min(rect.width, rect.height) * 0.18))
            var fillContext = context
            fillContext.fill(path, with: .color(tileFill(tile.node)))

            if tile.node.category == .reclaimable {
                var hatch = context
                hatch.clip(to: path)
                var stripe = Path()
                var start = rect.minX - rect.height
                while start < rect.maxX {
                    stripe.move(to: CGPoint(x: start, y: rect.maxY))
                    stripe.addLine(to: CGPoint(x: start + rect.height, y: rect.minY))
                    start += 9
                }
                hatch.stroke(stripe, with: .color(Color(hex: 0xFFFFFF).opacity(onLight ? 0.35 : 0.14)), lineWidth: 1)
            }

            if let pill = tile.pill {
                let pillPath = Path(pill, cornerRadius: 6)
                var pillContext = context
                pillContext.fill(pillPath, with: .color((onLight ? Color(hex: 0xFFFFFF) : Color(hex: 0x000000)).opacity(onLight ? 0.72 : 0.5)))
                let label = "\(tile.node.name) · \(displayValue(for: tile.node))"
                let text = Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(onLight ? Color(hex: 0x232B3A) : .white)
                var labelContext = context
                labelContext.clip(to: pillPath)
                labelContext.draw(text, at: CGPoint(x: pill.minX + 7, y: pill.midY), anchor: .leading)
            } else if rect.width > 60 && rect.height > 32 {
                let label = Text("\(tile.node.name)\n\(displayValue(for: tile.node))")
                    .font(.system(size: min(12, max(9, rect.width / 15)), weight: .medium))
                    .foregroundColor(onLight ? Color(hex: 0x232B3A).opacity(0.92) : Color(hex: 0xEDF1F8).opacity(0.94))
                var labelContext = context
                labelContext.clip(to: path)
                labelContext.draw(label, at: CGPoint(x: rect.minX + 7, y: rect.minY + 6), anchor: .topLeading)
            }

            let selected = tile.node.index == selectedIndex
            let borderColor: Color = selected ? Theme.accent : (onLight ? Color(hex: 0xFFFFFF).opacity(0.9) : Color(hex: 0x0B0E14).opacity(0.8))
            context.stroke(path, with: .color(borderColor), lineWidth: selected ? 2 : 1)
            if tile.pill != nil {
                var orbit = Path()
                let y = rect.minY + 2.5
                orbit.move(to: CGPoint(x: rect.minX + 7, y: y))
                orbit.addLine(to: CGPoint(x: rect.maxX - 7, y: y))
                context.stroke(orbit, with: .color(Theme.category(tile.node.colorCategory).opacity(0.95)), lineWidth: 2.5)
            }
        }
    }

    private func displayValue(for node: DiskNode) -> String {
        switch mode {
        case .files:
            let compacted: String
            if node.fileCount >= 1_000_000 { compacted = String(format: "%.1fM", Double(node.fileCount) / 1_000_000) }
            else if node.fileCount >= 1_000 { compacted = String(format: "%.1fk", Double(node.fileCount) / 1_000) }
            else { compacted = "\(node.fileCount)" }
            return L10n.filesCompact(compacted, count: node.fileCount)
        case .size, .age:
            return ByteFormatter.string(node.bytes(apparent: apparent))
        }
    }

    private func ageColor(_ date: Date?) -> Color {
        let days = max(0, Date().timeIntervalSince(date ?? .distantPast) / 86_400)
        let t = min(1, days / 365)
        let fresh = (r: 76.0, g: 195.0, b: 217.0)
        let old = (r: 201.0, g: 106.0, b: 44.0)
        return Color(red: (fresh.r + (old.r - fresh.r) * t) / 255, green: (fresh.g + (old.g - fresh.g) * t) / 255, blue: (fresh.b + (old.b - fresh.b) * t) / 255)
    }

}

extension Notification.Name {
    static let spaceMapRequestTrash = Notification.Name("SpaceMapRequestTrash")
}

private extension Path {
    init(_ rect: CGRect, cornerRadius: CGFloat) {
        self.init(roundedRect: rect, cornerRadius: cornerRadius)
    }
}
