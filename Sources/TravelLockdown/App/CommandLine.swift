import AppKit

enum CommandLineMode: Equatable {
    case menuBar
    case statusDryRun
    case restore

    static func parse(_ arguments: [String]) -> CommandLineMode? {
        switch Array(arguments.dropFirst()) {
        case ["--status", "--dry-run"]:
            .statusDryRun
        case ["--restore"]:
            .restore
        case []:
            .menuBar
        default:
            nil
        }
    }
}

enum ReadOnlyCommandLine {
    static func printStatus(
        using runner: any CommandRunning,
        writeLine: (String) -> Void = { print($0) }
    ) {
        for verdict in ReadOnlyStatusCollector(runner: runner).collect() {
            writeLine("\(verdict.component.rawValue): \(verdict.verification.rawValue)")
        }
    }
}

enum RestoreCommandLine {
    @MainActor
    static func run(
        confirm: () -> Bool,
        restore: () async throws -> RestoreResult,
        stdout: (String) -> Void = { print($0, terminator: "") },
        stderr: (String) -> Void = { value in
            try? FileHandle.standardError.write(contentsOf: Data(value.utf8))
        }
    ) async -> Int32 {
        guard confirm() else {
            stderr("Restore cancelled.\n")
            return 1
        }
        do {
            let result = try await restore()
            guard result.isFullyRestored else {
                let statusIDs = Set(result.statuses.map(\.id))
                let incompleteIDs = Set(
                    result.statuses.filter { !$0.matchesSnapshot }.map(\.id)
                ).union(result.expectedIDs.subtracting(statusIDs))
                if incompleteIDs.isEmpty {
                    stderr("Recovery incomplete.\n")
                } else {
                    for id in incompleteIDs.sorted(by: { $0.rawValue < $1.rawValue }) {
                        stderr("Recovery incomplete: \(id.rawValue)\n")
                    }
                }
                return 1
            }
            stdout("Restore completed and verified.\n")
            return 0
        } catch {
            stderr("Restore failed.\n")
            return 1
        }
    }
}

enum RestoreApplication {
    @MainActor
    static func run(
        coordinator: any LockdownCoordinating,
        confirm: () -> Bool = { NativeRestoreConfirmation.confirm() },
        stdout: (String) -> Void = { print($0, terminator: "") },
        stderr: (String) -> Void = { value in
            try? FileHandle.standardError.write(contentsOf: Data(value.utf8))
        }
    ) async -> Int32 {
        await RestoreCommandLine.run(
            confirm: confirm,
            restore: { try await coordinator.restore() },
            stdout: stdout,
            stderr: stderr
        )
    }
}

struct RestoreConfirmationPrompt: Equatable, Sendable {
    let title: String
    let message: String
    let confirmButton: String

    static let standard = RestoreConfirmationPrompt(
        title: "Restore Normal State?",
        message: "Travel Lockdown will restore settings from the captured baseline. "
            + "Bluetooth, continuity, Wi-Fi behavior, firewall, sharing, and wake settings may change. "
            + "If recovery is incomplete, keep the app and baseline installed, follow the attention "
            + "state, and retry restoration after completing the indicated System Settings steps.",
        confirmButton: "Restore Normal State"
    )
}

enum NativeRestoreConfirmation {
    @MainActor
    static func confirm(_ prompt: RestoreConfirmationPrompt = .standard) -> Bool {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = prompt.title
        alert.informativeText = prompt.message
        alert.addButton(withTitle: prompt.confirmButton)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
