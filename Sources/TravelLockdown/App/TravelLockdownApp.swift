import AppKit
import Darwin
import Foundation
import SwiftUI

@main
@MainActor
enum TravelLockdownLauncher {
    static func main() {
        guard let mode = CommandLineMode.parse(ProcessInfo.processInfo.arguments) else {
            let usage = Data("Usage: TravelLockdown [--status --dry-run | --restore]\n".utf8)
            try? FileHandle.standardError.write(contentsOf: usage)
            exit(2)
        }

        switch mode {
        case .menuBar:
            TravelLockdownApp.main()
        case .statusDryRun:
            ReadOnlyCommandLine.printStatus(using: ProcessCommandRunner())
            exit(0)
        case .restore:
            RestoreCommandApplication.run()
        }
    }
}

@MainActor
struct TravelLockdownApp: App {
    @StateObject private var model: LockdownViewModel
    let startupHydrationTask: Task<Void, Never>?

    init() {
        self.init(model: LockdownRuntime.makeViewModel())
    }

    init(model: LockdownViewModel) {
        _model = StateObject(wrappedValue: model)
        startupHydrationTask = model.beginStartupHydration()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model)
        } label: {
            Label(menuBarPresentation.title, systemImage: menuBarPresentation.systemImage)
                .help(menuBarPresentation.helpText)
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarPresentation: MenuBarPresentation {
        MenuBarPresentation.make(
            state: model.lockdownModeState,
            hasOperationAttention: model.operationAttention != nil
        )
    }
}

struct MenuBarPresentation: Equatable, Sendable {
    let title: String
    let systemImage: String
    let helpText: String

    static func make(
        state: LockdownModeState,
        hasOperationAttention: Bool
    ) -> MenuBarPresentation {
        if hasOperationAttention || state == .attention {
            return MenuBarPresentation(
                title: "Travel Lockdown",
                systemImage: "exclamationmark.shield.fill",
                helpText: "Travel Lockdown needs attention"
            )
        }

        if state == .verified {
            return MenuBarPresentation(
                title: "Travel Lockdown",
                systemImage: "lock.shield.fill",
                helpText: "Travel Lockdown is on and verified"
            )
        }

        return MenuBarPresentation(
            title: "Travel Lockdown",
            systemImage: "lock.shield",
            helpText: "Open Travel Lockdown status and preflight"
        )
    }
}

enum LockdownRuntime {
    static func makeCoordinator() -> LockdownCoordinator {
        let runner: any CommandRunning = ProcessCommandRunner()
        return LockdownCoordinator(controls: makeControls(runner: runner))
    }

    @MainActor
    static func makeViewModel() -> LockdownViewModel {
        let runner: any CommandRunning = ProcessCommandRunner()
        return LockdownViewModel(
            coordinator: LockdownCoordinator(controls: makeControls(runner: runner)),
            preflightProvider: PreflightControl(runner: runner)
        )
    }

    static func makeControls(
        runner: any CommandRunning,
        wifiClient: any WiFiConfigurationClient = CoreWLANWiFiConfigurationClient(),
        hotspotVerifier: any HotspotAutoJoinVerifying = HotspotAutoJoinVerifier()
    ) -> [AnyLockdownControl] {
        [
            AnyLockdownControl(BluetoothControl(runner: runner)),
            AnyLockdownControl(ContinuityControl(runner: runner)),
            AnyLockdownControl(
                WiFiPolicyControl(
                    client: wifiClient,
                    hotspotVerifier: hotspotVerifier
                )
            ),
            AnyLockdownControl(IngressControl(runner: runner)),
            AnyLockdownControl(WakeControl(runner: runner))
        ]
    }
}

private enum RestoreCommandApplication {
    @MainActor
    static func run() -> Never {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let delegate = RestoreCommandDelegate(
            coordinator: LockdownRuntime.makeCoordinator()
        )
        application.delegate = delegate
        withExtendedLifetime(delegate) {
            application.run()
        }
        fatalError("Restore command application unexpectedly terminated")
    }
}

private final class RestoreCommandDelegate: NSObject, NSApplicationDelegate {
    private let coordinator: any LockdownCoordinating

    init(coordinator: any LockdownCoordinating) {
        self.coordinator = coordinator
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor [coordinator] in
            let exitCode = await RestoreApplication.run(coordinator: coordinator)
            exit(exitCode)
        }
    }
}
