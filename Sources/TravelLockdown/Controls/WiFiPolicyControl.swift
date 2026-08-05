import AppKit
import CoreWLAN
import Foundation
import SecurityFoundation

enum WiFiCapability: Equatable, Sendable {
    case unproven
    case proven(profileCount: Int)
}

enum WiFiNetworkSecurity: String, Codable, Equatable, Sendable {
    case none
    case wep
    case wpaPersonal
    case wpaPersonalMixed
    case wpa2Personal
    case personal
    case dynamicWEP
    case wpaEnterprise
    case wpaEnterpriseMixed
    case wpa2Enterprise
    case enterprise
    case wpa3Personal
    case wpa3Enterprise
    case wpa3Transition
    case owe
    case oweTransition
    case unknown
}

struct WiFiNetworkProfileMetadata: Codable, Equatable, Sendable {
    let ssidData: Data
    let networkName: String?
    let security: WiFiNetworkSecurity

    init(ssidData: Data, networkName: String?, security: WiFiNetworkSecurity) {
        self.ssidData = ssidData
        self.networkName = networkName
        self.security = security
    }

    init(networkName: String, security: WiFiNetworkSecurity) {
        self.init(
            ssidData: Data(networkName.utf8),
            networkName: networkName,
            security: security
        )
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case ssidData
        case networkName
        case security
    }

    init(from decoder: any Decoder) throws {
        try rejectUnknownWiFiMetadataFields(decoder, allowed: CodingKeys.allCases)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        networkName = try container.decodeIfPresent(String.self, forKey: .networkName)
        if let encodedSSID = try container.decodeIfPresent(Data.self, forKey: .ssidData) {
            ssidData = encodedSSID
        } else if let networkName {
            ssidData = Data(networkName.utf8)
        } else {
            throw BaselineStoreError.invalidSnapshotPayload
        }
        guard (1...32).contains(ssidData.count) else {
            throw BaselineStoreError.invalidSnapshotPayload
        }
        security = try container.decode(WiFiNetworkSecurity.self, forKey: .security)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ssidData, forKey: .ssidData)
        try container.encodeIfPresent(networkName, forKey: .networkName)
        try container.encode(security, forKey: .security)
    }
}

struct WiFiPolicySnapshot: DeclaredNonSecretSnapshotModel, Equatable {
    static let snapshotModelID = "TravelLockdown.wifi-policy.v2"

    let preferredNetworks: [WiFiNetworkProfileMetadata]
    let rememberJoinedNetworks: Bool
    let requireAdministratorForAssociation: Bool
    let requireAdministratorForPower: Bool
    let requireAdministratorForIBSSMode: Bool
    let personalHotspotRecovery: ManualRecoveryMarker

    init(
        preferredNetworks: [WiFiNetworkProfileMetadata],
        rememberJoinedNetworks: Bool,
        requireAdministratorForAssociation: Bool,
        requireAdministratorForPower: Bool,
        requireAdministratorForIBSSMode: Bool,
        personalHotspotRecovery: ManualRecoveryMarker = .unresolved
    ) {
        self.preferredNetworks = preferredNetworks
        self.rememberJoinedNetworks = rememberJoinedNetworks
        self.requireAdministratorForAssociation = requireAdministratorForAssociation
        self.requireAdministratorForPower = requireAdministratorForPower
        self.requireAdministratorForIBSSMode = requireAdministratorForIBSSMode
        self.personalHotspotRecovery = personalHotspotRecovery
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case preferredNetworks
        case rememberJoinedNetworks
        case requireAdministratorForAssociation
        case requireAdministratorForPower
        case requireAdministratorForIBSSMode
        case personalHotspotRecovery
    }

    init(from decoder: any Decoder) throws {
        try rejectUnknownWiFiMetadataFields(decoder, allowed: CodingKeys.allCases)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        preferredNetworks = try container.decode(
            [WiFiNetworkProfileMetadata].self,
            forKey: .preferredNetworks
        )
        rememberJoinedNetworks = try container.decode(Bool.self, forKey: .rememberJoinedNetworks)
        requireAdministratorForAssociation = try container.decode(
            Bool.self,
            forKey: .requireAdministratorForAssociation
        )
        requireAdministratorForPower = try container.decode(
            Bool.self,
            forKey: .requireAdministratorForPower
        )
        requireAdministratorForIBSSMode = try container.decode(
            Bool.self,
            forKey: .requireAdministratorForIBSSMode
        )
        personalHotspotRecovery = try container.decodeIfPresent(
            ManualRecoveryMarker.self,
            forKey: .personalHotspotRecovery
        ) ?? .unresolved
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(preferredNetworks, forKey: .preferredNetworks)
        try container.encode(rememberJoinedNetworks, forKey: .rememberJoinedNetworks)
        try container.encode(
            requireAdministratorForAssociation,
            forKey: .requireAdministratorForAssociation
        )
        try container.encode(requireAdministratorForPower, forKey: .requireAdministratorForPower)
        try container.encode(
            requireAdministratorForIBSSMode,
            forKey: .requireAdministratorForIBSSMode
        )
        try container.encode(personalHotspotRecovery, forKey: .personalHotspotRecovery)
    }
}

private struct WiFiMetadataCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

private func rejectUnknownWiFiMetadataFields<Key: CodingKey & CaseIterable>(
    _ decoder: any Decoder,
    allowed: [Key]
) throws {
    let container = try decoder.container(keyedBy: WiFiMetadataCodingKey.self)
    let allowedNames = Set(allowed.map(\.stringValue))
    guard Set(container.allKeys.map(\.stringValue)).isSubset(of: allowedNames) else {
        throw BaselineStoreError.invalidSnapshotPayload
    }
}

protocol WiFiConfigurationClient: Sendable {
    func capability() async throws -> WiFiCapability
    func captureManualConnectBaseline() async throws -> WiFiPolicySnapshot
    func applyManualConnectPolicy() async throws
    func verifyManualConnectPolicy() async throws -> Bool
    func restoreManualConnectBaseline(_ baseline: WiFiPolicySnapshot) async throws
}

struct PublicWiFiConfigurationProjection: Equatable, Sendable {
    let preferredNetworks: [WiFiNetworkProfileMetadata]
    let rememberJoinedNetworks: Bool
    let requireAdministratorForAssociation: Bool
    let requireAdministratorForPower: Bool
    let requireAdministratorForIBSSMode: Bool

    init(
        preferredNetworks: [WiFiNetworkProfileMetadata],
        rememberJoinedNetworks: Bool,
        requireAdministratorForAssociation: Bool,
        requireAdministratorForPower: Bool,
        requireAdministratorForIBSSMode: Bool
    ) {
        self.preferredNetworks = preferredNetworks
        self.rememberJoinedNetworks = rememberJoinedNetworks
        self.requireAdministratorForAssociation = requireAdministratorForAssociation
        self.requireAdministratorForPower = requireAdministratorForPower
        self.requireAdministratorForIBSSMode = requireAdministratorForIBSSMode
    }

    init(_ snapshot: WiFiPolicySnapshot) {
        self.init(
            preferredNetworks: snapshot.preferredNetworks,
            rememberJoinedNetworks: snapshot.rememberJoinedNetworks,
            requireAdministratorForAssociation: snapshot.requireAdministratorForAssociation,
            requireAdministratorForPower: snapshot.requireAdministratorForPower,
            requireAdministratorForIBSSMode: snapshot.requireAdministratorForIBSSMode
        )
    }

    var snapshot: WiFiPolicySnapshot {
        WiFiPolicySnapshot(
            preferredNetworks: preferredNetworks,
            rememberJoinedNetworks: rememberJoinedNetworks,
            requireAdministratorForAssociation: requireAdministratorForAssociation,
            requireAdministratorForPower: requireAdministratorForPower,
            requireAdministratorForIBSSMode: requireAdministratorForIBSSMode
        )
    }
}

protocol PublicWiFiConfigurationAccess: Sendable {
    func currentConfiguration() throws -> PublicWiFiConfigurationProjection
    func commitConfiguration(_ projection: PublicWiFiConfigurationProjection) throws
}

struct CoreWLANWiFiConfigurationClient: WiFiConfigurationClient {
    private let access: any PublicWiFiConfigurationAccess

    init(access: any PublicWiFiConfigurationAccess = NativePublicWiFiConfigurationAccess()) {
        self.access = access
    }

    func capability() async throws -> WiFiCapability {
        do {
            let current = try access.currentConfiguration()
            try validate(current)
            return .proven(profileCount: current.preferredNetworks.count)
        } catch {
            return .unproven
        }
    }

    func captureManualConnectBaseline() async throws -> WiFiPolicySnapshot {
        let current = try access.currentConfiguration()
        try validate(current)
        return current.snapshot
    }

    func applyManualConnectPolicy() async throws {
        let current = try access.currentConfiguration()
        try validate(current)
        try access.commitConfiguration(
            PublicWiFiConfigurationProjection(
                preferredNetworks: [],
                rememberJoinedNetworks: false,
                requireAdministratorForAssociation:
                    current.requireAdministratorForAssociation,
                requireAdministratorForPower: current.requireAdministratorForPower,
                requireAdministratorForIBSSMode: current.requireAdministratorForIBSSMode
            )
        )
    }

    func verifyManualConnectPolicy() async throws -> Bool {
        let current = try access.currentConfiguration()
        try validate(current)
        return current.preferredNetworks.isEmpty && !current.rememberJoinedNetworks
    }

    func restoreManualConnectBaseline(_ baseline: WiFiPolicySnapshot) async throws {
        let projection = PublicWiFiConfigurationProjection(baseline)
        try validate(projection)
        try access.commitConfiguration(projection)
    }

    private func validate(_ projection: PublicWiFiConfigurationProjection) throws {
        for profile in projection.preferredNetworks {
            guard (1...32).contains(profile.ssidData.count),
                  profile.security != .unknown else {
                throw WiFiPolicyControlError.configurationNotRepresentable
            }
        }
    }
}

struct NativePublicWiFiConfigurationAccess: PublicWiFiConfigurationAccess {
    func currentConfiguration() throws -> PublicWiFiConfigurationProjection {
        guard let configuration = CWWiFiClient.shared().interface()?.configuration() else {
            throw WiFiPolicyControlError.capabilityUnproven
        }
        let profiles = try configuration.networkProfiles.map { value in
            guard let profile = value as? CWNetworkProfile,
                  let ssidData = profile.ssidData,
                  (1...32).contains(ssidData.count),
                  let security = Self.security(from: profile.security) else {
                throw WiFiPolicyControlError.configurationNotRepresentable
            }
            return WiFiNetworkProfileMetadata(
                ssidData: ssidData,
                networkName: profile.ssid,
                security: security
            )
        }
        return PublicWiFiConfigurationProjection(
            preferredNetworks: profiles,
            rememberJoinedNetworks: configuration.rememberJoinedNetworks,
            requireAdministratorForAssociation:
                configuration.requireAdministratorForAssociation,
            requireAdministratorForPower: configuration.requireAdministratorForPower,
            requireAdministratorForIBSSMode: configuration.requireAdministratorForIBSSMode
        )
    }

    func commitConfiguration(_ projection: PublicWiFiConfigurationProjection) throws {
        let nativeProfiles: [CWNetworkProfile] = try projection.preferredNetworks.map { profile in
            guard (1...32).contains(profile.ssidData.count),
                  let security = Self.security(from: profile.security) else {
                throw WiFiPolicyControlError.configurationNotRepresentable
            }
            let mutable = CWMutableNetworkProfile()
            mutable.ssidData = profile.ssidData
            mutable.security = security
            return mutable
        }
        guard let interface = CWWiFiClient.shared().interface(),
              let liveConfiguration = interface.configuration(),
              let mutableConfiguration = liveConfiguration.mutableCopy()
                as? CWMutableConfiguration,
              let authorization = SFAuthorization.authorization() as? SFAuthorization else {
            throw WiFiPolicyControlError.capabilityUnproven
        }

        mutableConfiguration.networkProfiles = NSOrderedSet(array: nativeProfiles)
        mutableConfiguration.rememberJoinedNetworks = projection.rememberJoinedNetworks
        mutableConfiguration.requireAdministratorForAssociation =
            projection.requireAdministratorForAssociation
        mutableConfiguration.requireAdministratorForPower = projection.requireAdministratorForPower
        mutableConfiguration.requireAdministratorForIBSSMode =
            projection.requireAdministratorForIBSSMode
        try interface.commitConfiguration(
            mutableConfiguration,
            authorization: authorization
        )
    }

    private static func security(from native: CWSecurity) -> WiFiNetworkSecurity? {
        switch native {
        case .none: WiFiNetworkSecurity.none
        case .WEP: .wep
        case .wpaPersonal: .wpaPersonal
        case .wpaPersonalMixed: .wpaPersonalMixed
        case .wpa2Personal: .wpa2Personal
        case .personal: .personal
        case .dynamicWEP: .dynamicWEP
        case .wpaEnterprise: .wpaEnterprise
        case .wpaEnterpriseMixed: .wpaEnterpriseMixed
        case .wpa2Enterprise: .wpa2Enterprise
        case .enterprise: .enterprise
        case .wpa3Personal: .wpa3Personal
        case .wpa3Enterprise: .wpa3Enterprise
        case .wpa3Transition: .wpa3Transition
        case .OWE: .owe
        case .oweTransition: .oweTransition
        default: nil
        }
    }

    private static func security(from stored: WiFiNetworkSecurity) -> CWSecurity? {
        switch stored {
        case .none: CWSecurity.none
        case .wep: .WEP
        case .wpaPersonal: .wpaPersonal
        case .wpaPersonalMixed: .wpaPersonalMixed
        case .wpa2Personal: .wpa2Personal
        case .personal: .personal
        case .dynamicWEP: .dynamicWEP
        case .wpaEnterprise: .wpaEnterprise
        case .wpaEnterpriseMixed: .wpaEnterpriseMixed
        case .wpa2Enterprise: .wpa2Enterprise
        case .enterprise: .enterprise
        case .wpa3Personal: .wpa3Personal
        case .wpa3Enterprise: .wpa3Enterprise
        case .wpa3Transition: .wpa3Transition
        case .owe: .OWE
        case .oweTransition: .oweTransition
        case .unknown: nil
        }
    }
}

protocol WiFiSettingsOpening: Sendable {
    func openWiFiSettings() throws
}

struct NativeWiFiSettingsOpener: WiFiSettingsOpening {
    private static let paneURL = URL(
        string: "x-apple.systempreferences:com.apple.wifi-settings-extension"
    )!

    private let open: @Sendable (URL) -> Bool

    init(open: @escaping @Sendable (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.open = open
    }

    func openWiFiSettings() throws {
        guard open(Self.paneURL) else {
            throw WiFiPolicyControlError.settingsOpenFailed
        }
    }
}

protocol HotspotAutoJoinVerifying: Sendable {
    func verify() -> Verification
    func openRemediation() throws
}

struct HotspotAutoJoinVerifier: HotspotAutoJoinVerifying {
    let remediation = "Set Ask to join hotspots to Never"

    private let settingsOpener: any WiFiSettingsOpening

    init(settingsOpener: any WiFiSettingsOpening = NativeWiFiSettingsOpener()) {
        self.settingsOpener = settingsOpener
    }

    func verify() -> Verification {
        .unavailable
    }

    func openRemediation() throws {
        try settingsOpener.openWiFiSettings()
    }
}

enum WiFiPolicyControlError: Error, Equatable {
    case capabilityUnproven
    case configurationNotRepresentable
    case settingsOpenFailed
}

struct WiFiPolicyControl: LockdownControl {
    let id = ControlID.wifiPolicy

    private let client: any WiFiConfigurationClient
    private let hotspotVerifier: any HotspotAutoJoinVerifying

    init(
        client: any WiFiConfigurationClient = CoreWLANWiFiConfigurationClient(),
        hotspotVerifier: any HotspotAutoJoinVerifying = HotspotAutoJoinVerifier()
    ) {
        self.client = client
        self.hotspotVerifier = hotspotVerifier
    }

    func capture() async throws -> ControlSnapshot {
        try await requireProvenCapability()
        let baseline = try await client.captureManualConnectBaseline()
        return try ControlSnapshot.capturing(baseline, for: id)
    }

    func plan(from snapshot: ControlSnapshot) async throws -> [PlannedChange] {
        [
            PlannedChange(
                control: id,
                summary: "Use manual Wi-Fi after disconnection; saved credentials are retained",
                sensitivity: .networkMetadata
            )
        ]
    }

    func apply() async throws {
        try await requireProvenCapability()
        try await client.applyManualConnectPolicy()
    }

    func verify() async throws -> ControlStatus {
        guard case .proven = try await client.capability() else {
            return ControlStatus(
                id: id,
                verification: .unavailable,
                detail: "Manual Wi-Fi connection policy is unavailable"
            )
        }

        let isVerified = try await client.verifyManualConnectPolicy()
        guard isVerified else {
            return ControlStatus(
                id: id,
                verification: .nonCompliant,
                detail: "Manual Wi-Fi connection policy is not verified"
            )
        }

        return switch hotspotVerifier.verify() {
        case .compliant:
            ControlStatus(
                id: id,
                verification: .compliant,
                detail: "Manual Wi-Fi connection policy verified"
            )
        case .nonCompliant:
            ControlStatus(
                id: id,
                verification: .nonCompliant,
                detail: "Automatic Personal Hotspot joining is not disabled"
            )
        case .unavailable:
            ControlStatus(
                id: id,
                verification: .unavailable,
                detail: "Set Ask to join hotspots to Never in Wi-Fi Settings",
                manualRecovery: ManualRecoveryInstruction(
                    pane: "System Settings > Wi-Fi",
                    action: "Set Ask to join hotspots to Never"
                )
            )
        case .failed:
            ControlStatus(
                id: id,
                verification: .failed,
                detail: "Personal Hotspot verification failed"
            )
        }
    }

    func restore(from snapshot: ControlSnapshot) async throws {
        let captured = try snapshot.decoded(as: WiFiPolicySnapshot.self, for: id)
        try await client.restoreManualConnectBaseline(captured)
        try hotspotVerifier.openRemediation()
    }

    func verifyRestored(from snapshot: ControlSnapshot) async throws -> RestorationStatus {
        let captured = try snapshot.decoded(as: WiFiPolicySnapshot.self, for: id)
        let current = try await client.captureManualConnectBaseline()
        let automatedMatches = current.preferredNetworks == captured.preferredNetworks
            && current.rememberJoinedNetworks == captured.rememberJoinedNetworks
            && current.requireAdministratorForAssociation
                == captured.requireAdministratorForAssociation
            && current.requireAdministratorForPower == captured.requireAdministratorForPower
            && current.requireAdministratorForIBSSMode
                == captured.requireAdministratorForIBSSMode
        if captured.personalHotspotRecovery == .unresolved {
            return RestorationStatus(
                id: id,
                matchesSnapshot: false,
                detail: "Restore Personal Hotspot auto-join in System Settings > Wi-Fi",
                manualRecovery: ManualRecoveryInstruction(
                    pane: "System Settings > Wi-Fi",
                    action: "Restore Personal Hotspot auto-join"
                )
            )
        }
        return RestorationStatus(
            id: id,
            matchesSnapshot: automatedMatches,
            detail: automatedMatches
                ? "Wi-Fi connection policy matches the captured baseline"
                : "Wi-Fi connection policy does not match the captured baseline"
        )
    }

    private func requireProvenCapability() async throws {
        guard case .proven = try await client.capability() else {
            throw WiFiPolicyControlError.capabilityUnproven
        }
    }
}
