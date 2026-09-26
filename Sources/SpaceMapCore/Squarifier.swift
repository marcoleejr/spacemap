import CoreGraphics
import Foundation

public struct TreemapTile: Sendable {
    public let node: DiskNode
    public let rect: CGRect

    public init(node: DiskNode, rect: CGRect) {
        self.node = node
        self.rect = rect
    }
}

public enum Squarifier {
    private struct WeightedNode {
        let node: DiskNode
        let weight: Double
    }

    /// Squarified treemap placement (Bruls, Huizing, van Wijk). Weights are normalized to the requested rect.
    public static func layout(nodes: [DiskNode], weights: [Double], in rect: CGRect) -> [TreemapTile] {
        guard !nodes.isEmpty, rect.width > 0, rect.height > 0 else { return [] }
        let usable = nodes.enumerated().map { index, node in
            WeightedNode(node: node, weight: index < weights.count ? max(0, weights[index]) : 0)
        }
        let positiveTotal = usable.reduce(0) { $0 + $1.weight }
        let fallback = positiveTotal == 0
        let sourceWeights = usable.map { fallback ? 1.0 : $0.weight }
        let total = sourceWeights.reduce(0, +)
        guard total.isFinite, total > 0 else { return [] }

        var remaining = usable.enumerated().map { index, item in
            WeightedNode(node: item.node, weight: sourceWeights[index] * rect.width * rect.height / total)
        }.sorted {
            if $0.weight == $1.weight { return $0.node.path < $1.node.path }
            return $0.weight > $1.weight
        }

        var result: [TreemapTile] = []
        var row: [WeightedNode] = []
        var remainingRect = rect

        while !remaining.isEmpty {
            let candidate = remaining[0]
            if row.isEmpty || worst(row + [candidate], shortSide: min(remainingRect.width, remainingRect.height)) <= worst(row, shortSide: min(remainingRect.width, remainingRect.height)) {
                row.append(candidate)
                remaining.removeFirst()
            } else {
                let placed = place(row, in: remainingRect)
                result.append(contentsOf: placed.tiles)
                remainingRect = placed.remaining
                row.removeAll(keepingCapacity: true)
            }
        }
        if !row.isEmpty { result.append(contentsOf: place(row, in: remainingRect).tiles) }
        return result
    }

    public static func layout(nodes: [DiskNode], in rect: CGRect, apparentSize: Bool = false) -> [TreemapTile] {
        let weights = nodes.map { Double(max(1, $0.bytes(apparent: apparentSize))) }
        return layout(nodes: nodes, weights: weights, in: rect)
    }

    public static func weights(for nodes: [DiskNode], mode: TreemapMode, apparentSize: Bool) -> [Double] {
        nodes.map { node in
            switch mode {
            case .files: Double(max(1, node.fileCount))
            case .size, .age: Double(max(1, node.bytes(apparent: apparentSize)))
            }
        }
    }

    private static func worst(_ row: [WeightedNode], shortSide: CGFloat) -> Double {
        guard let first = row.first, shortSide > 0 else { return .infinity }
        let sum = row.reduce(0) { $0 + $1.weight }
        guard sum > 0 else { return .infinity }
        let minimum = row.map(\.weight).min() ?? first.weight
        let maximum = row.map(\.weight).max() ?? first.weight
        let sideSquared = Double(shortSide * shortSide)
        let sumSquared = sum * sum
        return max(sideSquared * maximum / sumSquared, sumSquared / max(sideSquared * minimum, .leastNonzeroMagnitude))
    }

    private static func place(_ row: [WeightedNode], in rect: CGRect) -> (tiles: [TreemapTile], remaining: CGRect) {
        guard !row.isEmpty else { return ([], rect) }
        let rowWeight = row.reduce(0) { $0 + $1.weight }
        var tiles: [TreemapTile] = []

        if rect.width >= rect.height {
            // A wide remainder gets a vertical strip: divide along its long edge and keep tile ratios balanced.
            let stripWidth = min(rect.width, rowWeight / Double(rect.height))
            var y = rect.minY
            for (index, item) in row.enumerated() {
                let height: CGFloat
                if index == row.count - 1 {
                    height = max(0, rect.maxY - y)
                } else {
                    height = min(max(0, rect.maxY - y), CGFloat(item.weight / Double(max(stripWidth, .leastNonzeroMagnitude))))
                }
                tiles.append(TreemapTile(node: item.node, rect: CGRect(x: rect.minX, y: y, width: stripWidth, height: height)))
                y += height
            }
            let remainder = CGRect(x: rect.minX + stripWidth, y: rect.minY, width: max(0, rect.width - stripWidth), height: rect.height)
            return (tiles, remainder)
        } else {
            let stripHeight = min(rect.height, rowWeight / Double(rect.width))
            var x = rect.minX
            for (index, item) in row.enumerated() {
                let width: CGFloat
                if index == row.count - 1 {
                    width = max(0, rect.maxX - x)
                } else {
                    width = min(max(0, rect.maxX - x), CGFloat(item.weight / Double(max(stripHeight, .leastNonzeroMagnitude))))
                }
                tiles.append(TreemapTile(node: item.node, rect: CGRect(x: x, y: rect.minY, width: width, height: stripHeight)))
                x += width
            }
            let remainder = CGRect(x: rect.minX, y: rect.minY + stripHeight, width: rect.width, height: max(0, rect.height - stripHeight))
            return (tiles, remainder)
        }
    }
}
