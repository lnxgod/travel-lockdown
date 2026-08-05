import Foundation

enum PreflightItem: Equatable, Sendable {
    case fileVault(Verification)
    case usbAccessoryApproval(Verification)
    case privateWiFiAddress(Verification)

    var verification: Verification {
        switch self {
        case .fileVault(let verification),
             .usbAccessoryApproval(let verification),
             .privateWiFiAddress(let verification):
            verification
        }
    }

    var title: String {
        switch self {
        case .fileVault:
            "FileVault"
        case .usbAccessoryApproval:
            "USB accessory approval"
        case .privateWiFiAddress:
            "Private Wi-Fi address"
        }
    }

    var systemSettingsPath: String? {
        guard verification != .compliant else {
            return nil
        }
        return switch self {
        case .fileVault:
            "System Settings > Privacy & Security > FileVault"
        case .usbAccessoryApproval:
            "System Settings > Privacy & Security > Allow accessories to connect"
        case .privateWiFiAddress:
            "System Settings > Wi-Fi > Details > Private Wi-Fi address"
        }
    }
}

struct PreflightReport: Equatable, Sendable {
    let items: [PreflightItem]
}

protocol PreflightProviding: Sendable {
    func runPreflight() async -> PreflightReport
}

protocol PreflightReadbackChecking: Sendable {
    func readUSBAccessoryApproval() -> Verification
    func readPrivateWiFiAddress() -> Verification
}

/// macOS does not expose supported, stable readback for these settings to this app.
/// Keep them unavailable and direct the user to their native panes instead of guessing.
struct NativePreflightReadbackChecker: PreflightReadbackChecking {
    func readUSBAccessoryApproval() -> Verification {
        .unavailable
    }

    func readPrivateWiFiAddress() -> Verification {
        .unavailable
    }
}

struct PreflightControl: PreflightProviding {
    private let runner: any CommandRunning
    private let readbackChecker: any PreflightReadbackChecking

    init(
        runner: any CommandRunning = ProcessCommandRunner(),
        readbackChecker: any PreflightReadbackChecking = NativePreflightReadbackChecker()
    ) {
        self.runner = runner
        self.readbackChecker = readbackChecker
    }

    func runPreflight() async -> PreflightReport {
        PreflightReport(items: [
            .fileVault(readFileVault()),
            .usbAccessoryApproval(readbackChecker.readUSBAccessoryApproval()),
            .privateWiFiAddress(readbackChecker.readPrivateWiFiAddress())
        ])
    }

    private func readFileVault() -> Verification {
        guard let result = try? runner.run(
            executable: "/usr/bin/fdesetup",
            arguments: ["status"]
        ), result.exitCode == 0 else {
            return .unavailable
        }
        return StatusReaders.fileVault(result.stdout)
    }
}
