import AppKit
import Foundation

struct BluetoothSnapshot: DeclaredNonSecretSnapshotModel, Equatable {
    static let snapshotModelID = "TravelLockdown.bluetooth.v1"

    let isPoweredOn: Bool
}

enum BluetoothActionResult: Equatable, Sendable {
    case openedSettings
    case launchedShortcut
    case unavailable
}

protocol BluetoothActionProvider: Sendable {
    func requestPowerOff() async throws -> BluetoothActionResult
    func requestPowerOn() async throws -> BluetoothActionResult
}

struct UnavailableBluetoothActionProvider: BluetoothActionProvider {
    func requestPowerOff() async throws -> BluetoothActionResult {
        .unavailable
    }

    func requestPowerOn() async throws -> BluetoothActionResult {
        .unavailable
    }
}

extension BluetoothActionProvider where Self == UnavailableBluetoothActionProvider {
    static var unavailable: UnavailableBluetoothActionProvider {
        UnavailableBluetoothActionProvider()
    }
}

protocol BluetoothSettingsOpening: Sendable {
    func openBluetoothSettings() async -> Bool
}

protocol BluetoothInstructionPresenting: Sendable {
    func presentBluetoothInstruction(_ instruction: String) async
}

struct NativeBluetoothSettingsOpener: BluetoothSettingsOpening {
    private static let paneURL = URL(
        string: "x-apple.systempreferences:com.apple.BluetoothSettings"
    )!

    func openBluetoothSettings() async -> Bool {
        await MainActor.run {
            NSWorkspace.shared.open(Self.paneURL)
        }
    }
}

struct NativeBluetoothInstructionPresenter: BluetoothInstructionPresenting {
    func presentBluetoothInstruction(_ instruction: String) async {
        await MainActor.run {
            let alert = NSAlert()
            alert.messageText = "Travel Lockdown"
            alert.informativeText = instruction
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}

struct SystemSettingsBluetoothActionProvider: BluetoothActionProvider {
    private let settingsOpener: any BluetoothSettingsOpening
    private let instructionPresenter: any BluetoothInstructionPresenting

    init(
        settingsOpener: any BluetoothSettingsOpening = NativeBluetoothSettingsOpener(),
        instructionPresenter: any BluetoothInstructionPresenting =
            NativeBluetoothInstructionPresenter()
    ) {
        self.settingsOpener = settingsOpener
        self.instructionPresenter = instructionPresenter
    }

    func requestPowerOff() async throws -> BluetoothActionResult {
        await requestPowerChange(instruction: "Turn Bluetooth off in System Settings.")
    }

    func requestPowerOn() async throws -> BluetoothActionResult {
        await requestPowerChange(instruction: "Turn Bluetooth on in System Settings.")
    }

    private func requestPowerChange(instruction: String) async -> BluetoothActionResult {
        guard await settingsOpener.openBluetoothSettings() else {
            return .unavailable
        }
        await instructionPresenter.presentBluetoothInstruction(instruction)
        return .openedSettings
    }
}

enum BluetoothActionProviderError: Error, Equatable {
    case shortcutFailed
}

/// Optional setup uses Apple's visible Shortcuts actions and remains outside the app's
/// private API boundary. Users must create shortcuts with the two exact names below.
struct ShortcutsBluetoothActionProvider: BluetoothActionProvider {
    static let setupInstructions =
        "Create visible Apple Shortcuts actions named Travel Lockdown Bluetooth Off and "
        + "Travel Lockdown Bluetooth On. This stays outside the app's private API boundary."

    private static let powerOffShortcutName = "Travel Lockdown Bluetooth Off"
    private static let powerOnShortcutName = "Travel Lockdown Bluetooth On"

    private let runner: any CommandRunning

    init(runner: any CommandRunning = ProcessCommandRunner()) {
        self.runner = runner
    }

    func requestPowerOff() async throws -> BluetoothActionResult {
        try requestShortcut(named: Self.powerOffShortcutName)
    }

    func requestPowerOn() async throws -> BluetoothActionResult {
        try requestShortcut(named: Self.powerOnShortcutName)
    }

    private func requestShortcut(named shortcutName: String) throws -> BluetoothActionResult {
        let list = try runner.run(executable: "/usr/bin/shortcuts", arguments: ["list"])
        guard list.exitCode == 0 else {
            return .unavailable
        }
        let localNames = list.stdout.split(
            separator: "\n",
            omittingEmptySubsequences: true
        ).map(String.init)
        guard localNames.contains(shortcutName) else {
            return .unavailable
        }

        let result = try runner.run(
            executable: "/usr/bin/shortcuts",
            arguments: ["run", shortcutName]
        )
        guard result.exitCode == 0 else {
            throw BluetoothActionProviderError.shortcutFailed
        }
        return .launchedShortcut
    }
}

enum BluetoothControlError: Error, Equatable {
    case readbackUnavailable
}

struct BluetoothControl: LockdownControl {
    let id = ControlID.bluetooth

    private let actionProvider: any BluetoothActionProvider
    private let runner: any CommandRunning

    init(
        actionProvider: any BluetoothActionProvider = SystemSettingsBluetoothActionProvider(),
        runner: any CommandRunning
    ) {
        self.actionProvider = actionProvider
        self.runner = runner
    }

    func capture() async throws -> ControlSnapshot {
        guard let isPoweredOn = readPoweredState() else {
            throw BluetoothControlError.readbackUnavailable
        }
        return try ControlSnapshot.capturing(
            BluetoothSnapshot(isPoweredOn: isPoweredOn),
            for: id
        )
    }

    func plan(from snapshot: ControlSnapshot) async throws -> [PlannedChange] {
        [
            PlannedChange(
                control: id,
                summary: "Turn Bluetooth off with a supported user-mediated action",
                sensitivity: .public
            )
        ]
    }

    func apply() async throws {
        _ = try await actionProvider.requestPowerOff()
    }

    func verify() async throws -> ControlStatus {
        let verification: Verification
        switch readPoweredState() {
        case false?:
            verification = .compliant
        case true?:
            verification = .nonCompliant
        case nil:
            verification = .unavailable
        }
        let detail: String
        switch verification {
        case .compliant:
            detail = "Bluetooth is off"
        case .nonCompliant:
            detail = "Bluetooth is on"
        case .unavailable, .failed:
            detail = "Bluetooth state is unavailable"
        }
        return ControlStatus(id: id, verification: verification, detail: detail)
    }

    func restore(from snapshot: ControlSnapshot) async throws {
        let captured = try snapshot.decoded(as: BluetoothSnapshot.self, for: id)
        if captured.isPoweredOn {
            _ = try await actionProvider.requestPowerOn()
        } else {
            _ = try await actionProvider.requestPowerOff()
        }
    }

    func verifyRestored(from snapshot: ControlSnapshot) async throws -> RestorationStatus {
        let captured = try snapshot.decoded(as: BluetoothSnapshot.self, for: id)
        let matches = readPoweredState() == captured.isPoweredOn
        return RestorationStatus(
            id: id,
            matchesSnapshot: matches,
            detail: matches
                ? "Bluetooth state matches the captured baseline"
                : "Bluetooth state does not match the captured baseline"
        )
    }

    private func readPoweredState() -> Bool? {
        guard let result = try? runner.run(
            executable: "/usr/sbin/system_profiler",
            arguments: ["SPBluetoothDataType"]
        ), result.exitCode == 0 else {
            return nil
        }
        switch StatusReaders.bluetooth(result.stdout) {
        case .compliant:
            return false
        case .nonCompliant:
            return true
        case .unavailable, .failed:
            return nil
        }
    }
}
