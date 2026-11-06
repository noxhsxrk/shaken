import Foundation

/// A user-facing string. Shaken ships in English only; keys are the English text.
public func L(_ key: String) -> String {
    NSLocalizedString(key, bundle: .main, comment: "")
}

/// Localized format string; every placeholder in the catalog is `%@`.
public func L(_ key: String, _ args: String...) -> String {
    String(format: L(key), arguments: args.map { $0 as NSString })
}

public enum ShakenError: LocalizedError, Equatable {
    case unreadableImage(String)
    case unreadablePDF(String)
    case destinationNotWritable(String)
    case missingRequirement(tool: String, hint: String)
    case scriptFailed(name: String, message: String)
    case stepProducedNothing(String)
    case unsupportedInput(String)
    case nothingToDo(String)
    case outputChanged(String)
    case outputMissing(String)
    case notApproved(String)
    case invalidManifest(String)
    case git(String)
    case other(String)

    public var errorDescription: String? {
        switch self {
        case .unreadableImage(let n): return L("Can't read image “%@”. The file may be damaged.", n)
        case .unreadablePDF(let n): return L("Can't read PDF “%@”.", n)
        case .destinationNotWritable(let p): return L("Can't write to folder “%@”. Originals are untouched.", p)
        case .missingRequirement(let t, let h): return L("Needs “%@”. Install with: %@", t, h)
        case .scriptFailed(let n, let m): return m.isEmpty ? L("“%@” failed.", n) : m
        case .stepProducedNothing(let s): return L("Step “%@” produced no files.", s)
        case .unsupportedInput(let s): return L("This command can't handle: %@", s)
        case .nothingToDo(let s): return s
        case .outputChanged(let n): return L("“%@” was changed after it was created, so it won't be undone.", n)
        case .outputMissing(let n): return L("“%@” no longer exists.", n)
        case .notApproved(let n): return L("“%@” needs your permission before it can run.", n)
        case .invalidManifest(let s): return s
        case .git(let s): return s
        case .other(let s): return s
        }
    }
}
