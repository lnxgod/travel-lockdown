import Foundation
import Testing
@testable import TravelLockdown

@Suite("StatusReadersTests")
struct StatusReadersTests {
    private struct CommandKey: Hashable {
        let executable: String
        let arguments: [String]
    }

    private struct FixtureRunner: CommandRunning {
        let results: [CommandKey: CommandResult]

        func run(executable: String, arguments: [String]) throws -> CommandResult {
            guard let result = results[CommandKey(executable: executable, arguments: arguments)] else {
                throw FixtureError.unexpectedCommand
            }
            return result
        }
    }

    private final class RecordingRunner: @unchecked Sendable, CommandRunning {
        private let lock = NSLock()
        private let results: [CommandKey: CommandResult]
        private var recordedCommands: [CommandKey] = []

        init(results: [CommandKey: CommandResult]) {
            self.results = results
        }

        var commands: [CommandKey] {
            lock.withLock { recordedCommands }
        }

        func run(executable: String, arguments: [String]) throws -> CommandResult {
            let key = CommandKey(executable: executable, arguments: arguments)
            lock.withLock {
                recordedCommands.append(key)
            }
            guard let result = results[key] else {
                throw FixtureError.unexpectedCommand
            }
            return result
        }
    }

    private enum FixtureError: Error {
        case unexpectedCommand
    }

    @Test("Bluetooth parser accepts the system profiler off state")
    func bluetoothOffParsesAsCompliant() {
        let output = """
        Bluetooth:
            Bluetooth Controller:
                State: Off
        """

        #expect(StatusReaders.bluetooth(output) == .compliant)
    }

    @Test("firewall parser distinguishes stealth from block-all")
    func firewallParsersRequireAllRequestedPosture() {
        #expect(StatusReaders.firewallGlobal("Firewall is enabled.\n") == true)
        #expect(StatusReaders.firewallStealth("Stealth mode is on\n") == true)
        #expect(StatusReaders.firewallBlockAll("Block all is off\n") == false)
    }

    @Test("firewall parser accepts current socketfilterfw verdict phrases")
    func firewallParsersAcceptCurrentToolOutput() {
        #expect(StatusReaders.firewallGlobal("Firewall is enabled. (State = 1)\n") == true)
        #expect(StatusReaders.firewallGlobal("Firewall is enabled. (State = 2)\n") == true)
        #expect(StatusReaders.firewallGlobal("Firewall is disabled. (State = 0)\n") == false)
        #expect(StatusReaders.firewallStealth("Stealth mode enabled\n") == true)
        #expect(StatusReaders.firewallStealth("Stealth mode disabled\n") == false)
        #expect(
            StatusReaders.firewallBlockAll(
                "Firewall is set to block all non-essential incoming connections\n"
            ) == true
        )
        #expect(
            StatusReaders.firewallBlockAll(
                "Firewall is set to block all non-essential incoming connections.\n"
            ) == true
        )
        #expect(
            StatusReaders.firewallBlockAll(
                "Firewall is set to allow specific services and applications.\n"
            ) == false
        )
        #expect(StatusReaders.firewallBlockAll("Block all DISABLED!\n") == false)
    }

    @Test("unknown numeric firewall states fail closed")
    func unknownFirewallStateIsUnavailable() {
        #expect(StatusReaders.firewallGlobal("Firewall is enabled. (State = 999)\n") == nil)
        #expect(StatusReaders.firewallGlobal("Firewall is enabled. (State = -1)\n") == nil)
        #expect(StatusReaders.firewallGlobal("Firewall is enabled. (State = active)\n") == nil)
    }

    @Test("unknown output fails closed")
    func unrecognizedOutputIsUnavailable() {
        #expect(StatusReaders.bluetooth("unavailable") == .unavailable)
    }

    @Test("Handoff requires both advertised and received activity to be disabled")
    func handoffRequiresBothPreferencesOff() {
        let disabled = """
        {
            ActivityAdvertisingAllowed = 0;
            ActivityReceivingAllowed = 0;
        }
        """
        let advertisingEnabled = """
        {
            ActivityAdvertisingAllowed = 1;
            ActivityReceivingAllowed = 0;
        }
        """

        #expect(StatusReaders.handoff(disabled) == .compliant)
        #expect(StatusReaders.handoff(advertisingEnabled) == .nonCompliant)
        #expect(StatusReaders.handoff("{ ActivityAdvertisingAllowed = 0; }") == .unavailable)
    }

    @Test("AirDrop accepts only an explicit off preference")
    func airDropRequiresExplicitOffPreference() {
        #expect(StatusReaders.airDrop("{ DiscoverableMode = Off; }") == .compliant)
        #expect(StatusReaders.airDrop("{ DiscoverableMode = ContactsOnly; }") == .nonCompliant)
        #expect(StatusReaders.airDrop("{ SomeOtherKey = Off; }") == .unavailable)
    }

    @Test("FileVault parser distinguishes explicit on, off, and unknown states")
    func fileVaultRequiresExplicitStatus() {
        #expect(StatusReaders.fileVault("FileVault is On.\n") == .compliant)
        #expect(StatusReaders.fileVault("FileVault is Off.\n") == .nonCompliant)
        #expect(StatusReaders.fileVault("Deferred enablement is active.\n") == .unavailable)
    }

    @Test("firewall posture requires all three explicit protections")
    func firewallPostureFailsClosed() {
        #expect(
            StatusReaders.firewall(
                global: "Firewall is enabled.\n",
                stealth: "Stealth mode is on\n",
                blockAll: "Block all is on\n"
            ) == .compliant
        )
        #expect(
            StatusReaders.firewall(
                global: "Firewall is enabled.\n",
                stealth: "Stealth mode is on\n",
                blockAll: "Block all is off\n"
            ) == .nonCompliant
        )
        #expect(
            StatusReaders.firewall(
                global: "Firewall is enabled.\n",
                stealth: "unknown\n",
                blockAll: "Block all is on\n"
            ) == .unavailable
        )
    }

    @Test("wake parser requires an explicit disabled wake-on-network value")
    func wakeRequiresExplicitWompOff() {
        #expect(StatusReaders.wake("Currently in use:\n womp 0\n") == .compliant)
        #expect(StatusReaders.wake("Currently in use:\n womp 1\n") == .nonCompliant)
        #expect(StatusReaders.wake("Currently in use:\n sleep 1\n") == .unavailable)
    }

    @Test("command-line parser accepts only menu mode or the exact read-only status mode")
    func commandLineModeIsNarrowlyParsed() {
        #expect(CommandLineMode.parse(["TravelLockdown"]) == .menuBar)
        #expect(
            CommandLineMode.parse(["TravelLockdown", "--status", "--dry-run"])
                == .statusDryRun
        )
        #expect(CommandLineMode.parse(["TravelLockdown", "--status"]) == nil)
        #expect(
            CommandLineMode.parse(["TravelLockdown", "--dry-run", "--status"])
                == nil
        )
    }

    @Test("status collector uses only the fixed read-only command set")
    func collectorUsesFixedReadOnlyCommands() {
        let runner = RecordingRunner(results: compliantResults())
        let collector = ReadOnlyStatusCollector(runner: runner)

        #expect(
            collector.collect() == [
                ComponentVerdict(component: .bluetooth, verification: .compliant),
                ComponentVerdict(component: .handoff, verification: .compliant),
                ComponentVerdict(component: .airDrop, verification: .compliant),
                ComponentVerdict(component: .firewall, verification: .compliant),
                ComponentVerdict(component: .sharing, verification: .unavailable),
                ComponentVerdict(component: .fileVault, verification: .compliant),
                ComponentVerdict(component: .wake, verification: .compliant),
                ComponentVerdict(component: .manualWiFi, verification: .unavailable)
            ]
        )
        #expect(
            runner.commands == [
                CommandKey(
                    executable: "/usr/sbin/system_profiler",
                    arguments: ["SPBluetoothDataType"]
                ),
                CommandKey(
                    executable: "/usr/bin/defaults",
                    arguments: [
                        "-currentHost", "read", "com.apple.coreservices.useractivityd"
                    ]
                ),
                CommandKey(
                    executable: "/usr/bin/defaults",
                    arguments: ["read", "com.apple.sharingd"]
                ),
                CommandKey(
                    executable: "/usr/libexec/ApplicationFirewall/socketfilterfw",
                    arguments: ["--getglobalstate"]
                ),
                CommandKey(
                    executable: "/usr/libexec/ApplicationFirewall/socketfilterfw",
                    arguments: ["--getstealthmode"]
                ),
                CommandKey(
                    executable: "/usr/libexec/ApplicationFirewall/socketfilterfw",
                    arguments: ["--getblockall"]
                ),
                CommandKey(
                    executable: "/usr/bin/fdesetup",
                    arguments: ["status"]
                ),
                CommandKey(
                    executable: "/usr/bin/pmset",
                    arguments: ["-g"]
                )
            ]
        )
    }

    @Test("a nonzero status command is unavailable rather than secure")
    func commandFailureIsUnavailable() {
        var results = compliantResults()
        results[
            CommandKey(
                executable: "/usr/bin/fdesetup",
                arguments: ["status"]
            )
        ] = CommandResult(exitCode: 1, stdout: "FileVault is On.\n", stderr: "error")

        let verdicts = ReadOnlyStatusCollector(runner: FixtureRunner(results: results)).collect()

        #expect(verdicts.first(where: { $0.component == .fileVault })?.verification == .unavailable)
    }

    @Test("dry-run output contains only generic component verdicts")
    func dryRunOutputIsGeneric() {
        var lines: [String] = []

        ReadOnlyCommandLine.printStatus(
            using: compliantFixtureRunner(),
            writeLine: { lines.append($0) }
        )

        #expect(
            lines == [
                "Bluetooth: compliant",
                "Handoff: compliant",
                "AirDrop: compliant",
                "Firewall: compliant",
                "Sharing: unavailable",
                "FileVault: compliant",
                "Wake: compliant",
                "Manual Wi-Fi: unavailable"
            ]
        )
    }

    private func compliantFixtureRunner() -> FixtureRunner {
        FixtureRunner(results: compliantResults())
    }

    private func compliantResults() -> [CommandKey: CommandResult] {
        func success(_ output: String) -> CommandResult {
            CommandResult(exitCode: 0, stdout: output, stderr: "")
        }

        return [
            CommandKey(
                executable: "/usr/sbin/system_profiler",
                arguments: ["SPBluetoothDataType"]
            ): success("Bluetooth Controller:\n State: Off\n"),
            CommandKey(
                executable: "/usr/bin/defaults",
                arguments: ["-currentHost", "read", "com.apple.coreservices.useractivityd"]
            ): success(
                "{ ActivityAdvertisingAllowed = 0; ActivityReceivingAllowed = 0; }"
            ),
            CommandKey(
                executable: "/usr/bin/defaults",
                arguments: ["read", "com.apple.sharingd"]
            ): success("{ DiscoverableMode = Off; }"),
            CommandKey(
                executable: "/usr/libexec/ApplicationFirewall/socketfilterfw",
                arguments: ["--getglobalstate"]
            ): success("Firewall is enabled.\n"),
            CommandKey(
                executable: "/usr/libexec/ApplicationFirewall/socketfilterfw",
                arguments: ["--getstealthmode"]
            ): success("Stealth mode is on\n"),
            CommandKey(
                executable: "/usr/libexec/ApplicationFirewall/socketfilterfw",
                arguments: ["--getblockall"]
            ): success("Block all is on\n"),
            CommandKey(
                executable: "/usr/bin/fdesetup",
                arguments: ["status"]
            ): success("FileVault is On.\n"),
            CommandKey(
                executable: "/usr/bin/pmset",
                arguments: ["-g"]
            ): success("Currently in use:\n womp 0\n")
        ]
    }
}
