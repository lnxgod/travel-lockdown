import SwiftUI

enum MenuPanelLayout {
    static let width: CGFloat = 360
    static let dashboardViewportHeight: CGFloat = 380
}

struct MenuView: View {
    @ObservedObject var model: LockdownViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            lockdownControl
                .padding(.horizontal, 14)
                .padding(.top, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    workflowPanel
                        .disabled(model.isStatusRefreshInProgress)
                    recoveryAttention
                    statusResults
                    preflightResults
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .frame(height: MenuPanelLayout.dashboardViewportHeight)

            Divider()
            footer
        }
        .frame(width: MenuPanelLayout.width)
        .onAppear {
            Task { await model.refreshStatusIfIdle() }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            GameChangersBrandLogo(size: 42)
            VStack(alignment: .leading, spacing: 1) {
                Text("TRAVEL LOCKDOWN")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                Text("A free GameChangers AI tool")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(modeBadge)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(modeColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(modeColor.opacity(0.12), in: Capsule())
        }
        .padding(14)
    }

    private var lockdownControl: some View {
        HStack(spacing: 12) {
            Image(
                systemName: model.lockdownModeState == .off
                    ? "wave.3.right"
                    : "shield.checkered"
            )
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(modeColor)
                .frame(width: 28, height: 28)
                .background(modeColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text("Lockdown Mode")
                    .font(.headline)
                Text(modeDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)
            Button {
                model.requestLockdownModeToggle()
            } label: {
                LockdownSwitch(state: model.lockdownModeState)
            }
                .buttonStyle(.plain)
                .disabled(model.isLockdownModeToggleDisabled)
                .accessibilityLabel("Lockdown Mode")
                .accessibilityValue(lockdownAccessibilityValue)
                .accessibilityHint(lockdownAccessibilityHint)
                .accessibilityIdentifier("lockdown-mode-toggle")
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(modeColor.opacity(0.22), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var workflowPanel: some View {
        if model.isStatusRefreshInProgress {
            progressCard(
                title: "Refreshing status",
                detail: "Verifying supported controls. No settings are being changed."
            )
        } else {
            switch model.operationPhase {
            case .preparingRecovery:
                progressCard(
                    title: "Preparing recovery snapshot",
                    detail: "Reading settings twice for a stable review. Nothing is being changed."
                )
            case .preparingPlan:
                progressCard(
                    title: "Preparing lockdown plan",
                    detail: "Reading supported controls. Nothing is being changed."
                )
            case .enabling:
                progressCard(
                    title: "Applying and verifying",
                    detail: "Lockdown is not marked on until recovery state is safely captured."
                )
            case .restoring:
                progressCard(
                    title: "Restoring normal state",
                    detail: "Comparing every supported setting with the captured baseline."
                )
            case .idle:
                if model.isRecoverySetupPresented {
                    recoverySetupCard
                } else if let review = model.pendingPlanReview {
                    actionCard(title: review.title, symbol: "list.clipboard") {
                        if review.plan.changes.isEmpty {
                            Text("No changes are currently planned.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(review.plan.changes.enumerated()), id: \.offset) { _, change in
                                Label(change.menuSummary, systemImage: "checkmark.circle")
                                    .font(.caption)
                            }
                        }
                        HStack {
                            Button("Cancel") {
                                model.cancelEnable()
                            }
                            Spacer()
                            Button("Continue") {
                                model.acknowledgePlanReview()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                } else if let confirmation = model.pendingConfirmation {
                    actionCard(title: confirmation.title, symbol: "exclamationmark.shield") {
                        Text(confirmation.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("Cancel") {
                                model.cancelEnable()
                            }
                            Spacer()
                            Button("Enable Lockdown", role: .destructive) {
                                model.confirmEnable()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                        }
                    }
                } else if let confirmation = model.pendingRestoreConfirmation {
                    actionCard(title: confirmation.title, symbol: "arrow.uturn.backward.circle") {
                        Text(confirmation.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("Cancel") {
                                model.cancelRestore()
                            }
                            Spacer()
                            Button("Restore Normal State") {
                                model.confirmRestore()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
            }
        }
    }

    private var recoverySetupCard: some View {
        actionCard(
            title: model.recoverySetupReview?.purpose == .legacyReplacement
                ? "Finish Legacy Recovery"
                : "Set Up Recovery Snapshot",
            symbol: "externaldrive.badge.checkmark"
        ) {
            Text(
                model.recoverySetupReview?.purpose == .legacyReplacement
                    ? "The older snapshot preserved and restored its automatic values, but did "
                        + "not record AirPlay, Personal Hotspot, or Sharing. Choose those normal "
                        + "values now. The old snapshot stays intact unless verification succeeds."
                    : "Automatic settings are captured exactly. Review the settings macOS requires "
                        + "you to restore manually. No Wi-Fi, Bluetooth, or security setting changes "
                        + "when this snapshot is saved."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if let review = model.recoverySetupReview {
                GroupBox("Current automatic settings") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(review.items.enumerated()), id: \.offset) { _, item in
                            Label(item.summary, systemImage: "checkmark.circle")
                                .font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text(
                    "These exact values will be re-read before saving and again before Lockdown "
                        + "can turn on. If anything changes, setup stops instead of guessing."
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Toggle(
                "AirPlay Receiver normally on",
                isOn: Binding(
                    get: { model.recoverySetupProfile.airPlayReceiver.isEnabled },
                    set: { model.setAirPlayReceiverEnabled($0) }
                )
            )
            if model.recoverySetupProfile.airPlayReceiver.isEnabled {
                Picker(
                    "AirPlay access",
                    selection: Binding(
                        get: { model.recoverySetupProfile.airPlayReceiver.access },
                        set: { model.setAirPlayReceiverAccess($0) }
                    )
                ) {
                    ForEach(AirPlayReceiverAccess.allCases, id: \.self) { access in
                        Text(access.title).tag(access)
                    }
                }
                Toggle(
                    "AirPlay normally requires a password",
                    isOn: Binding(
                        get: {
                            model.recoverySetupProfile.airPlayReceiver.requiresPassword
                        },
                        set: { model.setAirPlayReceiverPasswordRequired($0) }
                    )
                )
            }

            Picker(
                "Personal Hotspot auto-join",
                selection: Binding(
                    get: { model.recoverySetupProfile.personalHotspotAutoJoin },
                    set: { model.setPersonalHotspotAutoJoin($0) }
                )
            ) {
                ForEach(PersonalHotspotAutoJoinMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }

            DisclosureGroup("Normal Sharing services") {
                ForEach(SharingService.allCases, id: \.self) { service in
                    Toggle(
                        service.rawValue,
                        isOn: Binding(
                            get: {
                                model.recoverySetupProfile.sharingServices[service] == true
                            },
                            set: { model.setSharingService(service, enabled: $0) }
                        )
                    )
                }
            }

            Text(
                "The snapshot stores Wi-Fi profile metadata for restoration, never passwords "
                    + "or authentication tokens. Touch ID, passwords, accounts, and FileVault "
                    + "are not changed."
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Cancel") {
                    model.cancelRecoverySetup()
                }
                Spacer()
                Button(
                    model.recoverySetupReview?.purpose == .legacyReplacement
                        ? "Finish Recovery & Prepare Snapshot"
                        : "Save Reviewed Snapshot"
                ) {
                    model.confirmRecoverySetup()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .accessibilityIdentifier("recovery-setup-card")
    }

    private func progressCard(title: String, detail: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func actionCard<Content: View>(
        title: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var statusResults: some View {
        GroupBox("Status") {
            if let status = model.status {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(status.controls.enumerated()), id: \.offset) { _, control in
                        Label(
                            Self.statusText(for: control),
                            systemImage: Self.statusSymbol(for: control.verification)
                        )
                        .font(.caption)
                        .foregroundStyle(Self.statusColor(for: control.verification))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Label("Waiting for the read-only status check", systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("status-results")
    }

    @ViewBuilder
    private var recoveryAttention: some View {
        if model.recoveryState == .prepared,
           model.preparedRecoveryMatchesCurrent != true {
            VStack(alignment: .leading, spacing: 6) {
                Label("Prepared snapshot needs a fresh review", systemImage: "arrow.triangle.2.circlepath")
                    .font(.subheadline.weight(.semibold))
                Text(
                    "Current settings no longer exactly match the prepared snapshot, or they "
                        + "could not be verified. Lockdown remains disabled until it is rebuilt."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Button("Rebuild Recovery Snapshot") {
                    model.rebuildPreparedRecovery()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("rebuild-recovery-snapshot")
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityIdentifier("stale-recovery-baseline")
        } else if model.recoveryState == .none,
                  model.lockdownModeState == .unmanaged {
            VStack(alignment: .leading, spacing: 6) {
                Label("Recovery snapshot missing", systemImage: "exclamationmark.shield.fill")
                    .font(.subheadline.weight(.semibold))
                Text(
                    "A recovery baseline is not available. Establish a reviewed normal-state "
                        + "snapshot before Lockdown can be enabled."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Button("Set Up Recovery Snapshot") {
                    model.presentRecoverySetup()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isRecoverySetupPresented)
                .accessibilityIdentifier("setup-recovery-snapshot")
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityIdentifier("missing-recovery-baseline")
        }
        if let attention = model.operationAttention {
            Label(attention.message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        }
        if let recovery = model.recoveryAttention {
            ForEach(Array(recovery.enumerated()), id: \.offset) { _, item in
                Label("\(item.id.rawValue): \(item.detail)", systemImage: "wrench.and.screwdriver")
                    .font(.caption)
            }
        }
        if let prompt = model.manualRecoveryPrompt {
            Label("Manual recovery required", systemImage: "hand.raised.fill")
                .font(.subheadline.weight(.semibold))
            ForEach(Array(prompt.instructions.enumerated()), id: \.offset) { _, instruction in
                Text(Self.manualRecoveryText(for: instruction))
                    .font(.caption)
            }
            if prompt.canConfirmCompletion {
                Button("I Completed These Settings") {
                    model.confirmManualRecoveryCompletion()
                }
            } else {
                Text(
                    "This older snapshot did not record the exact prior values for these settings. "
                        + "Review the values you want as normal to finish recovery safely."
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Dismiss") {
                        model.acknowledgeManualRecovery()
                    }
                    Spacer()
                    Button("Review Missing Recovery Settings") {
                        model.presentRecoverySetup()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    static func statusText(for status: ControlStatus) -> String {
        "\(status.id.rawValue): \(status.verification.rawValue) — \(status.detail)"
    }

    static func manualRecoveryText(for instruction: ManualRecoveryInstruction) -> String {
        "\(instruction.action) in \(instruction.pane)"
    }

    @ViewBuilder
    private var preflightResults: some View {
        GroupBox("Preflight") {
            if let report = model.preflightReport {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(report.items.enumerated()), id: \.offset) { _, item in
                        Label(
                            "\(item.title): \(item.verification.rawValue)",
                            systemImage: Self.statusSymbol(for: item.verification)
                        )
                        .font(.caption)
                        if let path = item.systemSettingsPath {
                            Text(path)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Label("Use Preflight below for travel-readiness checks", systemImage: "checklist")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("preflight-results")
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                Task { await model.refreshStatus() }
            } label: {
                Label("Status", systemImage: "checkmark.shield")
            }
            .disabled(model.isLockdownModeInteractionDisabled)
            .accessibilityIdentifier("refresh-status")

            Button {
                Task { await model.runPreflight() }
            } label: {
                Label("Preflight", systemImage: "checklist")
            }
            .accessibilityIdentifier("run-preflight")

            Spacer()
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .help("Quit Travel Lockdown")
        }
        .buttonStyle(.borderless)
        .disabled(model.operationPhase != .idle || model.isStatusRefreshInProgress)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var markState: GameChangersMarkState {
        switch model.lockdownModeState {
        case .verified:
            return .active
        case .attention, .unmanaged:
            return .attention
        case .off:
            break
        }
        if model.operationAttention != nil {
            return .attention
        }
        return .off
    }

    private var modeBadge: String {
        if !model.isStartupHydrated {
            return "CHECKING"
        }
        if model.isStatusRefreshInProgress {
            return "VERIFYING"
        }
        if model.operationAttention != nil {
            return model.lockdownModeState == .off ? "ERROR" : "ATTENTION"
        }
        switch model.operationPhase {
        case .preparingRecovery:
            return "CAPTURING"
        case .preparingPlan:
            return "PLANNING"
        case .enabling:
            return "LOCKING"
        case .restoring:
            return "RESTORING"
        case .idle:
            switch model.lockdownModeState {
            case .verified:
                return "LOCKED"
            case .attention:
                return "ATTENTION"
            case .unmanaged:
                return model.recoveryState == .prepared ? "CHANGED" : "UNMANAGED"
            case .off:
                return "READY"
            }
        }
    }

    private var modeDetail: String {
        if !model.isStartupHydrated {
            return "Checking for an existing recovery baseline…"
        }
        if model.isStatusRefreshInProgress {
            return "Refreshing status without changing settings…"
        }
        switch model.operationPhase {
        case .preparingRecovery:
            return "Capturing a reviewed recovery snapshot without changing settings…"
        case .preparingPlan:
            return "Preparing a read-only plan…"
        case .enabling:
            return "Applying and verifying the travel posture…"
        case .restoring:
            return "Restoring the captured normal state…"
        case .idle:
            if let attention = model.operationAttention {
                return attention.message
            }
            if model.pendingPlanReview != nil {
                return "Review the plan below to continue."
            }
            if model.pendingConfirmation != nil {
                return "Final confirmation is required below."
            }
            if model.pendingRestoreConfirmation != nil {
                return "Confirm recovery below."
            }
            switch model.lockdownModeState {
            case .verified:
                return "Lockdown verified. Toggle off to restore."
            case .attention:
                return "Recovery state exists; review the attention items below."
            case .unmanaged:
                return model.recoveryState == .prepared
                    ? "The prepared snapshot needs a fresh review before Lockdown can turn on."
                    : "Set up a reviewed recovery snapshot before enabling Lockdown."
            case .off:
                return model.recoveryState == .prepared
                    ? "Recovery snapshot ready. Turn on when you are ready to travel."
                    : "Turn on to stop auto-join while keeping Wi-Fi available."
            }
        }
    }

    private var modeColor: Color {
        switch markState {
        case .off:
            return Color(red: 0.42, green: 0.36, blue: 0.94)
        case .active:
            return .green
        case .attention:
            return .orange
        }
    }

    private static func statusSymbol(for verification: Verification) -> String {
        switch verification {
        case .compliant:
            "checkmark.circle.fill"
        case .nonCompliant:
            "circle"
        case .unavailable:
            "questionmark.circle"
        case .failed:
            "exclamationmark.triangle.fill"
        }
    }

    private static func statusColor(for verification: Verification) -> Color {
        switch verification {
        case .compliant:
            .green
        case .nonCompliant:
            .secondary
        case .unavailable, .failed:
            .orange
        }
    }

    private var lockdownAccessibilityValue: String {
        switch model.lockdownModeState {
        case .off:
            "Off"
        case .verified:
            "On and verified"
        case .attention:
            "Indeterminate; recovery attention required"
        case .unmanaged:
            model.recoveryState == .prepared
                ? "Prepared snapshot changed or could not be verified"
                : "Unmanaged; recovery snapshot missing"
        }
    }

    private var lockdownAccessibilityHint: String {
        switch model.lockdownModeState {
        case .off:
            "Prepares a plan before confirmed activation"
        case .verified, .attention:
            "Starts confirmed recovery"
        case .unmanaged:
            model.recoveryState == .prepared
                ? "Rebuild the recovery snapshot before activation"
                : "Automatic changes are unavailable without a recovery snapshot"
        }
    }
}

private struct LockdownSwitch: View {
    let state: LockdownModeState

    var body: some View {
        ZStack {
            Capsule()
                .fill(trackColor.opacity(0.34))
            Capsule()
                .stroke(trackColor.opacity(0.65), lineWidth: 1)
            Circle()
                .fill(.white)
                .shadow(color: .black.opacity(0.24), radius: 1, y: 1)
                .padding(3)
                .offset(x: thumbOffset)
            if state == .attention || state == .unmanaged {
                Image(systemName: "exclamationmark")
                    .font(.system(size: 8, weight: .black))
                    .foregroundStyle(.orange)
            }
        }
        .frame(width: 42, height: 24)
        .contentShape(Capsule())
    }

    private var trackColor: Color {
        switch state {
        case .off:
            .secondary
        case .verified:
            .green
        case .attention, .unmanaged:
            .orange
        }
    }

    private var thumbOffset: CGFloat {
        switch state {
        case .off:
            -9
        case .verified:
            9
        case .attention, .unmanaged:
            0
        }
    }
}
