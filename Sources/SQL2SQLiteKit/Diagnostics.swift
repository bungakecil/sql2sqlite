public enum WarningCategory: String, Sendable, CaseIterable {
    case skippedRoutine        = "skipped routine"
    case skippedIndex          = "skipped index"
    case unsupportedConstruct  = "unsupported construct"
    case droppedAttribute      = "dropped attribute"
    case unknownType           = "unknown type"
    case numericPrecision      = "numeric precision"
    case multiDatabase         = "multi-database dump"
    case malformed             = "malformed input"
    case viewFailed            = "view failed"
    case foreignKeyViolation   = "foreign key violation"
}

public struct Warning: Sendable, CustomStringConvertible {
    public let category: WarningCategory
    public let message: String
    public let byteOffset: Int
    public let line: Int

    public init(category: WarningCategory, message: String, byteOffset: Int, line: Int) {
        self.category = category
        self.message = message
        self.byteOffset = byteOffset
        self.line = line
    }

    public var description: String {
        "warning: \(message) [\(category.rawValue)] (line \(line), byte offset \(byteOffset))"
    }
}

public final class Diagnostics {
    private let strict: Bool
    private let quiet: Bool
    private let sink: (String) -> Void
    private var seenOnce: Set<WarningCategory> = []
    public private(set) var counts: [WarningCategory: Int] = [:]

    public init(strict: Bool, quiet: Bool, sink: @escaping (String) -> Void) {
        self.strict = strict
        self.quiet = quiet
        self.sink = sink
    }

    /// A sink-less instance for unit tests that do not assert on warnings.
    public static func discarding(strict: Bool = false) -> Diagnostics {
        Diagnostics(strict: strict, quiet: true, sink: { _ in })
    }

    public var total: Int { counts.values.reduce(0, +) }

    public func warn(_ category: WarningCategory, _ message: String,
                     offset: Int, line: Int) throws {
        let warning = Warning(category: category, message: message,
                              byteOffset: offset, line: line)
        counts[category, default: 0] += 1
        if strict { throw ConversionError.strict(warning) }
        if !quiet { sink(warning.description) }
    }

    /// Emits at most one warning per category for the whole run.
    public func warnOnce(_ category: WarningCategory, _ message: String,
                         offset: Int, line: Int) throws {
        guard seenOnce.insert(category).inserted else { return }
        try warn(category, message, offset: offset, line: line)
    }

    /// One-line end-of-run tally, or nil when nothing was skipped. Under --quiet
    /// this reports only a count: naming the categories is exactly the detail
    /// the caller asked to be spared.
    public func summaryFragment() -> String? {
        guard !counts.isEmpty else { return nil }
        if quiet { return "\(total) warning\(total == 1 ? "" : "s")" }
        return counts
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.value) \($0.key.rawValue)" }
            .joined(separator: ", ")
    }
}
