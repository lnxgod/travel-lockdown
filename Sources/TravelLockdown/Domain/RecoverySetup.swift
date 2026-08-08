import CryptoKit
import Foundation

enum RecoveryState: String, Codable, Equatable, Sendable {
    case none
    case prepared
    case active
    case invalid
}

enum AirPlayReceiverAccess: String, Codable, CaseIterable, Equatable, Sendable {
    case currentUser
    case anyoneOnSameNetwork
    case everyone

    var title: String {
        switch self {
        case .currentUser:
            "Current User"
        case .anyoneOnSameNetwork:
            "Anyone on the Same Network"
        case .everyone:
            "Everyone"
        }
    }
}

enum PersonalHotspotAutoJoinMode: String, Codable, CaseIterable, Equatable, Sendable {
    case never
    case askToJoin
    case automatic

    var title: String {
        switch self {
        case .never:
            "Never"
        case .askToJoin:
            "Ask To Join"
        case .automatic:
            "Automatic"
        }
    }
}

struct AirPlayReceiverBaseline: Codable, Equatable, Sendable {
    let isEnabled: Bool
    let access: AirPlayReceiverAccess
    let requiresPassword: Bool

    var recoveryInstruction: String {
        guard isEnabled else {
            return "Turn AirPlay Receiver off"
        }
        let passwordInstruction = requiresPassword
            ? "require a password"
            : "do not require a password"
        return "Turn AirPlay Receiver on, allow \(access.title), and \(passwordInstruction)"
    }
}

struct RecoverySetupProfile: Equatable, Sendable {
    var airPlayReceiver: AirPlayReceiverBaseline
    var personalHotspotAutoJoin: PersonalHotspotAutoJoinMode
    var sharingServices: [SharingService: Bool]

    static var recommended: RecoverySetupProfile {
        RecoverySetupProfile(
            airPlayReceiver: AirPlayReceiverBaseline(
                isEnabled: false,
                access: .currentUser,
                requiresPassword: true
            ),
            personalHotspotAutoJoin: .askToJoin,
            sharingServices: Dictionary(
                uniqueKeysWithValues: SharingService.allCases.map { ($0, false) }
            )
        )
    }

    func validated() throws -> RecoverySetupProfile {
        guard Set(sharingServices.keys) == Set(SharingService.allCases) else {
            throw RecoverySetupError.incompleteManualProfile
        }
        return self
    }

    static func reviewedProfile(in snapshots: [ControlSnapshot]) throws -> RecoverySetupProfile {
        guard let continuity = snapshots.first(where: { $0.id == .continuity }),
              let wifi = snapshots.first(where: { $0.id == .wifiPolicy }),
              let ingress = snapshots.first(where: { $0.id == .ingress }) else {
            throw RecoverySetupError.incompleteManualProfile
        }
        let continuitySnapshot = try continuity.decoded(
            as: ContinuitySnapshot.self,
            for: .continuity
        )
        let wifiSnapshot = try wifi.decoded(as: WiFiPolicySnapshot.self, for: .wifiPolicy)
        let ingressSnapshot = try ingress.decoded(as: IngressSnapshot.self, for: .ingress)
        guard let airPlay = continuitySnapshot.airPlayReceiverBaseline,
              let hotspot = wifiSnapshot.personalHotspotAutoJoin,
              ingressSnapshot.sharingRecovery.allSatisfy({ $0.isEnabled != nil }) else {
            throw RecoverySetupError.incompleteManualProfile
        }
        return try RecoverySetupProfile(
            airPlayReceiver: airPlay,
            personalHotspotAutoJoin: hotspot,
            sharingServices: Dictionary(
                uniqueKeysWithValues: ingressSnapshot.sharingRecovery.compactMap { marker in
                    marker.isEnabled.map { (marker.service, $0) }
                }
            )
        ).validated()
    }

    func reviewing(_ snapshot: ControlSnapshot) throws -> ControlSnapshot {
        switch snapshot.id {
        case .continuity:
            let captured = try snapshot.decoded(as: ContinuitySnapshot.self, for: .continuity)
            return try ControlSnapshot.capturing(
                ContinuitySnapshot(
                    activityAdvertisingAllowed: captured.activityAdvertisingAllowed,
                    activityReceivingAllowed: captured.activityReceivingAllowed,
                    discoverableMode: captured.discoverableMode,
                    airPlayReceiverBaseline: airPlayReceiver
                ),
                for: .continuity
            )
        case .wifiPolicy:
            let captured = try snapshot.decoded(as: WiFiPolicySnapshot.self, for: .wifiPolicy)
            return try ControlSnapshot.capturing(
                WiFiPolicySnapshot(
                    preferredNetworks: captured.preferredNetworks,
                    rememberJoinedNetworks: captured.rememberJoinedNetworks,
                    requireAdministratorForAssociation:
                        captured.requireAdministratorForAssociation,
                    requireAdministratorForPower: captured.requireAdministratorForPower,
                    requireAdministratorForIBSSMode: captured.requireAdministratorForIBSSMode,
                    personalHotspotAutoJoin: personalHotspotAutoJoin
                ),
                for: .wifiPolicy
            )
        case .ingress:
            let captured = try snapshot.decoded(as: IngressSnapshot.self, for: .ingress)
            return try ControlSnapshot.capturing(
                IngressSnapshot(
                    firewallEnabled: captured.firewallEnabled,
                    stealthModeEnabled: captured.stealthModeEnabled,
                    blockAllEnabled: captured.blockAllEnabled,
                    sharingRecovery: SharingService.allCases.map {
                        SharingRecoveryMarker(
                            service: $0,
                            isEnabled: sharingServices[$0]
                        )
                    }
                ),
                for: .ingress
            )
        case .bluetooth, .wake:
            return snapshot
        }
    }
}

struct RecoverySetupReviewItem: Equatable, Sendable {
    let control: ControlID
    let summary: String
}

enum RecoverySetupPurpose: String, Codable, Equatable, Sendable {
    case newSnapshot
    case legacyReplacement
    case preparedReplacement
}

struct RecoverySetupReview: Equatable, Sendable {
    let token: String
    let capturedAt: Date
    let items: [RecoverySetupReviewItem]
    let purpose: RecoverySetupPurpose

    init(
        token: String,
        capturedAt: Date,
        items: [RecoverySetupReviewItem],
        purpose: RecoverySetupPurpose = .newSnapshot
    ) {
        self.token = token
        self.capturedAt = capturedAt
        self.items = items
        self.purpose = purpose
    }

    static func make(
        from snapshots: [ControlSnapshot],
        capturedAt: Date = .now,
        token: String,
        purpose: RecoverySetupPurpose = .newSnapshot
    ) throws
        -> RecoverySetupReview
    {
        RecoverySetupReview(
            token: token,
            capturedAt: capturedAt,
            items: try snapshots.map(Self.reviewItem),
            purpose: purpose
        )
    }

    private static func reviewItem(_ snapshot: ControlSnapshot) throws -> RecoverySetupReviewItem {
        switch snapshot.id {
        case .bluetooth:
            let value = try snapshot.decoded(as: BluetoothSnapshot.self, for: .bluetooth)
            return RecoverySetupReviewItem(
                control: .bluetooth,
                summary: "Bluetooth currently \(value.isPoweredOn ? "on" : "off")"
            )
        case .continuity:
            let value = try snapshot.decoded(as: ContinuitySnapshot.self, for: .continuity)
            return RecoverySetupReviewItem(
                control: .continuity,
                summary: "Handoff advertising \(preferenceSummary(value.activityAdvertisingAllowed)); "
                    + "receiving \(preferenceSummary(value.activityReceivingAllowed)); "
                    + "AirDrop \(airDropSummary(value.discoverableMode))"
            )
        case .wifiPolicy:
            let value = try snapshot.decoded(as: WiFiPolicySnapshot.self, for: .wifiPolicy)
            return RecoverySetupReviewItem(
                control: .wifiPolicy,
                summary: "\(value.preferredNetworks.count) saved Wi-Fi profiles (names hidden); "
                    + "remember joined networks \(onOff(value.rememberJoinedNetworks)); "
                    + "administrator for association \(onOff(value.requireAdministratorForAssociation)); "
                    + "power \(onOff(value.requireAdministratorForPower)); "
                    + "legacy computer-to-computer mode \(onOff(value.requireAdministratorForIBSSMode))"
            )
        case .ingress:
            let value = try snapshot.decoded(as: IngressSnapshot.self, for: .ingress)
            return RecoverySetupReviewItem(
                control: .ingress,
                summary: "Firewall \(onOff(value.firewallEnabled)); stealth mode "
                    + "\(onOff(value.stealthModeEnabled)); block all inbound "
                    + "\(onOff(value.blockAllEnabled))"
            )
        case .wake:
            let value = try snapshot.decoded(as: WakeSnapshot.self, for: .wake)
            return RecoverySetupReviewItem(
                control: .wake,
                summary: "Wake for network access \(onOff(value.wakeForNetworkAccess))"
            )
        }
    }

    private static func onOff(_ value: Bool) -> String {
        value ? "on" : "off"
    }

    private static func preferenceSummary(_ value: PreferenceValue) -> String {
        switch value {
        case .missing:
            "not explicitly set"
        case .bool(let enabled):
            onOff(enabled)
        case .string:
            "custom"
        }
    }

    private static func airDropSummary(_ value: PreferenceValue) -> String {
        switch value {
        case .missing:
            "not explicitly set"
        case .bool:
            "custom"
        case .string(let mode):
            switch mode {
            case "Off": "off"
            case "ContactsOnly": "contacts only"
            case "Everyone": "everyone"
            default: "custom"
            }
        }
    }
}

enum RecoverySnapshotFingerprint {
    private struct PreparedReplacementReview: Encodable {
        let original: LockdownBaseline
        let snapshots: [ControlSnapshot]
    }

    static func snapshots(_ snapshots: [ControlSnapshot]) throws -> String {
        try digest(snapshots)
    }

    static func baseline(_ baseline: LockdownBaseline) throws -> String {
        try digest(baseline)
    }

    static func preparedReplacement(
        original: LockdownBaseline,
        snapshots: [ControlSnapshot]
    ) throws -> String {
        try digest(
            PreparedReplacementReview(
                original: original,
                snapshots: snapshots
            )
        )
    }

    static func tokenHash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func digest<Value: Encodable>(_ value: Value) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct RecoverySetupResult: Equatable, Sendable {
    let capturedAt: Date
    let controlCount: Int
}

enum RecoverySetupError: Error, Equatable {
    case captureFailed(ControlID)
    case incompleteManualProfile
    case recoveryStateAlreadyExists
    case recoveryStateRequired
    case recoveryStateNotActive
    case preparedBaselineDrifted
    case settingsChangedDuringReview
    case normalPostureRequired
    case legacyRecoveryNotEligible
    case reviewTokenMismatch
    case savedBaselineMismatch
    case unsupportedByCoordinator
    case manualRecoveryNotConfirmable
    case manualRecoveryAttestationMismatch
}
