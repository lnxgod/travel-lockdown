import Foundation

struct WakeSnapshot: DeclaredNonSecretSnapshotModel, Equatable {
    static let snapshotModelID = "TravelLockdown.wake.v1"

    let wakeForNetworkAccess: Bool
}

enum WakeControlError: Error, Equatable {
    case commandFailed
    case readbackUnavailable
}

struct WakeControl: LockdownControl {
    let id = ControlID.wake

    private let runner: any CommandRunning
    private let privilegedRunner: any AuthorizedCommandRunning

    init(
        runner: any CommandRunning,
        privilegedRunner: any AuthorizedCommandRunning = AuthorizationServicesCommandRunner()
    ) {
        self.runner = runner
        self.privilegedRunner = privilegedRunner
    }

    func capture() async throws -> ControlSnapshot {
        guard let wakeForNetworkAccess = readWakeForNetworkAccess() else {
            throw WakeControlError.readbackUnavailable
        }
        return try ControlSnapshot.capturing(
            WakeSnapshot(wakeForNetworkAccess: wakeForNetworkAccess),
            for: id
        )
    }

    func plan(from snapshot: ControlSnapshot) async throws -> [PlannedChange] {
        [
            PlannedChange(
                control: id,
                summary: "Turn wake for network access off",
                sensitivity: .public
            )
        ]
    }

    func apply() async throws {
        try execute(.wakeForNetworkAccessOff)
    }

    func verify() async throws -> ControlStatus {
        guard let enabled = readWakeForNetworkAccess() else {
            return ControlStatus(
                id: id,
                verification: .unavailable,
                detail: "Wake for network access readback is unavailable"
            )
        }
        return ControlStatus(
            id: id,
            verification: enabled ? .nonCompliant : .compliant,
            detail: enabled
                ? "Wake for network access is on"
                : "Wake for network access is off"
        )
    }

    func restore(from snapshot: ControlSnapshot) async throws {
        let captured = try snapshot.decoded(as: WakeSnapshot.self, for: id)
        try execute(
            captured.wakeForNetworkAccess
                ? .wakeForNetworkAccessOn
                : .wakeForNetworkAccessOff
        )
    }

    func verifyRestored(from snapshot: ControlSnapshot) async throws -> RestorationStatus {
        let captured = try snapshot.decoded(as: WakeSnapshot.self, for: id)
        let matches = readWakeForNetworkAccess() == captured.wakeForNetworkAccess
        return RestorationStatus(
            id: id,
            matchesSnapshot: matches,
            detail: matches
                ? "Wake setting matches the captured baseline"
                : "Wake setting does not match the captured baseline"
        )
    }

    private func execute(_ command: PrivilegedCommand) throws {
        let result = try privilegedRunner.run(command)
        if let exitCode = result.exitCode {
            guard exitCode == 0 else {
                throw WakeControlError.commandFailed
            }
            return
        }
        let expected = command == .wakeForNetworkAccessOn
        guard readWakeForNetworkAccess() == expected else {
            throw WakeControlError.readbackUnavailable
        }
    }

    private func readWakeForNetworkAccess() -> Bool? {
        guard let result = try? runner.run(executable: "/usr/bin/pmset", arguments: ["-g"]),
              result.exitCode == 0 else {
            return nil
        }
        return switch StatusReaders.wake(result.stdout) {
        case .compliant:
            false
        case .nonCompliant:
            true
        case .unavailable, .failed:
            nil
        }
    }
}
