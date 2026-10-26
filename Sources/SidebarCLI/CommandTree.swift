import ArgumentParser

/// Renders a command subtree for help screens.
///
/// ArgumentParser lists only direct subcommands, so each group hides its children from that list
/// (`shouldDisplay: false`) and renders the full subtree here as its discussion instead. Human
/// mode draws an aligned tree trimmed to the terminal width; agent mode prints untrimmed bullets.
enum CommandTree {
    struct Row {
        let label: String
        let abstract: String
    }

    static func render(children: [any ParsableCommand.Type]) -> String {
        let context = CLIContext.current
        if context.isAgent {
            return (["Commands:"] + bullets(children, depth: 0)).joined(separator: "\n")
        }
        let rows = treeRows(children, prefix: "", topLevel: true)
        let labelWidth = rows.map(\.label.count).max() ?? 0
        let lines = rows.map { row in
            // ArgumentParser re-wraps help text and breaks a line that fills the whole width.
            trim("  " + row.label.padding(toLength: labelWidth + 2, withPad: " ", startingAt: 0) + row.abstract, to: context.helpWidth - 1)
        }
        return (["Commands:"] + lines).joined(separator: "\n")
    }

    private static func treeRows(_ commands: [any ParsableCommand.Type], prefix: String, topLevel: Bool) -> [Row] {
        commands.enumerated().flatMap { index, command in
            let configuration = command.configuration
            let isLast = index == commands.count - 1
            let branch = topLevel ? "" : (isLast ? "╰─ " : "├─ ")
            let childPrefix = topLevel ? "" : prefix + (isLast ? "   " : "│  ")
            let row = Row(label: prefix + branch + (configuration.commandName ?? ""), abstract: configuration.abstract)
            return [row] + treeRows(configuration.subcommands, prefix: childPrefix, topLevel: false)
        }
    }

    private static func bullets(_ commands: [any ParsableCommand.Type], depth: Int) -> [String] {
        commands.flatMap { command in
            let configuration = command.configuration
            let line = String(repeating: "  ", count: depth) + "- \(configuration.commandName ?? ""): \(configuration.abstract)"
            return [line] + bullets(configuration.subcommands, depth: depth + 1)
        }
    }

    private static func trim(_ line: String, to width: Int) -> String {
        guard line.count > width, width > 3 else { return line }
        return String(line.prefix(width - 3)) + "..."
    }
}
