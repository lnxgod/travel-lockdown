import AppKit
import Foundation

struct IngressSnapshot: DeclaredNonSecretSnapshotModel, Equatable {
    static let snapshotModelID = "TravelLockdown.ingress.v1"

    let firewallEnabled: Bool
    let stealthModeEnabled: Bool
    let blockAllEnabled: Bool
    let sharingRecovery: [SharingRecoveryMarker]

    init(
        firewallEnabled: Bool,
        stealthModeEnabled: Bool,
        blockAllEnabled: Bool,
        sharingRecovery: [SharingRecoveryMarker] = SharingRecoveryMarker.allUnresolved
    ) {
        self.firewallEnabled = firewallEnabled
        self.stealthModeEnabled = stealthModeEnabled
        self.blockAllEnabled = blockAllEnabled
        self.sharingRecovery = sharingRecovery
    }

    private enum CodingKeys: String, CodingKey {
        case firewallEnabled
        case stealthModeEnabled
        case blockAllEnabled
        case sharingRecovery
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        firewallEnabled = try container.decode(Bool.self, forKey: .firewallEnabled)
        stealthModeEnabled = try container.decode(Bool.self, forKey: .stealthModeEnabled)
        blockAllEnabled = try container.decode(Bool.self, forKey: .blockAllEnabled)
        sharingRecovery = try container.decodeIfPresent(
            [SharingRecoveryMarker].self,
            forKey: .sharingRecovery
        ) ?? SharingRecoveryMarker.allUnresolved
        guard sharingRecovery.count == SharingService.allCases.count,
              Set(sharingRecovery.map(\.service)) == Set(SharingService.allCases) else {
            throw BaselineStoreError.invalidSnapshotPayload
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(firewallEnabled, forKey: .firewallEnabled)
        try container.encode(stealthModeEnabled, forKey: .stealthModeEnabled)
        try container.encode(blockAllEnabled, forKey: .blockAllEnabled)
        try container.encode(sharingRecovery, forKey: .sharingRecovery)
    }
}

enum SharingService: String, CaseIterable, Codable, Hashable, Sendable {
    case remoteLogin = "Remote Login"
    case remoteAppleEvents = "Remote Apple Events"
    case screenSharing = "Screen Sharing"
    case remoteManagement = "Remote Management"
    case fileSharing = "File Sharing"
    case mediaSharing = "Media Sharing"
    case printerSharing = "Printer Sharing"
    case bluetoothSharing = "Bluetooth Sharing"
    case internetSharing = "Internet Sharing"

    var nativeSharingPaneAction: String {
        "Turn \(rawValue) off in General > Sharing"
    }
}

struct SharingRecoveryMarker: Codable, Equatable, Sendable {
    let service: SharingService
    let recovery: ManualRecoveryMarker

    static let allUnresolved = SharingService.allCases.map {
        SharingRecoveryMarker(service: $0, recovery: .unresolved)
    }
}

struct SharingServiceStatus: Equatable, Sendable {
    let service: SharingService
    let verification: Verification
}

protocol SharingStatusCollecting: Sendable {
    func collect() -> [SharingServiceStatus]
}

/// No supported public API safely controls and reads back this complete service set.
/// Each service therefore remains explicit and unavailable instead of guessing labels.
struct NativeSharingStatusCollector: SharingStatusCollecting {
    func collect() -> [SharingServiceStatus] {
        SharingService.allCases.map {
            SharingServiceStatus(service: $0, verification: .unavailable)
        }
    }
}

protocol SharingSettingsOpening: Sendable {
    func openSharingSettings() throws
}

struct NativeSharingSettingsOpener: SharingSettingsOpening {
    private static let paneURL = URL(
        string: "x-apple.systempreferences:com.apple.Sharing-Settings.extension"
    )!

    private let open: @Sendable (URL) -> Bool

    init(open: @escaping @Sendable (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.open = open
    }

    func openSharingSettings() throws {
        guard open(Self.paneURL) else {
            throw IngressControlError.settingsOpenFailed
        }
    }
}

enum IngressControlError: Error, Equatable {
    case commandFailed
    case readbackUnavailable
    case settingsOpenFailed
}

struct IngressControl: LockdownControl {
    let id = ControlID.ingress

    private let runner: any CommandRunning
    private let privilegedRunner: any AuthorizedCommandRunning
    private let sharingStatusCollector: any SharingStatusCollecting
    private let settingsOpener: any SharingSettingsOpening

    init(
        runner: any CommandRunning,
        privilegedRunner: any AuthorizedCommandRunning = AuthorizationServicesCommandRunner(),
        sharingStatusCollector: any SharingStatusCollecting = NativeSharingStatusCollector(),
        settingsOpener: any SharingSettingsOpening = NativeSharingSettingsOpener()
    ) {
        self.runner = runner
        self.privilegedRunner = privilegedRunner
        self.sharingStatusCollector = sharingStatusCollector
        self.settingsOpener = settingsOpener
    }

    func capture() async throws -> ControlSnapshot {
        guard let snapshot = readFirewall() else {
            throw IngressControlError.readbackUnavailable
        }
        return try ControlSnapshot.capturing(snapshot, for: id)
    }

    func plan(from snapshot: ControlSnapshot) async throws -> [PlannedChange] {
        var changes = [
            PlannedChange(control: id, summary: "Turn Firewall on", sensitivity: .public),
            PlannedChange(control: id, summary: "Turn stealth mode on", sensitivity: .public),
            PlannedChange(control: id, summary: "Block all inbound connections", sensitivity: .public)
        ]
        changes.append(
            contentsOf: SharingService.allCases.map {
                PlannedChange(control: id, summary: $0.nativeSharingPaneAction, sensitivity: .public)
            }
        )
        return changes
    }

    func apply() async throws {
        try execute(.firewallEnable)
        try execute(.firewallStealthEnable)
        try execute(.firewallBlockAllEnable)
        try settingsOpener.openSharingSettings()
    }

    func verify() async throws -> ControlStatus {
        guard let firewall = readFirewall() else {
            return ControlStatus(
                id: id,
                verification: .unavailable,
                detail: "Firewall, stealth mode, or block-all readback is unavailable"
            )
        }
        guard firewall.firewallEnabled,
              firewall.stealthModeEnabled,
              firewall.blockAllEnabled else {
            return ControlStatus(
                id: id,
                verification: .nonCompliant,
                detail: "Firewall, stealth mode, and block-all must all be on"
            )
        }

        let sharing = sharingStatusCollector.collect()
        guard sharing.count == SharingService.allCases.count,
              Set(sharing.map(\.service)) == Set(SharingService.allCases) else {
            return unavailableSharingStatus(for: SharingService.allCases)
        }
        if sharing.contains(where: { $0.verification == .failed }) {
            return ControlStatus(
                id: id,
                verification: .failed,
                detail: "Sharing service verification failed"
            )
        }
        let nonCompliant = sharing.filter { $0.verification == .nonCompliant }.map(\.service)
        if !nonCompliant.isEmpty {
            return ControlStatus(
                id: id,
                verification: .nonCompliant,
                detail: nativeActions(for: nonCompliant)
            )
        }
        let unavailable = sharing.filter { $0.verification == .unavailable }.map(\.service)
        if !unavailable.isEmpty {
            return unavailableSharingStatus(for: unavailable)
        }
        return ControlStatus(
            id: id,
            verification: .compliant,
            detail: "Firewall and inbound sharing posture verified"
        )
    }

    func restore(from snapshot: ControlSnapshot) async throws {
        let captured = try snapshot.decoded(as: IngressSnapshot.self, for: id)
        try execute(captured.firewallEnabled ? .firewallEnable : .firewallDisable)
        try execute(
            captured.stealthModeEnabled ? .firewallStealthEnable : .firewallStealthDisable
        )
        try execute(
            captured.blockAllEnabled ? .firewallBlockAllEnable : .firewallBlockAllDisable
        )
        try settingsOpener.openSharingSettings()
    }

    func verifyRestored(from snapshot: ControlSnapshot) async throws -> RestorationStatus {
        let captured = try snapshot.decoded(as: IngressSnapshot.self, for: id)
        let firewallMatches = readFirewall().map {
            $0.firewallEnabled == captured.firewallEnabled
                && $0.stealthModeEnabled == captured.stealthModeEnabled
                && $0.blockAllEnabled == captured.blockAllEnabled
        } ?? false
        let unresolved = captured.sharingRecovery.filter { $0.recovery == .unresolved }
        if !unresolved.isEmpty {
            return RestorationStatus(
                id: id,
                matchesSnapshot: false,
                detail: nativeActions(for: unresolved.map(\.service)),
                manualRecovery: ManualRecoveryInstruction(
                    pane: "System Settings > General > Sharing",
                    action: "Restore every listed Sharing service"
                )
            )
        }
        return RestorationStatus(
            id: id,
            matchesSnapshot: firewallMatches,
            detail: firewallMatches
                ? "Firewall settings match the captured baseline"
                : "Firewall settings do not match the captured baseline"
        )
    }

    private func execute(_ command: PrivilegedCommand) throws {
        let result = try privilegedRunner.run(command)
        if let exitCode = result.exitCode {
            guard exitCode == 0 else {
                throw IngressControlError.commandFailed
            }
            return
        }
        guard exactReadbackMatches(command) else {
            throw IngressControlError.readbackUnavailable
        }
    }

    private func exactReadbackMatches(_ command: PrivilegedCommand) -> Bool {
        switch command {
        case .firewallEnable, .firewallDisable:
            guard let output = read(
                executable: "/usr/libexec/ApplicationFirewall/socketfilterfw",
                arguments: ["--getglobalstate"]
            ), let enabled = StatusReaders.firewallGlobal(output) else {
                return false
            }
            return enabled == (command == .firewallEnable)
        case .firewallStealthEnable, .firewallStealthDisable:
            guard let output = read(
                executable: "/usr/libexec/ApplicationFirewall/socketfilterfw",
                arguments: ["--getstealthmode"]
            ), let enabled = StatusReaders.firewallStealth(output) else {
                return false
            }
            return enabled == (command == .firewallStealthEnable)
        case .firewallBlockAllEnable, .firewallBlockAllDisable:
            guard let output = read(
                executable: "/usr/libexec/ApplicationFirewall/socketfilterfw",
                arguments: ["--getblockall"]
            ), let enabled = StatusReaders.firewallBlockAll(output) else {
                return false
            }
            return enabled == (command == .firewallBlockAllEnable)
        case .wakeForNetworkAccessOff, .wakeForNetworkAccessOn:
            return false
        }
    }

    private func readFirewall() -> IngressSnapshot? {
        guard let global = read(
            executable: "/usr/libexec/ApplicationFirewall/socketfilterfw",
            arguments: ["--getglobalstate"]
        ),
        let stealth = read(
            executable: "/usr/libexec/ApplicationFirewall/socketfilterfw",
            arguments: ["--getstealthmode"]
        ),
        let blockAll = read(
            executable: "/usr/libexec/ApplicationFirewall/socketfilterfw",
            arguments: ["--getblockall"]
        ),
        let firewallEnabled = StatusReaders.firewallGlobal(global),
        let stealthModeEnabled = StatusReaders.firewallStealth(stealth),
        let blockAllEnabled = StatusReaders.firewallBlockAll(blockAll) else {
            return nil
        }
        return IngressSnapshot(
            firewallEnabled: firewallEnabled,
            stealthModeEnabled: stealthModeEnabled,
            blockAllEnabled: blockAllEnabled
        )
    }

    private func read(executable: String, arguments: [String]) -> String? {
        guard let result = try? runner.run(executable: executable, arguments: arguments),
              result.exitCode == 0 else {
            return nil
        }
        return result.stdout
    }

    private func unavailableSharingStatus(
        for services: [SharingService]
    ) -> ControlStatus {
        ControlStatus(
            id: id,
            verification: .unavailable,
            detail: nativeActions(for: services),
            manualRecovery: ManualRecoveryInstruction(
                pane: "System Settings > General > Sharing",
                action: "Turn off every listed Sharing service"
            )
        )
    }

    private func nativeActions(for services: [SharingService]) -> String {
        services.map(\.nativeSharingPaneAction).joined(separator: "; ")
    }
}
