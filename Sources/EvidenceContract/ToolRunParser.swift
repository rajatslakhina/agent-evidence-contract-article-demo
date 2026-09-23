import Foundation

/// Turns a raw command, its output and its exit code into a `ToolRun`.
///
/// This is the only door into the evidence log, and it reads what the harness
/// captured, not what the agent quoted. Understands `swift test`, `swift build`,
/// `xcodebuild`, `rg` and `grep`; anything else returns nil and is not evidence.
public enum ToolRunParser {
    public static func parse(command: String, output: String, exitCode: Int32) -> ToolRun? {
        let tokens = tokenize(command)
        guard let tool = tokens.first else { return nil }

        switch tool {
        case "swift":
            if tokens.contains("test") {
                let filters = values(after: "--filter", in: tokens)
                return testRun(command, exitCode, filters.isEmpty ? .fullSuite : .filtered(filters), output)
            }
            if tokens.contains("build") {
                return ToolRun(command: command, exitCode: exitCode, kind: .build)
            }
            return nil
        case "xcodebuild":
            if tokens.contains("test") {
                // -only-testing:Target/Class/method -> Class/method. A bare
                // -only-testing:Target is kept as-is and will only cover claims
                // that name it the same way.
                let filters = tokens
                    .filter { $0.hasPrefix("-only-testing:") }
                    .map { String($0.dropFirst("-only-testing:".count)) }
                    .map { $0.split(separator: "/").count > 1
                        ? $0.split(separator: "/").dropFirst().joined(separator: "/") : $0 }
                return testRun(command, exitCode, filters.isEmpty ? .fullSuite : .filtered(filters), output)
            }
            return ToolRun(command: command, exitCode: exitCode, kind: .build)
        case "rg", "grep":
            guard let pattern = tokens.dropFirst().first(where: { !$0.hasPrefix("-") }) else { return nil }
            let hits = output.split(whereSeparator: \.isNewline)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
            return ToolRun(command: command, exitCode: exitCode,
                           kind: .search(pattern: pattern.replacingOccurrences(of: #"\b"#, with: ""), hits: hits))
        default:
            return nil
        }
    }

    private static func testRun(_ command: String, _ exitCode: Int32, _ scope: TestScope, _ output: String) -> ToolRun {
        ToolRun(command: command, exitCode: exitCode,
                kind: .test(scope: scope, executed: executedCount(in: output), failedTests: failedTests(in: output)))
    }

    /// The last XCTest summary line is the outermost suite's total.
    static func executedCount(in output: String) -> Int? {
        let regex = try! NSRegularExpression(pattern: #"Executed (\d+) tests?, with \d+ failures?"#)
        let range = NSRange(output.startIndex..., in: output)
        guard let match = regex.matches(in: output, range: range).last,
              let r = Range(match.range(at: 1), in: output) else { return nil }
        return Int(output[r])
    }

    /// Linux prints `Test Case 'Class.method' failed`; Darwin prints
    /// `Test Case '-[Module.Class method]' failed`. Both become `Class/method`.
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

    private static func values(after flag: String, in tokens: [String]) -> [String] {
        var result: [String] = []
        for (index, token) in tokens.enumerated() where token == flag {
            let next = index + 1
            if next < tokens.count { result.append(tokens[next]) }
        }
        return result
    }
}
