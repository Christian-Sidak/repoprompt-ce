import Darwin
import Foundation
import RepoPromptShared

/// `repoprompt-mcp diagnostics terminal-summary [--since-hours N]`
///
/// Prints a counts-only JSON summary of local MCP terminal records (proxy and app layers) so the
/// field-failure taxonomy can be measured without sharing record contents. Read-only; no app
/// connection, network, or TTY is required.
enum MCPDiagnosticsCommand {
    static let usage = "usage: repoprompt-mcp diagnostics terminal-summary [--since-hours N]"
    static let usageExitCode: Int32 = 64

    static func run(
        arguments: [String],
        eventsDirectory: URL = MCPFilesystemConstants.eventsDirectoryURL(),
        now: Date = Date(),
        output: (String) -> Void = { print($0) },
        errorOutput: (String) -> Void = { fputs($0 + "\n", stderr) }
    ) -> Int32 {
        guard arguments.first == "terminal-summary" else {
            errorOutput(usage)
            return usageExitCode
        }
        var since: Date?
        var remaining = arguments.dropFirst()
        while let argument = remaining.popFirst() {
            guard argument == "--since-hours",
                  let raw = remaining.popFirst(),
                  let hours = Double(raw), hours.isFinite, hours > 0
            else {
                errorOutput(usage)
                return usageExitCode
            }
            since = now.addingTimeInterval(-hours * 3600)
        }

        let summary = MCPTerminalRecordSummary.summarize(directory: eventsDirectory, since: since)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(summary), let text = String(data: data, encoding: .utf8) else {
            errorOutput("repoprompt-mcp diagnostics: could not encode the summary")
            return 1
        }
        output(text)
        return 0
    }
}
