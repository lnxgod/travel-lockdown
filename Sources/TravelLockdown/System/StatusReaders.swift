import Foundation

enum StatusReaders {
    static func bluetooth(_ output: String) -> Verification {
        switch value(after: "State:", in: output)?.lowercased() {
        case "off":
            .compliant
        case "on":
            .nonCompliant
        default:
            .unavailable
        }
    }

    static func firewallGlobal(_ output: String) -> Bool? {
        if let legacy = parseEnabledDisabled(
            output,
            enabled: ["Firewall is enabled."],
            disabled: ["Firewall is disabled."]
        ) {
            return legacy
        }

        let normalized = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if let state = integer(in: normalized, after: "Firewall is enabled. (State = "),
           [1, 2].contains(state) {
            return true
        }
        if let state = integer(in: normalized, after: "Firewall is disabled. (State = "),
           state == 0 {
            return false
        }
        return nil
    }

    static func firewallStealth(_ output: String) -> Bool? {
        parseEnabledDisabled(
            output,
            enabled: ["Stealth mode is on", "Stealth mode enabled"],
            disabled: ["Stealth mode is off", "Stealth mode disabled"]
        )
    }

    static func firewallBlockAll(_ output: String) -> Bool? {
        parseEnabledDisabled(
            output,
            enabled: [
                "Block all is on",
                "Firewall is set to block all non-essential incoming connections",
                "Firewall is set to block all non-essential incoming connections."
            ],
            disabled: [
                "Block all is off",
                "Block all DISABLED!",
                "Firewall is set to allow specific services and applications."
            ]
        )
    }

    static func firewall(global: String, stealth: String, blockAll: String) -> Verification {
        let values = [
            firewallGlobal(global),
            firewallStealth(stealth),
            firewallBlockAll(blockAll)
        ]
        guard values.allSatisfy({ $0 != nil }) else {
            return .unavailable
        }
        return values.allSatisfy({ $0 == true }) ? .compliant : .nonCompliant
    }

    static func handoff(_ output: String) -> Verification {
        let advertising = preferenceBool("ActivityAdvertisingAllowed", in: output)
        let receiving = preferenceBool("ActivityReceivingAllowed", in: output)
        guard let advertising, let receiving else {
            return .unavailable
        }
        return advertising || receiving ? .nonCompliant : .compliant
    }

    static func airDrop(_ output: String) -> Verification {
        guard let value = preferenceValue("DiscoverableMode", in: output)?.lowercased() else {
            return .unavailable
        }
        switch value {
        case "off":
            return .compliant
        case "contactsonly", "contacts only", "everyone":
            return .nonCompliant
        default:
            return .unavailable
        }
    }

    static func fileVault(_ output: String) -> Verification {
        switch output.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "FileVault is On.":
            .compliant
        case "FileVault is Off.":
            .nonCompliant
        default:
            .unavailable
        }
    }

    static func wake(_ output: String) -> Verification {
        guard let value = whitespaceValue("womp", in: output) else {
            return .unavailable
        }
        return switch value {
        case "0":
            .compliant
        case "1":
            .nonCompliant
        default:
            .unavailable
        }
    }

    private static func parseEnabledDisabled(
        _ output: String,
        enabled: [String],
        disabled: [String]
    ) -> Bool? {
        let normalized = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if enabled.contains(where: { normalized.caseInsensitiveCompare($0) == .orderedSame }) {
            return true
        }
        if disabled.contains(where: { normalized.caseInsensitiveCompare($0) == .orderedSame }) {
            return false
        }
        return nil
    }

    private static func integer(in output: String, after prefix: String) -> Int? {
        guard output.hasPrefix(prefix), output.hasSuffix(")") else {
            return nil
        }
        let value = output.dropFirst(prefix.count).dropLast()
        return Int(value)
    }

    private static func value(after label: String, in output: String) -> String? {
        output.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(label) else { return nil }
            return String(trimmed.dropFirst(label.count))
                .trimmingCharacters(in: .whitespaces)
        }.first
    }

    private static func preferenceBool(_ key: String, in output: String) -> Bool? {
        switch preferenceValue(key, in: output)?.lowercased() {
        case "0", "false", "no":
            false
        case "1", "true", "yes":
            true
        default:
            nil
        }
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

    private static func whitespaceValue(_ key: String, in output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2, fields[0] == Substring(key) else {
                continue
            }
            return String(fields[1])
        }
        return nil
    }
}

enum StatusComponent: String, Equatable, Sendable {
    case bluetooth = "Bluetooth"
    case handoff = "Handoff"
    case airDrop = "AirDrop"
    case firewall = "Firewall"
    case sharing = "Sharing"
    case fileVault = "FileVault"
    case wake = "Wake"
    case manualWiFi = "Manual Wi-Fi"
}

struct ComponentVerdict: Equatable, Sendable {
    let component: StatusComponent
    let verification: Verification
}

struct ReadOnlyStatusCollector: Sendable {
    private let runner: any CommandRunning

    init(runner: any CommandRunning) {
        self.runner = runner
    }

    func collect() -> [ComponentVerdict] {
        let bluetooth = read(
            executable: "/usr/sbin/system_profiler",
            arguments: ["SPBluetoothDataType"]
        )
        let handoff = read(
            executable: "/usr/bin/defaults",
            arguments: ["-currentHost", "read", "com.apple.coreservices.useractivityd"]
        )
        let airDrop = read(
            executable: "/usr/bin/defaults",
            arguments: ["read", "com.apple.sharingd"]
        )
        let firewallGlobal = read(
            executable: "/usr/libexec/ApplicationFirewall/socketfilterfw",
            arguments: ["--getglobalstate"]
        )
        let firewallStealth = read(
            executable: "/usr/libexec/ApplicationFirewall/socketfilterfw",
            arguments: ["--getstealthmode"]
        )
        let firewallBlockAll = read(
            executable: "/usr/libexec/ApplicationFirewall/socketfilterfw",
            arguments: ["--getblockall"]
        )
        let fileVault = read(
            executable: "/usr/bin/fdesetup",
            arguments: ["status"]
        )
        let wake = read(
            executable: "/usr/bin/pmset",
            arguments: ["-g"]
        )

        return [
            ComponentVerdict(
                component: .bluetooth,
                verification: bluetooth.map(StatusReaders.bluetooth) ?? .unavailable
            ),
            ComponentVerdict(
                component: .handoff,
                verification: handoff.map(StatusReaders.handoff) ?? .unavailable
            ),
            ComponentVerdict(
                component: .airDrop,
                verification: airDrop.map(StatusReaders.airDrop) ?? .unavailable
            ),
            ComponentVerdict(
                component: .firewall,
                verification: firewall(
                    global: firewallGlobal,
                    stealth: firewallStealth,
                    blockAll: firewallBlockAll
                )
            ),
            ComponentVerdict(
                component: .sharing,
                verification: .unavailable
            ),
            ComponentVerdict(
                component: .fileVault,
                verification: fileVault.map(StatusReaders.fileVault) ?? .unavailable
            ),
            ComponentVerdict(
                component: .wake,
                verification: wake.map(StatusReaders.wake) ?? .unavailable
            ),
            ComponentVerdict(
                component: .manualWiFi,
                verification: .unavailable
            )
        ]
    }

    private func read(executable: String, arguments: [String]) -> String? {
        guard let result = try? runner.run(executable: executable, arguments: arguments),
              result.exitCode == 0 else {
            return nil
        }
        return result.stdout
    }

    private func firewall(global: String?, stealth: String?, blockAll: String?) -> Verification {
        guard let global, let stealth, let blockAll else {
            return .unavailable
        }
        return StatusReaders.firewall(global: global, stealth: stealth, blockAll: blockAll)
    }
}
