import Foundation
import Testing
@testable import TravelLockdown

@Suite("ViewModelTests")
struct ViewModelTests {
    @Test("preflight never invokes a control apply operation")
    func preflightIsReadOnly() async throws {
        let coordinator = FakeCoordinator()
        let preflight = FakePreflightProvider(
            report: .init(items: [.fileVault(.compliant)])
        )
        let model = await LockdownViewModel(
            coordinator: coordinator,
            preflightProvider: preflight
        )

        await model.runPreflight()

        #expect(coordinator.enableCount == 0)
        #expect(preflight.runCount == 1)
        #expect(await model.preflightReport?.items == [.fileVault(.compliant)])
    }

    @Test("enable requires dry-run review before impact confirmation")
    func enableNeedsConfirmation() async throws {
        let coordinator = FakeCoordinator()
        let model = await LockdownViewModel(
            coordinator: coordinator,
            preflightProvider: FakePreflightProvider()
        )

        let dryRunTask = await model.requestEnable()
        await dryRunTask?.value

        #expect(await model.pendingPlanReview != nil)
        #expect(await model.pendingConfirmation == nil)
        #expect(coordinator.enableDryRuns == [true])
    }

    @Test("dry-run review is redacted and must be acknowledged before live enable")
    @MainActor
    func dryRunReviewGatesLiveEnable() async {
        let coordinator = FakeCoordinator(
            dryRunPlan: DryRunPlan(changes: [
                PlannedChange(
                    control: .wifiPolicy,
                    summary: "Configure Wi-Fi for Airport Lounge SSID",
                    sensitivity: .networkMetadata
                ),
                PlannedChange(
                    control: .bluetooth,
                    summary: "Disable Bluetooth",
                    sensitivity: .public
                )
            ])
        )
        let model = LockdownViewModel(
            coordinator: coordinator,
            preflightProvider: FakePreflightProvider()
        )

        let dryRunTask = model.requestEnable()
        await dryRunTask?.value

        #expect(coordinator.enableDryRuns == [true])
        #expect(model.pendingPlanReview?.message.contains("Configure manual Wi-Fi connection") == true)
        #expect(model.pendingPlanReview?.message.contains("Airport Lounge SSID") == false)
        #expect(model.pendingConfirmation == nil)
        #expect(model.confirmEnable() == nil)

        model.acknowledgePlanReview()

        #expect(model.pendingPlanReview == nil)
        #expect(model.pendingConfirmation != nil)
        #expect(coordinator.enableDryRuns == [true])

        let liveEnableTask = model.confirmEnable()
        await liveEnableTask?.value

        #expect(coordinator.enableDryRuns == [true, false])
    }

    @Test("a missing dry-run plan blocks live enable")
    @MainActor
    func missingDryRunPlanBlocksLiveEnable() async {
        let coordinator = FakeCoordinator(dryRunPlan: nil)
        let model = LockdownViewModel(
            coordinator: coordinator,
            preflightProvider: FakePreflightProvider()
        )

        let dryRunTask = model.requestEnable()
        await dryRunTask?.value
        let liveEnableTask = model.confirmEnable()
        await liveEnableTask?.value

        #expect(coordinator.enableDryRuns == [true])
        #expect(model.pendingPlanReview == nil)
        #expect(model.pendingConfirmation == nil)
        #expect(model.operationAttention == .enableFailed)
    }

    @Test("enable immediately publishes a visible preparing phase")
    @MainActor
    func enablePublishesPreparingPhase() async {
        let coordinator = DelayedDryRunCoordinator()
        let model = LockdownViewModel(
            coordinator: coordinator,
            preflightProvider: FakePreflightProvider()
        )

        let request = model.requestEnable()
        await coordinator.waitUntilDryRunStarts()

        #expect(model.operationPhase == .preparingPlan)
        #expect(model.pendingPlanReview == nil)

        await coordinator.completeOldestDryRun(with: DryRunPlan(changes: []))
        await request?.value

        #expect(model.operationPhase == .idle)
        #expect(model.pendingPlanReview != nil)
    }

    @Test("duplicate enable requests start at most one dry run while a review is in flight")
    @MainActor
    func duplicateEnableRequestsDoNotStartConcurrentDryRuns() async {
        let coordinator = DelayedDryRunCoordinator()
        let model = LockdownViewModel(
            coordinator: coordinator,
            preflightProvider: FakePreflightProvider()
        )

        let firstRequest = model.requestEnable()
        await coordinator.waitUntilDryRunStarts()
        let secondRequest = model.requestEnable()

        #expect(secondRequest == nil)
        #expect(await coordinator.enableCalls() == [true])
        #expect(model.pendingPlanReview == nil)
        #expect(model.pendingConfirmation == nil)

        await coordinator.completeOldestDryRun(with: DryRunPlan(changes: []))
        await firstRequest?.value

        #expect(model.pendingPlanReview != nil)
    }

    @Test("a cancelled stale dry run cannot block or override a newer acknowledged plan")
    @MainActor
    func staleDryRunCannotOverrideAcknowledgedPlan() async {
        let coordinator = DelayedDryRunCoordinator()
        let model = LockdownViewModel(
            coordinator: coordinator,
            preflightProvider: FakePreflightProvider()
        )
        let stalePlan = DryRunPlan(changes: [
            PlannedChange(
                control: .bluetooth,
                summary: "Stale Bluetooth plan",
                sensitivity: .public
            )
        ])
        let currentPlan = DryRunPlan(changes: [
            PlannedChange(
                control: .wake,
                summary: "Current wake plan",
                sensitivity: .public
            )
        ])

        let staleRequest = model.requestEnable()
        await coordinator.waitUntilDryRunStarts()
        model.cancelEnable()

        let currentRequest = model.requestEnable()
        await coordinator.waitUntilDryRunStarts()
        await coordinator.completeNewestDryRun(with: currentPlan)
        await currentRequest?.value
        model.acknowledgePlanReview()
        let currentConfirmation = model.pendingConfirmation

        let liveEnable = model.confirmEnable()
        await liveEnable?.value

        #expect(currentConfirmation != nil)
        #expect(await coordinator.enableCalls() == [true, true, false])
        #expect(model.pendingConfirmation == nil)

        await coordinator.completeOldestDryRun(with: stalePlan)
        await staleRequest?.value

        #expect(await coordinator.enableCalls() == [true, true, false])
        #expect(model.pendingPlanReview == nil)
        #expect(model.pendingConfirmation == nil)
    }

    @Test("confirmation describes every user-visible impact and preserved credentials")
    func confirmationDescribesKnownImpacts() async {
        let model = await LockdownViewModel(
            coordinator: FakeCoordinator(),
            preflightProvider: FakePreflightProvider()
        )

        await acknowledgePlanReview(for: model)

        let message = await model.pendingConfirmation?.message ?? ""
        for requiredImpact in [
            "Bluetooth devices",
            "Apple Watch Auto Unlock",
            "Handoff",
            "AirDrop",
            "AirPlay Receiver",
            "sharing and remote administration",
            "inbound connections",
            "Wi-Fi auto-join",
            "after a drop",
            "reconnect to Wi-Fi manually",
            "Touch ID",
            "password settings"
        ] {
            #expect(message.contains(requiredImpact))
        }
    }

    @Test("confirmation cannot activate before an enable request")
    func confirmationRequiresPendingRequest() async {
        let coordinator = FakeCoordinator()
        let model = await LockdownViewModel(
            coordinator: coordinator,
            preflightProvider: FakePreflightProvider()
        )

        let enableTask = await model.confirmEnable()
        await enableTask?.value

        #expect(coordinator.enableCount == 0)
    }

    @Test("cancelling visible confirmation prevents later activation")
    func cancelledConfirmationCannotActivate() async {
        let coordinator = FakeCoordinator()
        let model = await LockdownViewModel(
            coordinator: coordinator,
            preflightProvider: FakePreflightProvider()
        )

        await acknowledgePlanReview(for: model)
        await model.cancelEnable()
        let enableTask = await model.confirmEnable()
        await enableTask?.value

        #expect(await model.pendingConfirmation == nil)
        #expect(coordinator.enableDryRuns == [true])
    }

    @Test("visible confirmation activates once and publishes its verified status")
    func confirmedEnableActivates() async {
        let enabledStatus = LockdownStatus.make(controls: [
            ControlStatus(
                id: .bluetooth,
                verification: .compliant,
                detail: "Bluetooth is off"
            )
        ])
        let coordinator = FakeCoordinator(enableStatus: enabledStatus)
        let model = await LockdownViewModel(
            coordinator: coordinator,
            preflightProvider: FakePreflightProvider()
        )

        await acknowledgePlanReview(for: model)
        let firstEnable = await model.confirmEnable()
        let secondEnable = await model.confirmEnable()
        await firstEnable?.value
        await secondEnable?.value

        #expect(coordinator.enableDryRuns == [true, false])
        #expect(await model.pendingConfirmation == nil)
        #expect(await model.status == enabledStatus)
    }

    @Test("partial activation keeps recovery available")
    func partialActivationKeepsRestoreAvailable() async {
        let partialStatus = LockdownStatus.make(controls: [
            ControlStatus(
                id: .bluetooth,
                verification: .unavailable,
                detail: "Bluetooth state is unavailable"
            )
        ])
        let coordinator = FakeCoordinator(
            enableStatus: partialStatus,
            hasRecoveryState: true
        )
        let model = await LockdownViewModel(
            coordinator: coordinator,
            preflightProvider: FakePreflightProvider()
        )

        await acknowledgePlanReview(for: model)
        let enableTask = await model.confirmEnable()
        await enableTask?.value

        #expect(await model.isRestoreAvailable)
        #expect(await model.status?.isActive == false)
    }

    @Test("accepted confirmation survives alert dismissal")
    func acceptedConfirmationSurvivesDismissal() async {
        let coordinator = FakeCoordinator()
        let model = await LockdownViewModel(
            coordinator: coordinator,
            preflightProvider: FakePreflightProvider()
        )

        await acknowledgePlanReview(for: model)
        let enableTask = await model.confirmEnable()
        await model.cancelEnable()
        await enableTask?.value

        #expect(coordinator.enableDryRuns == [true, false])
    }

    @Test("menu toggle off asks for recovery confirmation before restoring")
    @MainActor
    func menuToggleOffRequiresRestoreConfirmation() async {
        let coordinator = FakeCoordinator(hasRecoveryState: true)
        let model = LockdownViewModel(
            coordinator: coordinator,
            preflightProvider: FakePreflightProvider()
        )
        await model.refreshStatus()
        #expect(model.lockdownModeState == .attention)
        model.requestLockdownModeToggle()

        #expect(model.pendingRestoreConfirmation != nil)
        #expect(coordinator.restoreCount == 0)

        let restoreTask = model.confirmRestore()
        await restoreTask?.value

        #expect(coordinator.restoreCount == 1)
        #expect(model.pendingRestoreConfirmation == nil)
    }

    @Test("mode state distinguishes verified lockdown from recovery attention")
    @MainActor
    func modeStateRequiresCompleteVerification() async {
        let verifiedStatus = LockdownStatus.make(controls: ControlID.allCases.map {
            ControlStatus(id: $0, verification: .compliant, detail: "verified")
        })
        let verifiedModel = LockdownViewModel(
            coordinator: FakeCoordinator(status: verifiedStatus, hasRecoveryState: true),
            preflightProvider: FakePreflightProvider()
        )
        let attentionModel = LockdownViewModel(
            coordinator: FakeCoordinator(
                status: LockdownStatus.make(controls: []),
                hasRecoveryState: true
            ),
            preflightProvider: FakePreflightProvider()
        )

        await verifiedModel.refreshStatus()
        await attentionModel.refreshStatus()

        #expect(verifiedModel.lockdownModeState == .verified)
        #expect(attentionModel.lockdownModeState == .attention)
    }

    @Test("cancelling inline recovery confirmation leaves recovery untouched")
    @MainActor
    func cancellingRestoreConfirmationDoesNotRestore() async {
        let coordinator = FakeCoordinator(hasRecoveryState: true)
        let model = LockdownViewModel(
            coordinator: coordinator,
            preflightProvider: FakePreflightProvider()
        )
        await model.refreshStatus()

        model.requestRestore()
        model.cancelRestore()
        let restoreTask = model.confirmRestore()
        await restoreTask?.value

        #expect(coordinator.restoreCount == 0)
        #expect(model.pendingRestoreConfirmation == nil)
    }

    @Test("restore remains unavailable until a confirmed enable attempt completes")
    @MainActor
    func restoreAvailabilityWaitsForEnableCompletion() async {
        let coordinator = DeferredEnableCoordinator()
        let model = LockdownViewModel(
            coordinator: coordinator,
            preflightProvider: FakePreflightProvider()
        )

        let dryRunTask = model.requestEnable()
        await dryRunTask?.value
        model.acknowledgePlanReview()
        let enableTask = model.confirmEnable()

        #expect(model.isRestoreAvailable == false)
        await coordinator.waitUntilEnableStarts()
        #expect(model.isRestoreAvailable == false)
        await coordinator.completeEnable()
        await enableTask?.value

        #expect(model.isRestoreAvailable)
    }

    @Test("status refresh verifies without enabling or restoring")
    func statusRefreshIsReadOnly() async {
        let currentStatus = LockdownStatus.make(controls: [
            ControlStatus(id: .wake, verification: .nonCompliant, detail: "Wake is on")
        ])
        let coordinator = FakeCoordinator(status: currentStatus)
        let model = await LockdownViewModel(
            coordinator: coordinator,
            preflightProvider: FakePreflightProvider()
        )

        await model.refreshStatus()

        #expect(await model.status == currentStatus)
        #expect(coordinator.statusCount == 1)
        #expect(coordinator.enableCount == 0)
        #expect(coordinator.restoreCount == 0)
        #expect(await model.isRestoreAvailable == false)
    }

    @Test("status reveals persisted recovery state on a fresh ViewModel")
    func statusFindsPersistedRecoveryOnFreshViewModel() async {
        let coordinator = FakeCoordinator(hasRecoveryState: true)
        let model = await LockdownViewModel(
            coordinator: coordinator,
            preflightProvider: FakePreflightProvider()
        )

        await model.refreshStatus()

        #expect(await model.isRestoreAvailable)
        #expect(coordinator.recoveryStateQueryCount == 1)
        #expect(coordinator.enableCount == 0)
        #expect(coordinator.restoreCount == 0)
    }

    @Test("a suspended status refresh gates enable and restore until its result is published")
    @MainActor
    func suspendedStatusRefreshGatesMutations() async {
        let coordinator = DelayedRefreshCoordinator()
        let model = LockdownViewModel(
            coordinator: coordinator,
            preflightProvider: FakePreflightProvider()
        )

        let startup = model.beginStartupHydration()
        await startup?.value
        #expect(model.isRestoreAvailable)

        model.requestRestore()
        #expect(model.pendingRestoreConfirmation != nil)
        await model.refreshStatusIfIdle()
        #expect(await coordinator.statusCalls() == 1)
        #expect(model.isStatusRefreshInProgress == false)
        #expect(model.pendingRestoreConfirmation != nil)
        model.cancelRestore()

        let enableCoordinator = FakeCoordinator()
        let enableModel = LockdownViewModel(
            coordinator: enableCoordinator,
            preflightProvider: FakePreflightProvider()
        )
        let dryRun = enableModel.requestEnable()
        await dryRun?.value
        enableModel.acknowledgePlanReview()
        #expect(enableModel.pendingConfirmation != nil)
        await enableModel.refreshStatusIfIdle()
        #expect(enableCoordinator.statusCount == 0)
        #expect(enableModel.pendingConfirmation != nil)

        let refresh = Task { await model.refreshStatusIfIdle() }
        await coordinator.waitUntilDelayedStatusStarts()

        #expect(model.isStatusRefreshInProgress)
        #expect(model.isLockdownModeInteractionDisabled)
        #expect(model.requestEnable() == nil)
        model.requestRestore()
        #expect(model.pendingRestoreConfirmation == nil)
        #expect(await coordinator.mutationCounts() == (enable: 0, restore: 0))

        await coordinator.completeDelayedStatus()
        await refresh.value

        #expect(model.isStatusRefreshInProgress == false)
        model.requestRestore()
        #expect(model.pendingRestoreConfirmation != nil)
        #expect(await coordinator.mutationCounts() == (enable: 0, restore: 0))
    }

    @Test("app startup hydration gates Enable and prioritizes persisted recovery")
    @MainActor
    func startupHydrationShowsRestoreBeforeEnable() async {
        let inactiveStatus = LockdownStatus.make(controls: [
            ControlStatus(
                id: .wake,
                verification: .nonCompliant,
                detail: "Wake is on"
            )
        ])
        let coordinator = FakeCoordinator(
            status: inactiveStatus,
            hasRecoveryState: true
        )
        let model = LockdownViewModel(
            coordinator: coordinator,
            preflightProvider: FakePreflightProvider()
        )

        let startup = model.beginStartupHydration()

        #expect(startup != nil)
        #expect(model.lockdownModeState == .off)
        #expect(model.requestEnable() == nil)

        await startup?.value

        #expect(model.status == inactiveStatus)
        #expect(model.lockdownModeState == .attention)
        #expect(model.isRestoreAvailable)
        #expect(coordinator.statusCount == 1)
        #expect(coordinator.recoveryStateQueryCount == 1)
        #expect(coordinator.enableCount == 0)
        #expect(coordinator.restoreCount == 0)
    }

    @Test("fresh app startup presents Restore for a persisted recovery baseline")
    @MainActor
    func appStartupPresentsRestoreForPersistedRecovery() async {
        let coordinator = FakeCoordinator(
            status: LockdownStatus.make(controls: [
                ControlStatus(
                    id: .wake,
                    verification: .nonCompliant,
                    detail: "Wake is on"
                )
            ]),
            hasRecoveryState: true
        )
        let model = LockdownViewModel(
            coordinator: coordinator,
            preflightProvider: FakePreflightProvider()
        )

        let app = TravelLockdownApp(model: model)
        await app.startupHydrationTask?.value

        #expect(model.lockdownModeState == .attention)
        #expect(coordinator.statusCount == 1)
        #expect(coordinator.recoveryStateQueryCount == 1)
        #expect(coordinator.enableCount == 0)
        #expect(coordinator.restoreCount == 0)
    }

    @Test("restore action restores once then refreshes status")
    func restoreRefreshesStatus() async {
        let restoredStatus = LockdownStatus.make(controls: [
            ControlStatus(id: .wake, verification: .nonCompliant, detail: "Wake restored")
        ])
        let coordinator = FakeCoordinator(status: restoredStatus)
        let model = await LockdownViewModel(
            coordinator: coordinator,
            preflightProvider: FakePreflightProvider()
        )

        await model.restoreNormalState()

        #expect(coordinator.restoreCount == 1)
        #expect(coordinator.statusCount == 1)
        #expect(coordinator.recoveryStateQueryCount == 1)
        #expect(await model.status == restoredStatus)
    }

    @Test("view model retains partial recovery detail and manual acknowledgement is UI-only")
    @MainActor
    func partialRestorePublishesNonSecretRecoveryAttention() async {
        let partial = RestorationStatus(
            id: .wake,
            matchesSnapshot: false,
            detail: "Restore wake for network access in Battery settings",
            manualRecovery: ManualRecoveryInstruction(
                pane: "System Settings > Battery",
                action: "Restore wake for network access"
            )
        )
        let coordinator = AttentionCoordinator(
            restoreResult: RestoreResult(expectedIDs: [.wake], statuses: [partial])
        )
        let model = LockdownViewModel(
            coordinator: coordinator,
            preflightProvider: FakePreflightProvider()
        )

        await model.restoreNormalState()

        #expect(model.recoveryAttention == [partial])
        #expect(model.operationAttention?.isNonSecretFailure == true)
        #expect(model.operationAttention == .manualRecoveryRequired)
        #expect(model.manualRecoveryPrompt?.message.contains("System Settings > Battery") == true)
        #expect(model.isRestoreAvailable == true)

        model.acknowledgeManualRecovery()

        #expect(model.manualRecoveryPrompt == nil)
        #expect(model.recoveryAttention == [partial])
        #expect(model.isRestoreAvailable == true)
    }

    @Test("successful enable clears obsolete recovery attention")
    @MainActor
    func successfulEnableClearsPriorRecoveryAttention() async {
        let partial = RestorationStatus(
            id: .wake,
            matchesSnapshot: false,
            detail: "Restore wake for network access in Battery settings",
            manualRecovery: ManualRecoveryInstruction(
                pane: "System Settings > Battery",
                action: "Restore wake for network access"
            )
        )
        let model = LockdownViewModel(
            coordinator: AttentionCoordinator(
                restoreResult: RestoreResult(expectedIDs: [.wake], statuses: [partial])
            ),
            preflightProvider: FakePreflightProvider()
        )

        await model.restoreNormalState()
        #expect(model.operationAttention == .manualRecoveryRequired)
        #expect(model.recoveryAttention == [partial])
        #expect(model.manualRecoveryPrompt != nil)

        let dryRun = model.requestEnable()
        await dryRun?.value
        model.acknowledgePlanReview()
        let enable = model.confirmEnable()
        await enable?.value

        #expect(model.operationAttention == nil)
        #expect(model.recoveryAttention == nil)
        #expect(model.manualRecoveryPrompt == nil)
    }

    @Test("restore uses the aggregate result and reports every missing control")
    @MainActor
    func restoreSynthesizesAttentionForMissingExpectedIDs() async {
        let returned = RestorationStatus(
            id: .wake,
            matchesSnapshot: true,
            detail: "Wake matched the captured baseline"
        )
        let coordinator = AttentionCoordinator(
            restoreResult: RestoreResult(
                expectedIDs: [.wake, .bluetooth],
                statuses: [returned]
            )
        )
        let model = LockdownViewModel(
            coordinator: coordinator,
            preflightProvider: FakePreflightProvider()
        )

        await model.restoreNormalState()

        #expect(model.operationAttention == .restoreIncomplete)
        #expect(model.recoveryAttention == [
            RestorationStatus(
                id: .bluetooth,
                matchesSnapshot: false,
                detail: "Recovery verification was not returned for this control"
            )
        ])
        #expect(model.manualRecoveryPrompt == nil)
    }

    @Test("automated restore mismatch uses generic incomplete wording")
    @MainActor
    func automatedMismatchDoesNotClaimManualRecovery() async {
        let automatedMismatch = RestorationStatus(
            id: .wake,
            matchesSnapshot: false,
            detail: "Wake did not match the captured baseline"
        )
        let coordinator = AttentionCoordinator(
            restoreResult: RestoreResult(expectedIDs: [.wake], statuses: [automatedMismatch])
        )
        let model = LockdownViewModel(
            coordinator: coordinator,
            preflightProvider: FakePreflightProvider()
        )

        await model.restoreNormalState()

        #expect(model.operationAttention == .restoreIncomplete)
        #expect(model.operationAttention?.message.contains("Manual") == false)
        #expect(model.manualRecoveryPrompt == nil)
    }

    @Test("enable failure publishes generic attention without localized error text")
    @MainActor
    func enableFailurePublishesGenericAttention() async {
        let model = LockdownViewModel(
            coordinator: AttentionCoordinator(enableFailure: true),
            preflightProvider: FakePreflightProvider()
        )
        let dryRun = model.requestEnable()
        await dryRun?.value
        model.acknowledgePlanReview()

        let enable = model.confirmEnable()
        await enable?.value

        #expect(model.operationAttention?.isNonSecretFailure == true)
        #expect(model.operationAttention?.message.contains("localized secret") == false)
    }

    @Test("menu status and attention text includes detail and documented native pane")
    @MainActor
    func menuTextIncludesNonSecretDetailAndManualPane() {
        let status = ControlStatus(
            id: .continuity,
            verification: .unavailable,
            detail: "Turn AirPlay Receiver off in General > AirDrop & Continuity"
        )
        let instruction = ManualRecoveryInstruction(
            pane: "System Settings > General > AirDrop & Continuity",
            action: "Restore AirPlay Receiver"
        )

        #expect(MenuView.statusText(for: status).contains(status.detail))
        #expect(MenuView.manualRecoveryText(for: instruction).contains(instruction.pane))
    }

    @Test("preflight executes only the FileVault read command")
    func preflightCommandBoundaryIsReadOnly() async {
        let runner = RecordingCommandRunner(results: [
            CommandKey(
                executable: "/usr/bin/fdesetup",
                arguments: ["status"]
            ): CommandResult(exitCode: 0, stdout: "FileVault is On.\n", stderr: "")
        ])
        let checker = FakePreflightReadbackChecker(
            usbAccessoryApproval: .compliant,
            privateWiFiAddress: .nonCompliant
        )
        let control = PreflightControl(runner: runner, readbackChecker: checker)

        let report = await control.runPreflight()

        #expect(report.items == [
            .fileVault(.compliant),
            .usbAccessoryApproval(.compliant),
            .privateWiFiAddress(.nonCompliant)
        ])
        #expect(runner.commands == [
            CommandKey(executable: "/usr/bin/fdesetup", arguments: ["status"])
        ])
        #expect(checker.usbReadCount == 1)
        #expect(checker.privateWiFiReadCount == 1)
    }

    @Test("missing preflight readback fails closed with native Settings paths")
    func missingPreflightReadbackHasSettingsPaths() async {
        let runner = RecordingCommandRunner(results: [:])
        let control = PreflightControl(
            runner: runner,
            readbackChecker: FakePreflightReadbackChecker(
                usbAccessoryApproval: .unavailable,
                privateWiFiAddress: .unavailable
            )
        )

        let report = await control.runPreflight()

        #expect(report.items == [
            .fileVault(.unavailable),
            .usbAccessoryApproval(.unavailable),
            .privateWiFiAddress(.unavailable)
        ])
        #expect(report.items.map(\.systemSettingsPath) == [
            "System Settings > Privacy & Security > FileVault",
            "System Settings > Privacy & Security > Allow accessories to connect",
            "System Settings > Wi-Fi > Details > Private Wi-Fi address"
        ])
    }
}

private func acknowledgePlanReview(for model: LockdownViewModel) async {
    let dryRunTask = await model.requestEnable()
    await dryRunTask?.value
    await model.acknowledgePlanReview()
}

private final class FakeCoordinator: @unchecked Sendable, LockdownCoordinating {
    private let lock = NSLock()
    private let enableStatus: LockdownStatus
    private let currentStatus: LockdownStatus
    private let dryRunPlan: DryRunPlan?
    private let hasRecoveryStateValue: Bool
    private var storedEnableCount = 0
    private var storedEnableDryRuns: [Bool] = []
    private var storedRestoreCount = 0
    private var storedStatusCount = 0
    private var storedRecoveryStateQueryCount = 0

    init(
        enableStatus: LockdownStatus = .make(controls: []),
        status: LockdownStatus = .make(controls: []),
        dryRunPlan: DryRunPlan? = DryRunPlan(changes: []),
        hasRecoveryState: Bool = false
    ) {
        self.enableStatus = enableStatus
        currentStatus = status
        self.dryRunPlan = dryRunPlan
        hasRecoveryStateValue = hasRecoveryState
    }

    var enableCount: Int {
        lock.withLock { storedEnableCount }
    }

    var enableDryRuns: [Bool] {
        lock.withLock { storedEnableDryRuns }
    }

    var restoreCount: Int {
        lock.withLock { storedRestoreCount }
    }

    var statusCount: Int {
        lock.withLock { storedStatusCount }
    }

    var recoveryStateQueryCount: Int {
        lock.withLock { storedRecoveryStateQueryCount }
    }

    func enable(dryRun: Bool) async throws -> CoordinatorResult {
        lock.withLock {
            storedEnableCount += 1
            storedEnableDryRuns.append(dryRun)
        }
        return CoordinatorResult(
            status: enableStatus,
            dryRunPlan: dryRun ? dryRunPlan : nil
        )
    }

    func restore() async throws -> RestoreResult {
        lock.withLock {
            storedRestoreCount += 1
        }
        return RestoreResult(expectedIDs: [], statuses: [])
    }

    func status() async -> LockdownStatus {
        lock.withLock {
            storedStatusCount += 1
        }
        return currentStatus
    }

    func hasRecoveryState() async -> Bool {
        lock.withLock {
            storedRecoveryStateQueryCount += 1
        }
        return hasRecoveryStateValue
    }
}

private final class AttentionCoordinator: @unchecked Sendable, LockdownCoordinating {
    private let restoreResult: RestoreResult
    private let enableFailure: Bool

    init(
        restoreResult: RestoreResult = RestoreResult(expectedIDs: [], statuses: []),
        enableFailure: Bool = false
    ) {
        self.restoreResult = restoreResult
        self.enableFailure = enableFailure
    }

    func enable(dryRun: Bool) async throws -> CoordinatorResult {
        if dryRun {
            return CoordinatorResult(
                status: .make(controls: []),
                dryRunPlan: DryRunPlan(changes: [])
            )
        }
        if enableFailure {
            throw AttentionCoordinatorError.localizedSecret
        }
        return CoordinatorResult(status: .make(controls: []), dryRunPlan: nil)
    }

    func restore() async throws -> RestoreResult {
        restoreResult
    }

    func status() async -> LockdownStatus {
        .make(controls: [])
    }

    func hasRecoveryState() async -> Bool {
        true
    }
}

private enum AttentionCoordinatorError: Error, LocalizedError {
    case localizedSecret

    var errorDescription: String? {
        "localized secret must never reach UI"
    }
}

private actor DeferredEnableCoordinator: LockdownCoordinating {
    private var enableStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var enableContinuation: CheckedContinuation<CoordinatorResult, Never>?

    func enable(dryRun: Bool) async throws -> CoordinatorResult {
        if dryRun {
            return CoordinatorResult(
                status: .make(controls: []),
                dryRunPlan: DryRunPlan(changes: [])
            )
        }
        let waiters = enableStartWaiters
        enableStartWaiters.removeAll()
        waiters.forEach { $0.resume() }

        return await withCheckedContinuation { continuation in
            enableContinuation = continuation
        }
    }

    func restore() async throws -> RestoreResult {
        RestoreResult(expectedIDs: [], statuses: [])
    }

    func status() async -> LockdownStatus {
        .make(controls: [])
    }

    func hasRecoveryState() async -> Bool {
        true
    }

    func waitUntilEnableStarts() async {
        await withCheckedContinuation { continuation in
            enableStartWaiters.append(continuation)
        }
    }

    func completeEnable() {
        enableContinuation?.resume(
            returning: CoordinatorResult(status: .make(controls: []), dryRunPlan: nil)
        )
        enableContinuation = nil
    }
}

private actor DelayedDryRunCoordinator: LockdownCoordinating {
    private var recordedEnableCalls: [Bool] = []
    private var unobservedDryRunStarts = 0
    private var dryRunStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var dryRunContinuations: [CheckedContinuation<CoordinatorResult, Never>] = []

    func enable(dryRun: Bool) async throws -> CoordinatorResult {
        recordedEnableCalls.append(dryRun)
        guard dryRun else {
            return CoordinatorResult(status: .make(controls: []), dryRunPlan: nil)
        }

        signalDryRunStart()
        return await withCheckedContinuation { continuation in
            dryRunContinuations.append(continuation)
        }
    }

    func restore() async throws -> RestoreResult {
        RestoreResult(expectedIDs: [], statuses: [])
    }

    func status() async -> LockdownStatus {
        .make(controls: [])
    }

    func hasRecoveryState() async -> Bool {
        false
    }

    func enableCalls() -> [Bool] {
        recordedEnableCalls
    }

    func waitUntilDryRunStarts() async {
        if unobservedDryRunStarts > 0 {
            unobservedDryRunStarts -= 1
            return
        }
        await withCheckedContinuation { continuation in
            dryRunStartWaiters.append(continuation)
        }
    }

    func completeOldestDryRun(with plan: DryRunPlan) {
        guard !dryRunContinuations.isEmpty else {
            return
        }
        dryRunContinuations.removeFirst().resume(
            returning: CoordinatorResult(status: .make(controls: []), dryRunPlan: plan)
        )
    }

    func completeNewestDryRun(with plan: DryRunPlan) {
        guard let continuation = dryRunContinuations.popLast() else {
            return
        }
        continuation.resume(
            returning: CoordinatorResult(status: .make(controls: []), dryRunPlan: plan)
        )
    }

    private func signalDryRunStart() {
        if let waiter = dryRunStartWaiters.first {
            dryRunStartWaiters.removeFirst()
            waiter.resume()
        } else {
            unobservedDryRunStarts += 1
        }
    }
}

private actor DelayedRefreshCoordinator: LockdownCoordinating {
    private let currentStatus = LockdownStatus.make(controls: [
        ControlStatus(id: .wake, verification: .nonCompliant, detail: "Wake is on")
    ])
    private var statusCallCount = 0
    private var unobservedDelayedStatusStarts = 0
    private var delayedStatusStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var delayedStatusContinuation: CheckedContinuation<LockdownStatus, Never>?
    private var enableCount = 0
    private var restoreCount = 0

    func enable(dryRun: Bool) async throws -> CoordinatorResult {
        enableCount += 1
        return CoordinatorResult(
            status: currentStatus,
            dryRunPlan: dryRun ? DryRunPlan(changes: []) : nil
        )
    }

    func restore() async throws -> RestoreResult {
        restoreCount += 1
        return RestoreResult(expectedIDs: [], statuses: [])
    }

    func status() async -> LockdownStatus {
        statusCallCount += 1
        guard statusCallCount > 1 else {
            return currentStatus
        }

        signalDelayedStatusStart()
        return await withCheckedContinuation { continuation in
            delayedStatusContinuation = continuation
        }
    }

    func hasRecoveryState() async -> Bool {
        true
    }

    func waitUntilDelayedStatusStarts() async {
        if unobservedDelayedStatusStarts > 0 {
            unobservedDelayedStatusStarts -= 1
            return
        }
        await withCheckedContinuation { continuation in
            delayedStatusStartWaiters.append(continuation)
        }
    }

    func completeDelayedStatus() {
        delayedStatusContinuation?.resume(returning: currentStatus)
        delayedStatusContinuation = nil
    }

    func mutationCounts() -> (enable: Int, restore: Int) {
        (enableCount, restoreCount)
    }

    func statusCalls() -> Int {
        statusCallCount
    }

    private func signalDelayedStatusStart() {
        if let waiter = delayedStatusStartWaiters.first {
            delayedStatusStartWaiters.removeFirst()
            waiter.resume()
        } else {
            unobservedDelayedStatusStarts += 1
        }
    }
}

private struct CommandKey: Hashable, Sendable {
    let executable: String
    let arguments: [String]
}

private final class RecordingCommandRunner: @unchecked Sendable, CommandRunning {
    private let lock = NSLock()
    private let results: [CommandKey: CommandResult]
    private var storedCommands: [CommandKey] = []

    init(results: [CommandKey: CommandResult]) {
        self.results = results
    }

    var commands: [CommandKey] {
        lock.withLock { storedCommands }
    }

    func run(executable: String, arguments: [String]) throws -> CommandResult {
        let command = CommandKey(executable: executable, arguments: arguments)
        lock.withLock {
            storedCommands.append(command)
        }
        guard let result = results[command] else {
            throw FakeReadError.unavailable
        }
        return result
    }
}

private final class FakePreflightReadbackChecker: @unchecked Sendable,
    PreflightReadbackChecking
{
    private let lock = NSLock()
    private let usbAccessoryApproval: Verification
    private let privateWiFiAddress: Verification
    private var storedUSBReadCount = 0
    private var storedPrivateWiFiReadCount = 0

    init(
        usbAccessoryApproval: Verification,
        privateWiFiAddress: Verification
    ) {
        self.usbAccessoryApproval = usbAccessoryApproval
        self.privateWiFiAddress = privateWiFiAddress
    }

    var usbReadCount: Int {
        lock.withLock { storedUSBReadCount }
    }

    var privateWiFiReadCount: Int {
        lock.withLock { storedPrivateWiFiReadCount }
    }

    func readUSBAccessoryApproval() -> Verification {
        lock.withLock {
            storedUSBReadCount += 1
        }
        return usbAccessoryApproval
    }

    func readPrivateWiFiAddress() -> Verification {
        lock.withLock {
            storedPrivateWiFiReadCount += 1
        }
        return privateWiFiAddress
    }
}

private enum FakeReadError: Error {
    case unavailable
}

private final class FakePreflightProvider: @unchecked Sendable, PreflightProviding {
    private let lock = NSLock()
    private let report: PreflightReport
    private var storedRunCount = 0

    init(report: PreflightReport = .init(items: [])) {
        self.report = report
    }

    var runCount: Int {
        lock.withLock { storedRunCount }
    }

    func runPreflight() async -> PreflightReport {
        lock.withLock {
            storedRunCount += 1
        }
        return report
    }
}
