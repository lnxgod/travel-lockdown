import AppKit
import Foundation

enum PreferenceValue: Codable, Equatable, Sendable {
    case missing
    case bool(Bool)
    case string(String)
}

struct ContinuitySnapshot: DeclaredNonSecretSnapshotModel, Equatable {
    static let snapshotModelID = "TravelLockdown.continuity.v1"

    let activityAdvertisingAllowed: PreferenceValue
    let activityReceivingAllowed: PreferenceValue
    let discoverableMode: PreferenceValue
    let airPlayReceiverRecovery: ManualRecoveryMarker

    init(
        activityAdvertisingAllowed: PreferenceValue,
        activityReceivingAllowed: PreferenceValue,
        discoverableMode: PreferenceValue,
        airPlayReceiverRecovery: ManualRecoveryMarker = .unresolved
    ) {
        self.activityAdvertisingAllowed = activityAdvertisingAllowed
        self.activityReceivingAllowed = activityReceivingAllowed
        self.discoverableMode = discoverableMode
        self.airPlayReceiverRecovery = airPlayReceiverRecovery
    }

    private enum CodingKeys: String, CodingKey {
        case activityAdvertisingAllowed
        case activityReceivingAllowed
        case discoverableMode
        case airPlayReceiverRecovery
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        activityAdvertisingAllowed = try container.decode(
            PreferenceValue.self,
            forKey: .activityAdvertisingAllowed
        )
        activityReceivingAllowed = try container.decode(
            PreferenceValue.self,
            forKey: .activityReceivingAllowed
        )
        discoverableMode = try container.decode(PreferenceValue.self, forKey: .discoverableMode)
        airPlayReceiverRecovery = try container.decodeIfPresent(
            ManualRecoveryMarker.self,
            forKey: .airPlayReceiverRecovery
        ) ?? .unresolved
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(activityAdvertisingAllowed, forKey: .activityAdvertisingAllowed)
        try container.encode(activityReceivingAllowed, forKey: .activityReceivingAllowed)
        try container.encode(discoverableMode, forKey: .discoverableMode)
        try container.encode(airPlayReceiverRecovery, forKey: .airPlayReceiverRecovery)
    }
}

enum AirPlayReceiverVerifier: Sendable {
    case unavailable
}

protocol AirDropContinuitySettingsOpening: Sendable {
    func openAirDropAndContinuity() throws
}

struct NativeAirDropContinuitySettingsOpener: AirDropContinuitySettingsOpening {
    private static let paneURL = URL(
        string: "x-apple.systempreferences:com.apple.AirDrop-Handoff-Settings.extension"
    )!

    private let open: @Sendable (URL) -> Bool

    init(open: @escaping @Sendable (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.open = open
    }

    func openAirDropAndContinuity() throws {
        guard open(Self.paneURL) else {
            throw ContinuityControlError.settingsOpenFailed
        }
    }
}

enum ContinuityControlError: Error, Equatable {
    case commandFailed
    case settingsOpenFailed
}

struct ContinuityControl: LockdownControl {
    let id = ControlID.continuity

    private let runner: any CommandRunning
    private let airPlayVerifier: AirPlayReceiverVerifier
    private let settingsOpener: any AirDropContinuitySettingsOpening

    init(
        runner: any CommandRunning,
        airPlayVerifier: AirPlayReceiverVerifier = .unavailable,
        settingsOpener: any AirDropContinuitySettingsOpening =
            NativeAirDropContinuitySettingsOpener()
    ) {
        self.runner = runner
        self.airPlayVerifier = airPlayVerifier
        self.settingsOpener = settingsOpener
    }

    func capture() async throws -> ControlSnapshot {
        try ControlSnapshot.capturing(readPreferences(), for: id)
    }

    func plan(from snapshot: ControlSnapshot) async throws -> [PlannedChange] {
        [
            PlannedChange(
                control: id,
                summary: "Turn Handoff off",
                sensitivity: .public
            ),
            PlannedChange(
                control: id,
                summary: "Turn AirDrop receiving off",
                sensitivity: .public
            ),
            PlannedChange(
                control: id,
                summary: "Turn AirPlay Receiver off in General > AirDrop & Continuity",
                sensitivity: .public
            )
        ]
    }

    func apply() async throws {
        try execute(arguments: [
            "-currentHost", "write", "com.apple.coreservices.useractivityd",
            "ActivityAdvertisingAllowed", "-bool", "false"
        ])
        try execute(arguments: [
            "-currentHost", "write", "com.apple.coreservices.useractivityd",
            "ActivityReceivingAllowed", "-bool", "false"
        ])
        try execute(arguments: [
            "write", "com.apple.sharingd", "DiscoverableMode", "-string", "Off"
        ])
        try settingsOpener.openAirDropAndContinuity()
    }

    func verify() async throws -> ControlStatus {
        let preferences = try readPreferences()
        guard preferences.activityAdvertisingAllowed == .bool(false),
              preferences.activityReceivingAllowed == .bool(false),
              preferences.discoverableMode == .string("Off") else {
            return ControlStatus(
                id: id,
                verification: .nonCompliant,
                detail: "Handoff or AirDrop is not off"
            )
        }
        switch airPlayVerifier {
        case .unavailable:
            return ControlStatus(
                id: id,
                verification: .unavailable,
                detail: "Turn AirPlay Receiver off in General > AirDrop & Continuity",
                manualRecovery: ManualRecoveryInstruction(
                    pane: "System Settings > General > AirDrop & Continuity",
                    action: "Turn AirPlay Receiver off"
                )
            )
        }
    }

    func restore(from snapshot: ControlSnapshot) async throws {
        let captured = try snapshot.decoded(as: ContinuitySnapshot.self, for: id)
        try restore(
            captured.activityAdvertisingAllowed,
            domainArguments: ["-currentHost"],
            domain: "com.apple.coreservices.useractivityd",
            key: "ActivityAdvertisingAllowed"
        )
        try restore(
            captured.activityReceivingAllowed,
            domainArguments: ["-currentHost"],
            domain: "com.apple.coreservices.useractivityd",
            key: "ActivityReceivingAllowed"
        )
        try restore(
            captured.discoverableMode,
            domainArguments: [],
            domain: "com.apple.sharingd",
            key: "DiscoverableMode"
        )
        try settingsOpener.openAirDropAndContinuity()
    }

    func verifyRestored(from snapshot: ControlSnapshot) async throws -> RestorationStatus {
        let captured = try snapshot.decoded(as: ContinuitySnapshot.self, for: id)
        let current = try readPreferences()
        let automatedMatches = current.activityAdvertisingAllowed
                == captured.activityAdvertisingAllowed
            && current.activityReceivingAllowed == captured.activityReceivingAllowed
            && current.discoverableMode == captured.discoverableMode
        if captured.airPlayReceiverRecovery == .unresolved {
            return RestorationStatus(
                id: id,
                matchesSnapshot: false,
                detail: "Restore AirPlay Receiver in General > AirDrop & Continuity",
                manualRecovery: ManualRecoveryInstruction(
                    pane: "System Settings > General > AirDrop & Continuity",
                    action: "Restore AirPlay Receiver"
                )
            )
        }
        return RestorationStatus(
            id: id,
            matchesSnapshot: automatedMatches,
            detail: automatedMatches
                ? "Continuity preferences match the captured baseline"
                : "Continuity preferences do not match the captured baseline"
        )
    }

    private func readPreferences() throws -> ContinuitySnapshot {
        let handoff = try read(
            domain: "com.apple.coreservices.useractivityd",
            currentHost: true
        )
        let airDrop = try read(domain: "com.apple.sharingd", currentHost: false)
        return ContinuitySnapshot(
            activityAdvertisingAllowed: Self.boolPreference(
                "ActivityAdvertisingAllowed",
                in: handoff
            ),
            activityReceivingAllowed: Self.boolPreference(
                "ActivityReceivingAllowed",
                in: handoff
            ),
            discoverableMode: Self.stringPreference("DiscoverableMode", in: airDrop)
        )
    }

    private func read(domain: String, currentHost: Bool) throws -> String {
        let arguments = (currentHost ? ["-currentHost"] : []) + ["read", domain]
        let result = try runner.run(executable: "/usr/bin/defaults", arguments: arguments)
        if result.exitCode == 0 {
            return result.stdout
        }
        guard Self.isMissingDomain(result, domain: domain) else {
            throw ContinuityControlError.commandFailed
        }
        return ""
    }

    private static func isMissingDomain(_ result: CommandResult, domain: String) -> Bool {
        guard result.exitCode == 1, result.stdout.isEmpty else {
            return false
        }
        let escapedDomain = NSRegularExpression.escapedPattern(for: domain)
        let pattern =
            #"^(?:\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3} defaults\[\d+:\d+\][ \t]*\r?\n)?Domain "#
            + escapedDomain
            + #" does not exist\r?\n?$"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return false
        }
        let range = NSRange(result.stderr.startIndex..., in: result.stderr)
        return expression.firstMatch(in: result.stderr, range: range)?.range == range
    }

    private func restore(
        _ value: PreferenceValue,
        domainArguments: [String],
        domain: String,
        key: String
    ) throws {
        switch value {
        case .missing:
            try execute(arguments: domainArguments + ["delete", domain, key])
        case .bool(let bool):
            try execute(
                arguments: domainArguments
                    + ["write", domain, key, "-bool", bool ? "true" : "false"]
            )
        case .string(let string):
            try execute(
                arguments: domainArguments + ["write", domain, key, "-string", string]
            )
        }
    }

    private func execute(arguments: [String]) throws {
        let result = try runner.run(executable: "/usr/bin/defaults", arguments: arguments)
        guard result.exitCode == 0 else {
            throw ContinuityControlError.commandFailed
        }
    }

    private static func boolPreference(_ key: String, in output: String) -> PreferenceValue {
        guard let value = preferenceValue(key, in: output) else {
            return .missing
        }
        return switch value.lowercased() {
        case "0", "false", "no": .bool(false)
        case "1", "true", "yes": .bool(true)
        default: .string(value)
        }
    }

    private static func stringPreference(_ key: String, in output: String) -> PreferenceValue {
        guard let value = preferenceValue(key, in: output) else {
            return .missing
        }
        return .string(value)
    }

    private static func preferenceValue(_ key: String, in output: String) -> String? {
        let segments = output
            .replacingOccurrences(of: "{", with: "\n")
            .replacingOccurrences(of: "}", with: "\n")
            .split(whereSeparator: { $0 == ";" || $0.isNewline })

        for segment in segments {
            let assignment = segment.split(separator: "=", maxSplits: 1)
            guard assignment.count == 2,
                  assignment[0].trimmingCharacters(in: .whitespaces) == key else {
                continue
            }
            return assignment[1]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return nil
    }
}
