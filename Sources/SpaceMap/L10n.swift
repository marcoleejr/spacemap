import Foundation
import SpaceMapCore

/// App localization through the compiled Localizable catalog
/// (Sources/SpaceMap/Resources/Localizable.xcstrings, compiled to .lproj by
/// scripts/strings.py). The system picks the language; no in-app switcher.
enum L10n {
    /// Inside SpaceMap.app the catalogs live in Contents/Resources, so
    /// Bundle.main is used; `swift run` falls back to SwiftPM's resource bundle.
    /// (Touching Bundle.module inside the .app would crash: it only looks next
    /// to the executable's build products.)
    static let bundle: Bundle = {
        if Bundle.main.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: "en") != nil {
            return .main
        }
        return .module
    }()

    static func string(_ key: StaticString) -> String {
        NSLocalizedString(String(describing: key), bundle: bundle, comment: "")
    }

    static func format(_ key: StaticString, _ args: CVarArg...) -> String {
        String(format: string(key), arguments: args)
    }

    static func plural(_ key: StaticString, count: Int) -> String {
        let template = NSLocalizedString(String(describing: key), bundle: bundle, comment: "")
        return String.localizedStringWithFormat(template, count)
    }

    static func files(_ count: Int) -> String { plural("file_count", count: count) }
    static func dirs(_ count: Int) -> String { plural("dir_count", count: count) }

    /// Reference-style compact counts ("4.4M files"): the number is
    /// pre-compacted; singularity follows each locale's one-rule
    /// (French treats 0 as singular, Japanese never inflects).
    static func filesCompact(_ compact: String, count: Int) -> String {
        format(singular(count) ? "files_compact_one" : "files_compact_other", compact)
    }

    static func dirsCompact(_ compact: String, count: Int) -> String {
        format(singular(count) ? "dirs_compact_one" : "dirs_compact_other", compact)
    }

    private static func singular(_ count: Int) -> Bool {
        switch Locale.current.language.languageCode?.identifier {
        case "ja": false
        case "fr": count <= 1
        default: count == 1
        }
    }

    static func age(from date: Date?, now: Date = .now) -> String {
        switch ByteFormatter.ageParts(from: date, now: now) {
        case .unknown: return string("age.unknown")
        case .justNow: return string("age.just_now")
        case let .minutes(value): return plural("age.minute", count: value)
        case let .hours(value): return plural("age.hour", count: value)
        case let .days(value): return plural("age.day", count: value)
        case let .months(value): return plural("age.month", count: value)
        case let .years(value): return plural("age.year", count: value)
        }
    }

    static func candidateSubtitle(_ candidate: CleanupCandidate) -> String {
        switch candidate.kind {
        case .buildOutput: return string("worth.build_output")
        case .cache: return string("worth.cache")
        case .agentWorkspace: return string("worth.agent")
        case .largeRepository: return string("worth.repo")
        case .oldMedia: return string("worth.old_media")
        case let .oldOther(date): return format("worth.old_other", age(from: date))
        }
    }
}

extension DiskCategory {
    var localizedTitle: String {
        switch self {
        case .reclaimable: L10n.string("category.reclaimable")
        case .code: L10n.string("category.code")
        case .agentScratch: L10n.string("category.agent")
        case .toolchains: L10n.string("category.toolchains")
        case .synced: L10n.string("category.synced")
        case .git: L10n.string("category.git")
        case .media: L10n.string("category.media")
        case .documents: L10n.string("category.documents")
        case .cache: L10n.string("category.cache")
        }
    }
}

extension TreemapMode {
    var localizedTitle: String {
        switch self {
        case .size: L10n.string("mode.size")
        case .files: L10n.string("mode.files")
        case .age: L10n.string("mode.age")
        }
    }
}
