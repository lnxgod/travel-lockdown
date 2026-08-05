import Foundation

extension SnapshotModelRegistry {
    static var travelLockdown: SnapshotModelRegistry {
        var registry = SnapshotModelRegistry()
        registry.register(BluetoothSnapshot.self, for: .bluetooth)
        registry.register(ContinuitySnapshot.self, for: .continuity)
        registry.register(WiFiPolicySnapshot.self, for: .wifiPolicy)
        registry.register(IngressSnapshot.self, for: .ingress)
        registry.register(WakeSnapshot.self, for: .wake)
        return registry
    }
}

struct CoordinatorResult: Equatable, Sendable {
    let status: LockdownStatus
    let dryRunPlan: DryRunPlan?
}

enum CoordinatorError: Error, Equatable {
    case transactionInProgress
    case baselineControlSetMismatch
    case baselineRemovalFailed
}

protocol LockdownCoordinating: Sendable {
    func enable(dryRun: Bool) async throws -> CoordinatorResult
    func restore() async throws -> RestoreResult
    func status() async -> LockdownStatus
    func hasRecoveryState() async -> Bool
}

actor LockdownCoordinator: LockdownCoordinating {
    private let controls: [AnyLockdownControl]
    private let baselineStore: BaselineStore
    private var isTransactionInProgress = false

    init<Control: LockdownControl>(
        controls: [Control],
        baselineStore: BaselineStore = BaselineStore(modelRegistry: .travelLockdown)
    ) {
        self.controls = controls.map(AnyLockdownControl.init)
        self.baselineStore = baselineStore
    }

    func enable(dryRun: Bool) async throws -> CoordinatorResult {
        if dryRun {
            var changes: [PlannedChange] = []
            for control in controls {
                changes.append(
                    contentsOf: try await control.plan(from: .empty(for: control.id))
                )
            }
            return CoordinatorResult(
                status: .make(controls: []),
                dryRunPlan: DryRunPlan(changes: changes)
            )
        }

        try beginTransaction()
        defer { finishTransaction() }
        let baselineTransaction = try baselineStore.beginExclusiveTransaction()
        defer { baselineTransaction.release() }

        if baselineTransaction.exists {
            try validateControlSet(in: baselineTransaction.load())
        } else {
            var snapshots: [ControlSnapshot] = []
            for control in controls {
                snapshots.append(try await control.capture())
            }

            try baselineTransaction.save(
                LockdownBaseline(version: 1, capturedAt: .now, snapshots: snapshots)
            )
        }

        var statuses: [ControlStatus] = []
        for control in controls {
            do {
                try await control.apply()
            } catch {
                _ = try? await control.verify()
                statuses.append(failedStatus(for: control.id, operation: "apply"))
                continue
            }

            do {
                statuses.append(try await control.verify())
            } catch {
                statuses.append(failedStatus(for: control.id, operation: "verification"))
            }
        }

        return CoordinatorResult(
            status: .make(controls: statuses),
            dryRunPlan: nil
        )
    }

    func restore() async throws -> RestoreResult {
        try beginTransaction()
        defer { finishTransaction() }
        let baselineTransaction = try baselineStore.beginExclusiveTransaction()
        defer { baselineTransaction.release() }

        let baseline = try baselineTransaction.load()
        try validateControlSet(in: baseline)
        let expectedIDs = Set(baseline.snapshots.map(\.id))
        var statuses: [RestorationStatus] = []

        for control in controls.reversed() {
            guard let snapshot = baseline.snapshots.first(where: { $0.id == control.id }) else {
                continue
            }

            do {
                try await control.restore(from: snapshot)
            } catch {
                _ = try? await control.verifyRestored(from: snapshot)
                statuses.append(
                    failedRestorationStatus(for: control.id, operation: "restore")
                )
                continue
            }

            do {
                statuses.append(try await control.verifyRestored(from: snapshot))
            } catch {
                statuses.append(
                    failedRestorationStatus(for: control.id, operation: "verification")
                )
            }
        }

        let result = RestoreResult(expectedIDs: expectedIDs, statuses: statuses)
        if result.isFullyRestored {
            guard try baselineTransaction.removeAfterVerifiedRestore(result, matching: baseline) else {
                throw CoordinatorError.baselineRemovalFailed
            }
        }
        return result
    }

    func status() async -> LockdownStatus {
        var statuses: [ControlStatus] = []
        for control in controls {
            do {
                statuses.append(try await control.verify())
            } catch {
                statuses.append(failedStatus(for: control.id, operation: "verification"))
            }
        }
        return .make(controls: statuses)
    }

    func hasRecoveryState() async -> Bool {
        baselineStore.exists
    }

    private func beginTransaction() throws {
        guard !isTransactionInProgress else {
            throw CoordinatorError.transactionInProgress
        }
        isTransactionInProgress = true
    }

    private func finishTransaction() {
        isTransactionInProgress = false
    }

    private func validateControlSet(in baseline: LockdownBaseline) throws {
        let registeredIDs = controls.map(\.id)
        let snapshotIDs = baseline.snapshots.map(\.id)
        guard Set(registeredIDs).count == registeredIDs.count,
              Set(snapshotIDs).count == snapshotIDs.count,
              Set(snapshotIDs) == Set(registeredIDs) else {
            throw CoordinatorError.baselineControlSetMismatch
        }
    }

    private func failedStatus(for id: ControlID, operation: String) -> ControlStatus {
        ControlStatus(
            id: id,
            verification: .failed,
            detail: "Lockdown control \(operation) failed"
        )
    }

    private func failedRestorationStatus(
        for id: ControlID,
        operation: String
    ) -> RestorationStatus {
        RestorationStatus(
            id: id,
            matchesSnapshot: false,
            detail: "Baseline restoration \(operation) failed"
        )
    }
}
