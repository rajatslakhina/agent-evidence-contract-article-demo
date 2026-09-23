/// One thing the harness observed. There is deliberately no case for "the
/// agent says it ran X": the agent's prose is a separate input to the
/// evaluator and can never become an event.
public enum SessionEvent: Hashable, Sendable {
    case edit(file: String)
    case run(ToolRun)
}

public struct ToolRun: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// `executed` is nil when the output had no parseable summary line.
        case test(scope: TestScope, executed: Int?, failedTests: [String])
        case build
        /// `pattern` is kept verbatim. `narrowed` is true for `-w`, a path
        /// other than `.`, or a type/glob/max-count restriction.
        case search(pattern: String, narrowed: Bool, hits: Int)
    }

    public let command: String
    public let exitCode: Int32
    public let kind: Kind

    public init(command: String, exitCode: Int32, kind: Kind) {
        self.command = command
        self.exitCode = exitCode
        self.kind = kind
    }

    public var succeeded: Bool { exitCode == 0 }
}

/// An ordered log. An event's index is its timestamp: "fresh" means "after the
/// last edit", nothing more clever than that.
public struct SessionLog: Hashable, Sendable {
    public private(set) var events: [SessionEvent]

    /// An empty log. Events arrive through `record` and `recordEdit`.
    public init() {
        self.events = []
    }

    /// Internal on purpose: tests build logs directly, integrations should not.
    init(_ events: [SessionEvent]) {
        self.events = events
    }

    mutating func append(_ event: SessionEvent) {
        events.append(event)
    }

    /// Index of the most recent edit, or nil if the agent edited nothing.
    public var lastEditIndex: Int? {
        events.lastIndex { if case .edit = $0 { return true } else { return false } }
    }

    /// The file touched by the most recent edit, for feedback messages.
    public var lastEditedFile: String? {
        guard let index = lastEditIndex, case .edit(let file) = events[index] else { return nil }
        return file
    }

    /// All tool runs with their positions, oldest first.
    public var runs: [(index: Int, run: ToolRun)] {
        events.enumerated().compactMap { offset, event in
            if case .run(let run) = event { return (offset, run) }
            return nil
        }
    }
}

extension SessionLog {
    /// Records a command the harness actually executed. Returns false (and
    /// records nothing) when the command is not one the parser understands:
    /// unknown tools are not evidence.
    @discardableResult
    public mutating func record(command: String, output: String, exitCode: Int32) -> Bool {
        guard let run = ToolRunParser.parse(command: command, output: output, exitCode: exitCode) else { return false }
        append(.run(run))
        return true
    }

    public mutating func recordEdit(_ file: String) {
        append(.edit(file: file))
    }
}
