#if canImport(SwiftUI)
import SwiftUI

/// Replays the sample session: the report the agent tried to stop with, the
/// verdict on every claim, and the Stop-hook reason it would have been handed.
@available(iOS 17.0, macOS 14.0, *)
public struct EvidenceContractDemoView: View {
    public enum Attempt: String, CaseIterable, Identifiable {
        case first = "First attempt"
        case revised = "After feedback"
        public var id: String { rawValue }
    }

    @State private var attempt: Attempt = .first
    private let evaluator = ContractEvaluator()

    public init() {}

    private var log: SessionLog {
        attempt == .first ? SampleSession.firstAttempt : SampleSession.afterFeedback
    }

    private var report: ContractReport {
        evaluator.evaluate(report: attempt == .first ? SampleSession.report : SampleSession.revisedReport, log: log)
    }

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Attempt", selection: $attempt) {
                        ForEach(Attempt.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    summary
                }

                Section("Claims in the final report") {
                    ForEach(report.results) { result in
                        ClaimRow(result: result)
                    }
                }

                Section("What the harness saw") {
                    ForEach(Array(log.events.enumerated()), id: \.offset) { index, event in
                        EventRow(index: index, event: event, isLastEdit: index == log.lastEditIndex)
                    }
                }

                if let reason = report.stopHookReason {
                    Section("Stop hook reason (fed back to the agent)") {
                        Text(reason)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("Evidence Contract")
        }
    }

    private var summary: some View {
        HStack {
            Image(systemName: report.isSatisfied ? "checkmark.seal.fill" : "xmark.octagon.fill")
                .foregroundStyle(report.isSatisfied ? Color.green : Color.red)
                .font(.title2)
            VStack(alignment: .leading) {
                Text(report.isSatisfied ? "Contract satisfied" : "Stop blocked")
                    .font(.headline)
                Text("\(report.rejected.count) of \(report.checkable.count) checkable claims rejected")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

@available(iOS 17.0, macOS 14.0, *)
private struct ClaimRow: View {
    let result: ClaimResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(result.verdict.label.uppercased())
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(color.opacity(0.18), in: Capsule())
                    .foregroundStyle(color)
                Text(result.claim.sentence)
                    .font(.subheadline)
            }
            if let move = result.nextMove {
                Text(move)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var color: Color {
        switch result.verdict {
        case .backed: return .green
        case .notProvable: return .gray
        case .contradicted: return .red
        default: return .orange
        }
    }
}

@available(iOS 17.0, macOS 14.0, *)
private struct EventRow: View {
    let index: Int
    let event: SessionEvent
    let isLastEdit: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(index)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .trailing)
            Text(line)
                .font(.system(.caption, design: .monospaced))
            if isLastEdit {
                Text("LAST EDIT")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.orange)
            }
        }
    }

    private var line: String {
        switch event {
        case .edit(let file):
            return "edit \(file)"
        case .run(let run):
            switch run.kind {
            case .test(_, let executed, let failed):
                let count = executed.map { String($0) } ?? "?"
                return "\(run.command) -> exit \(run.exitCode), \(count) run, \(failed.count) failed"
            case .build:
                return "\(run.command) -> exit \(run.exitCode)"
            case .search(_, _, let hits):
                return "\(run.command) -> \(hits) hit\(hits == 1 ? "" : "s")"
            }
        }
    }
}
#endif
