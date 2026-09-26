import Foundation

public enum ByteFormatter {
    private static let units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"]

    public static func string(_ bytes: UInt64, precision: Int = 1) -> String {
        guard bytes > 0 else { return "0 B" }
        var value = Double(bytes)
        var unitIndex = 0
        while value >= 1024, unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = precision
        formatter.minimumFractionDigits = 0
        formatter.usesGroupingSeparator = true
        let number = formatter.string(from: NSNumber(value: value)) ?? String(format: "%.*f", precision, value)
        return "\(number) \(units[unitIndex])"
    }

    public static func valueAndUnit(_ bytes: UInt64, precision: Int = 1) -> (value: String, unit: String) {
        let formatted = string(bytes, precision: precision)
        let pieces = formatted.split(separator: " ", maxSplits: 1).map(String.init)
        return (pieces.first ?? "0", pieces.count > 1 ? pieces[1] : "B")
    }

/// Language-neutral age decomposition. The app renders these parts through
    /// its localizations; `relativeAge` keeps the English rendering for logs
    /// and tests.
    public enum AgeParts: Sendable, Equatable {
        case unknown
        case justNow
        case minutes(Int)
        case hours(Int)
        case days(Int)
        case months(Int)
        case years(Int)
    }

    public static func ageParts(from date: Date?, now: Date = .now) -> AgeParts {
        guard let date else { return .unknown }
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return .justNow }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return .minutes(minutes) }
        let hours = minutes / 60
        if hours < 24 { return .hours(hours) }
        let days = hours / 24
        if days < 30 { return .days(days) }
        let months = max(1, days / 30)
        if months < 12 { return .months(months) }
        return .years(max(1, days / 365))
    }

    public static func relativeAge(from date: Date?, now: Date = .now) -> String {
        switch ageParts(from: date, now: now) {
        case .unknown: return "Unknown"
        case .justNow: return "just now"
        case let .minutes(value): return value == 1 ? "1 minute ago" : "\(value) minutes ago"
        case let .hours(value): return value == 1 ? "1 hour ago" : "\(value) hours ago"
        case let .days(value): return value == 1 ? "1 day ago" : "\(value) days ago"
        case let .months(value): return value == 1 ? "1 month ago" : "\(value) months ago"
        case let .years(value): return value == 1 ? "1 year ago" : "\(value) years ago"
        }
    }
}
