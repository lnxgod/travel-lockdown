import Foundation
import Testing
@testable import TravelLockdown

@Suite("ControlTests")
struct ControlTests {
    @Test("Bluetooth action is not successful until system profiler reports off")
    func bluetoothActionRequiresControllerReadback() async throws {
        let provider = FakeBluetoothActionProvider(actionResult: .openedSettings)
        let runner = FakeRunner(results: [
            .bluetoothRead: .success("Bluetooth Controller:\n State: On\n")
        ])
        let control = BluetoothControl(actionProvider: provider, runner: runner)

        try await control.apply()

        #expect(try await control.verify().verification == .nonCompliant)
    }

    @Test("unavailable Bluetooth provider remains fail-closed")
    func bluetoothMissingActionProviderDoesNotProduceCompliance() async throws {
        let control = BluetoothControl(
            actionProvider: .unavailable,
            runner: FakeRunner(results: [
                .bluetoothRead: .success("Bluetooth Controller:\n State: On\n")
            ])
        )

        #expect(try await control.verify().verification == .nonCompliant)
    }

    @Test("Bluetooth capture preserves the exact powered state in the declared registry")
    func bluetoothCaptureUsesDeclaredTypedSnapshot() async throws {
        let control = BluetoothControl(
            actionProvider: FakeBluetoothActionProvider(actionResult: .unavailable),
            runner: FakeRunner(results: [
                .bluetoothRead: .success("Bluetooth Controller:\n State: On\n")
            ])
        )
        let snapshot = try await control.capture()
        let expected = try ControlSnapshot.capturing(
            BluetoothSnapshot(isPoweredOn: true),
            for: .bluetooth
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BaselineStore(directory: directory, modelRegistry: .travelLockdown)

        try store.save(
            LockdownBaseline(
                version: 1,
                capturedAt: Date(timeIntervalSince1970: 1),
                snapshots: [snapshot]
            )
        )

        #expect(snapshot == expected)
        #expect(try store.load().snapshots == [expected])
    }

    @Test("Bluetooth restore requests the captured powered state and verifies readback")
    func bluetoothRestoreUsesExactBaselineAndReadback() async throws {
        let provider = FakeBluetoothActionProvider(actionResult: .openedSettings)
        let control = BluetoothControl(
            actionProvider: provider,
            runner: FakeRunner(results: [
                .bluetoothRead: .success("Bluetooth Controller:\n State: On\n")
            ])
        )
        let snapshot = try ControlSnapshot.capturing(
            BluetoothSnapshot(isPoweredOn: true),
            for: .bluetooth
        )

        try await control.restore(from: snapshot)
        let restoration = try await control.verifyRestored(from: snapshot)

        #expect(provider.requests == [.powerOn])
        #expect(restoration.matchesSnapshot == true)
    }

    @Test("Bluetooth restore mismatch retains a nonmatching result")
    func bluetoothRestoreDetectsReadbackMismatch() async throws {
        let provider = FakeBluetoothActionProvider(actionResult: .launchedShortcut)
        let control = BluetoothControl(
            actionProvider: provider,
            runner: FakeRunner(results: [
                .bluetoothRead: .success("Bluetooth Controller:\n State: Off\n")
            ])
        )
        let snapshot = try ControlSnapshot.capturing(
            BluetoothSnapshot(isPoweredOn: true),
            for: .bluetooth
        )

        try await control.restore(from: snapshot)
        let restoration = try await control.verifyRestored(from: snapshot)

        #expect(provider.requests == [.powerOn])
        #expect(restoration.matchesSnapshot == false)
    }

    @Test("Bluetooth restore requests off for an off baseline and verifies exact readback")
    func bluetoothRestorePreservesOffBaseline() async throws {
        let provider = FakeBluetoothActionProvider(actionResult: .openedSettings)
        let control = BluetoothControl(
            actionProvider: provider,
            runner: FakeRunner(results: [
                .bluetoothRead: .success("Bluetooth Controller:\n State: Off\n")
            ])
        )
        let snapshot = try ControlSnapshot.capturing(
            BluetoothSnapshot(isPoweredOn: false),
            for: .bluetooth
        )

        try await control.restore(from: snapshot)
        let restoration = try await control.verifyRestored(from: snapshot)

        #expect(provider.requests == [.powerOff])
        #expect(restoration.matchesSnapshot == true)
    }

    @Test("Bluetooth unknown readback cannot be captured or verified")
    func bluetoothUnknownReadbackFailsClosed() async throws {
        let control = BluetoothControl(
            actionProvider: FakeBluetoothActionProvider(actionResult: .unavailable),
            runner: FakeRunner(results: [
                .bluetoothRead: .success("Bluetooth Controller:\n State: Unknown\n")
            ])
        )

        await #expect(throws: BluetoothControlError.readbackUnavailable) {
            try await control.capture()
        }
        #expect(try await control.verify().verification == .unavailable)
    }

    @Test("Bluetooth Settings mediation gives one instruction without claiming success")
    func bluetoothSettingsProviderUsesVisibleGuidance() async throws {
        let mediator = FakeBluetoothSettingsMediator(openResult: true)
        let provider = SystemSettingsBluetoothActionProvider(
            settingsOpener: mediator,
            instructionPresenter: mediator
        )

        #expect(try await provider.requestPowerOff() == .openedSettings)
        #expect(try await provider.requestPowerOn() == .openedSettings)
        #expect(mediator.openCount == 2)
        #expect(mediator.instructions == [
            "Turn Bluetooth off in System Settings.",
            "Turn Bluetooth on in System Settings."
        ])
    }

    @Test("Bluetooth Settings open failure remains unavailable and gives no instruction")
    func bluetoothSettingsProviderFailsClosed() async throws {
        let mediator = FakeBluetoothSettingsMediator(openResult: false)
        let provider = SystemSettingsBluetoothActionProvider(
            settingsOpener: mediator,
            instructionPresenter: mediator
        )

        #expect(try await provider.requestPowerOff() == .unavailable)
        #expect(mediator.openCount == 1)
        #expect(mediator.instructions.isEmpty)
    }

    @Test("Bluetooth Shortcut runs only after the exact visible local name is found")
    func bluetoothShortcutRequiresExactLocalName() async throws {
        let runner = FakeRunner(results: [
            .shortcutsList: .success(
                "Travel Lockdown Bluetooth Off Copy\nTravel Lockdown Bluetooth On\n"
            )
        ])
        let provider = ShortcutsBluetoothActionProvider(runner: runner)

        #expect(try await provider.requestPowerOff() == .unavailable)
        #expect(runner.commands == [.shortcutsList])
    }

    @Test("Bluetooth Shortcut mediation uses only the two exact approved names")
    func bluetoothShortcutUsesApprovedActionNames() async throws {
        let offRunner = FakeRunner(results: [
            .shortcutsList: .success("Travel Lockdown Bluetooth Off\n"),
            .shortcutsRunOff: .success("")
        ])
        let onRunner = FakeRunner(results: [
            .shortcutsList: .success("Travel Lockdown Bluetooth On\n"),
            .shortcutsRunOn: .success("")
        ])

        #expect(
            try await ShortcutsBluetoothActionProvider(runner: offRunner).requestPowerOff()
                == .launchedShortcut
        )
        #expect(
            try await ShortcutsBluetoothActionProvider(runner: onRunner).requestPowerOn()
                == .launchedShortcut
        )
        #expect(offRunner.commands == [.shortcutsList, .shortcutsRunOff])
        #expect(onRunner.commands == [.shortcutsList, .shortcutsRunOn])
    }

    @Test("Bluetooth Shortcut launch failure never reports a launched action")
    func bluetoothShortcutRequiresSuccessfulLaunchResult() async throws {
        let runner = FakeRunner(results: [
            .shortcutsList: .success("Travel Lockdown Bluetooth Off\n"),
            .shortcutsRunOff: CommandResult(
                exitCode: 7,
                stdout: "",
                stderr: "shortcut failed"
            )
        ])
        let provider = ShortcutsBluetoothActionProvider(runner: runner)

        await #expect(throws: BluetoothActionProviderError.shortcutFailed) {
            try await provider.requestPowerOff()
        }
        #expect(runner.commands == [.shortcutsList, .shortcutsRunOff])
    }

    @Test("privileged runner accepts only predefined command identifiers")
    func privilegedCommandDoesNotAcceptUserShellText() {
        #expect(PrivilegedCommand.allCases == [
            .firewallEnable,
            .firewallDisable,
            .firewallStealthEnable,
            .firewallStealthDisable,
            .firewallBlockAllEnable,
            .firewallBlockAllDisable,
            .wakeForNetworkAccessOff,
            .wakeForNetworkAccessOn
        ])
        #expect(
            PrivilegedCommand.firewallEnable.executable
                == "/usr/libexec/ApplicationFirewall/socketfilterfw"
        )
        #expect(
            PrivilegedCommand.firewallDisable.executable
                == "/usr/libexec/ApplicationFirewall/socketfilterfw"
        )
        #expect(PrivilegedCommand.firewallEnable.arguments == ["--setglobalstate", "on"])
        #expect(PrivilegedCommand.firewallDisable.arguments == ["--setglobalstate", "off"])
        #expect(PrivilegedCommand.firewallStealthEnable.arguments == ["--setstealthmode", "on"])
        #expect(PrivilegedCommand.firewallStealthDisable.arguments == ["--setstealthmode", "off"])
        #expect(PrivilegedCommand.firewallBlockAllEnable.arguments == ["--setblockall", "on"])
        #expect(PrivilegedCommand.firewallBlockAllDisable.arguments == ["--setblockall", "off"])
        #expect(PrivilegedCommand.wakeForNetworkAccessOff.executable == "/usr/sbin/systemsetup")
        #expect(PrivilegedCommand.wakeForNetworkAccessOn.executable == "/usr/sbin/systemsetup")
        #expect(
            PrivilegedCommand.wakeForNetworkAccessOff.arguments
                == ["-setwakeonnetworkaccess", "off"]
        )
        #expect(
            PrivilegedCommand.wakeForNetworkAccessOn.arguments
                == ["-setwakeonnetworkaccess", "on"]
        )
    }

    @Test("authorization runner preserves successful launch with unknown completion")
    func authorizationRunnerPreservesUnknownCompletion() throws {
        let runner = AuthorizationServicesCommandRunner(
            executor: FakeAuthorizationExecutor(
                output: AuthorizedExecutionOutput(
                    terminationStatus: nil,
                    stdout: "legacy launch completed",
                    stderr: ""
                )
            )
        )

        let result = try runner.run(.firewallEnable)

        #expect(result.exitCode == nil)
        #expect(result.stdout == "legacy launch completed")
    }

    @Test("unknown privileged completion succeeds only after immediate exact readback")
    func authorizationUnknownCompletionRequiresPositiveReadback() async throws {
        let executor = FakeAuthorizationExecutor(
            output: AuthorizedExecutionOutput(
                terminationStatus: nil,
                stdout: "legacy launch completed",
                stderr: ""
            )
        )
        let control = IngressControl(
            runner: FakeRunner(results: [
                .firewallGlobalRead: .success("Firewall is enabled. (State = 1)\n"),
                .firewallStealthRead: .success("Stealth mode is on\n"),
                .firewallBlockAllRead: .success("Block all is on\n")
            ]),
            privilegedRunner: AuthorizationServicesCommandRunner(executor: executor),
            sharingStatusCollector: FakeSharingStatusCollector(.allCompliant),
            settingsOpener: FakeSharingSettingsOpener()
        )

        try await control.apply()

        #expect(executor.commands == [
            .firewallEnable,
            .firewallStealthEnable,
            .firewallBlockAllEnable
        ])
    }

    @Test("unknown privileged completion with mismatching readback fails closed")
    func authorizationUnknownCompletionRejectsMismatch() async {
        let executor = FakeAuthorizationExecutor(
            output: AuthorizedExecutionOutput(
                terminationStatus: nil,
                stdout: "legacy launch completed",
                stderr: ""
            )
        )
        let control = IngressControl(
            runner: FakeRunner(results: [
                .firewallGlobalRead: .success("Firewall is disabled. (State = 0)\n"),
                .firewallStealthRead: .success("Stealth mode is on\n"),
                .firewallBlockAllRead: .success("Block all is on\n")
            ]),
            privilegedRunner: AuthorizationServicesCommandRunner(executor: executor),
            sharingStatusCollector: FakeSharingStatusCollector(.allCompliant),
            settingsOpener: FakeSharingSettingsOpener()
        )

        await #expect(throws: IngressControlError.readbackUnavailable) {
            try await control.apply()
        }
        #expect(executor.commands == [.firewallEnable])
    }

    @Test("unknown wake completion succeeds only after exact immediate wake readback")
    func authorizationUnknownWakeCompletionRequiresPositiveReadback() async throws {
        let acceptedRunner = FakePrivilegedRunner(
            unknownCommands: [.wakeForNetworkAccessOff]
        )
        let accepted = WakeControl(
            runner: FakeRunner(results: [
                .wakeRead: .success("Currently in use:\n womp 0\n")
            ]),
            privilegedRunner: acceptedRunner
        )

        try await accepted.apply()
        #expect(acceptedRunner.commands == [.wakeForNetworkAccessOff])

        let rejected = WakeControl(
            runner: FakeRunner(results: [
                .wakeRead: .success("Currently in use:\n womp 1\n")
            ]),
            privilegedRunner: FakePrivilegedRunner(
                unknownCommands: [.wakeForNetworkAccessOff]
            )
        )
        await #expect(throws: WakeControlError.readbackUnavailable) {
            try await rejected.apply()
        }
    }

    @Test("authorization runner preserves a reported nonzero termination status")
    func authorizationRunnerPreservesNonzeroStatus() throws {
        let runner = AuthorizationServicesCommandRunner(
            executor: FakeAuthorizationExecutor(
                output: AuthorizedExecutionOutput(
                    terminationStatus: 19,
                    stdout: "",
                    stderr: "privileged command failed"
                )
            )
        )

        let result = try runner.run(.wakeForNetworkAccessOff)

        #expect(result.exitCode == 19)
        #expect(result.stderr == "privileged command failed")
    }

    @Test("authorization runner rejects unavailable completion before execution")
    func authorizationRunnerPreflightsCompletionCapability() {
        let executor = FakeAuthorizationExecutor(
            capability: .unavailable,
            output: AuthorizedExecutionOutput(
                terminationStatus: nil,
                stdout: "must not execute",
                stderr: ""
            )
        )
        let runner = AuthorizationServicesCommandRunner(executor: executor)

        #expect(throws: AuthorizedCommandError.completionStatusUnavailable) {
            try runner.run(.firewallEnable)
        }
        #expect(executor.executeCount == 0)
    }

    @Test("ingress nonzero privileged result stops later commands and Sharing guidance")
    func ingressNonzeroPrivilegedResultStopsApply() async throws {
        let privilegedRunner = FakePrivilegedRunner(results: [
            (.firewallStealthEnable, CommandResult(
                exitCode: 23,
                stdout: "",
                stderr: "mutation failed"
            ))
        ])
        let opener = FakeSharingSettingsOpener()
        let control = IngressControl(
            runner: FakeRunner(results: [:]),
            privilegedRunner: privilegedRunner,
            sharingStatusCollector: FakeSharingStatusCollector(.allUnavailable),
            settingsOpener: opener
        )

        await #expect(throws: IngressControlError.commandFailed) {
            try await control.apply()
        }

        #expect(privilegedRunner.commands == [.firewallEnable, .firewallStealthEnable])
        #expect(opener.openCount == 0)
    }

    @Test("wake nonzero restore result retains the recovery baseline")
    func wakeNonzeroRestoreRetainsBaseline() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BaselineStore(directory: directory, modelRegistry: .travelLockdown)
        let snapshot = try ControlSnapshot.capturing(
            WakeSnapshot(wakeForNetworkAccess: true),
            for: .wake
        )
        try store.save(
            LockdownBaseline(
                version: 1,
                capturedAt: Date(timeIntervalSince1970: 1),
                snapshots: [snapshot]
            )
        )
        let privilegedRunner = FakePrivilegedRunner(results: [
            (.wakeForNetworkAccessOn, CommandResult(
                exitCode: 24,
                stdout: "",
                stderr: "restore failed"
            ))
        ])
        let control = WakeControl(
            runner: FakeRunner(results: [
                .wakeRead: .success("Currently in use:\n womp 0\n")
            ]),
            privilegedRunner: privilegedRunner
        )
        let coordinator = LockdownCoordinator(controls: [control], baselineStore: store)

        let result = try await coordinator.restore()

        #expect(privilegedRunner.commands == [.wakeForNetworkAccessOn])
        #expect(result.isFullyRestored == false)
        #expect(result.statuses.first?.matchesSnapshot == false)
        #expect(store.exists == true)
    }

    @Test("ingress control remains noncompliant when block-all readback is off")
    func ingressVerificationRequiresBlockAllAndStealth() async throws {
        let runner = FakeRunner(results: [
            .firewallGlobalRead: .success("Firewall is enabled."),
            .firewallStealthRead: .success("Stealth mode is on"),
            .firewallBlockAllRead: .success("Block all is off")
        ])
        let control = IngressControl(
            runner: runner,
            privilegedRunner: FakePrivilegedRunner(),
            sharingStatusCollector: FakeSharingStatusCollector(.allCompliant)
        )

        #expect(try await control.verify().verification == .nonCompliant)
    }

    @Test("unknown sharing status remains unavailable with exact native actions")
    func ingressUnavailableSharingStatusFailsClosed() async throws {
        let runner = FakeRunner(results: [
            .firewallGlobalRead: .success("Firewall is enabled."),
            .firewallStealthRead: .success("Stealth mode is on"),
            .firewallBlockAllRead: .success("Block all is on")
        ])
        let control = IngressControl(
            runner: runner,
            privilegedRunner: FakePrivilegedRunner(),
            sharingStatusCollector: NativeSharingStatusCollector()
        )

        let status = try await control.verify()

        #expect(status.verification == .unavailable)
        for service in SharingService.allCases {
            #expect(status.detail.contains(service.nativeSharingPaneAction))
        }
    }

    @Test("ingress apply uses only fixed privileged commands and fake Sharing guidance")
    func ingressApplyUsesFixedAuthorizationAndUserMediation() async throws {
        let privilegedRunner = FakePrivilegedRunner()
        let opener = FakeSharingSettingsOpener()
        let control = IngressControl(
            runner: FakeRunner(results: [:]),
            privilegedRunner: privilegedRunner,
            sharingStatusCollector: FakeSharingStatusCollector(.allUnavailable),
            settingsOpener: opener
        )

        try await control.apply()

        #expect(privilegedRunner.commands == [
            .firewallEnable,
            .firewallStealthEnable,
            .firewallBlockAllEnable
        ])
        #expect(opener.openCount == 1)
    }

    @Test("ingress capture preserves exact firewall state in the declared registry")
    func ingressCapturePreservesExactFirewallState() async throws {
        let runner = FakeRunner(results: [
            .firewallGlobalRead: .success("Firewall is disabled."),
            .firewallStealthRead: .success("Stealth mode is on"),
            .firewallBlockAllRead: .success("Block all is off")
        ])
        let control = IngressControl(
            runner: runner,
            privilegedRunner: FakePrivilegedRunner(),
            sharingStatusCollector: FakeSharingStatusCollector(.allUnavailable)
        )
        let snapshot = try await control.capture()
        let expected = try ControlSnapshot.capturing(
            IngressSnapshot(
                firewallEnabled: false,
                stealthModeEnabled: true,
                blockAllEnabled: false
            ),
            for: .ingress
        )

        #expect(snapshot == expected)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BaselineStore(directory: directory, modelRegistry: .travelLockdown)
        try store.save(
            LockdownBaseline(
                version: 1,
                capturedAt: Date(timeIntervalSince1970: 1),
                snapshots: [snapshot]
            )
        )
        #expect(try store.load().snapshots == [expected])
    }

    @Test("ingress restore selects fixed commands for every captured firewall value")
    func ingressRestoreSelectsExactFixedCommands() async throws {
        let privilegedRunner = FakePrivilegedRunner()
        let control = IngressControl(
            runner: FakeRunner(results: [:]),
            privilegedRunner: privilegedRunner,
            sharingStatusCollector: FakeSharingStatusCollector(.allUnavailable),
            settingsOpener: FakeSharingSettingsOpener()
        )
        let firstSnapshot = try ControlSnapshot.capturing(
            IngressSnapshot(
                firewallEnabled: false,
                stealthModeEnabled: true,
                blockAllEnabled: false
            ),
            for: .ingress
        )
        let secondSnapshot = try ControlSnapshot.capturing(
            IngressSnapshot(
                firewallEnabled: true,
                stealthModeEnabled: false,
                blockAllEnabled: true
            ),
            for: .ingress
        )

        try await control.restore(from: firstSnapshot)
        try await control.restore(from: secondSnapshot)

        #expect(privilegedRunner.commands == [
            .firewallDisable,
            .firewallStealthEnable,
            .firewallBlockAllDisable,
            .firewallEnable,
            .firewallStealthDisable,
            .firewallBlockAllEnable
        ])
    }

    @Test("manual Sharing stays unresolved while automatic firewall evidence is preserved")
    func ingressManualSharingMarkersPreventRestoredMatch() async throws {
        let runner = FakeRunner(results: [
            .firewallGlobalRead: .success("Firewall is disabled."),
            .firewallStealthRead: .success("Stealth mode is on"),
            .firewallBlockAllRead: .success("Block all is off")
        ])
        let control = IngressControl(
            runner: runner,
            privilegedRunner: FakePrivilegedRunner(),
            sharingStatusCollector: FakeSharingStatusCollector(.allUnavailable),
            settingsOpener: FakeSharingSettingsOpener()
        )
        let snapshot = try ControlSnapshot.capturing(
            IngressSnapshot(
                firewallEnabled: false,
                stealthModeEnabled: true,
                blockAllEnabled: false
            ),
            for: .ingress
        )

        let restoration = try await control.verifyRestored(from: snapshot)

        #expect(restoration.matchesSnapshot)
        for service in SharingService.allCases {
            #expect(restoration.detail.contains(service.rawValue))
        }
    }

    @Test("legacy Ingress snapshot decodes every Sharing service as unresolved")
    func ingressLegacySnapshotAddsAllSharingMarkers() throws {
        let legacy = Data(
            """
            {
              "firewallEnabled": true,
              "stealthModeEnabled": true,
              "blockAllEnabled": true
            }
            """.utf8
        )

        let decoded = try JSONDecoder().decode(IngressSnapshot.self, from: legacy)
        let canonical = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)

        #expect(canonical.contains("sharingRecovery"))
        for service in SharingService.allCases {
            #expect(canonical.contains(service.rawValue))
        }
    }

    @Test("Ingress snapshot rejects an incomplete Sharing recovery marker set")
    func ingressSnapshotRejectsMissingSharingMarkers() {
        let incomplete = Data(
            """
            {
              "firewallEnabled": true,
              "stealthModeEnabled": true,
              "blockAllEnabled": true,
              "sharingRecovery": []
            }
            """.utf8
        )

        #expect(throws: BaselineStoreError.invalidSnapshotPayload) {
            try JSONDecoder().decode(IngressSnapshot.self, from: incomplete)
        }
    }

    @Test("wake verification requires explicit wake-on-network readback off")
    func wakeVerificationFailsClosedOnUnknownReadback() async throws {
        let runner = FakeRunner(results: [
            .wakeRead: .success("Currently in use:\n sleep 1\n")
        ])
        let control = WakeControl(runner: runner, privilegedRunner: FakePrivilegedRunner())

        #expect(try await control.verify().verification == .unavailable)
    }

    @Test("wake capture records its exact declared non-secret value")
    func wakeCapturePreservesExactValue() async throws {
        let runner = FakeRunner(results: [
            .wakeRead: .success("Currently in use:\n womp 1\n")
        ])
        let control = WakeControl(runner: runner, privilegedRunner: FakePrivilegedRunner())

        #expect(
            try await control.capture()
                == ControlSnapshot.capturing(
                    WakeSnapshot(wakeForNetworkAccess: true),
                    for: .wake
                )
        )
    }

    @Test("wake restore selects fixed commands for both captured values")
    func wakeRestoreSelectsExactFixedCommand() async throws {
        let privilegedRunner = FakePrivilegedRunner()
        let control = WakeControl(
            runner: FakeRunner(results: [:]),
            privilegedRunner: privilegedRunner
        )
        let enabled = try ControlSnapshot.capturing(
            WakeSnapshot(wakeForNetworkAccess: true),
            for: .wake
        )
        let disabled = try ControlSnapshot.capturing(
            WakeSnapshot(wakeForNetworkAccess: false),
            for: .wake
        )

        try await control.restore(from: enabled)
        try await control.restore(from: disabled)

        #expect(privilegedRunner.commands == [
            .wakeForNetworkAccessOn,
            .wakeForNetworkAccessOff
        ])
    }

    @Test("Wi-Fi policy is unavailable when a reversible manual configuration cannot be proven")
    func wifiPolicyFailsClosedWithoutIsolationProof() async throws {
        let client = FakeWiFiConfigurationClient(capability: .unproven)
        let control = WiFiPolicyControl(
            client: client,
            hotspotVerifier: FakeHotspotAutoJoinVerifier(.unavailable)
        )

        #expect(try await control.verify().verification == .unavailable)
        #expect(
            try await control.plan(from: .empty(for: .wifiPolicy)).first?.menuSummary
                == "Configure manual Wi-Fi connection"
        )
    }

    @Test("Wi-Fi policy does not expose an SSID in normal status detail")
    func wifiPolicyStatusRedactsNetworkMetadata() async throws {
        let client = FakeWiFiConfigurationClient(capability: .proven(profileCount: 3))
        let control = WiFiPolicyControl(
            client: client,
            hotspotVerifier: FakeHotspotAutoJoinVerifier(.compliant)
        )

        #expect(try await control.verify().detail == "Manual Wi-Fi connection policy verified")
    }

    @Test("proven manual Wi-Fi cannot pass while Personal Hotspot verification is unavailable")
    func wifiPolicyRequiresHotspotVerification() async throws {
        let client = FakeWiFiConfigurationClient(capability: .proven(profileCount: 3))
        let control = WiFiPolicyControl(client: client)

        #expect(try await control.verify().verification == .unavailable)
    }

    @Test("unavailable Personal Hotspot verification prevents an active posture")
    func wifiPolicyUnavailableHotspotBlocksActivePosture() async throws {
        let client = FakeWiFiConfigurationClient(capability: .proven(profileCount: 3))
        let control = WiFiPolicyControl(client: client)
        var statuses = ControlID.allCases
            .filter { $0 != .wifiPolicy }
            .map { ControlStatus(id: $0, verification: .compliant, detail: "verified") }

        statuses.append(try await control.verify())

        #expect(LockdownStatus.make(controls: statuses).isActive == false)
    }

    @Test("manual Wi-Fi noncompliance remains noncompliant before hotspot guidance")
    func wifiPolicyManualNoncomplianceTakesPrecedence() async throws {
        let client = FakeWiFiConfigurationClient(
            capability: .proven(profileCount: 3),
            manualPolicyVerified: false
        )
        let control = WiFiPolicyControl(
            client: client,
            hotspotVerifier: FakeHotspotAutoJoinVerifier(.unavailable)
        )

        #expect(try await control.verify().verification == .nonCompliant)
    }

    @Test("hotspot auto-join noncompliance prevents Wi-Fi compliance")
    func wifiPolicyHotspotNoncomplianceBlocksCompliance() async throws {
        let client = FakeWiFiConfigurationClient(capability: .proven(profileCount: 3))
        let control = WiFiPolicyControl(
            client: client,
            hotspotVerifier: FakeHotspotAutoJoinVerifier(.nonCompliant)
        )

        #expect(try await control.verify().verification == .nonCompliant)
    }

    @Test("Wi-Fi capture and apply stop before mutation when capability is unproven")
    func wifiPolicyCaptureAndApplyRequireCapabilityProof() async throws {
        let client = FakeWiFiConfigurationClient(capability: .unproven)
        let control = WiFiPolicyControl(client: client)

        await #expect(throws: WiFiPolicyControlError.capabilityUnproven) {
            try await control.capture()
        }
        await #expect(throws: WiFiPolicyControlError.capabilityUnproven) {
            try await control.apply()
        }

        #expect(client.events == ["capability", "capability"])
    }

    @Test("Wi-Fi policy captures and restores the exact declared non-secret baseline")
    func wifiPolicyRestoresExactBaseline() async throws {
        let baseline = WiFiPolicySnapshot(
            preferredNetworks: [],
            rememberJoinedNetworks: true,
            requireAdministratorForAssociation: true,
            requireAdministratorForPower: false,
            requireAdministratorForIBSSMode: false
        )
        let client = FakeWiFiConfigurationClient(
            capability: .proven(profileCount: 2),
            capturedBaselines: [baseline, baseline]
        )
        let control = WiFiPolicyControl(
            client: client,
            hotspotVerifier: FakeHotspotAutoJoinVerifier(.unavailable)
        )

        let snapshot = try await control.capture()
        let expected = try ControlSnapshot.capturing(
            baseline,
            for: .wifiPolicy
        )
        try await control.apply()
        try await control.restore(from: snapshot)
        let restoration = try await control.verifyRestored(from: snapshot)

        #expect(snapshot == expected)
        #expect(client.restoredBaselines == [baseline])
        #expect(restoration.matchesSnapshot)
        #expect(restoration.detail.contains("Personal Hotspot"))
        #expect(
            client.events == [
                "capability", "capture", "capability", "apply", "restore", "capture"
            ]
        )
    }

    @Test("Wi-Fi restored verification detects changed baseline metadata")
    func wifiPolicyRestoredVerificationDetectsMismatch() async throws {
        let original = WiFiPolicySnapshot(
            preferredNetworks: [],
            rememberJoinedNetworks: true,
            requireAdministratorForAssociation: false,
            requireAdministratorForPower: false,
            requireAdministratorForIBSSMode: false
        )
        let changed = WiFiPolicySnapshot(
            preferredNetworks: [],
            rememberJoinedNetworks: false,
            requireAdministratorForAssociation: false,
            requireAdministratorForPower: false,
            requireAdministratorForIBSSMode: false
        )
        let client = FakeWiFiConfigurationClient(
            capability: .proven(profileCount: 1),
            capturedBaselines: [changed]
        )
        let control = WiFiPolicyControl(client: client)
        let snapshot = try ControlSnapshot.capturing(original, for: .wifiPolicy)

        let restoration = try await control.verifyRestored(from: snapshot)

        #expect(restoration.matchesSnapshot == false)
    }

    @Test("production snapshot registry rejects unreviewed Wi-Fi baseline fields")
    func wifiSnapshotRegistryRejectsUnreviewedPayload() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BaselineStore(directory: directory, modelRegistry: .travelLockdown)
        let snapshot = try ControlSnapshot.capturing(
            CompatibleWiFiPolicySnapshot(
                preferredNetworks: [],
                rememberJoinedNetworks: true,
                requireAdministratorForAssociation: false,
                requireAdministratorForPower: false,
                requireAdministratorForIBSSMode: false,
                credential: "unreviewed"
            ),
            for: .wifiPolicy
        )

        #expect(throws: BaselineStoreError.invalidSnapshotPayload) {
            try store.save(
                LockdownBaseline(
                    version: 1,
                    capturedAt: Date(timeIntervalSince1970: 1),
                    snapshots: [snapshot]
                )
            )
        }
    }

    @Test("Wi-Fi snapshot rejects a credential-like unreviewed payload")
    func wifiSnapshotRejectsUnreviewedCredentialField() throws {
        let payload = Data(
            """
            {
              "preferredNetworks": [],
              "rememberJoinedNetworks": true,
              "requireAdministratorForAssociation": false,
              "requireAdministratorForPower": false,
              "requireAdministratorForIBSSMode": false,
              "credential": "unreviewed"
            }
            """.utf8
        )

        #expect(throws: BaselineStoreError.invalidSnapshotPayload) {
            try JSONDecoder().decode(WiFiPolicySnapshot.self, from: payload)
        }
    }

    @Test("legacy Wi-Fi snapshot decodes to an unresolved hotspot marker")
    func wifiLegacySnapshotAddsManualHotspotMarker() throws {
        let legacy = Data(
            """
            {
              "preferredNetworks": [],
              "rememberJoinedNetworks": true,
              "requireAdministratorForAssociation": false,
              "requireAdministratorForPower": false,
              "requireAdministratorForIBSSMode": false
            }
            """.utf8
        )

        let decoded = try JSONDecoder().decode(WiFiPolicySnapshot.self, from: legacy)
        let canonical = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)

        #expect(canonical.contains("personalHotspotRecovery"))
        #expect(canonical.contains("unresolved"))
    }

    @Test("supported public Wi-Fi adapter reaches capture apply and positive readback")
    func wifiAdapterUsesSupportedPublicPipeline() async throws {
        let baseline = WiFiPolicySnapshot(
            preferredNetworks: [
                WiFiNetworkProfileMetadata(
                    ssidData: Data([0x41, 0x00, 0x42]),
                    networkName: nil,
                    security: .wpa3Personal
                ),
                WiFiNetworkProfileMetadata(
                    ssidData: Data("Second".utf8),
                    networkName: "Second",
                    security: .wpa2Enterprise
                )
            ],
            rememberJoinedNetworks: true,
            requireAdministratorForAssociation: true,
            requireAdministratorForPower: false,
            requireAdministratorForIBSSMode: false
        )
        let access = FakePublicWiFiConfigurationAccess(
            initial: baseline,
            supportsPublicCommit: true
        )
        let control = WiFiPolicyControl(
            client: CoreWLANWiFiConfigurationClient(access: access),
            hotspotVerifier: FakeHotspotAutoJoinVerifier(.compliant)
        )

        _ = try await control.capture()
        try await control.apply()

        #expect(try await control.verify().verification == .compliant)
        #expect(access.committedProjection?.preferredNetworks.isEmpty == true)
        #expect(access.committedProjection?.rememberJoinedNetworks == false)
        #expect(access.exportedCredentials == false)
    }

    @Test("runtime factory accepts a supported fake Wi-Fi client pipeline")
    func wifiRuntimeFactoryIsInjectableWithoutNativeAccess() async throws {
        let baseline = WiFiPolicySnapshot(
            preferredNetworks: [],
            rememberJoinedNetworks: true,
            requireAdministratorForAssociation: false,
            requireAdministratorForPower: false,
            requireAdministratorForIBSSMode: false
        )
        let access = FakePublicWiFiConfigurationAccess(initial: baseline)
        let controls = LockdownRuntime.makeControls(
            runner: FakeRunner(results: [:]),
            wifiClient: CoreWLANWiFiConfigurationClient(access: access),
            hotspotVerifier: FakeHotspotAutoJoinVerifier(.compliant)
        )
        let wifi = try #require(controls.first(where: { $0.id == .wifiPolicy }))

        _ = try await wifi.capture()
        try await wifi.apply()
        let status = try await wifi.verify()

        #expect(status.verification == .compliant)
        #expect(access.committedProjection?.preferredNetworks.isEmpty == true)
    }

    @Test("unsupported public Wi-Fi representation stops before fake commit")
    func wifiAdapterRejectsUnsupportedProjection() async {
        let access = FakePublicWiFiConfigurationAccess(
            initial: nil,
            supportsPublicCommit: false
        )
        let control = WiFiPolicyControl(
            client: CoreWLANWiFiConfigurationClient(access: access),
            hotspotVerifier: FakeHotspotAutoJoinVerifier(.compliant)
        )

        await #expect(throws: WiFiPolicyControlError.capabilityUnproven) {
            try await control.capture()
        }
        #expect(access.committedProjection == nil)
    }

    @Test("unknown public Wi-Fi security stops before fake commit")
    func wifiAdapterRejectsUnknownSecurityProjection() async {
        let baseline = WiFiPolicySnapshot(
            preferredNetworks: [
                WiFiNetworkProfileMetadata(
                    ssidData: Data("Unsupported".utf8),
                    networkName: "Unsupported",
                    security: .unknown
                )
            ],
            rememberJoinedNetworks: true,
            requireAdministratorForAssociation: false,
            requireAdministratorForPower: false,
            requireAdministratorForIBSSMode: false
        )
        let access = FakePublicWiFiConfigurationAccess(initial: baseline)
        let control = WiFiPolicyControl(
            client: CoreWLANWiFiConfigurationClient(access: access),
            hotspotVerifier: FakeHotspotAutoJoinVerifier(.compliant)
        )

        await #expect(throws: WiFiPolicyControlError.capabilityUnproven) {
            try await control.capture()
        }
        #expect(access.committedProjection == nil)
    }

    @Test("Personal Hotspot remains unavailable after opening user-mediated Wi-Fi Settings")
    func wifiHotspotGuidanceNeverSynthesizesSuccess() throws {
        let opener = FakeWiFiSettingsOpener()
        let verifier = HotspotAutoJoinVerifier(settingsOpener: opener)

        #expect(verifier.verify() == .unavailable)
        #expect(verifier.remediation == "Set Ask to join hotspots to Never")

        try verifier.openRemediation()

        #expect(opener.openCount == 1)
        #expect(verifier.verify() == .unavailable)
    }

    @Test("continuity control plans Handoff and AirDrop without inventing an AirPlay result")
    func continuityPlanRequiresAirPlayVerification() async throws {
        let runner = FakeRunner(results: [
            .handoffRead: .success(
                "{ ActivityAdvertisingAllowed = 1; ActivityReceivingAllowed = 1; }"
            ),
            .airDropRead: .success("{ DiscoverableMode = ContactsOnly; }")
        ])
        let control = ContinuityControl(
            runner: runner,
            airPlayVerifier: .unavailable,
            settingsOpener: FakeSettingsOpener()
        )

        let snapshot = try await control.capture()
        let plan = try await control.plan(from: snapshot)

        #expect(plan.count == 3)
        #expect(try await control.verify().verification == .nonCompliant)
    }

    @Test("enabled Handoff advertising is noncompliant before AirPlay guidance")
    func enabledHandoffAdvertisingIsNonCompliant() async throws {
        let control = continuityControl(
            handoff: "{ ActivityAdvertisingAllowed = 1; ActivityReceivingAllowed = 0; }",
            airDrop: "{ DiscoverableMode = Off; }"
        )

        #expect(try await control.verify().verification == .nonCompliant)
    }

    @Test("enabled Handoff receiving is noncompliant before AirPlay guidance")
    func enabledHandoffReceivingIsNonCompliant() async throws {
        let control = continuityControl(
            handoff: "{ ActivityAdvertisingAllowed = 0; ActivityReceivingAllowed = 1; }",
            airDrop: "{ DiscoverableMode = Off; }"
        )

        #expect(try await control.verify().verification == .nonCompliant)
    }

    @Test("enabled AirDrop is noncompliant before AirPlay guidance")
    func enabledAirDropIsNonCompliant() async throws {
        let control = continuityControl(
            handoff: "{ ActivityAdvertisingAllowed = 0; ActivityReceivingAllowed = 0; }",
            airDrop: "{ DiscoverableMode = ContactsOnly; }"
        )

        #expect(try await control.verify().verification == .nonCompliant)
    }

    @Test("capture records every missing preference explicitly")
    func captureRecordsMissingPreferences() async throws {
        let runner = FakeRunner(results: [
            .handoffRead: .success("{ ActivityReceivingAllowed = 0; }"),
            .airDropRead: .success("{ OtherPreference = 1; }")
        ])
        let control = ContinuityControl(
            runner: runner,
            airPlayVerifier: .unavailable,
            settingsOpener: FakeSettingsOpener()
        )

        let snapshot = try await control.capture()
        let expected = try ControlSnapshot.capturing(
            ContinuitySnapshot(
                activityAdvertisingAllowed: .missing,
                activityReceivingAllowed: .bool(false),
                discoverableMode: .missing
            ),
            for: .continuity
        )

        #expect(snapshot == expected)
    }

    @Test("wholly absent preference domains capture every managed value as missing")
    func absentDomainsCaptureMissingPreferences() async throws {
        let runner = FakeRunner(results: [
            .handoffRead: .missingDomain("com.apple.coreservices.useractivityd"),
            .airDropRead: .missingDomain("com.apple.sharingd")
        ])
        let control = ContinuityControl(
            runner: runner,
            airPlayVerifier: .unavailable,
            settingsOpener: FakeSettingsOpener()
        )
        let expected = try ControlSnapshot.capturing(
            ContinuitySnapshot(
                activityAdvertisingAllowed: .missing,
                activityReceivingAllowed: .missing,
                discoverableMode: .missing
            ),
            for: .continuity
        )

        #expect(try await control.capture() == expected)
    }

    @Test("unresolved AirPlay preserves automatic Continuity evidence")
    func restoredVerificationRecognizesAbsentDomains() async throws {
        let runner = FakeRunner(results: [
            .handoffRead: .missingDomain("com.apple.coreservices.useractivityd"),
            .airDropRead: .missingDomain("com.apple.sharingd")
        ])
        let control = ContinuityControl(
            runner: runner,
            airPlayVerifier: .unavailable,
            settingsOpener: FakeSettingsOpener()
        )
        let snapshot = try ControlSnapshot.capturing(
            ContinuitySnapshot(
                activityAdvertisingAllowed: .missing,
                activityReceivingAllowed: .missing,
                discoverableMode: .missing
            ),
            for: .continuity
        )

        let restoration = try await control.verifyRestored(from: snapshot)

        #expect(restoration.matchesSnapshot)
        #expect(restoration.detail.contains("AirPlay Receiver"))
    }

    @Test("unknown nonzero preference reads still fail closed")
    func unknownPreferenceReadFailureFailsClosed() async throws {
        let runner = FakeRunner(results: [
            .handoffRead: CommandResult(
                exitCode: 1,
                stdout: "",
                stderr: "Permission denied\n"
            )
        ])
        let control = ContinuityControl(
            runner: runner,
            airPlayVerifier: .unavailable,
            settingsOpener: FakeSettingsOpener()
        )

        await #expect(throws: ContinuityControlError.commandFailed) {
            try await control.capture()
        }
    }

    @Test("a missing-domain diagnostic for another domain fails closed")
    func wrongMissingDomainDiagnosticFailsClosed() async throws {
        let runner = FakeRunner(results: [
            .handoffRead: .missingDomain("com.example.not-the-requested-domain")
        ])
        let control = ContinuityControl(
            runner: runner,
            airPlayVerifier: .unavailable,
            settingsOpener: FakeSettingsOpener()
        )

        await #expect(throws: ContinuityControlError.commandFailed) {
            try await control.capture()
        }
    }

    @Test("apply uses only fixed Continuity mutations then opens native guidance")
    func applyUsesFixedCommandsAndUserMediatedGuidance() async throws {
        let runner = FakeRunner(results: [
            .disableAdvertising: .success(""),
            .disableReceiving: .success(""),
            .disableAirDrop: .success("")
        ])
        let opener = FakeSettingsOpener()
        let control = ContinuityControl(
            runner: runner,
            airPlayVerifier: .unavailable,
            settingsOpener: opener
        )

        try await control.apply()

        #expect(
            runner.commands == [
                .disableAdvertising,
                .disableReceiving,
                .disableAirDrop
            ]
        )
        #expect(opener.openCount == 1)
    }

    @Test("a failed mutation never opens System Settings")
    func failedMutationDoesNotOpenSettings() async throws {
        let runner = FakeRunner(results: [
            .disableAdvertising: CommandResult(exitCode: 1, stdout: "", stderr: "failed")
        ])
        let opener = FakeSettingsOpener()
        let control = ContinuityControl(
            runner: runner,
            airPlayVerifier: .unavailable,
            settingsOpener: opener
        )

        await #expect(throws: ContinuityControlError.commandFailed) {
            try await control.apply()
        }

        #expect(runner.commands == [.disableAdvertising])
        #expect(opener.openCount == 0)
    }

    @Test("native guidance targets only the AirDrop and Continuity pane")
    func nativeGuidanceUsesAirDropContinuityPane() throws {
        let recorder = URLRecorder()
        let opener = NativeAirDropContinuitySettingsOpener { url in
            recorder.record(url)
            return true
        }

        try opener.openAirDropAndContinuity()

        #expect(
            recorder.urls.map(\.absoluteString) == [
                "x-apple.systempreferences:com.apple.AirDrop-Handoff-Settings.extension"
            ]
        )
    }

    @Test("restore deletes only keys captured missing and writes captured typed values")
    func restorePreservesMissingPreferences() async throws {
        let runner = FakeRunner(results: [
            .handoffRead: .success("{ ActivityReceivingAllowed = 1; }"),
            .airDropRead: .success("{ OtherPreference = 1; }"),
            .deleteAdvertising: .success(""),
            .enableReceiving: .success(""),
            .deleteAirDrop: .success("")
        ])
        let opener = FakeSettingsOpener()
        let control = ContinuityControl(
            runner: runner,
            airPlayVerifier: .unavailable,
            settingsOpener: opener
        )
        let snapshot = try await control.capture()
        runner.clearCommands()

        try await control.restore(from: snapshot)
        let restoration = try await control.verifyRestored(from: snapshot)

        #expect(
            runner.commands == [
                .deleteAdvertising,
                .enableReceiving,
                .deleteAirDrop,
                .handoffRead,
                .airDropRead
            ]
        )
        #expect(restoration.matchesSnapshot)
        #expect(restoration.id == .continuity)
        #expect(opener.openCount == 1)
    }

    @Test("legacy Continuity snapshot decodes to an unresolved AirPlay marker")
    func continuityLegacySnapshotAddsAirPlayMarker() throws {
        let legacy = Data(
            """
            {
              "activityAdvertisingAllowed": {"bool": {"_0": true}},
              "activityReceivingAllowed": {"missing": {}},
              "discoverableMode": {"string": {"_0": "ContactsOnly"}}
            }
            """.utf8
        )

        let decoded = try JSONDecoder().decode(ContinuitySnapshot.self, from: legacy)
        let canonical = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)

        #expect(canonical.contains("airPlayReceiverRecovery"))
        #expect(canonical.contains("unresolved"))
    }

    @Test("restore writes the original bool and string values without invented defaults")
    func restoreWritesCapturedValues() async throws {
        let runner = FakeRunner(results: [
            .restoreAdvertisingTrue: .success(""),
            .restoreReceivingFalse: .success(""),
            .restoreAirDropContactsOnly: .success("")
        ])
        let control = ContinuityControl(
            runner: runner,
            airPlayVerifier: .unavailable,
            settingsOpener: FakeSettingsOpener()
        )
        let snapshot = try ControlSnapshot.capturing(
            ContinuitySnapshot(
                activityAdvertisingAllowed: .bool(true),
                activityReceivingAllowed: .bool(false),
                discoverableMode: .string("ContactsOnly")
            ),
            for: .continuity
        )

        try await control.restore(from: snapshot)

        #expect(
            runner.commands == [
                .restoreAdvertisingTrue,
                .restoreReceivingFalse,
                .restoreAirDropContactsOnly
            ]
        )
    }

    @Test("restored verification detects a preference mismatch")
    func restoredVerificationDetectsMismatch() async throws {
        let runner = FakeRunner(results: [
            .handoffRead: .success(
                "{ ActivityAdvertisingAllowed = 0; ActivityReceivingAllowed = 0; }"
            ),
            .airDropRead: .success("{ DiscoverableMode = Off; }")
        ])
        let control = ContinuityControl(
            runner: runner,
            airPlayVerifier: .unavailable,
            settingsOpener: FakeSettingsOpener()
        )
        let snapshot = try ControlSnapshot.capturing(
            ContinuitySnapshot(
                activityAdvertisingAllowed: .bool(true),
                activityReceivingAllowed: .bool(false),
                discoverableMode: .string("Off")
            ),
            for: .continuity
        )

        let restoration = try await control.verifyRestored(from: snapshot)

        #expect(restoration.matchesSnapshot == false)
    }

    @Test("unavailable AirPlay readback prevents active lockdown")
    func unavailableAirPlayPreventsActiveStatus() async throws {
        let runner = FakeRunner(results: [
            .handoffRead: .success(
                "{ ActivityAdvertisingAllowed = 0; ActivityReceivingAllowed = 0; }"
            ),
            .airDropRead: .success("{ DiscoverableMode = Off; }")
        ])
        let control = ContinuityControl(
            runner: runner,
            airPlayVerifier: .unavailable,
            settingsOpener: FakeSettingsOpener()
        )
        var statuses = ControlID.allCases
            .filter { $0 != .continuity }
            .map { ControlStatus(id: $0, verification: .compliant, detail: "verified") }
        statuses.append(try await control.verify())

        #expect(LockdownStatus.make(controls: statuses).isActive == false)
    }

    @Test("production snapshot registry canonicalizes Continuity baselines")
    func continuitySnapshotRegistryCanonicalizesPayload() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BaselineStore(
            directory: directory,
            modelRegistry: .travelLockdown
        )
        let snapshot = try ControlSnapshot.capturing(
            CompatibleContinuitySnapshot(
                activityAdvertisingAllowed: .bool(true),
                activityReceivingAllowed: .missing,
                discoverableMode: .string("ContactsOnly"),
                extra: "must be removed"
            ),
            for: .continuity
        )
        let baseline = LockdownBaseline(
            version: 1,
            capturedAt: Date(timeIntervalSince1970: 1),
            snapshots: [snapshot]
        )

        try store.save(baseline)

        #expect(
            try store.load().snapshots == [
                ControlSnapshot.capturing(
                    ContinuitySnapshot(
                        activityAdvertisingAllowed: .bool(true),
                        activityReceivingAllowed: .missing,
                        discoverableMode: .string("ContactsOnly")
                    ),
                    for: .continuity
                )
            ]
        )
    }

    private func continuityControl(
        handoff: String,
        airDrop: String
    ) -> ContinuityControl {
        ContinuityControl(
            runner: FakeRunner(results: [
                .handoffRead: .success(handoff),
                .airDropRead: .success(airDrop)
            ]),
            airPlayVerifier: .unavailable,
            settingsOpener: FakeSettingsOpener()
        )
    }
}

private final class FakeWiFiConfigurationClient: @unchecked Sendable, WiFiConfigurationClient {
    private let lock = NSLock()
    private let reportedCapability: WiFiCapability
    private let manualPolicyVerified: Bool
    private var pendingBaselines: [WiFiPolicySnapshot]
    private var recordedEvents: [String] = []
    private var recordedRestoredBaselines: [WiFiPolicySnapshot] = []

    init(
        capability: WiFiCapability,
        capturedBaselines: [WiFiPolicySnapshot] = [],
        manualPolicyVerified: Bool = true
    ) {
        reportedCapability = capability
        pendingBaselines = capturedBaselines
        self.manualPolicyVerified = manualPolicyVerified
    }

    func capability() async throws -> WiFiCapability {
        lock.withLock { recordedEvents.append("capability") }
        return reportedCapability
    }

    func captureManualConnectBaseline() async throws -> WiFiPolicySnapshot {
        try lock.withLock {
            recordedEvents.append("capture")
            guard !pendingBaselines.isEmpty else {
                throw FixtureError.unexpectedWiFiOperation
            }
            return pendingBaselines.removeFirst()
        }
    }

    func applyManualConnectPolicy() async throws {
        lock.withLock { recordedEvents.append("apply") }
    }

    func verifyManualConnectPolicy() async throws -> Bool {
        lock.withLock { recordedEvents.append("verify") }
        return manualPolicyVerified
    }

    func restoreManualConnectBaseline(_ baseline: WiFiPolicySnapshot) async throws {
        lock.withLock {
            recordedEvents.append("restore")
            recordedRestoredBaselines.append(baseline)
        }
    }

    var events: [String] {
        lock.withLock { recordedEvents }
    }

    var restoredBaselines: [WiFiPolicySnapshot] {
        lock.withLock { recordedRestoredBaselines }
    }
}

private struct FakeHotspotAutoJoinVerifier: HotspotAutoJoinVerifying {
    let verification: Verification

    init(_ verification: Verification) {
        self.verification = verification
    }

    func verify() -> Verification {
        verification
    }

    func openRemediation() throws {}
}

private struct CompatibleWiFiPolicySnapshot: DeclaredNonSecretSnapshotModel {
    static let snapshotModelID = WiFiPolicySnapshot.snapshotModelID

    let preferredNetworks: [WiFiNetworkProfileMetadata]
    let rememberJoinedNetworks: Bool
    let requireAdministratorForAssociation: Bool
    let requireAdministratorForPower: Bool
    let requireAdministratorForIBSSMode: Bool
    let credential: String
}

private final class FakePublicWiFiConfigurationAccess: @unchecked Sendable,
    PublicWiFiConfigurationAccess
{
    private let lock = NSLock()
    private let supportsPublicCommit: Bool
    private var current: PublicWiFiConfigurationProjection?
    private var storedCommittedProjection: PublicWiFiConfigurationProjection?
    private var recordedEvents: [String] = []

    init(
        initial: WiFiPolicySnapshot? = nil,
        supportsPublicCommit: Bool = true
    ) {
        current = initial.map(PublicWiFiConfigurationProjection.init)
        self.supportsPublicCommit = supportsPublicCommit
    }

    func currentConfiguration() throws -> PublicWiFiConfigurationProjection {
        try lock.withLock {
            recordedEvents.append("capture")
            guard supportsPublicCommit, let current else {
                throw WiFiPolicyControlError.capabilityUnproven
            }
            return current
        }
    }

    func commitConfiguration(_ projection: PublicWiFiConfigurationProjection) throws {
        try lock.withLock {
            recordedEvents.append("commit")
            guard supportsPublicCommit else {
                throw WiFiPolicyControlError.capabilityUnproven
            }
            self.current = projection
            storedCommittedProjection = projection
        }
    }

    var events: [String] {
        lock.withLock { recordedEvents }
    }

    var committedProjection: PublicWiFiConfigurationProjection? {
        lock.withLock { storedCommittedProjection }
    }

    var exportedCredentials: Bool {
        false
    }
}

private final class FakeWiFiSettingsOpener: @unchecked Sendable, WiFiSettingsOpening {
    private let lock = NSLock()
    private var recordedOpenCount = 0

    func openWiFiSettings() throws {
        lock.withLock { recordedOpenCount += 1 }
    }

    var openCount: Int {
        lock.withLock { recordedOpenCount }
    }
}

private struct CompatibleContinuitySnapshot: DeclaredNonSecretSnapshotModel {
    static let snapshotModelID = ContinuitySnapshot.snapshotModelID

    let activityAdvertisingAllowed: PreferenceValue
    let activityReceivingAllowed: PreferenceValue
    let discoverableMode: PreferenceValue
    let extra: String
}

private struct Command: Hashable, Sendable {
    let executable: String
    let arguments: [String]

    static let handoffRead = Command(
        executable: "/usr/bin/defaults",
        arguments: ["-currentHost", "read", "com.apple.coreservices.useractivityd"]
    )

    static let airDropRead = Command(
        executable: "/usr/bin/defaults",
        arguments: ["read", "com.apple.sharingd"]
    )
    static let firewallGlobalRead = Command(
        executable: "/usr/libexec/ApplicationFirewall/socketfilterfw",
        arguments: ["--getglobalstate"]
    )
    static let firewallStealthRead = Command(
        executable: "/usr/libexec/ApplicationFirewall/socketfilterfw",
        arguments: ["--getstealthmode"]
    )
    static let firewallBlockAllRead = Command(
        executable: "/usr/libexec/ApplicationFirewall/socketfilterfw",
        arguments: ["--getblockall"]
    )
    static let wakeRead = Command(
        executable: "/usr/bin/pmset",
        arguments: ["-g"]
    )
    static let bluetoothRead = Command(
        executable: "/usr/sbin/system_profiler",
        arguments: ["SPBluetoothDataType"]
    )
    static let shortcutsList = Command(
        executable: "/usr/bin/shortcuts",
        arguments: ["list"]
    )
    static let shortcutsRunOff = Command(
        executable: "/usr/bin/shortcuts",
        arguments: ["run", "Travel Lockdown Bluetooth Off"]
    )
    static let shortcutsRunOn = Command(
        executable: "/usr/bin/shortcuts",
        arguments: ["run", "Travel Lockdown Bluetooth On"]
    )

    static let disableAdvertising = defaults([
        "-currentHost", "write", "com.apple.coreservices.useractivityd",
        "ActivityAdvertisingAllowed", "-bool", "false"
    ])
    static let disableReceiving = defaults([
        "-currentHost", "write", "com.apple.coreservices.useractivityd",
        "ActivityReceivingAllowed", "-bool", "false"
    ])
    static let disableAirDrop = defaults([
        "write", "com.apple.sharingd", "DiscoverableMode", "-string", "Off"
    ])
    static let deleteAdvertising = defaults([
        "-currentHost", "delete", "com.apple.coreservices.useractivityd",
        "ActivityAdvertisingAllowed"
    ])
    static let enableReceiving = defaults([
        "-currentHost", "write", "com.apple.coreservices.useractivityd",
        "ActivityReceivingAllowed", "-bool", "true"
    ])
    static let deleteAirDrop = defaults([
        "delete", "com.apple.sharingd", "DiscoverableMode"
    ])
    static let restoreAdvertisingTrue = defaults([
        "-currentHost", "write", "com.apple.coreservices.useractivityd",
        "ActivityAdvertisingAllowed", "-bool", "true"
    ])
    static let restoreReceivingFalse = disableReceiving
    static let restoreAirDropContactsOnly = defaults([
        "write", "com.apple.sharingd", "DiscoverableMode", "-string", "ContactsOnly"
    ])

    private static func defaults(_ arguments: [String]) -> Command {
        Command(executable: "/usr/bin/defaults", arguments: arguments)
    }
}

private final class FakeBluetoothActionProvider: @unchecked Sendable, BluetoothActionProvider {
    enum Request: Equatable {
        case powerOff
        case powerOn
    }

    private let lock = NSLock()
    let actionResult: BluetoothActionResult
    private var recordedRequests: [Request] = []

    init(actionResult: BluetoothActionResult) {
        self.actionResult = actionResult
    }

    func requestPowerOff() async throws -> BluetoothActionResult {
        lock.withLock { recordedRequests.append(.powerOff) }
        return actionResult
    }

    func requestPowerOn() async throws -> BluetoothActionResult {
        lock.withLock { recordedRequests.append(.powerOn) }
        return actionResult
    }

    var requests: [Request] {
        lock.withLock { recordedRequests }
    }
}

private final class FakeBluetoothSettingsMediator: @unchecked Sendable,
    BluetoothSettingsOpening, BluetoothInstructionPresenting
{
    private let lock = NSLock()
    private let openResult: Bool
    private var recordedOpenCount = 0
    private var recordedInstructions: [String] = []

    init(openResult: Bool) {
        self.openResult = openResult
    }

    func openBluetoothSettings() async -> Bool {
        lock.withLock { recordedOpenCount += 1 }
        return openResult
    }

    func presentBluetoothInstruction(_ instruction: String) async {
        lock.withLock { recordedInstructions.append(instruction) }
    }

    var openCount: Int {
        lock.withLock { recordedOpenCount }
    }

    var instructions: [String] {
        lock.withLock { recordedInstructions }
    }
}

private final class FakePrivilegedRunner: @unchecked Sendable, AuthorizedCommandRunning {
    private let lock = NSLock()
    private let results: [(PrivilegedCommand, CommandResult)]
    private let unknownCommands: [PrivilegedCommand]
    private var recordedCommands: [PrivilegedCommand] = []

    init(
        results: [(PrivilegedCommand, CommandResult)] = [],
        unknownCommands: [PrivilegedCommand] = []
    ) {
        self.results = results
        self.unknownCommands = unknownCommands
    }

    func run(_ command: PrivilegedCommand) throws -> AuthorizedCommandResult {
        lock.withLock { recordedCommands.append(command) }
        if unknownCommands.contains(command) {
            return .completionUnknown(stdout: "legacy launch completed")
        }
        return .exited(results.first(where: { $0.0 == command })?.1 ?? .success(""))
    }

    var commands: [PrivilegedCommand] {
        lock.withLock { recordedCommands }
    }
}

private final class FakeAuthorizationExecutor: @unchecked Sendable, AuthorizationExecuting {
    private let lock = NSLock()
    let capability: AuthorizationExecutionCapability
    let output: AuthorizedExecutionOutput
    private var recordedExecuteCount = 0
    private var recordedCommands: [PrivilegedCommand] = []

    init(
        capability: AuthorizationExecutionCapability = .reportsTerminationStatus,
        output: AuthorizedExecutionOutput
    ) {
        self.capability = capability
        self.output = output
    }

    func execute(_ command: PrivilegedCommand) throws -> AuthorizedExecutionOutput {
        lock.withLock {
            recordedExecuteCount += 1
            recordedCommands.append(command)
        }
        return output
    }

    var executeCount: Int {
        lock.withLock { recordedExecuteCount }
    }

    var commands: [PrivilegedCommand] {
        lock.withLock { recordedCommands }
    }
}

private struct FakeSharingStatusCollector: SharingStatusCollecting {
    enum Fixture {
        case allCompliant
        case allUnavailable
    }

    let fixture: Fixture

    init(_ fixture: Fixture) {
        self.fixture = fixture
    }

    func collect() -> [SharingServiceStatus] {
        SharingService.allCases.map {
            SharingServiceStatus(
                service: $0,
                verification: fixture == .allCompliant ? .compliant : .unavailable
            )
        }
    }
}

private final class FakeSharingSettingsOpener: @unchecked Sendable, SharingSettingsOpening {
    private let lock = NSLock()
    private var recordedOpenCount = 0

    func openSharingSettings() throws {
        lock.withLock { recordedOpenCount += 1 }
    }

    var openCount: Int {
        lock.withLock { recordedOpenCount }
    }
}

private final class FakeRunner: @unchecked Sendable, CommandRunning {
    private let lock = NSLock()
    private let results: [Command: CommandResult]
    private var recordedCommands: [Command] = []

    init(results: [Command: CommandResult]) {
        self.results = results
    }

    func run(executable: String, arguments: [String]) throws -> CommandResult {
        let command = Command(executable: executable, arguments: arguments)
        return try lock.withLock {
            recordedCommands.append(command)
            guard let result = results[command] else {
                throw FixtureError.unexpectedCommand
            }
            return result
        }
    }

    var commands: [Command] {
        lock.withLock { recordedCommands }
    }

    func clearCommands() {
        lock.withLock { recordedCommands.removeAll() }
    }
}

private final class FakeSettingsOpener: @unchecked Sendable, AirDropContinuitySettingsOpening {
    private let lock = NSLock()
    private var recordedOpenCount = 0

    var openCount: Int {
        lock.withLock { recordedOpenCount }
    }

    func openAirDropAndContinuity() throws {
        lock.withLock { recordedOpenCount += 1 }
    }
}

private enum FixtureError: Error {
    case unexpectedCommand
    case unexpectedWiFiOperation
}

private final class URLRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedURLs: [URL] = []

    var urls: [URL] {
        lock.withLock { recordedURLs }
    }

    func record(_ url: URL) {
        lock.withLock { recordedURLs.append(url) }
    }
}

private extension CommandResult {
    static func success(_ stdout: String) -> CommandResult {
        CommandResult(exitCode: 0, stdout: stdout, stderr: "")
    }

    static func missingDomain(_ domain: String) -> CommandResult {
        CommandResult(
            exitCode: 1,
            stdout: "",
            stderr: "2026-08-02 14:07:35.897 defaults[76834:18962954] \n"
                + "Domain \(domain) does not exist\n"
        )
    }
}
