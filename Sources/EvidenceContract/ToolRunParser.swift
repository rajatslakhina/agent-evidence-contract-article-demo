import Foundation

/// Turns a raw command, its output and its exit code into a `ToolRun`.
///
/// `SessionLog.record(command:output:exitCode:)` calls this, and it is the only
/// public way to put a tool run into the log. Nothing in the type stops a caller
/// feeding it invented output, so wire it to commands your harness executed.
/// Understands `swift test`, `swift build`, `xcodebuild`, `rg` and `grep`;
/// anything else returns nil and is not evidence. When in doubt it records the
/// run as narrower than it might have been, never wider.
public enum ToolRunParser {
    public static func parse(command: String, output: String, exitCode: Int32) -> ToolRun? {
        let tokens = tokenize(command)
        guard let tool = tokens.first else { return nil }

        switch tool {
        case "swift":
            if tokens.contains("test") {
                let filters = values(of: "--filter", in: tokens)
                // --skip narrows a run in ways a name cannot express, so a run
                // that skipped anything backs no claim by scope.
                let skipped = !values(of: "--skip", in: tokens).isEmpty
                let scope: TestScope = skipped ? .filtered([]) : (filters.isEmpty ? .fullSuite : .filtered(filters))
                return testRun(command, exitCode, scope, output)
            }
            if tokens.contains("build") {
                return ToolRun(command: command, exitCode: exitCode, kind: .build)
            }
            return nil
        case "xcodebuild":
            let nonBuilding: Set<String> = ["-list", "-showBuildSettings", "-version", "-showsdks",
                                            "-resolvePackageDependencies", "-showTestPlans", "-showdestinations"]
            if tokens.contains(where: { nonBuilding.contains($0) }) { return nil }
            if tokens.contains("test") || tokens.contains("test-without-building") {
                // -only-testing:Target/Class/method -> Class/method. A bare
                // -only-testing:Target is kept as-is and will only cover claims
                // that name it the same way. -skip-testing narrows like --skip.
                let filters = tokens
                    .filter { $0.hasPrefix("-only-testing:") }
                    .map { String($0.dropFirst("-only-testing:".count)) }
                    .map { $0.split(separator: "/").count > 1
                        ? $0.split(separator: "/").dropFirst().joined(separator: "/") : $0 }
                let skipped = tokens.contains { $0.hasPrefix("-skip-testing:") }
                let scope: TestScope = skipped ? .filtered([]) : (filters.isEmpty ? .fullSuite : .filtered(filters))
                return testRun(command, exitCode, scope, output)
            }
            // Default action is build. `clean` alone, or `docbuild`, builds nothing you can claim.
            let building: Set<String> = ["build", "build-for-testing", "archive", "install"]
            let otherActions: Set<String> = ["clean", "analyze", "docbuild", "installsrc"]
            if !tokens.contains(where: { building.contains($0) }) && tokens.contains(where: { otherActions.contains($0) }) {
                return nil
            }
            return ToolRun(command: command, exitCode: exitCode, kind: .build)
        case "rg", "grep":
            return searchRun(command, tokens, output, exitCode)
        default:
            return nil
        }
    }

    // MARK: - Search

    private static let valueFlags: Set<String> = [
        "-e", "--regexp", "-t", "--type", "-T", "--type-not", "-g", "--glob",
        "-m", "--max-count", "-A", "-B", "-C", "--include", "--exclude"
    ]
    private static let narrowingFlags: Set<String> = [
        "-w", "--word-regexp", "-t", "--type", "-T", "--type-not", "-g", "--glob",
        "--include", "--exclude", "-m", "--max-count"
    ]

    private static func searchRun(_ command: String, _ tokens: [String], _ output: String, _ exitCode: Int32) -> ToolRun? {
        var pattern: String?
        var paths: [String] = []
        var narrowed = false
        var index = 1
        while index < tokens.count {
            let token = tokens[index]
            let flag = token.split(separator: "=", maxSplits: 1).first.map(String.init) ?? token
            if token.hasPrefix("-") {
                if narrowingFlags.contains(flag) { narrowed = true }
                if flag == "-e" || flag == "--regexp" {
                    if token.contains("=") {
                        pattern = String(token.split(separator: "=", maxSplits: 1)[1])
                    } else if index + 1 < tokens.count {
                        pattern = tokens[index + 1]
                    }
                }
                if valueFlags.contains(token) { index += 1 }
            } else if pattern == nil {
                pattern = token
            } else {
                paths.append(token)
            }
            index += 1
        }
        guard let pattern else { return nil }
        // Searching a subdirectory is a narrower claim than "no references".
        if paths.contains(where: { $0 != "." && $0 != "./" }) { narrowed = true }
        var hits = output.split(whereSeparator: \.isNewline)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        // rg and grep exit 0 only when something matched, even with -q.
        if exitCode == 0 && hits == 0 { hits = 1 }
        return ToolRun(command: command, exitCode: exitCode,
                       kind: .search(pattern: pattern, narrowed: narrowed, hits: hits))
    }

    // MARK: - Tests

    private static func testRun(_ command: String, _ exitCode: Int32, _ scope: TestScope, _ output: String) -> ToolRun {
        let executed = executedCount(in: output)
        var failed = failedTests(in: output)
        // A trap (fatalError, out-of-range index) kills the XCTest process
        // before it prints a failure line or a summary. Under a filter naming
        // exactly one test method, that crash is that test failing.
        if (executed ?? 0) == 0, failed.isEmpty, exitCode != 0, crashed(output),
           case .filtered(let filters) = scope, filters.count == 1,
           let only = filters.first, only.contains("/") {
            failed = [only]
        }
        return ToolRun(command: command, exitCode: exitCode,
                       kind: .test(scope: scope, executed: executed, failedTests: failed))
    }

    /// How `swift test` reports a trapped test process on Linux.
    static func crashed(_ output: String) -> Bool {
        output.contains("Exited with unexpected signal code") || output.contains("Fatal error:")
    }

    /// XCTest's last "Executed N tests" line is its outermost total. Swift
    /// Testing reports its own "Test run with N tests" line. `swift test` runs
    /// both, so the two are added. Nil when neither appears.
    static func executedCount(in output: String) -> Int? {
        let range = NSRange(output.startIndex..., in: output)
        func lastNumber(_ pattern: String) -> Int? {
            let regex = try! NSRegularExpression(pattern: pattern)
            guard let match = regex.matches(in: output, range: range).last,
                  let r = Range(match.range(at: 1), in: output) else { return nil }
            return Int(output[r])
        }
        let xctest = lastNumber(#"Executed (\d+) tests?, with \d+ failures?"#)
        let swiftTesting = lastNumber(#"Test run with (\d+) tests? (?:passed|failed)"#)
        if xctest == nil && swiftTesting == nil { return nil }
        return (xctest ?? 0) + (swiftTesting ?? 0)
    }

    /// Linux prints `Test Case 'Class.method' failed`; Darwin prints
    /// `Test Case '-[Module.Class method]' failed`. Both become `Class/method`.
    /// Swift Testing failures are not named yet.
    static func failedTests(in output: String) -> [String] {
        let regex = try! NSRegularExpression(
            pattern: #"Test Case '(?:-\[(?:\w+\.)?(\w+) (\w+)\]|(\w+)\.(\w+))' failed"#)
        let range = NSRange(output.startIndex..., in: output)
        var names: [String] = []
        for match in regex.matches(in: output, range: range) {
            let groups = (1...4).map { index -> String? in
                guard let r = Range(match.range(at: index), in: output) else { return nil }
                return String(output[r])
            }
            if let cls = groups[0], let method = groups[1] {
                names.append("\(cls)/\(method)")
            } else if let cls = groups[2], let method = groups[3] {
                names.append("\(cls)/\(method)")
            }
        }
        return names
    }

    static func tokenize(_ command: String) -> [String] {
        command.split(separator: " ").map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        }.filter { !$0.isEmpty }
    }

    /// Values for `--flag value` and `--flag=value`.
    static func values(of flag: String, in tokens: [String]) -> [String] {
        var result: [String] = []
        for (index, token) in tokens.enumerated() {
            if token == flag {
                let next = index + 1
                if next < tokens.count { result.append(tokens[next]) }
            } else if token.hasPrefix(flag + "=") {
                result.append(String(token.dropFirst(flag.count + 1)))
            }
        }
        return result
    }
}
