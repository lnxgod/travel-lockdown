enum ControlID: String, Codable, CaseIterable, Hashable, Sendable {
    case bluetooth
    case continuity
    case wifiPolicy
    case ingress
    case wake
}

enum Verification: String, Codable, Equatable, Sendable {
    case compliant
    case nonCompliant
    case unavailable
    case failed
}

struct ControlStatus: Codable, Equatable, Sendable {
    let id: ControlID
    let verification: Verification
    let detail: String
    let manualRecovery: ManualRecoveryInstruction?

    init(
        id: ControlID,
        verification: Verification,
        detail: String,
        manualRecovery: ManualRecoveryInstruction? = nil
    ) {
        self.id = id
        self.verification = verification
        self.detail = detail
        self.manualRecovery = manualRecovery
    }
}

struct ManualRecoveryInstruction: Codable, Equatable, Sendable {
    enum Confirmation: String, Codable, Equatable, Sendable {
        case unavailable
        case userAttestation
    }

    let pane: String
    let action: String
    let confirmation: Confirmation

    init(
        pane: String,
        action: String,
        confirmation: Confirmation = .unavailable
    ) {
        self.pane = pane
        self.action = action
        self.confirmation = confirmation
    }
}

struct LockdownStatus: Equatable, Sendable {
    let controls: [ControlStatus]

    static func make(controls: [ControlStatus]) -> LockdownStatus {
        LockdownStatus(controls: controls)
    }

    var isActive: Bool {
        ControlID.allCases.allSatisfy { control in
            let matchingControls = controls.filter { $0.id == control }
            return matchingControls.count == 1 && matchingControls[0].verification == .compliant
        }
    }

    var isClearlyUnlocked: Bool {
        ControlID.allCases.allSatisfy { control in
            let matchingControls = controls.filter { $0.id == control }
            return matchingControls.count == 1
                && matchingControls[0].verification == .nonCompliant
        }
    }
}
