import Foundation
import Testing
@testable import TravelLockdown

@Suite("CoordinatorTests")
struct CoordinatorTests {
    @Test("live enable uses the reviewed baseline without recapturing current settings")
    func coordinatorSnapshotsBeforeApplying() async throws {
        let log = EventLog()
        let fixture = try coordinatorFixture(
            controls: [
                FakeControl(.bluetooth, log: log),
                FakeControl(.continuity, log: log)
            ]
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        _ = try await fixture.coordinator.enable(dryRun: false)

        #expect(
            log.events == [
                "apply:bluetooth",
                "apply:continuity"
            ]
        )
    }

    @Test("failed verification never produces an active result and preserves the baseline")
    func failedVerificationPreservesBaseline() async throws {
        let fixture = try coordinatorFixture(
            controls: [FakeControl(.wifiPolicy, verification: .unavailable)]
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let result = try await fixture.coordinator.enable(dryRun: false)

        #expect(result.status.isActive == false)
        #expect(fixture.store.exists == true)
    }

    @Test("a retry after failed activation preserves the reviewed normal-state baseline")
    func repeatedEnablePreservesOriginalBaseline() async throws {
        let log = EventLog()
        let captureSequence = FakeCaptureSequence([true, false])
        let fixture = try coordinatorFixture(
            controls: [
                FakeControl(
                    .bluetooth,
                    log: log,
                    verification: .unavailable,
                    captureSequence: captureSequence
                )
            ]
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        _ = try await fixture.coordinator.enable(dryRun: false)
        let originalBaseline = try fixture.store.load()

        _ = try await fixture.coordinator.enable(dryRun: false)

        #expect(try fixture.store.load() == originalBaseline)
        #expect(
            originalBaseline.snapshots == [
                try ControlSnapshot.capturing(
                    FakeSnapshot(wasEnabled: true),
                    for: .bluetooth
                )
            ]
        )
        #expect(log.events.filter { $0 == "capture:bluetooth" }.isEmpty)
    }

    @Test("an invalid existing baseline fails before capture or apply")
    func invalidExistingBaselinePreventsControlWork() async throws {
        let log = EventLog()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let baselineURL = directory.appendingPathComponent("baseline.json")
        let invalidBaseline = Data("invalid baseline fixture".utf8)
        try invalidBaseline.write(to: baselineURL)
        var registry = SnapshotModelRegistry()
        registry.register(FakeSnapshot.self, for: .bluetooth)
        let store = BaselineStore(directory: directory, modelRegistry: registry)
        let coordinator = LockdownCoordinator(
            controls: [FakeControl(.bluetooth, log: log)],
            baselineStore: store
        )
        var didThrow = false

        #expect(await coordinator.recoveryState() == .invalid)
        #expect(await coordinator.hasRecoveryState())
        #expect(log.events.isEmpty)
        #expect(try Data(contentsOf: baselineURL) == invalidBaseline)

        do {
            _ = try await coordinator.enable(dryRun: false)
        } catch {
            didThrow = true
        }

        #expect(didThrow == true)
        #expect(log.events.isEmpty)
        #expect(try Data(contentsOf: baselineURL) == invalidBaseline)
    }

    @Test("an existing baseline must exactly match the registered control IDs")
    func existingBaselineRequiresExactControlSet() async throws {
        let scenarios: [(baselineIDs: [ControlID], controlIDs: [ControlID])] = [
            (baselineIDs: [.bluetooth], controlIDs: [.bluetooth, .continuity]),
            (baselineIDs: [.bluetooth, .bluetooth], controlIDs: [.bluetooth]),
            (baselineIDs: [.bluetooth, .continuity], controlIDs: [.bluetooth])
        ]

        for scenario in scenarios {
            let log = EventLog()
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            var registry = SnapshotModelRegistry()
            for id in ControlID.allCases {
                registry.register(FakeSnapshot.self, for: id)
            }
            let store = BaselineStore(directory: directory, modelRegistry: registry)
            try store.save(
                LockdownBaseline(
                    version: 1,
                    capturedAt: Date(timeIntervalSince1970: 1),
                    snapshots: try scenario.baselineIDs.map {
                        try ControlSnapshot.capturing(
                            FakeSnapshot(wasEnabled: true),
                            for: $0
                        )
                    }
                )
            )
            let baselineURL = directory.appendingPathComponent("baseline.json")
            let originalBaseline = try Data(contentsOf: baselineURL)
            let coordinator = LockdownCoordinator(
                controls: scenario.controlIDs.map { FakeControl($0, log: log) },
                baselineStore: store
            )
            var didThrow = false

            #expect(await coordinator.recoveryState() == .invalid)
            #expect(log.events.isEmpty)
            #expect(try Data(contentsOf: baselineURL) == originalBaseline)

            do {
                _ = try await coordinator.enable(dryRun: false)
            } catch {
                didThrow = true
            }

            #expect(didThrow == true)
            #expect(log.events.isEmpty)
            #expect(try Data(contentsOf: baselineURL) == originalBaseline)
            try FileManager.default.removeItem(at: directory)
        }
    }

    @Test("restore rejects missing duplicate or extra snapshots before any control work")
    func restoreRequiresExactControlSetBeforeMutation() async throws {
        let scenarios: [(baselineIDs: [ControlID], controlIDs: [ControlID])] = [
            (baselineIDs: [.bluetooth], controlIDs: [.bluetooth, .continuity]),
            (baselineIDs: [.bluetooth, .bluetooth], controlIDs: [.bluetooth]),
            (baselineIDs: [.bluetooth, .continuity], controlIDs: [.bluetooth])
        ]

        for scenario in scenarios {
            let log = EventLog()
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            var registry = SnapshotModelRegistry()
            for id in ControlID.allCases {
                registry.register(FakeSnapshot.self, for: id)
            }
            let store = BaselineStore(directory: directory, modelRegistry: registry)
            try store.save(
                LockdownBaseline(
                    version: 1,
                    capturedAt: Date(timeIntervalSince1970: 1),
                    snapshots: try scenario.baselineIDs.map {
                        try ControlSnapshot.capturing(
                            FakeSnapshot(wasEnabled: true),
                            for: $0
                        )
                    }
                )
            )
            let baselineURL = directory.appendingPathComponent("baseline.json")
            let originalBaseline = try Data(contentsOf: baselineURL)
            let coordinator = LockdownCoordinator(
                controls: scenario.controlIDs.map {
                    FakeControl($0, log: log, recordRestoration: true)
                },
                baselineStore: store
            )

            var receivedError: CoordinatorError?
            do {
                _ = try await coordinator.restore()
            } catch let error as CoordinatorError {
                receivedError = error
            }

            #expect(receivedError == .baselineControlSetMismatch)
            #expect(log.events.isEmpty)
            #expect((try? Data(contentsOf: baselineURL)) == originalBaseline)
        }
    }

    @Test("dry run plans from empty snapshots without capture or mutation")
    func dryRunHasNoCaptureOrMutation() async throws {
        let log = EventLog()
        let fixture = try coordinatorFixture(
            controls: [
                FakeControl(.bluetooth, log: log, recordPlan: true),
                FakeControl(.wifiPolicy, log: log, recordPlan: true)
            ],
            seedActiveBaseline: false
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let result = try await fixture.coordinator.enable(dryRun: true)
        let plannedControlIDs = result.dryRunPlan?.changes.map { $0.control }

        #expect(log.events == ["plan:bluetooth", "plan:wifiPolicy"])
        #expect(plannedControlIDs == [ControlID.bluetooth, ControlID.wifiPolicy])
        #expect(result.status.controls.isEmpty)
        #expect(fixture.store.exists == false)
    }

    @Test("each apply is immediately followed by its lockdown verification")
    func applyAndVerificationStayInRegistrationOrder() async throws {
        let log = EventLog()
        let fixture = try coordinatorFixture(
            controls: [
                FakeControl(.bluetooth, log: log, recordVerification: true),
                FakeControl(.continuity, log: log, recordVerification: true)
            ]
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        _ = try await fixture.coordinator.enable(dryRun: false)

        #expect(
            log.events == [
                "apply:bluetooth",
                "verify:bluetooth",
                "apply:continuity",
                "verify:continuity"
            ]
        )
    }

    @Test("an apply error becomes a failed status and later controls still run")
    func applyErrorReturnsAllStatuses() async throws {
        let log = EventLog()
        let fixture = try coordinatorFixture(
            controls: [
                FakeControl(.bluetooth, log: log, failure: .apply),
                FakeControl(.continuity, log: log)
            ]
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let result = try await fixture.coordinator.enable(dryRun: false)

        #expect(
            result.status.controls.map { $0.id }
                == [ControlID.bluetooth, ControlID.continuity]
        )
        #expect(result.status.controls.first?.verification == .failed)
        #expect(result.status.controls.last?.verification == .compliant)
        #expect(log.events.suffix(2) == ["apply:bluetooth", "apply:continuity"])
        #expect(fixture.store.exists == true)
    }

    @Test("a capture error prevents every apply and baseline save")
    func captureFailurePreventsMutation() async throws {
        let log = EventLog()
        let fixture = try coordinatorFixture(
            controls: [
                FakeControl(.bluetooth, log: log, verification: .nonCompliant),
                FakeControl(
                    .continuity,
                    log: log,
                    verification: .nonCompliant,
                    failure: .capture
                ),
                FakeControl(.wifiPolicy, log: log, verification: .nonCompliant),
                FakeControl(.ingress, log: log, verification: .nonCompliant),
                FakeControl(.wake, log: log, verification: .nonCompliant)
            ],
            seedActiveBaseline: false
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        await #expect(throws: RecoverySetupError.captureFailed(.continuity)) {
            try await fixture.coordinator.reviewRecoverySetup()
        }

        #expect(log.events == ["capture:bluetooth", "capture:continuity"])
        #expect(fixture.store.exists == false)
    }

    @Test("missing recovery state fails before capture or apply")
    func baselineSaveFailurePreventsMutation() async throws {
        let log = EventLog()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BaselineStore(directory: directory)
        let coordinator = LockdownCoordinator(
            controls: [FakeControl(.bluetooth, log: log)],
            baselineStore: store
        )

        await #expect(throws: RecoverySetupError.recoveryStateRequired) {
            try await coordinator.enable(dryRun: false)
        }

        #expect(log.events.isEmpty)
        #expect(store.exists == false)
    }

    @Test("only the full compliant required set activates lockdown")
    func fullRequiredSetActivatesLockdown() async throws {
        let fixture = try coordinatorFixture(
            controls: ControlID.allCases.map { FakeControl($0) }
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let result = try await fixture.coordinator.enable(dryRun: false)

        #expect(result.status.isActive == true)
        #expect(result.dryRunPlan == nil)
    }

    @Test("status verifies controls without capture or mutation")
    func statusIsReadOnly() async throws {
        let log = EventLog()
        let fixture = try coordinatorFixture(
            controls: [FakeControl(.bluetooth, log: log, recordVerification: true)],
            seedActiveBaseline: false
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let status = await fixture.coordinator.status()

        #expect(status.controls.map { $0.id } == [ControlID.bluetooth])
        #expect(log.events == ["verify:bluetooth"])
        #expect(fixture.store.exists == false)
    }

    @Test("restore and restored verification run together in reverse registration order")
    func restoreRunsInReverseOrder() async throws {
        let log = EventLog()
        let fixture = try coordinatorFixture(
            controls: [
                FakeControl(.bluetooth, log: log, recordRestoration: true),
                FakeControl(.continuity, log: log, recordRestoration: true)
            ]
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        log.removeAll()

        let result = try await fixture.coordinator.restore()

        #expect(
            log.events == [
                "restore:continuity",
                "verifyRestored:continuity",
                "restore:bluetooth",
                "verifyRestored:bluetooth"
            ]
        )
        #expect(result.expectedIDs == Set([ControlID.bluetooth, ControlID.continuity]))
        #expect(result.isFullyRestored == true)
        #expect(fixture.store.exists)
        #expect(try fixture.store.load().recoveryState == .prepared)
    }

    @Test("restore uses baseline comparison and retains a mismatched baseline")
    func restoreMismatchPreservesBaseline() async throws {
        let fixture = try coordinatorFixture(
            controls: [
                FakeControl(
                    .bluetooth,
                    verification: .compliant,
                    restorationMatches: false
                )
            ]
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let result = try await fixture.coordinator.restore()

        #expect(result.statuses == [
            RestorationStatus(
                id: .bluetooth,
                matchesSnapshot: false,
                detail: "Fake restoration mismatch"
            )
        ])
        #expect(result.isFullyRestored == false)
        #expect(fixture.store.exists == true)
    }

    @Test("unresolved AirPlay recovery marker keeps the baseline active")
    func unresolvedAirPlayRetainsBaseline() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BaselineStore(directory: directory, modelRegistry: .travelLockdown)
        let snapshot = try ControlSnapshot.capturing(
            ContinuitySnapshot(
                activityAdvertisingAllowed: .bool(true),
                activityReceivingAllowed: .bool(false),
                discoverableMode: .string("ContactsOnly")
            ),
            for: .continuity
        )
        try store.save(
            LockdownBaseline(
                version: 1,
                capturedAt: Date(timeIntervalSince1970: 1),
                snapshots: [snapshot]
            )
        )
        let opener = CoordinatorSettingsOpener()
        let control = ContinuityControl(
            runner: CoordinatorContinuityRunner(),
            airPlayVerifier: .unavailable,
            settingsOpener: opener
        )
        let coordinator = LockdownCoordinator(controls: [control], baselineStore: store)

        let result = try await coordinator.restore()

        #expect(result.isFullyRestored == false)
        #expect(result.statuses.first?.id == .continuity)
        #expect(result.statuses.first?.matchesSnapshot == true)
        #expect(result.statuses.first?.detail.contains("AirPlay Receiver") == true)
        #expect(store.exists == true)
        #expect(opener.openCount == 1)
    }

    @Test("active mixed Continuity recovery can retry and complete")
    func activeMixedContinuityRecoveryCanRetryAndComplete() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BaselineStore(directory: directory, modelRegistry: .travelLockdown)
        let snapshot = try ControlSnapshot.capturing(
            ContinuitySnapshot(
                activityAdvertisingAllowed: .missing,
                activityReceivingAllowed: .bool(true),
                discoverableMode: .string("ContactsOnly"),
                airPlayReceiverBaseline: AirPlayReceiverBaseline(
                    isEnabled: true,
                    access: .currentUser,
                    requiresPassword: true
                )
            ),
            for: .continuity
        )
        try store.save(
            LockdownBaseline(
                version: 1,
                capturedAt: Date(timeIntervalSince1970: 1),
                snapshots: [snapshot],
                recoveryState: .active
            )
        )
        let runner = MixedContinuityRecoveryRunner()
        let coordinator = LockdownCoordinator(
            controls: [
                ContinuityControl(
                    runner: runner,
                    airPlayVerifier: .unavailable,
                    settingsOpener: FailingCoordinatorSettingsOpener()
                )
            ],
            baselineStore: store
        )

        let result = try await coordinator.restore()

        #expect(result.isFullyRestored == false)
        #expect(result.statuses.first?.matchesSnapshot == true)
        #expect(result.statuses.first?.manualRecovery?.confirmation == .userAttestation)
        #expect(runner.didAttemptAlreadyMissingDelete)
        #expect(runner.didRestoreRemainingPreferences)
        #expect(store.exists)

        let instruction = try #require(result.statuses.first?.manualRecovery)
        let token = try #require(result.recoveryToken)
        let completed = try await coordinator.completeManualRecovery(
            token: token,
            instructions: [instruction]
        )

        #expect(completed.isFullyRestored)
        #expect(store.exists)
        #expect(try store.load().recoveryState == .prepared)
    }

    @Test("restore errors remain per-control mismatches and preserve the baseline")
    func restoreErrorPreservesBaseline() async throws {
        let fixture = try coordinatorFixture(
            controls: [
                FakeControl(
                    .wake,
                    restorationMatches: false,
                    failure: .restore
                )
            ]
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let result = try await fixture.coordinator.restore()

        #expect(result.statuses.count == 1)
        #expect(result.statuses.first?.id == .wake)
        #expect(result.statuses.first?.matchesSnapshot == false)
        #expect(result.statuses.first?.detail.isEmpty == false)
        #expect(fixture.store.exists == true)
    }

    @Test("a second mutation cannot enter while a transaction is suspended")
    func concurrentMutationIsRejected() async throws {
        let gate = CaptureGate()
        let fixture = try coordinatorFixture(
            controls: ControlID.allCases.map {
                FakeControl(
                    $0,
                    verification: .nonCompliant,
                    captureGate: $0 == .bluetooth ? gate : nil
                )
            },
            seedActiveBaseline: false
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let firstReview = Task {
            try? await fixture.coordinator.reviewRecoverySetup()
        }
        await gate.waitUntilBlocked()

        let secondEnable = Task {
            do {
                _ = try await fixture.coordinator.enable(dryRun: false)
                return false
            } catch CoordinatorError.transactionInProgress {
                return true
            } catch {
                return false
            }
        }
        await Task.yield()
        await gate.release()

        _ = await firstReview.value
        #expect(await secondEnable.value == true)
    }

    @Test("separate coordinators reject a competing baseline mutation before control work")
    func sharedBaselineRejectsCompetingMutationBeforeControlWork() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var registry = SnapshotModelRegistry()
        for id in ControlID.allCases {
            registry.register(FakeSnapshot.self, for: id)
        }
        let store = BaselineStore(directory: directory, modelRegistry: registry)
        let captureGate = CaptureGate()
        let firstLog = EventLog()
        let secondLog = EventLog()
        let first = LockdownCoordinator(
            controls: ControlID.allCases.map {
                FakeControl(
                    $0,
                    log: firstLog,
                    verification: .nonCompliant,
                    captureGate: $0 == .bluetooth ? captureGate : nil
                )
            },
            baselineStore: store
        )
        let second = LockdownCoordinator(
            controls: ControlID.allCases.map {
                FakeControl($0, log: secondLog, verification: .nonCompliant)
            },
            baselineStore: store
        )
        let firstReview = Task {
            try? await first.reviewRecoverySetup()
        }
        await captureGate.waitUntilBlocked()

        var competingMutationError: BaselineStoreError?
        do {
            _ = try await second.reviewRecoverySetup()
        } catch let error as BaselineStoreError {
            competingMutationError = error
        }

        #expect(competingMutationError == .transactionUnavailable)
        #expect(secondLog.events.isEmpty)
        await captureGate.release()
        _ = await firstReview.value
    }

    @Test("separate coordinators reject a competing restore before control work")
    func sharedBaselineRejectsCompetingRestoreBeforeControlWork() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var registry = SnapshotModelRegistry()
        registry.register(FakeSnapshot.self, for: .bluetooth)
        let store = BaselineStore(directory: directory, modelRegistry: registry)
        try store.save(
            LockdownBaseline(
                version: 1,
                capturedAt: Date(timeIntervalSince1970: 1),
                snapshots: [
                    try ControlSnapshot.capturing(
                        FakeSnapshot(wasEnabled: true),
                        for: .bluetooth
                    )
                ],
                recoveryState: .active
            )
        )

        let restoreGate = CaptureGate()
        let firstLog = EventLog()
        let secondLog = EventLog()
        let first = LockdownCoordinator(
            controls: [
                FakeControl(
                    .bluetooth,
                    log: firstLog,
                    recordRestoration: true,
                    restorationGate: restoreGate
                )
            ],
            baselineStore: store
        )
        let second = LockdownCoordinator(
            controls: [FakeControl(.bluetooth, log: secondLog, recordRestoration: true)],
            baselineStore: store
        )
        let firstRestore = Task {
            try await first.restore()
        }
        await restoreGate.waitUntilBlocked()

        var competingRestoreError: BaselineStoreError?
        do {
            _ = try await second.restore()
        } catch let error as BaselineStoreError {
            competingRestoreError = error
        }

        #expect(competingRestoreError == .transactionUnavailable)
        #expect(secondLog.events.isEmpty)
        await restoreGate.release()
        #expect(try await firstRestore.value.isFullyRestored == true)
        #expect(store.exists)
        #expect(try store.load().recoveryState == .prepared)
    }

    @Test("a replaced baseline makes restore fail and retains the replacement")
    func replacedBaselineFailsRestoreAndRetainsRecoveryState() async throws {
        let replacementWriter = BaselineReplacementWriter()
        let fixture = try coordinatorFixture(
            controls: [
                FakeControl(
                    .bluetooth,
                    restorationAction: { try replacementWriter.replace() }
                )
            ]
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let replacement = LockdownBaseline(
            version: 1,
            capturedAt: Date(timeIntervalSince1970: 2),
            snapshots: [
                try ControlSnapshot.capturing(
                    FakeSnapshot(wasEnabled: false),
                    for: .bluetooth
                )
            ]
        )
        replacementWriter.configure(directory: fixture.directory, baseline: replacement)

        var restoreError: CoordinatorError?
        do {
            _ = try await fixture.coordinator.restore()
        } catch let error as CoordinatorError {
            restoreError = error
        }

        #expect(restoreError == .baselinePreparationFailed)
        #expect(try fixture.store.load() == replacement)
        #expect(fixture.store.exists == true)
    }

    private func coordinatorFixture(
        controls: [FakeControl],
        seedActiveBaseline: Bool = true
    ) throws -> (coordinator: LockdownCoordinator, store: BaselineStore, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        var registry = SnapshotModelRegistry()
        for id in ControlID.allCases {
            registry.register(FakeSnapshot.self, for: id)
        }
        let store = BaselineStore(directory: directory, modelRegistry: registry)
        if seedActiveBaseline {
            try store.save(
                LockdownBaseline(
                    version: 1,
                    capturedAt: Date(timeIntervalSince1970: 1),
                    snapshots: try controls.map {
                        try ControlSnapshot.capturing(
                            FakeSnapshot(wasEnabled: true),
                            for: $0.id
                        )
                    },
                    recoveryState: .active
                )
            )
        }
        return (LockdownCoordinator(controls: controls, baselineStore: store), store, directory)
    }
}

private struct FakeSnapshot: DeclaredNonSecretSnapshotModel {
    static let snapshotModelID = "tests.coordinator.fake"

    let wasEnabled: Bool
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [String] = []

    var events: [String] {
        lock.withLock { recordedEvents }
    }

    func append(_ event: String) {
        lock.withLock {
            recordedEvents.append(event)
        }
    }

    func removeAll() {
        lock.withLock {
            recordedEvents.removeAll()
        }
    }
}

private final class FakeCaptureSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool]

    init(_ values: [Bool]) {
        self.values = values
    }

    func next() -> Bool {
        lock.withLock {
            values.isEmpty ? false : values.removeFirst()
        }
    }
}

private final class BaselineReplacementWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedDirectory: URL?
    private var storedBaseline: LockdownBaseline?

    func configure(directory: URL, baseline: LockdownBaseline) {
        lock.withLock {
            storedDirectory = directory
            storedBaseline = baseline
        }
    }

    func replace() throws {
        let replacement = lock.withLock { (storedDirectory, storedBaseline) }
        guard let directory = replacement.0, let baseline = replacement.1 else {
            throw FakeControlError.requestedFailure
        }
        let baselineURL = directory.appendingPathComponent("baseline.json")
        try JSONEncoder().encode(baseline).write(to: baselineURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: baselineURL.path
        )
    }
}

private enum FakeControlError: Error, Equatable {
    case requestedFailure
}

private struct CoordinatorContinuityRunner: CommandRunning {
    func run(executable: String, arguments: [String]) throws -> CommandResult {
        guard executable == "/usr/bin/defaults" else {
            return CommandResult(exitCode: 90, stdout: "", stderr: "unexpected executable")
        }
        if arguments == [
            "-currentHost", "read", "com.apple.coreservices.useractivityd"
        ] {
            return CommandResult(
                exitCode: 0,
                stdout: "{ ActivityAdvertisingAllowed = 1; ActivityReceivingAllowed = 0; }",
                stderr: ""
            )
        }
        if arguments == ["read", "com.apple.sharingd"] {
            return CommandResult(
                exitCode: 0,
                stdout: "{ DiscoverableMode = ContactsOnly; }",
                stderr: ""
            )
        }
        let allowedWrites: [[String]] = [
            [
                "-currentHost", "write", "com.apple.coreservices.useractivityd",
                "ActivityAdvertisingAllowed", "-bool", "true"
            ],
            [
                "-currentHost", "write", "com.apple.coreservices.useractivityd",
                "ActivityReceivingAllowed", "-bool", "false"
            ],
            [
                "write", "com.apple.sharingd", "DiscoverableMode", "-string", "ContactsOnly"
            ]
        ]
        return allowedWrites.contains(arguments)
            ? CommandResult(exitCode: 0, stdout: "", stderr: "")
            : CommandResult(exitCode: 91, stdout: "", stderr: "unexpected arguments")
    }
}

private final class MixedContinuityRecoveryRunner: @unchecked Sendable, CommandRunning {
    private let lock = NSLock()
    private var advertising: PreferenceValue = .missing
    private var receiving: PreferenceValue = .bool(false)
    private var discoverableMode: PreferenceValue = .string("Off")
    private var attemptedAlreadyMissingDelete = false
    private var restoredReceiving = false
    private var restoredDiscoverableMode = false

    func run(executable: String, arguments: [String]) throws -> CommandResult {
        guard executable == "/usr/bin/defaults" else {
            return CommandResult(exitCode: 90, stdout: "", stderr: "unexpected executable")
        }
        return lock.withLock {
            switch arguments {
            case ["-currentHost", "read", "com.apple.coreservices.useractivityd"]:
                return .init(
                    exitCode: 0,
                    stdout: Self.domain([
                        "ActivityAdvertisingAllowed": advertising,
                        "ActivityReceivingAllowed": receiving
                    ]),
                    stderr: ""
                )
            case ["read", "com.apple.sharingd"]:
                return .init(
                    exitCode: 0,
                    stdout: Self.domain(["DiscoverableMode": discoverableMode]),
                    stderr: ""
                )
            case [
                "-currentHost", "delete", "com.apple.coreservices.useractivityd",
                "ActivityAdvertisingAllowed"
            ]:
                attemptedAlreadyMissingDelete = true
                guard advertising != .missing else {
                    return .init(
                        exitCode: 1,
                        stdout: "",
                        stderr: "Domain/default pair does not exist"
                    )
                }
                advertising = .missing
                return .init(exitCode: 0, stdout: "", stderr: "")
            case [
                "-currentHost", "write", "com.apple.coreservices.useractivityd",
                "ActivityReceivingAllowed", "-bool", "true"
            ]:
                receiving = .bool(true)
                restoredReceiving = true
                return .init(exitCode: 0, stdout: "", stderr: "")
            case [
                "write", "com.apple.sharingd", "DiscoverableMode", "-string", "ContactsOnly"
            ]:
                discoverableMode = .string("ContactsOnly")
                restoredDiscoverableMode = true
                return .init(exitCode: 0, stdout: "", stderr: "")
            default:
                return .init(exitCode: 91, stdout: "", stderr: "unexpected arguments")
            }
        }
    }

    var didAttemptAlreadyMissingDelete: Bool {
        lock.withLock { attemptedAlreadyMissingDelete }
    }

    var didRestoreRemainingPreferences: Bool {
        lock.withLock { restoredReceiving && restoredDiscoverableMode }
    }

    private static func domain(_ values: [String: PreferenceValue]) -> String {
        let assignments = values.compactMap { key, value -> String? in
            switch value {
            case .missing:
                return nil
            case .bool(let enabled):
                return "\(key) = \(enabled ? 1 : 0);"
            case .string(let value):
                return "\(key) = \(value);"
            }
        }.sorted()
        return "{ \(assignments.joined(separator: " ")) }"
    }
}

private final class CoordinatorSettingsOpener: @unchecked Sendable,
    AirDropContinuitySettingsOpening
{
    private let lock = NSLock()
    private var storedOpenCount = 0

    func openAirDropAndContinuity() throws {
        lock.withLock { storedOpenCount += 1 }
    }

    var openCount: Int {
        lock.withLock { storedOpenCount }
    }
}

private struct FailingCoordinatorSettingsOpener: AirDropContinuitySettingsOpening {
    func openAirDropAndContinuity() throws {
        throw ContinuityControlError.settingsOpenFailed
    }
}

private enum FakeOperation: Equatable, Sendable {
    case capture
    case apply
    case verify
    case restore
    case verifyRestored
}

private actor CaptureGate {
    private var isOpen = false
    private var blockedContinuations: [CheckedContinuation<Void, Never>] = []
    private var observer: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            blockedContinuations.append(continuation)
            observer?.resume()
            observer = nil
        }
    }

    func waitUntilBlocked() async {
        guard blockedContinuations.isEmpty else { return }
        await withCheckedContinuation { observer = $0 }
    }

    func release() {
        isOpen = true
        let continuations = blockedContinuations
        blockedContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }
}

private struct FakeControl: LockdownControl {
    let id: ControlID
    private let log: EventLog?
    private let verification: Verification
    private let restorationMatches: Bool
    private let failure: FakeOperation?
    private let recordPlan: Bool
    private let recordVerification: Bool
    private let recordRestoration: Bool
    private let captureGate: CaptureGate?
    private let captureSequence: FakeCaptureSequence?
    private let restorationAction: (@Sendable () throws -> Void)?
    private let restorationGate: CaptureGate?

    init(
        _ id: ControlID,
        log: EventLog? = nil,
        verification: Verification = .compliant,
        restorationMatches: Bool = true,
        failure: FakeOperation? = nil,
        recordPlan: Bool = false,
        recordVerification: Bool = false,
        recordRestoration: Bool = false,
        captureGate: CaptureGate? = nil,
        captureSequence: FakeCaptureSequence? = nil,
        restorationAction: (@Sendable () throws -> Void)? = nil,
        restorationGate: CaptureGate? = nil
    ) {
        self.id = id
        self.log = log
        self.verification = verification
        self.restorationMatches = restorationMatches
        self.failure = failure
        self.recordPlan = recordPlan
        self.recordVerification = recordVerification
        self.recordRestoration = recordRestoration
        self.captureGate = captureGate
        self.captureSequence = captureSequence
        self.restorationAction = restorationAction
        self.restorationGate = restorationGate
    }

    func capture() async throws -> ControlSnapshot {
        log?.append("capture:\(id.rawValue)")
        await captureGate?.wait()
        try failIfRequested(.capture)
        return try ControlSnapshot.capturing(
            FakeSnapshot(wasEnabled: captureSequence?.next() ?? true),
            for: id
        )
    }

    func plan(from snapshot: ControlSnapshot) async throws -> [PlannedChange] {
        if recordPlan {
            log?.append("plan:\(id.rawValue)")
        }
        return [
            PlannedChange(
                control: id,
                summary: "Apply \(id.rawValue) lockdown",
                sensitivity: .public
            )
        ]
    }

    func apply() async throws {
        log?.append("apply:\(id.rawValue)")
        try failIfRequested(.apply)
    }

    func verify() async throws -> ControlStatus {
        if recordVerification {
            log?.append("verify:\(id.rawValue)")
        }
        try failIfRequested(.verify)
        return ControlStatus(id: id, verification: verification, detail: "Fake verification")
    }

    func restore(from snapshot: ControlSnapshot) async throws {
        if recordRestoration {
            log?.append("restore:\(id.rawValue)")
        }
        await restorationGate?.wait()
        try restorationAction?()
        try failIfRequested(.restore)
    }

    func verifyRestored(from snapshot: ControlSnapshot) async throws -> RestorationStatus {
        if recordRestoration {
            log?.append("verifyRestored:\(id.rawValue)")
        }
        try failIfRequested(.verifyRestored)
        return RestorationStatus(
            id: id,
            matchesSnapshot: restorationMatches,
            detail: restorationMatches ? "Fake restoration" : "Fake restoration mismatch"
        )
    }

    private func failIfRequested(_ operation: FakeOperation) throws {
        if failure == operation {
            throw FakeControlError.requestedFailure
        }
    }
}
