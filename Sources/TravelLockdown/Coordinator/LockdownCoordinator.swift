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
    case baselinePreparationFailed
}

protocol LockdownCoordinating: Sendable {
    func enable(dryRun: Bool) async throws -> CoordinatorResult
    func restore() async throws -> RestoreResult
    func status() async -> LockdownStatus
    func hasRecoveryState() async -> Bool
    func recoveryState() async -> RecoveryState
    func reviewRecoverySetup() async throws -> RecoverySetupReview
    func prepareRecovery(
        profile: RecoverySetupProfile,
        reviewToken: String
    ) async throws -> RecoverySetupResult
    func preparedRecoveryMatchesCurrent() async -> Bool?
    func discardPreparedRecovery() async throws
    func completeManualRecovery(
        token: String,
        instructions: [ManualRecoveryInstruction]
    ) async throws -> RestoreResult
}

extension LockdownCoordinating {
    func recoveryState() async -> RecoveryState {
        await hasRecoveryState() ? .active : .none
    }

    func reviewRecoverySetup() async throws -> RecoverySetupReview {
        throw RecoverySetupError.unsupportedByCoordinator
    }

    func prepareRecovery(
        profile: RecoverySetupProfile,
        reviewToken: String
    ) async throws -> RecoverySetupResult {
        throw RecoverySetupError.unsupportedByCoordinator
    }

    func preparedRecoveryMatchesCurrent() async -> Bool? {
        nil
    }

    func discardPreparedRecovery() async throws {
        throw RecoverySetupError.unsupportedByCoordinator
    }

    func completeManualRecovery(
        token: String,
        instructions: [ManualRecoveryInstruction]
    ) async throws -> RestoreResult {
        throw RecoverySetupError.unsupportedByCoordinator
    }
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

        guard baselineTransaction.exists else {
            throw RecoverySetupError.recoveryStateRequired
        }
        let baseline = try baselineTransaction.load()
        try validateControlSet(in: baseline)
        if baseline.recoveryState == .prepared {
            guard try await preparedBaselineMatchesCurrent(baseline) else {
                throw RecoverySetupError.preparedBaselineDrifted
            }
            try baselineTransaction.save(
                LockdownBaseline(
                    version: baseline.version,
                    capturedAt: baseline.capturedAt,
                    snapshots: baseline.snapshots,
                    recoveryState: .active
                )
            )
        } else if baseline.recoveryState != .active {
            throw RecoverySetupError.recoveryStateRequired
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
        guard baseline.recoveryState == .active else {
            throw RecoverySetupError.recoveryStateNotActive
        }
        let expectedIDs = Set(baseline.snapshots.map(\.id))
        var statuses: [RestorationStatus] = []

        for control in controls.reversed() {
            guard let snapshot = baseline.snapshots.first(where: { $0.id == control.id }) else {
                continue
            }

            do {
                try await control.restore(from: snapshot)
            } catch {
                if let verified = try? await control.verifyRestored(from: snapshot),
                   verified.matchesSnapshot {
                    statuses.append(verified)
                } else {
                    statuses.append(
                        failedRestorationStatus(for: control.id, operation: "restore")
                    )
                }
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

        let result = RestoreResult(
            expectedIDs: expectedIDs,
            statuses: statuses,
            recoveryToken: try RecoverySnapshotFingerprint.baseline(baseline)
        )
        if result.isFullyRestored {
            guard try baselineTransaction.prepareAfterVerifiedRestore(result, matching: baseline) else {
                throw CoordinatorError.baselinePreparationFailed
            }
        }
        return result
    }

    func status() async -> LockdownStatus {
        await currentStatus()
    }

    private func currentStatus() async -> LockdownStatus {
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

    func recoveryState() async -> RecoveryState {
        guard baselineStore.exists else {
            return .none
        }
        return (try? baselineStore.load().recoveryState) ?? .active
    }

    func reviewRecoverySetup() async throws -> RecoverySetupReview {
        try beginTransaction()
        defer { finishTransaction() }
        let baselineTransaction = try baselineStore.beginExclusiveTransaction()
        defer { baselineTransaction.release() }

        if baselineTransaction.exists {
            let baseline = try baselineTransaction.load()
            try validateControlSet(in: baseline)
            try await requireLegacyAutomaticRecoveryComplete(baseline)
            return try RecoverySetupReview.make(
                from: baseline.snapshots,
                capturedAt: baseline.capturedAt,
                token: RecoverySnapshotFingerprint.baseline(baseline),
                purpose: .legacyReplacement
            )
        }

        try await requireClearlyNormalPosture()
        let snapshots = try await captureStableSnapshots()
        try await requireClearlyNormalPosture()
        return try RecoverySetupReview.make(from: snapshots)
    }

    func prepareRecovery(
        profile: RecoverySetupProfile,
        reviewToken: String
    ) async throws -> RecoverySetupResult {
        try beginTransaction()
        defer { finishTransaction() }
        let baselineTransaction = try baselineStore.beginExclusiveTransaction()
        defer { baselineTransaction.release() }

        let reviewedProfile = try profile.validated()

        if baselineTransaction.exists {
            let original = try baselineTransaction.load()
            try validateControlSet(in: original)
            try await requireLegacyAutomaticRecoveryComplete(original)
            guard try RecoverySnapshotFingerprint.baseline(original) == reviewToken else {
                throw RecoverySetupError.reviewTokenMismatch
            }

            let candidate = LockdownBaseline(
                version: original.version,
                capturedAt: .now,
                snapshots: try original.snapshots.map(reviewedProfile.reviewing),
                recoveryState: .prepared
            )
            try validateControlSet(in: candidate)
            try baselineTransaction.save(candidate)
            guard try baselineTransaction.load() == candidate else {
                try rollbackLegacyReplacement(
                    candidate: candidate,
                    original: original,
                    transaction: baselineTransaction
                )
                throw RecoverySetupError.savedBaselineMismatch
            }
            do {
                guard try await preparedBaselineMatchesCurrent(candidate) else {
                    throw RecoverySetupError.settingsChangedDuringReview
                }
            } catch {
                try rollbackLegacyReplacement(
                    candidate: candidate,
                    original: original,
                    transaction: baselineTransaction
                )
                throw error
            }
            return RecoverySetupResult(
                capturedAt: candidate.capturedAt,
                controlCount: candidate.snapshots.count
            )
        }

        try await requireClearlyNormalPosture()
        let automaticSnapshots = try await captureStableSnapshots()
        guard try RecoverySnapshotFingerprint.snapshots(automaticSnapshots) == reviewToken else {
            throw RecoverySetupError.reviewTokenMismatch
        }
        try await requireClearlyNormalPosture()
        let snapshots = try automaticSnapshots.map(reviewedProfile.reviewing)
        let baseline = LockdownBaseline(
            version: 1,
            capturedAt: .now,
            snapshots: snapshots,
            recoveryState: .prepared
        )
        try validateControlSet(in: baseline)
        try baselineTransaction.save(baseline)
        guard try baselineTransaction.load() == baseline else {
            throw RecoverySetupError.savedBaselineMismatch
        }
        do {
            let verifiedAutomaticSnapshots = try await captureStableSnapshots()
            let verifiedSnapshots = try verifiedAutomaticSnapshots.map(reviewedProfile.reviewing)
            guard verifiedSnapshots == baseline.snapshots else {
                throw RecoverySetupError.settingsChangedDuringReview
            }
            try await requireClearlyNormalPosture()
        } catch {
            guard try baselineTransaction.removePrepared(matching: baseline) else {
                throw RecoverySetupError.savedBaselineMismatch
            }
            throw error
        }
        return RecoverySetupResult(
            capturedAt: baseline.capturedAt,
            controlCount: baseline.snapshots.count
        )
    }

    func preparedRecoveryMatchesCurrent() async -> Bool? {
        do {
            try beginTransaction()
        } catch {
            return nil
        }
        defer { finishTransaction() }
        do {
            let baselineTransaction = try baselineStore.beginExclusiveTransaction()
            defer { baselineTransaction.release() }
            guard baselineTransaction.exists else { return nil }
            let baseline = try baselineTransaction.load()
            try validateControlSet(in: baseline)
            guard baseline.recoveryState == .prepared else { return nil }
            return try await preparedBaselineMatchesCurrent(baseline)
        } catch {
            return false
        }
    }

    func discardPreparedRecovery() async throws {
        try beginTransaction()
        defer { finishTransaction() }
        let baselineTransaction = try baselineStore.beginExclusiveTransaction()
        defer { baselineTransaction.release() }
        let baseline = try baselineTransaction.load()
        try validateControlSet(in: baseline)
        guard baseline.recoveryState == .prepared else {
            throw RecoverySetupError.recoveryStateNotActive
        }
        guard try baselineTransaction.removePrepared(matching: baseline) else {
            throw RecoverySetupError.savedBaselineMismatch
        }
    }

    func completeManualRecovery(
        token: String,
        instructions: [ManualRecoveryInstruction]
    ) async throws -> RestoreResult {
        try beginTransaction()
        defer { finishTransaction() }
        let baselineTransaction = try baselineStore.beginExclusiveTransaction()
        defer { baselineTransaction.release() }

        let baseline = try baselineTransaction.load()
        try validateControlSet(in: baseline)
        guard baseline.recoveryState == .active else {
            throw RecoverySetupError.manualRecoveryNotConfirmable
        }
        guard try RecoverySnapshotFingerprint.baseline(baseline) == token,
              !instructions.isEmpty,
              instructions.allSatisfy({ $0.confirmation == .userAttestation }) else {
            throw RecoverySetupError.manualRecoveryAttestationMismatch
        }

        let expectedIDs = Set(baseline.snapshots.map(\.id))
        var rawStatuses: [RestorationStatus] = []
        for control in controls.reversed() {
            guard let snapshot = baseline.snapshots.first(where: { $0.id == control.id }) else {
                continue
            }
            let status: RestorationStatus
            do {
                status = try await control.verifyRestored(from: snapshot)
            } catch {
                rawStatuses.append(
                    failedRestorationStatus(for: control.id, operation: "verification")
                )
                continue
            }
            rawStatuses.append(status)
        }

        guard rawStatuses.compactMap(\.manualRecovery) == instructions else {
            throw RecoverySetupError.manualRecoveryAttestationMismatch
        }
        let statuses = rawStatuses.map { status in
            if let manualRecovery = status.manualRecovery,
               status.matchesSnapshot,
               manualRecovery.confirmation == .userAttestation {
                return RestorationStatus(
                    id: status.id,
                    matchesSnapshot: true,
                    detail: "Automatic settings verified and manual recovery confirmed"
                )
            }
            return status
        }

        let result = RestoreResult(
            expectedIDs: expectedIDs,
            statuses: statuses,
            recoveryToken: token
        )
        guard result.isFullyRestored else {
            return result
        }
        guard try baselineTransaction.prepareAfterVerifiedRestore(result, matching: baseline) else {
            throw CoordinatorError.baselinePreparationFailed
        }
        return result
    }

    private func captureStableSnapshots() async throws -> [ControlSnapshot] {
        let first = try await captureSnapshots()
        let second = try await captureSnapshots()
        guard first == second else {
            throw RecoverySetupError.settingsChangedDuringReview
        }
        return second
    }

    private func captureSnapshots() async throws -> [ControlSnapshot] {
        var snapshots: [ControlSnapshot] = []
        for control in controls {
            do {
                snapshots.append(try await control.capture())
            } catch {
                throw RecoverySetupError.captureFailed(control.id)
            }
        }
        return snapshots
    }

    private func preparedBaselineMatchesCurrent(_ baseline: LockdownBaseline) async throws -> Bool {
        guard baseline.recoveryState == .prepared else { return false }
        let profile = try RecoverySetupProfile.reviewedProfile(in: baseline.snapshots)
        let currentAutomaticSnapshots = try await captureStableSnapshots()
        let current = try currentAutomaticSnapshots.map(profile.reviewing)
        return current == baseline.snapshots
    }

    private func requireClearlyNormalPosture() async throws {
        guard await currentStatus().isClearlyUnlocked else {
            throw RecoverySetupError.normalPostureRequired
        }
    }

    private func requireLegacyAutomaticRecoveryComplete(
        _ baseline: LockdownBaseline
    ) async throws {
        guard baseline.recoveryState == .active,
              (try? RecoverySetupProfile.reviewedProfile(in: baseline.snapshots)) == nil else {
            throw RecoverySetupError.legacyRecoveryNotEligible
        }

        var statuses: [RestorationStatus] = []
        for control in controls.reversed() {
            guard let snapshot = baseline.snapshots.first(where: { $0.id == control.id }) else {
                throw RecoverySetupError.legacyRecoveryNotEligible
            }
            do {
                statuses.append(try await control.verifyRestored(from: snapshot))
            } catch {
                throw RecoverySetupError.legacyRecoveryNotEligible
            }
        }

        let expectedIDs = Set(baseline.snapshots.map(\.id))
        let manualStatuses = statuses.filter { $0.manualRecovery != nil }
        guard statuses.count == expectedIDs.count,
              Set(statuses.map(\.id)) == expectedIDs,
              statuses.allSatisfy(\.matchesSnapshot),
              Set(manualStatuses.map(\.id)) == Set([
                  ControlID.continuity,
                  .wifiPolicy,
                  .ingress
              ]),
              manualStatuses.allSatisfy({
                  $0.manualRecovery?.confirmation == .unavailable
              }) else {
            throw RecoverySetupError.legacyRecoveryNotEligible
        }
    }

    private func rollbackLegacyReplacement(
        candidate: LockdownBaseline,
        original: LockdownBaseline,
        transaction: BaselineTransaction
    ) throws {
        guard try transaction.load() == candidate else {
            throw RecoverySetupError.savedBaselineMismatch
        }
        try transaction.save(original)
        guard try transaction.load() == original else {
            throw RecoverySetupError.savedBaselineMismatch
        }
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
