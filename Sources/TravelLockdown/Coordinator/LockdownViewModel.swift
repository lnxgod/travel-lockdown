import Combine
import Foundation

struct LockdownConfirmation: Equatable, Identifiable, Sendable {
    let id: UUID
    let reviewID: UUID
    let title: String
    let message: String

    static func enableImpact(for reviewID: UUID) -> LockdownConfirmation {
        LockdownConfirmation(
            id: UUID(),
            reviewID: reviewID,
            title: "Enable Travel Lockdown?",
            message: "Bluetooth devices and Apple Watch Auto Unlock will stop working. "
                + "Handoff, AirDrop, AirPlay Receiver, sharing and remote administration, "
                + "and inbound connections will be disabled. Wi-Fi auto-join will be disabled. "
                + "The current Wi-Fi connection is not intentionally disconnected; after a drop, "
                + "reconnect to Wi-Fi manually. Touch ID and password settings are not changed."
        )
    }
}

struct RestoreConfirmation: Equatable, Identifiable, Sendable {
    let id: UUID
    let title: String
    let message: String

    static func normalState() -> RestoreConfirmation {
        RestoreConfirmation(
            id: UUID(),
            title: "Restore Normal State?",
            message: "Travel Lockdown will restore every supported setting from the captured "
                + "baseline. Controls that macOS cannot verify automatically will remain visible "
                + "as manual recovery steps."
        )
    }
}

enum LockdownOperationPhase: Equatable, Sendable {
    case idle
    case preparingRecovery
    case preparingPlan
    case enabling
    case restoring
}

enum LockdownModeState: Equatable, Sendable {
    case off
    case verified
    case attention
    case unmanaged
}

struct DryRunPlanReview: Equatable, Identifiable, Sendable {
    let id: UUID
    let plan: DryRunPlan

    var title: String {
        "Review Travel Lockdown Plan"
    }

    var message: String {
        guard !plan.changes.isEmpty else {
            return "No changes are planned."
        }
        return plan.changes.map(\.menuSummary).joined(separator: "\n")
    }
}

struct OperationAttention: Equatable, Sendable {
    let message: String

    var isNonSecretFailure: Bool { true }

    static let enableFailed = OperationAttention(
        message: "Travel Lockdown could not complete the enable operation."
    )
    static let restoreFailed = OperationAttention(
        message: "Travel Lockdown could not complete recovery."
    )
    static let restoreIncomplete = OperationAttention(
        message: "Recovery incomplete: one or more controls did not verify."
    )
    static let manualRecoveryRequired = OperationAttention(
        message: "Manual recovery required: one or more controls remain incomplete."
    )
    static let recoverySetupFailed = OperationAttention(
        message: "Recovery snapshot setup failed without changing any settings."
    )
    static let normalPostureRequired = OperationAttention(
        message: "Recovery setup stopped because the current posture is locked or ambiguous. "
            + "Restore a clearly normal state first; the app will not bless lockdown settings "
            + "as your recovery target."
    )
    static let legacyRecoveryNotReady = OperationAttention(
        message: "The older recovery snapshot cannot be replaced until every automatic setting "
            + "has been restored and verified. The original snapshot was kept unchanged."
    )
}

struct ManualRecoveryPrompt: Equatable, Identifiable, Sendable {
    let id: UUID
    let instructions: [ManualRecoveryInstruction]
    let recoveryToken: String?

    var message: String {
        instructions.map { "\($0.action) in \($0.pane)" }.joined(separator: "\n")
    }

    var canConfirmCompletion: Bool {
        !instructions.isEmpty
            && recoveryToken != nil
            && instructions.allSatisfy { $0.confirmation == .userAttestation }
    }
}

@MainActor
final class LockdownViewModel: ObservableObject {
    @Published private(set) var status: LockdownStatus?
    @Published private(set) var preflightReport: PreflightReport?
    @Published private(set) var pendingPlanReview: DryRunPlanReview?
    @Published private(set) var pendingConfirmation: LockdownConfirmation?
    @Published private(set) var pendingRestoreConfirmation: RestoreConfirmation?
    @Published private(set) var operationPhase: LockdownOperationPhase = .idle
    @Published private(set) var isRestoreAvailable = false
    @Published private(set) var recoveryState: RecoveryState = .none
    @Published private(set) var preparedRecoveryMatchesCurrent: Bool?
    @Published private(set) var isRecoverySetupPresented = false
    @Published private(set) var recoverySetupProfile = RecoverySetupProfile.recommended
    @Published private(set) var recoverySetupReview: RecoverySetupReview?
    @Published private(set) var isStatusRefreshInProgress = false
    @Published private(set) var isStartupHydrationInProgress = false
    @Published private(set) var isStartupHydrated = false
    @Published private(set) var recoveryAttention: [RestorationStatus]?
    @Published private(set) var operationAttention: OperationAttention?
    @Published private(set) var manualRecoveryPrompt: ManualRecoveryPrompt?

    private let coordinator: any LockdownCoordinating
    private let preflightProvider: any PreflightProviding
    private var enableWorkflow: EnableWorkflow = .idle
    private var inFlightDryRunIDs: Set<UUID> = []

    init(
        coordinator: any LockdownCoordinating,
        preflightProvider: any PreflightProviding
    ) {
        self.coordinator = coordinator
        self.preflightProvider = preflightProvider
    }

    var lockdownModeState: LockdownModeState {
        if recoveryState == .active {
            return status?.isActive == true ? .verified : .attention
        }
        if recoveryState == .prepared {
            return preparedRecoveryMatchesCurrent == true ? .off : .unmanaged
        }
        return status == nil ? .off : .unmanaged
    }

    var isLockdownModeInteractionDisabled: Bool {
        !isStartupHydrated
            || operationPhase != .idle
            || pendingPlanReview != nil
            || pendingConfirmation != nil
            || pendingRestoreConfirmation != nil
            || isRecoverySetupPresented
            || isStatusRefreshInProgress
            || (recoveryState == .prepared && preparedRecoveryMatchesCurrent != true)
    }

    var isLockdownModeToggleDisabled: Bool {
        isLockdownModeInteractionDisabled || lockdownModeState == .unmanaged
    }

    var canReplaceLegacyRecovery: Bool {
        guard recoveryState == .active,
              let prompt = manualRecoveryPrompt,
              !prompt.instructions.isEmpty else {
            return false
        }
        return prompt.instructions.allSatisfy { $0.confirmation == .unavailable }
    }

    @discardableResult
    func beginStartupHydration() -> Task<Void, Never>? {
        guard !isStartupHydrated,
              !isStartupHydrationInProgress,
              !isStatusRefreshInProgress else {
            return nil
        }
        isStartupHydrationInProgress = true
        return Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            await self.refreshStatus()
            self.isStartupHydrationInProgress = false
            self.isStartupHydrated = true
        }
    }

    @discardableResult
    func requestEnable() -> Task<Void, Never>? {
        guard !isStartupHydrationInProgress,
              !isStatusRefreshInProgress,
              operationPhase == .idle,
              pendingRestoreConfirmation == nil,
              case .idle = enableWorkflow else {
            return nil
        }
        let reviewID = UUID()
        enableWorkflow = .dryRunInFlight(reviewID)
        operationPhase = .preparingPlan
        operationAttention = nil
        inFlightDryRunIDs.insert(reviewID)

        return Task {
            let result: CoordinatorResult?
            do {
                result = try await coordinator.enable(dryRun: true)
            } catch {
                result = nil
            }
            inFlightDryRunIDs.remove(reviewID)
            guard case .dryRunInFlight(let activeReviewID) = enableWorkflow,
                  activeReviewID == reviewID else {
                return
            }
            guard let plan = result?.dryRunPlan else {
                enableWorkflow = .idle
                operationPhase = .idle
                operationAttention = .enableFailed
                return
            }
            let review = DryRunPlanReview(id: reviewID, plan: plan)
            enableWorkflow = .awaitingPlanReview(review)
            operationPhase = .idle
            pendingPlanReview = review
        }
    }

    @discardableResult
    func requestLockdownModeToggle() -> Task<Void, Never>? {
        if recoveryState == .active {
            requestRestore()
            return nil
        }
        guard recoveryState == .prepared,
              preparedRecoveryMatchesCurrent == true,
              lockdownModeState == .off else {
            return nil
        }
        return requestEnable()
    }

    func acknowledgePlanReview() {
        guard case .awaitingPlanReview(let review) = enableWorkflow,
              pendingPlanReview?.id == review.id else {
            return
        }
        pendingPlanReview = nil
        let confirmation = LockdownConfirmation.enableImpact(for: review.id)
        enableWorkflow = .awaitingConfirmation(
            reviewID: review.id,
            confirmation: confirmation
        )
        pendingConfirmation = confirmation
    }

    func cancelEnable() {
        switch enableWorkflow {
        case .dryRunInFlight(let reviewID):
            // The coordinator's read-only work may not cooperate with Task cancellation.
            // Retire this request logically so a hung, cancelled review cannot make a
            // later visible confirmation a permanent no-op. Its stale result is still
            // rejected by the workflow ID guard in requestEnable().
            inFlightDryRunIDs.remove(reviewID)
            enableWorkflow = .idle
            operationPhase = .idle
            pendingPlanReview = nil
            pendingConfirmation = nil
        case .awaitingPlanReview, .awaitingConfirmation:
            enableWorkflow = .idle
            operationPhase = .idle
            pendingPlanReview = nil
            pendingConfirmation = nil
        case .idle, .enabling:
            return
        }
    }

    @discardableResult
    func confirmEnable() -> Task<Void, Never>? {
        guard case .awaitingConfirmation(let reviewID, let confirmation) = enableWorkflow,
              confirmation.reviewID == reviewID,
              pendingConfirmation?.id == confirmation.id,
              !isStatusRefreshInProgress,
              inFlightDryRunIDs.isEmpty else {
            return nil
        }
        pendingConfirmation = nil
        enableWorkflow = .enabling(reviewID)
        operationPhase = .enabling

        return Task {
            do {
                let result = try await coordinator.enable(dryRun: false)
                status = result.status
                operationAttention = nil
                recoveryAttention = nil
                manualRecoveryPrompt = nil
                publishManualRecovery(
                    from: result.status.controls.compactMap(\.manualRecovery),
                    recoveryToken: nil
                )
            } catch {
                operationAttention = .enableFailed
                status = await coordinator.status()
            }
            await refreshRecoveryState()
            guard case .enabling(let activeReviewID) = enableWorkflow,
                  activeReviewID == reviewID else {
                return
            }
            enableWorkflow = .idle
            operationPhase = .idle
        }
    }

    func requestRestore() {
        guard isRestoreAvailable,
              !isStatusRefreshInProgress,
              operationPhase == .idle,
              pendingRestoreConfirmation == nil,
              case .idle = enableWorkflow else {
            return
        }
        pendingRestoreConfirmation = .normalState()
    }

    func cancelRestore() {
        guard pendingRestoreConfirmation != nil,
              !isStatusRefreshInProgress,
              operationPhase == .idle else {
            return
        }
        pendingRestoreConfirmation = nil
    }

    @discardableResult
    func confirmRestore() -> Task<Void, Never>? {
        guard pendingRestoreConfirmation != nil,
              !isStatusRefreshInProgress,
              operationPhase == .idle else {
            return nil
        }
        pendingRestoreConfirmation = nil
        operationPhase = .restoring
        return Task {
            await restoreNormalState()
            if operationPhase == .restoring {
                operationPhase = .idle
            }
        }
    }

    func restoreNormalState() async {
        guard !isStatusRefreshInProgress else {
            return
        }
        do {
            let result = try await coordinator.restore()
            if result.isFullyRestored {
                recoveryAttention = nil
                operationAttention = nil
                manualRecoveryPrompt = nil
            } else {
                let mismatches = result.statuses.filter { !$0.matchesSnapshot }
                let returnedIDs = Set(result.statuses.map(\.id))
                let missing = result.expectedIDs
                    .subtracting(returnedIDs)
                    .sorted { $0.rawValue < $1.rawValue }
                    .map {
                        RestorationStatus(
                            id: $0,
                            matchesSnapshot: false,
                            detail: "Recovery verification was not returned for this control"
                        )
                    }
                let incomplete = mismatches + missing
                recoveryAttention = incomplete.isEmpty ? nil : incomplete
                let manualInstructions = result.statuses.compactMap(\.manualRecovery)
                if manualInstructions.isEmpty {
                    operationAttention = .restoreIncomplete
                    manualRecoveryPrompt = nil
                } else {
                    operationAttention = .manualRecoveryRequired
                    publishManualRecovery(
                        from: manualInstructions,
                        recoveryToken: result.recoveryToken
                    )
                }
            }
        } catch {
            operationAttention = .restoreFailed
        }
        status = await coordinator.status()
        await refreshRecoveryState()
    }

    func acknowledgeManualRecovery() {
        manualRecoveryPrompt = nil
    }

    @discardableResult
    func presentRecoverySetup() -> Task<Void, Never>? {
        guard recoveryState == .none || canReplaceLegacyRecovery,
              isStartupHydrated,
              operationPhase == .idle,
              !isStatusRefreshInProgress,
              !isRecoverySetupPresented else {
            return nil
        }
        recoverySetupProfile = .recommended
        recoverySetupReview = nil
        operationAttention = nil
        operationPhase = .preparingRecovery
        return Task {
            do {
                recoverySetupReview = try await coordinator.reviewRecoverySetup()
                isRecoverySetupPresented = true
            } catch RecoverySetupError.normalPostureRequired {
                operationAttention = .normalPostureRequired
            } catch RecoverySetupError.legacyRecoveryNotEligible {
                operationAttention = .legacyRecoveryNotReady
            } catch {
                operationAttention = .recoverySetupFailed
            }
            operationPhase = .idle
        }
    }

    func cancelRecoverySetup() {
        guard operationPhase == .idle else { return }
        isRecoverySetupPresented = false
        recoverySetupReview = nil
    }

    func setAirPlayReceiverEnabled(_ isEnabled: Bool) {
        recoverySetupProfile.airPlayReceiver = AirPlayReceiverBaseline(
            isEnabled: isEnabled,
            access: recoverySetupProfile.airPlayReceiver.access,
            requiresPassword: recoverySetupProfile.airPlayReceiver.requiresPassword
        )
    }

    func setAirPlayReceiverAccess(_ access: AirPlayReceiverAccess) {
        recoverySetupProfile.airPlayReceiver = AirPlayReceiverBaseline(
            isEnabled: recoverySetupProfile.airPlayReceiver.isEnabled,
            access: access,
            requiresPassword: recoverySetupProfile.airPlayReceiver.requiresPassword
        )
    }

    func setAirPlayReceiverPasswordRequired(_ isRequired: Bool) {
        recoverySetupProfile.airPlayReceiver = AirPlayReceiverBaseline(
            isEnabled: recoverySetupProfile.airPlayReceiver.isEnabled,
            access: recoverySetupProfile.airPlayReceiver.access,
            requiresPassword: isRequired
        )
    }

    func setPersonalHotspotAutoJoin(_ mode: PersonalHotspotAutoJoinMode) {
        recoverySetupProfile.personalHotspotAutoJoin = mode
    }

    func setSharingService(_ service: SharingService, enabled: Bool) {
        recoverySetupProfile.sharingServices[service] = enabled
    }

    @discardableResult
    func confirmRecoverySetup() -> Task<Void, Never>? {
        guard isRecoverySetupPresented,
              let review = recoverySetupReview,
              (review.purpose == .newSnapshot && recoveryState == .none
                || review.purpose == .legacyReplacement && recoveryState == .active),
              operationPhase == .idle,
              !isStatusRefreshInProgress else {
            return nil
        }
        let profile = recoverySetupProfile
        operationPhase = .preparingRecovery
        return Task {
            do {
                _ = try await coordinator.prepareRecovery(
                    profile: profile,
                    reviewToken: review.token
                )
                operationAttention = nil
                isRecoverySetupPresented = false
                recoverySetupReview = nil
                if review.purpose == .legacyReplacement {
                    manualRecoveryPrompt = nil
                    recoveryAttention = nil
                }
            } catch RecoverySetupError.normalPostureRequired {
                operationAttention = .normalPostureRequired
            } catch RecoverySetupError.legacyRecoveryNotEligible {
                operationAttention = .legacyRecoveryNotReady
            } catch {
                operationAttention = .recoverySetupFailed
            }
            await refreshRecoveryState()
            status = await coordinator.status()
            operationPhase = .idle
        }
    }

    @discardableResult
    func rebuildPreparedRecovery() -> Task<Void, Never>? {
        guard recoveryState == .prepared,
              preparedRecoveryMatchesCurrent != true,
              operationPhase == .idle,
              !isStatusRefreshInProgress,
              !isRecoverySetupPresented else {
            return nil
        }
        operationPhase = .preparingRecovery
        operationAttention = nil
        return Task {
            do {
                try await coordinator.discardPreparedRecovery()
                recoveryState = .none
                preparedRecoveryMatchesCurrent = nil
                recoverySetupProfile = .recommended
                recoverySetupReview = try await coordinator.reviewRecoverySetup()
                isRecoverySetupPresented = true
            } catch {
                operationAttention = .recoverySetupFailed
                await refreshRecoveryState()
            }
            operationPhase = .idle
        }
    }

    @discardableResult
    func confirmManualRecoveryCompletion() -> Task<Void, Never>? {
        guard let prompt = manualRecoveryPrompt,
              let recoveryToken = prompt.recoveryToken,
              prompt.canConfirmCompletion,
              recoveryState == .active,
              operationPhase == .idle,
              !isStatusRefreshInProgress else {
            return nil
        }
        operationPhase = .restoring
        return Task {
            do {
                let result = try await coordinator.completeManualRecovery(
                    token: recoveryToken,
                    instructions: prompt.instructions
                )
                if result.isFullyRestored {
                    manualRecoveryPrompt = nil
                    recoveryAttention = nil
                    operationAttention = nil
                } else {
                    recoveryAttention = result.statuses.filter { !$0.matchesSnapshot }
                    operationAttention = .restoreIncomplete
                }
            } catch {
                operationAttention = .restoreFailed
            }
            status = await coordinator.status()
            await refreshRecoveryState()
            operationPhase = .idle
        }
    }

    func refreshStatus() async {
        guard !isStatusRefreshInProgress,
              operationPhase == .idle,
              pendingPlanReview == nil,
              pendingConfirmation == nil,
              pendingRestoreConfirmation == nil,
              case .idle = enableWorkflow else {
            return
        }
        isStatusRefreshInProgress = true
        defer { isStatusRefreshInProgress = false }

        let refreshedStatus = await coordinator.status()
        let refreshedRecoveryState = await coordinator.recoveryState()
        status = refreshedStatus
        recoveryState = refreshedRecoveryState
        isRestoreAvailable = refreshedRecoveryState == .active
        preparedRecoveryMatchesCurrent = refreshedRecoveryState == .prepared
            ? await coordinator.preparedRecoveryMatchesCurrent()
            : nil
    }

    func refreshStatusIfIdle() async {
        guard !isStartupHydrationInProgress,
              !isStatusRefreshInProgress,
              operationPhase == .idle,
              pendingPlanReview == nil,
              pendingConfirmation == nil,
              pendingRestoreConfirmation == nil,
              case .idle = enableWorkflow else {
            return
        }
        await refreshStatus()
    }

    func runPreflight() async {
        preflightReport = await preflightProvider.runPreflight()
    }

    private func publishManualRecovery(
        from instructions: [ManualRecoveryInstruction],
        recoveryToken: String?
    ) {
        guard !instructions.isEmpty else { return }
        manualRecoveryPrompt = ManualRecoveryPrompt(
            id: UUID(),
            instructions: instructions,
            recoveryToken: recoveryToken
        )
    }

    private func refreshRecoveryState() async {
        recoveryState = await coordinator.recoveryState()
        isRestoreAvailable = recoveryState == .active
        preparedRecoveryMatchesCurrent = recoveryState == .prepared
            ? await coordinator.preparedRecoveryMatchesCurrent()
            : nil
    }

    private enum EnableWorkflow {
        case idle
        case dryRunInFlight(UUID)
        case awaitingPlanReview(DryRunPlanReview)
        case awaitingConfirmation(reviewID: UUID, confirmation: LockdownConfirmation)
        case enabling(UUID)
    }
}
