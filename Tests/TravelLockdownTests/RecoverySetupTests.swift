import Foundation
import Testing
@testable import TravelLockdown

@Suite("RecoverySetupTests")
struct RecoverySetupTests {
    private struct PendingRecoveryReviewProbe: Decodable {
        let tokenHash: String
        let purpose: RecoverySetupPurpose
        let bindingFingerprint: String
    }

    @Test("review is stable, redacted, and does not mutate settings")
    func reviewIsStableRedactedAndReadOnly() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let review = try await fixture.coordinator.reviewRecoverySetup()

        #expect(review.items.count == ControlID.allCases.count)
        #expect(review.token.count == 64)
        #expect(review.items.map(\.summary).joined().contains("Example Network") == false)
        #expect(review.items.first(where: { $0.control == .wifiPolicy })?.summary.contains("1 saved") == true)
        #expect(fixture.state.captureCount == ControlID.allCases.count * 2)
        #expect(fixture.state.applyCount == 0)
        #expect(fixture.state.restoreCount == 0)
        #expect(fixture.store.exists == false)
    }

    @Test("unchanged reviews use fresh opaque tokens and invalidate the prior review")
    func repeatedReviewsUseFreshOpaqueTokens() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let reviewURL = fixture.directory.appendingPathComponent("recovery-review.json")

        let first = try await fixture.coordinator.reviewRecoverySetup()
        let firstRecordData = try Data(contentsOf: reviewURL)
        let firstRecord = try JSONDecoder().decode(
            PendingRecoveryReviewProbe.self,
            from: firstRecordData
        )
        let second = try await fixture.coordinator.reviewRecoverySetup()
        let secondRecordData = try Data(contentsOf: reviewURL)
        let secondRecord = try JSONDecoder().decode(
            PendingRecoveryReviewProbe.self,
            from: secondRecordData
        )

        #expect(first.items == second.items)
        #expect(first.token != second.token)
        #expect(first.token.count == 64)
        #expect(second.token.count == 64)
        #expect(first.token.utf8.allSatisfy(Self.isLowercaseHex))
        #expect(second.token.utf8.allSatisfy(Self.isLowercaseHex))
        #expect(firstRecord.purpose == .newSnapshot)
        #expect(secondRecord.purpose == .newSnapshot)
        #expect(firstRecord.bindingFingerprint == secondRecord.bindingFingerprint)
        #expect(firstRecord.tokenHash == RecoverySnapshotFingerprint.tokenHash(first.token))
        #expect(secondRecord.tokenHash == RecoverySnapshotFingerprint.tokenHash(second.token))
        #expect(firstRecord.tokenHash != secondRecord.tokenHash)

        let visibleRecord = String(decoding: secondRecordData, as: UTF8.self)
        #expect(visibleRecord.contains(second.token) == false)
        #expect(visibleRecord.contains("Example Network") == false)
        #expect(
            try FileManager.default.attributesOfItem(atPath: reviewURL.path)[.posixPermissions]
                as? Int == 0o600
        )
        #expect(
            try FileManager.default.attributesOfItem(atPath: fixture.directory.path)[.posixPermissions]
                as? Int == 0o700
        )

        await #expect(throws: RecoverySetupError.reviewTokenMismatch) {
            try await fixture.coordinator.prepareRecovery(
                profile: .testNormal,
                reviewToken: first.token
            )
        }
        await #expect(throws: RecoverySetupError.reviewTokenMismatch) {
            try await fixture.coordinator.prepareRecovery(
                profile: .testNormal,
                reviewToken: "not-a-token"
            )
        }
        #expect(fixture.store.exists == false)
        #expect(try Data(contentsOf: reviewURL) == secondRecordData)

        _ = try await fixture.coordinator.prepareRecovery(
            profile: .testNormal,
            reviewToken: second.token
        )
        #expect(fixture.store.exists)
        #expect(FileManager.default.fileExists(atPath: reviewURL.path) == false)
        #expect(fixture.state.applyCount == 0)
        #expect(fixture.state.restoreCount == 0)
    }

    @Test("recovery review refuses a lockdown-like current posture")
    func reviewRejectsLockedPosture() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        fixture.state.forceLockdownVerification()

        await #expect(throws: RecoverySetupError.normalPostureRequired) {
            try await fixture.coordinator.reviewRecoverySetup()
        }

        #expect(fixture.store.exists == false)
        #expect(fixture.state.captureCount == 0)
        #expect(fixture.state.applyCount == 0)
        #expect(fixture.state.restoreCount == 0)
    }

    @Test("prepare requires the exact reviewed automatic snapshot")
    func prepareRejectsStaleReviewToken() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        await #expect(throws: RecoverySetupError.reviewTokenMismatch) {
            try await fixture.coordinator.prepareRecovery(
                profile: .testNormal,
                reviewToken: String(repeating: "0", count: 64)
            )
        }

        #expect(fixture.store.exists == false)
        #expect(fixture.state.applyCount == 0)
    }

    @Test("prepare rechecks that the reviewed posture is still clearly normal")
    func prepareRejectsPostureChange() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let review = try await fixture.coordinator.reviewRecoverySetup()
        fixture.state.forceLockdownVerification()

        await #expect(throws: RecoverySetupError.normalPostureRequired) {
            try await fixture.coordinator.prepareRecovery(
                profile: .testNormal,
                reviewToken: review.token
            )
        }

        #expect(fixture.store.exists == false)
        #expect(fixture.state.applyCount == 0)
        #expect(fixture.state.restoreCount == 0)
    }

    @Test("prepare captures reviewed manual fields without changing the Mac")
    func prepareStoresReviewedCompositeSnapshot() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let review = try await fixture.coordinator.reviewRecoverySetup()

        let result = try await fixture.coordinator.prepareRecovery(
            profile: .testNormal,
            reviewToken: review.token
        )
        let baseline = try fixture.store.load()
        let profile = try RecoverySetupProfile.reviewedProfile(in: baseline.snapshots)

        #expect(result.controlCount == ControlID.allCases.count)
        #expect(baseline.recoveryState == .prepared)
        #expect(profile == .testNormal)
        #expect(fixture.state.applyCount == 0)
        #expect(fixture.state.restoreCount == 0)
    }

    @Test("marker-shaped Wi-Fi names prepare successfully and stay out of output")
    func markerShapedWiFiNamesPrepareAndStayRedacted() async throws {
        let networkNames = ["password=guest", "token=guest"]
        let fixture = try makeFixture(wifiNetworkNames: networkNames)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let review = try await fixture.coordinator.reviewRecoverySetup()
        let dryRun = try await fixture.coordinator.enable(dryRun: true)
        let commandOutput = RecoveryOutputSink()
        let commandErrors = RecoveryOutputSink()
        let reviewExitCode = await RecoveryReviewCommandLine.run(
            review: { review },
            stdout: commandOutput.write,
            stderr: commandErrors.write
        )
        let prepareExitCode = await RecoverySetupCommandLine.run(
            profile: .testNormal,
            reviewToken: review.token,
            prepare: { profile, token in
                try await fixture.coordinator.prepareRecovery(
                    profile: profile,
                    reviewToken: token
                )
            },
            stdout: commandOutput.write,
            stderr: commandErrors.write
        )
        let visibleOutput = commandOutput.text + commandErrors.text
            + (dryRun.dryRunPlan?.changes.map(\.menuSummary).joined(separator: "\n") ?? "")

        #expect(reviewExitCode == 0)
        #expect(prepareExitCode == 0)
        for networkName in networkNames {
            #expect(visibleOutput.contains(networkName) == false)
        }

        let baseline = try fixture.store.load()
        let wifiSnapshot = try #require(
            baseline.snapshots.first(where: { $0.id == .wifiPolicy })
        ).decoded(as: WiFiPolicySnapshot.self, for: .wifiPolicy)

        #expect(baseline.recoveryState == .prepared)
        #expect(
            wifiSnapshot.preferredNetworks.map(\.networkName)
                == networkNames.map(Optional.some)
        )
        #expect(fixture.state.applyCount == 0)
        #expect(fixture.state.restoreCount == 0)
    }

    @Test("prepared activation rechecks exact values before becoming active")
    func preparedActivationPromotesWithoutOverwritingBaseline() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let review = try await fixture.coordinator.reviewRecoverySetup()
        _ = try await fixture.coordinator.prepareRecovery(
            profile: .testNormal,
            reviewToken: review.token
        )
        let prepared = try fixture.store.load()

        let result = try await fixture.coordinator.enable(dryRun: false)
        let active = try fixture.store.load()

        #expect(result.status.isActive)
        #expect(active.recoveryState == .active)
        #expect(active.capturedAt == prepared.capturedAt)
        #expect(active.snapshots == prepared.snapshots)
        #expect(fixture.state.applyCount == ControlID.allCases.count)
    }

    @Test("prepared activation fails closed when automatic settings drift")
    func preparedActivationRejectsDrift() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let review = try await fixture.coordinator.reviewRecoverySetup()
        _ = try await fixture.coordinator.prepareRecovery(
            profile: .testNormal,
            reviewToken: review.token
        )
        fixture.state.set(
            try ControlSnapshot.capturing(
                BluetoothSnapshot(isPoweredOn: false),
                for: .bluetooth
            )
        )

        await #expect(throws: RecoverySetupError.preparedBaselineDrifted) {
            try await fixture.coordinator.enable(dryRun: false)
        }

        #expect(try fixture.store.load().recoveryState == .prepared)
        #expect(fixture.state.applyCount == 0)
    }

    @Test("prepared recovery cannot mutate through the restore path")
    func preparedSnapshotCannotRestore() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let review = try await fixture.coordinator.reviewRecoverySetup()
        _ = try await fixture.coordinator.prepareRecovery(
            profile: .testNormal,
            reviewToken: review.token
        )

        await #expect(throws: RecoverySetupError.recoveryStateNotActive) {
            try await fixture.coordinator.restore()
        }

        #expect(fixture.state.restoreCount == 0)
        #expect(try fixture.store.load().recoveryState == .prepared)
    }

    @Test("manual completion is bound to the exact active baseline and prompt")
    func manualAttestationCompletesOnlyMatchingRecovery() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let review = try await fixture.coordinator.reviewRecoverySetup()
        _ = try await fixture.coordinator.prepareRecovery(
            profile: .testNormal,
            reviewToken: review.token
        )
        _ = try await fixture.coordinator.enable(dryRun: false)
        let active = try fixture.store.load()

        let restore = try await fixture.coordinator.restore()
        let instructions = restore.statuses.compactMap(\.manualRecovery)
        let token = try #require(restore.recoveryToken)
        #expect(restore.isFullyRestored == false)
        #expect(instructions.isEmpty == false)

        await #expect(throws: RecoverySetupError.manualRecoveryAttestationMismatch) {
            try await fixture.coordinator.completeManualRecovery(
                token: String(repeating: "f", count: 64),
                instructions: instructions
            )
        }
        #expect(fixture.store.exists)

        let completed = try await fixture.coordinator.completeManualRecovery(
            token: token,
            instructions: instructions
        )
        #expect(completed.isFullyRestored)
        let prepared = try fixture.store.load()
        #expect(fixture.store.exists)
        #expect(prepared.recoveryState == .prepared)
        #expect(prepared.version == active.version)
        #expect(prepared.capturedAt == active.capturedAt)
        #expect(prepared.snapshots == active.snapshots)
    }

    @Test("changing settings during a review cannot produce a torn snapshot")
    func unstableReviewIsRejected() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        fixture.state.changeBluetoothAfterFirstCapture()

        await #expect(throws: RecoverySetupError.settingsChangedDuringReview) {
            try await fixture.coordinator.reviewRecoverySetup()
        }

        #expect(fixture.store.exists == false)
        #expect(fixture.state.applyCount == 0)
    }

    @Test("legacy active recovery is atomically completed as a prepared snapshot")
    func legacyRecoveryCanBeSafelyReplaced() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let original = try fixture.state.legacyBaseline()
        try fixture.store.save(original)

        let review = try await fixture.coordinator.reviewRecoverySetup()
        let expectedBinding = try RecoverySnapshotFingerprint.baseline(original)
        let reviewRecord = try JSONDecoder().decode(
            PendingRecoveryReviewProbe.self,
            from: Data(
                contentsOf: fixture.directory.appendingPathComponent("recovery-review.json")
            )
        )
        #expect(review.purpose == .legacyReplacement)
        #expect(reviewRecord.purpose == .legacyReplacement)
        #expect(reviewRecord.bindingFingerprint == expectedBinding)
        #expect(reviewRecord.tokenHash == RecoverySnapshotFingerprint.tokenHash(review.token))

        let result = try await fixture.coordinator.prepareRecovery(
            profile: .testNormal,
            reviewToken: review.token
        )
        let replacement = try fixture.store.load()

        #expect(result.controlCount == ControlID.allCases.count)
        #expect(replacement.recoveryState == .prepared)
        #expect(try RecoverySetupProfile.reviewedProfile(in: replacement.snapshots) == .testNormal)
        #expect(fixture.state.applyCount == 0)
        #expect(fixture.state.restoreCount == 0)
        let matchesCurrent = await fixture.coordinator.preparedRecoveryMatchesCurrent()
        #expect(matchesCurrent == true)
    }

    @Test("legacy replacement rejects stale evidence and keeps the active baseline exact")
    func legacyReplacementFailurePreservesOriginal() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let original = try fixture.state.legacyBaseline()
        try fixture.store.save(original)
        let baselineURL = fixture.directory.appendingPathComponent("baseline.json")
        let originalData = try Data(contentsOf: baselineURL)
        let review = try await fixture.coordinator.reviewRecoverySetup()

        await #expect(throws: RecoverySetupError.reviewTokenMismatch) {
            try await fixture.coordinator.prepareRecovery(
                profile: .testNormal,
                reviewToken: String(repeating: "0", count: 64)
            )
        }
        #expect(try fixture.store.load() == original)
        #expect(try Data(contentsOf: baselineURL) == originalData)

        await #expect(throws: RecoverySetupError.reviewTokenMismatch) {
            try await fixture.coordinator.prepareRecovery(
                profile: .testNormal,
                reviewToken: "malformed"
            )
        }
        #expect(try fixture.store.load() == original)
        #expect(try Data(contentsOf: baselineURL) == originalData)

        fixture.state.set(
            try ControlSnapshot.capturing(
                BluetoothSnapshot(isPoweredOn: false),
                for: .bluetooth
            )
        )
        await #expect(throws: RecoverySetupError.settingsChangedDuringReview) {
            try await fixture.coordinator.prepareRecovery(
                profile: .testNormal,
                reviewToken: review.token
            )
        }
        #expect(try fixture.store.load() == original)
        #expect(fixture.state.applyCount == 0)
        #expect(fixture.state.restoreCount == 0)
    }

    @Test("prepared replacement review, cancellation, and review failure preserve the exact original")
    func preparedReplacementReviewNeverConsumesOriginal() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let initialReview = try await fixture.coordinator.reviewRecoverySetup()
        _ = try await fixture.coordinator.prepareRecovery(
            profile: .testNormal,
            reviewToken: initialReview.token
        )
        let original = try fixture.store.load()
        let baselineURL = fixture.directory.appendingPathComponent("baseline.json")
        let originalData = try Data(contentsOf: baselineURL)
        fixture.state.set(
            try ControlSnapshot.capturing(
                BluetoothSnapshot(isPoweredOn: false),
                for: .bluetooth
            )
        )

        let replacementReview = try await fixture.coordinator.reviewRecoverySetup()

        #expect(replacementReview.purpose == .preparedReplacement)
        #expect(replacementReview.token.count == 64)
        #expect(try fixture.store.load() == original)
        #expect(try Data(contentsOf: baselineURL) == originalData)

        await #expect(throws: RecoverySetupError.reviewTokenMismatch) {
            try await fixture.coordinator.prepareRecovery(
                profile: .testNormal,
                reviewToken: String(repeating: "0", count: 64)
            )
        }
        await #expect(throws: RecoverySetupError.reviewTokenMismatch) {
            try await fixture.coordinator.prepareRecovery(
                profile: .testNormal,
                reviewToken: "malformed"
            )
        }
        #expect(try fixture.store.load() == original)
        #expect(try Data(contentsOf: baselineURL) == originalData)

        // Closing the review is cancellation: no coordinator mutation is requested.
        #expect(try fixture.store.load() == original)
        #expect(try Data(contentsOf: baselineURL) == originalData)

        fixture.state.forceLockdownVerification()
        await #expect(throws: RecoverySetupError.normalPostureRequired) {
            try await fixture.coordinator.reviewRecoverySetup()
        }
        #expect(try fixture.store.load() == original)
        #expect(try Data(contentsOf: baselineURL) == originalData)
        #expect(fixture.state.applyCount == 0)
        #expect(fixture.state.restoreCount == 0)
    }

    @Test("failed prepared candidate verification rolls back the exact original")
    func preparedReplacementFailureRollsBackOriginal() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let initialReview = try await fixture.coordinator.reviewRecoverySetup()
        _ = try await fixture.coordinator.prepareRecovery(
            profile: .testNormal,
            reviewToken: initialReview.token
        )
        let original = try fixture.store.load()
        let replacementReview = try await fixture.coordinator.reviewRecoverySetup()
        fixture.state.changeBluetooth(
            afterAdditionalCaptures: ControlID.allCases.count * 2
        )

        await #expect(throws: RecoverySetupError.settingsChangedDuringReview) {
            try await fixture.coordinator.prepareRecovery(
                profile: .testNormal,
                reviewToken: replacementReview.token
            )
        }

        #expect(try fixture.store.load() == original)
        #expect(fixture.state.applyCount == 0)
        #expect(fixture.state.restoreCount == 0)
    }

    @Test("successful prepared replacement is verified without applying or restoring")
    func preparedReplacementSucceedsWithoutControlMutation() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let initialReview = try await fixture.coordinator.reviewRecoverySetup()
        _ = try await fixture.coordinator.prepareRecovery(
            profile: .testNormal,
            reviewToken: initialReview.token
        )
        let original = try fixture.store.load()
        fixture.state.set(
            try ControlSnapshot.capturing(
                BluetoothSnapshot(isPoweredOn: false),
                for: .bluetooth
            )
        )
        let replacementReview = try await fixture.coordinator.reviewRecoverySetup()

        let result = try await fixture.coordinator.prepareRecovery(
            profile: .testNormal,
            reviewToken: replacementReview.token
        )
        let replacement = try fixture.store.load()
        let bluetooth = try #require(
            replacement.snapshots.first(where: { $0.id == .bluetooth })
        ).decoded(as: BluetoothSnapshot.self, for: .bluetooth)

        #expect(replacementReview.purpose == .preparedReplacement)
        #expect(result.controlCount == ControlID.allCases.count)
        #expect(replacement.recoveryState == .prepared)
        #expect(replacement != original)
        #expect(bluetooth.isPoweredOn == false)
        #expect(await fixture.coordinator.preparedRecoveryMatchesCurrent() == true)
        #expect(fixture.state.applyCount == 0)
        #expect(fixture.state.restoreCount == 0)
    }

    private func makeFixture(wifiNetworkNames: [String] = ["Example Network"]) throws -> (
        coordinator: LockdownCoordinator,
        store: BaselineStore,
        state: RecoveryTestState,
        directory: URL
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let state = try RecoveryTestState(wifiNetworkNames: wifiNetworkNames)
        let controls = ControlID.allCases.map { RecoveryTestControl(id: $0, state: state) }
        let store = BaselineStore(directory: directory, modelRegistry: .travelLockdown)
        return (
            LockdownCoordinator(controls: controls, baselineStore: store),
            store,
            state,
            directory
        )
    }

    private static func isLowercaseHex(_ byte: UInt8) -> Bool {
        (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
    }
}

private final class RecoveryOutputSink: @unchecked Sendable {
    private let lock = NSLock()
    private var storedText = ""

    func write(_ value: String) {
        lock.withLock { storedText += value }
    }

    var text: String {
        lock.withLock { storedText }
    }
}

private extension RecoverySetupProfile {
    static var testNormal: RecoverySetupProfile {
        RecoverySetupProfile(
            airPlayReceiver: AirPlayReceiverBaseline(
                isEnabled: true,
                access: .currentUser,
                requiresPassword: true
            ),
            personalHotspotAutoJoin: .askToJoin,
            sharingServices: Dictionary(
                uniqueKeysWithValues: SharingService.allCases.map { ($0, false) }
            )
        )
    }
}

private final class RecoveryTestState: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [ControlID: ControlSnapshot]
    private var storedCaptureCount = 0
    private var storedApplyCount = 0
    private var storedRestoreCount = 0
    private var bluetoothChangeAfterCaptureCount: Int?
    private var appliedIDs: Set<ControlID> = []
    private var forceLockdown = false

    init(wifiNetworkNames: [String] = ["Example Network"]) throws {
        snapshots = [
            .bluetooth: try ControlSnapshot.capturing(
                BluetoothSnapshot(isPoweredOn: true),
                for: .bluetooth
            ),
            .continuity: try ControlSnapshot.capturing(
                ContinuitySnapshot(
                    activityAdvertisingAllowed: .bool(true),
                    activityReceivingAllowed: .bool(true),
                    discoverableMode: .string("ContactsOnly")
                ),
                for: .continuity
            ),
            .wifiPolicy: try ControlSnapshot.capturing(
                WiFiPolicySnapshot(
                    preferredNetworks: wifiNetworkNames.map {
                        WiFiNetworkProfileMetadata(networkName: $0, security: .wpa3Personal)
                    },
                    rememberJoinedNetworks: true,
                    requireAdministratorForAssociation: false,
                    requireAdministratorForPower: false,
                    requireAdministratorForIBSSMode: false
                ),
                for: .wifiPolicy
            ),
            .ingress: try ControlSnapshot.capturing(
                IngressSnapshot(
                    firewallEnabled: true,
                    stealthModeEnabled: false,
                    blockAllEnabled: false
                ),
                for: .ingress
            ),
            .wake: try ControlSnapshot.capturing(
                WakeSnapshot(wakeForNetworkAccess: true),
                for: .wake
            )
        ]
    }

    var captureCount: Int { lock.withLock { storedCaptureCount } }
    var applyCount: Int { lock.withLock { storedApplyCount } }
    var restoreCount: Int { lock.withLock { storedRestoreCount } }

    func capture(_ id: ControlID) throws -> ControlSnapshot {
        try lock.withLock {
            storedCaptureCount += 1
            if id == .bluetooth,
               let changeAfter = bluetoothChangeAfterCaptureCount,
               storedCaptureCount > changeAfter {
                snapshots[.bluetooth] = try ControlSnapshot.capturing(
                    BluetoothSnapshot(isPoweredOn: false),
                    for: .bluetooth
                )
                bluetoothChangeAfterCaptureCount = nil
            }
            guard let snapshot = snapshots[id] else {
                throw RecoverySetupError.savedBaselineMismatch
            }
            return snapshot
        }
    }

    func set(_ snapshot: ControlSnapshot) {
        lock.withLock { snapshots[snapshot.id] = snapshot }
    }

    func changeBluetoothAfterFirstCapture() {
        changeBluetooth(afterAdditionalCaptures: ControlID.allCases.count)
    }

    func changeBluetooth(afterAdditionalCaptures captureCount: Int) {
        lock.withLock {
            bluetoothChangeAfterCaptureCount = storedCaptureCount + captureCount
        }
    }

    func forceLockdownVerification() {
        lock.withLock { forceLockdown = true }
    }

    func verification(for id: ControlID) -> Verification {
        lock.withLock {
            forceLockdown || appliedIDs.contains(id) ? .compliant : .nonCompliant
        }
    }

    func legacyBaseline() throws -> LockdownBaseline {
        try lock.withLock {
            LockdownBaseline(
                version: 1,
                capturedAt: Date(timeIntervalSince1970: 1),
                snapshots: try ControlID.allCases.map { id in
                    guard let snapshot = snapshots[id] else {
                        throw RecoverySetupError.savedBaselineMismatch
                    }
                    return snapshot
                },
                recoveryState: .active
            )
        }
    }

    func recordApply(_ id: ControlID) {
        lock.withLock {
            storedApplyCount += 1
            appliedIDs.insert(id)
        }
    }

    func recordRestore() {
        lock.withLock { storedRestoreCount += 1 }
    }
}

private struct RecoveryTestControl: LockdownControl {
    let id: ControlID
    let state: RecoveryTestState

    func capture() async throws -> ControlSnapshot {
        try state.capture(id)
    }

    func plan(from snapshot: ControlSnapshot) async throws -> [PlannedChange] {
        [PlannedChange(control: id, summary: "Test lockdown", sensitivity: .public)]
    }

    func apply() async throws {
        state.recordApply(id)
    }

    func verify() async throws -> ControlStatus {
        let verification = state.verification(for: id)
        return ControlStatus(id: id, verification: verification, detail: "Test verified")
    }

    func restore(from snapshot: ControlSnapshot) async throws {
        state.recordRestore()
    }

    func verifyRestored(from snapshot: ControlSnapshot) async throws -> RestorationStatus {
        switch id {
        case .continuity:
            let value = try snapshot.decoded(as: ContinuitySnapshot.self, for: id)
            guard let baseline = value.airPlayReceiverBaseline else {
                return legacyManualStatus(
                    pane: "System Settings > General > AirDrop & Continuity",
                    action: "Restore AirPlay Receiver"
                )
            }
            let instruction = baseline.recoveryInstruction
            return manualStatus(
                pane: "System Settings > General > AirDrop & Continuity",
                action: instruction
            )
        case .wifiPolicy:
            let value = try snapshot.decoded(as: WiFiPolicySnapshot.self, for: id)
            guard let mode = value.personalHotspotAutoJoin else {
                return legacyManualStatus(
                    pane: "System Settings > Wi-Fi",
                    action: "Restore Personal Hotspot auto-join"
                )
            }
            return manualStatus(
                pane: "System Settings > Wi-Fi",
                action: "Set Ask to join hotspots to \(mode.title)"
            )
        case .ingress:
            let value = try snapshot.decoded(as: IngressSnapshot.self, for: id)
            guard value.sharingRecovery.allSatisfy({ $0.isEnabled != nil }) else {
                return legacyManualStatus(
                    pane: "System Settings > General > Sharing",
                    action: "Restore every listed Sharing service"
                )
            }
            let actions = value.sharingRecovery.map {
                "Turn \($0.service.rawValue) \($0.isEnabled == true ? "on" : "off")"
            }.joined(separator: "; ")
            return manualStatus(
                pane: "System Settings > General > Sharing",
                action: actions
            )
        case .bluetooth, .wake:
            return RestorationStatus(
                id: id,
                matchesSnapshot: true,
                detail: "Test automatic restoration verified"
            )
        }
    }

    private func manualStatus(pane: String, action: String) -> RestorationStatus {
        RestorationStatus(
            id: id,
            matchesSnapshot: true,
            detail: action,
            manualRecovery: ManualRecoveryInstruction(
                pane: pane,
                action: action,
                confirmation: .userAttestation
            )
        )
    }

    private func legacyManualStatus(pane: String, action: String) -> RestorationStatus {
        RestorationStatus(
            id: id,
            matchesSnapshot: true,
            detail: action,
            manualRecovery: ManualRecoveryInstruction(pane: pane, action: action)
        )
    }
}
