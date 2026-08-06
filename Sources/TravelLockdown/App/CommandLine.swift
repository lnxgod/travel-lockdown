import AppKit

enum CommandLineMode: Equatable {
    case menuBar
    case statusDryRun
    case reviewRecovery
    case prepareRecovery(profile: RecoverySetupProfile, reviewToken: String)
    case restore

    static func parse(_ arguments: [String]) -> CommandLineMode? {
        let values = Array(arguments.dropFirst())
        if values.count == 14,
           values[0] == "--prepare-recovery",
           values[1] == "--review-token",
           values[3] == "--airplay",
           values[5] == "--airplay-access",
           values[7] == "--airplay-password",
           values[9] == "--hotspot",
           values[11] == "--sharing",
           values[13] == "--confirmed",
           values[2].count == 64,
           values[2].allSatisfy({ $0.isHexDigit }) {
            return Self.recoveryProfile(
                airPlay: values[4],
                access: values[6],
                password: values[8],
                hotspot: values[10],
                sharing: values[12]
            ).map {
                CommandLineMode.prepareRecovery(profile: $0, reviewToken: values[2].lowercased())
            }
        }

        return switch values {
        case ["--status", "--dry-run"]:
            .statusDryRun
        case ["--review-recovery"]:
            .reviewRecovery
        case ["--restore"]:
            .restore
        case []:
            .menuBar
        default:
            nil
        }
    }

    private static func recoveryProfile(
        airPlay: String,
        access: String,
        password: String,
        hotspot: String,
        sharing: String
    ) -> RecoverySetupProfile? {
        let airPlayEnabled: Bool
        switch airPlay {
        case "on": airPlayEnabled = true
        case "off": airPlayEnabled = false
        default: return nil
        }

        let airPlayAccess: AirPlayReceiverAccess
        switch access {
        case "current-user": airPlayAccess = .currentUser
        case "same-network": airPlayAccess = .anyoneOnSameNetwork
        case "everyone": airPlayAccess = .everyone
        default: return nil
        }

        let requiresPassword: Bool
        switch password {
        case "required": requiresPassword = true
        case "not-required": requiresPassword = false
        default: return nil
        }

        let hotspotMode: PersonalHotspotAutoJoinMode
        switch hotspot {
        case "never": hotspotMode = .never
        case "ask-to-join": hotspotMode = .askToJoin
        case "automatic": hotspotMode = .automatic
        default: return nil
        }

        let sharingEnabled: Bool
        switch sharing {
        case "all-off": sharingEnabled = false
        case "all-on": sharingEnabled = true
        default: return nil
        }

        return RecoverySetupProfile(
            airPlayReceiver: AirPlayReceiverBaseline(
                isEnabled: airPlayEnabled,
                access: airPlayAccess,
                requiresPassword: requiresPassword
            ),
            personalHotspotAutoJoin: hotspotMode,
            sharingServices: Dictionary(
                uniqueKeysWithValues: SharingService.allCases.map {
                    ($0, sharingEnabled)
                }
            )
        )
    }
}

@MainActor
enum RecoveryReviewCommandLine {
    static func run(
        review: () async throws -> RecoverySetupReview,
        stdout: (String) -> Void = { print($0, terminator: "") },
        stderr: (String) -> Void = { value in
            try? FileHandle.standardError.write(contentsOf: Data(value.utf8))
        }
    ) async -> Int32 {
        do {
            let result = try await review()
            if result.purpose == .legacyReplacement {
                stdout(
                    "Legacy recovery: automatic values are verified; review the missing manual values below.\n"
                )
            }
            for item in result.items {
                stdout("\(item.control.rawValue): \(item.summary)\n")
            }
            stdout("Review token: \(result.token)\n")
            return 0
        } catch RecoverySetupError.captureFailed(let control) {
            stderr("Recovery review unavailable for \(control.rawValue); no settings changed.\n")
            return 1
        } catch RecoverySetupError.normalPostureRequired {
            stderr(
                "Recovery review stopped: current settings are locked or ambiguous; "
                    + "restore a clearly normal posture first. No settings changed.\n"
            )
            return 1
        } catch RecoverySetupError.legacyRecoveryNotEligible {
            stderr(
                "Legacy recovery is not ready to replace; the original snapshot was kept.\n"
            )
            return 1
        } catch {
            stderr("Recovery snapshot review failed without changing settings.\n")
            return 1
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

@MainActor
enum RecoverySetupCommandLine {
    static func run(
        profile: RecoverySetupProfile,
        reviewToken: String,
        prepare: (RecoverySetupProfile, String) async throws -> RecoverySetupResult,
        stdout: (String) -> Void = { print($0, terminator: "") },
        stderr: (String) -> Void = { value in
            try? FileHandle.standardError.write(contentsOf: Data(value.utf8))
        }
    ) async -> Int32 {
        do {
            let result = try await prepare(profile, reviewToken)
            guard result.controlCount == ControlID.allCases.count else {
                stderr("Recovery snapshot verification failed.\n")
                return 1
            }
            stdout("Recovery snapshot prepared and verified.\n")
            return 0
        } catch {
            stderr("Recovery snapshot setup failed without changing settings.\n")
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
