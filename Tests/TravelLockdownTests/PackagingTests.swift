import Darwin
import Foundation
import Testing
@testable import TravelLockdown

@Suite("PackagingTests")
struct PackagingTests {
    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test("release bundle advertises a menu-bar-only executable")
    func appBundleInfoContainsMenuBarFlag() throws {
        let info = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: packageRoot.appendingPathComponent("App/Info.plist")),
            format: nil
        ) as? [String: Any]

        #expect(info?["LSUIElement"] as? Bool == true)
        #expect(info?["CFBundleExecutable"] as? String == "TravelLockdown")
        #expect(info?["CFBundleIdentifier"] as? String == "ai.gamechangers.travel-lockdown")
        #expect(info?["CFBundleShortVersionString"] as? String == "1.0.0")
        #expect(info?["LSMinimumSystemVersion"] as? String == "15.0")
    }

    @Test("public release is branded, licensed, and keeps menu confirmations inline")
    func publicReleaseMetadataIsComplete() throws {
        let logo = packageRoot.appendingPathComponent("Assets/gamechangers-ai.png")
        let license = packageRoot.appendingPathComponent("LICENSE")
        let menuSource = packageRoot
            .appendingPathComponent("Sources/TravelLockdown/App/MenuView.swift")
        let menuText = try String(contentsOf: menuSource, encoding: .utf8)

        #expect(FileManager.default.fileExists(atPath: logo.path))
        #expect(FileManager.default.fileExists(atPath: license.path))
        #expect(menuText.contains("LockdownSwitch"))
        #expect(menuText.contains("Refreshing status"))
        #expect(menuText.contains("VERIFYING"))
        #expect(menuText.contains(".alert(item:") == false)

        let appSource = try String(
            contentsOf: packageRoot
                .appendingPathComponent("Sources/TravelLockdown/App/TravelLockdownApp.swift"),
            encoding: .utf8
        )
        #expect(appSource.contains("GameChangersMenuBarLogo"))
    }

    @Test("command-line parser accepts restore only as the exact mutation mode")
    func commandLineParserAcceptsOnlyExactRestoreMode() {
        #expect(CommandLineMode.parse(["TravelLockdown", "--restore"]) == .restore)
        #expect(CommandLineMode.parse(["TravelLockdown", "--restore", "--confirm"]) == nil)
        #expect(CommandLineMode.parse(["TravelLockdown", "--enable"]) == nil)
        #expect(CommandLineMode.parse(["TravelLockdown", "--lockdown"]) == nil)
    }

    @Test("recovery helper rejects every invocation except exact confirmation")
    func recoveryHelperRequiresExactConfirmation() throws {
        let script = packageRoot.appendingPathComponent("scripts/recover-travel-lockdown.sh")

        let missingConfirmation = try runZsh(script)
        #expect(missingConfirmation.exitCode == 64)
        #expect(missingConfirmation.stderr == "Usage: recover-travel-lockdown.sh --confirm\n")

        let extraArgument = try runZsh(script, arguments: ["--confirm", "extra"])
        #expect(extraArgument.exitCode == 64)
        #expect(extraArgument.stderr == "Usage: recover-travel-lockdown.sh --confirm\n")
    }

    @Test("recovery helper locates only the adjacent bundle and forwards restore")
    func recoveryHelperForwardsOnlyRestoreToAdjacentBundle() throws {
        let fixture = try RecoveryScriptFixture(
            sourceScript: packageRoot.appendingPathComponent("scripts/recover-travel-lockdown.sh")
        )
        defer { fixture.remove() }

        let result = try runZsh(fixture.script, arguments: ["--confirm"])

        #expect(result.exitCode == 23)
        #expect(result.stdout == "fake app received:--restore\n")
        #expect(result.stderr.isEmpty)
    }

    @Test("restore command cancellation never invokes restoration")
    func restoreCommandRequiresVisibleConfirmation() async {
        let calls = RestoreCallCount()

        let exitCode = await RestoreCommandLine.run(
            confirm: { false },
            restore: {
                calls.increment()
                return fullyRestoredResult()
            }
        )

        #expect(exitCode != 0)
        #expect(calls.value == 0)
    }

    @Test("restore command remains nonzero until every control verifies")
    func restoreCommandFailsClosedOnPartialVerification() async {
        let partial = RestoreResult(
            expectedIDs: [.bluetooth, .wake],
            statuses: [
                RestorationStatus(
                    id: .bluetooth,
                    matchesSnapshot: true,
                    detail: "restored"
                ),
                RestorationStatus(
                    id: .wake,
                    matchesSnapshot: false,
                    detail: "manual recovery required"
                )
            ]
        )

        let exitCode = await RestoreCommandLine.run(
            confirm: { true },
            restore: { partial }
        )

        #expect(exitCode != 0)
    }

    @Test("restore CLI prints nonsecret cancellation failure and incomplete diagnostics")
    func restoreCommandPrintsUsefulFailureDiagnostics() async {
        let cancellationError = TextSink()
        let cancelled = await RestoreCommandLine.run(
            confirm: { false },
            restore: { fullyRestoredResult() },
            stdout: { _ in },
            stderr: cancellationError.write
        )
        #expect(cancelled != 0)
        #expect(cancellationError.text == "Restore cancelled.\n")

        let incompleteError = TextSink()
        let incomplete = await RestoreCommandLine.run(
            confirm: { true },
            restore: {
                RestoreResult(
                    expectedIDs: [.wake],
                    statuses: [
                        RestorationStatus(
                            id: .wake,
                            matchesSnapshot: false,
                            detail: "private raw detail must not print"
                        )
                    ]
                )
            },
            stdout: { _ in },
            stderr: incompleteError.write
        )
        #expect(incomplete != 0)
        #expect(incompleteError.text.contains("wake"))
        #expect(incompleteError.text.contains("incomplete"))
        #expect(incompleteError.text.contains("private raw detail") == false)

        let thrownError = TextSink()
        let failed = await RestoreCommandLine.run(
            confirm: { true },
            restore: { throw RestoreDiagnosticFixtureError.localizedSecret },
            stdout: { _ in },
            stderr: thrownError.write
        )
        #expect(failed != 0)
        #expect(thrownError.text == "Restore failed.\n")
        #expect(thrownError.text.contains("localized secret") == false)
    }

    @Test("restore CLI prints concise success only after complete verification")
    func restoreCommandPrintsSuccessDiagnostic() async {
        let output = TextSink()
        let errors = TextSink()

        let exitCode = await RestoreCommandLine.run(
            confirm: { true },
            restore: { fullyRestoredResult() },
            stdout: output.write,
            stderr: errors.write
        )

        #expect(exitCode == 0)
        #expect(output.text == "Restore completed and verified.\n")
        #expect(errors.text.isEmpty)
    }

    @Test("restore command exits zero only after complete verification")
    func restoreCommandSucceedsAfterCompleteVerification() async {
        let exitCode = await RestoreCommandLine.run(
            confirm: { true },
            restore: { fullyRestoredResult() }
        )

        #expect(exitCode == 0)
    }

    @Test("confirmed recovery invokes the coordinator and returns its verified outcome")
    @MainActor
    func restoreApplicationInvokesCoordinatorAfterConfirmation() async {
        let coordinator = RestoreCoordinatorFake(result: fullyRestoredResult())

        let exitCode = await RestoreApplication.run(
            coordinator: coordinator,
            confirm: { true }
        )

        #expect(exitCode == 0)
        #expect(coordinator.restoreCallCount == 1)
    }

    @Test("restore application returns nonzero when the coordinator rejects a malformed baseline")
    @MainActor
    func restoreApplicationFailsClosedOnBaselineMismatch() async {
        let coordinator = RestoreCoordinatorFake(error: .baselineControlSetMismatch)

        let exitCode = await RestoreApplication.run(
            coordinator: coordinator,
            confirm: { true }
        )

        #expect(exitCode != 0)
        #expect(coordinator.restoreCallCount == 1)
    }

    @Test("restore application returns nonzero when recovery-state removal fails")
    @MainActor
    func restoreApplicationFailsClosedOnBaselineRemovalFailure() async {
        let coordinator = RestoreCoordinatorFake(error: .baselineRemovalFailed)

        let exitCode = await RestoreApplication.run(
            coordinator: coordinator,
            confirm: { true }
        )

        #expect(exitCode != 0)
        #expect(coordinator.restoreCallCount == 1)
    }

    @Test("restore confirmation visibly explains impact and incomplete recovery")
    func restoreConfirmationExplainsRecoverySafety() {
        let prompt = RestoreConfirmationPrompt.standard

        #expect(prompt.title == "Restore Normal State?")
        #expect(prompt.confirmButton == "Restore Normal State")
        #expect(prompt.message.contains("captured baseline"))
        #expect(prompt.message.contains("settings may change"))
        #expect(prompt.message.contains("incomplete"))
        #expect(prompt.message.contains("keep the app and baseline installed"))
    }

    @Test("build script publishes a stable release through the documented build path")
    func buildScriptUsesStableReleaseDestination() throws {
        let fixture = try BuildScriptFixture(
            sourceScript: packageRoot.appendingPathComponent("scripts/build-app.sh"),
            sourcePlist: packageRoot.appendingPathComponent("App/Info.plist")
        )
        defer { fixture.remove() }

        let environment = fixture.environment()
        let result = try runProcess(
            executable: URL(fileURLWithPath: "/bin/zsh"),
            arguments: [fixture.script.path],
            currentDirectory: fixture.unrelatedDirectory,
            environment: environment
        )
        #expect(result.exitCode == 0)
        let buildDestination = try FileManager.default.destinationOfSymbolicLink(
            atPath: fixture.project.appendingPathComponent("build").path
        )
        #expect(URL(fileURLWithPath: buildDestination).lastPathComponent == "current")
        #expect(
            URL(fileURLWithPath: buildDestination).deletingLastPathComponent()
                .resolvingSymlinksInPath()
                == fixture.releaseDirectory.resolvingSymlinksInPath()
        )
        let currentLink = fixture.releaseDirectory.appendingPathComponent("current")
        let firstCurrentDestination = try FileManager.default.destinationOfSymbolicLink(
            atPath: currentLink.path
        )
        let firstVersion = fixture.releaseDirectory
            .appendingPathComponent(firstCurrentDestination)
            .standardizedFileURL
        #expect(firstVersion.path.hasPrefix(
            fixture.releaseDirectory.appendingPathComponent("versions/").path
        ))
        #expect(try firstVersion.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false)
        #expect(
            FileManager.default.isExecutableFile(
                atPath: fixture.project
                    .appendingPathComponent("build/TravelLockdown.app/Contents/MacOS/TravelLockdown")
                    .path
            )
        )
        #expect(
            FileManager.default.fileExists(
                atPath: fixture.project
                    .appendingPathComponent("build/TravelLockdown.app/Contents/Info.plist")
                .path
            )
        )
        #expect(
            FileManager.default.fileExists(
                atPath: fixture.project
                    .appendingPathComponent(
                        "build/TravelLockdown.app/Contents/Resources/gamechangers-ai.png"
                    )
                    .path
            )
        )
        let releaseAttributes = try FileManager.default.attributesOfItem(
            atPath: fixture.releaseDirectory.path
        )
        #expect(releaseAttributes[.posixPermissions] as? Int == 0o700)
        #expect(releaseAttributes[.ownerAccountID] as? Int == Int(geteuid()))

        let secondResult = try runProcess(
            executable: URL(fileURLWithPath: "/bin/zsh"),
            arguments: [fixture.script.path],
            currentDirectory: fixture.unrelatedDirectory,
            environment: environment
        )
        #expect(secondResult.exitCode == 0)
        #expect(FileManager.default.fileExists(atPath: firstVersion.path))
        let secondCurrentDestination = try FileManager.default.destinationOfSymbolicLink(
            atPath: currentLink.path
        )
        #expect(secondCurrentDestination != firstCurrentDestination)
        let secondVersion = fixture.releaseDirectory
            .appendingPathComponent(secondCurrentDestination)
            .standardizedFileURL
        let versionAttributes = try FileManager.default.attributesOfItem(
            atPath: secondVersion.path
        )
        #expect(versionAttributes[.posixPermissions] as? Int == 0o700)
        #expect(versionAttributes[.ownerAccountID] as? Int == Int(geteuid()))

        let postPublishVerification = try runProcess(
            executable: fixture.fakeBin.appendingPathComponent("codesign"),
            arguments: [
                "--verify",
                "--deep",
                "--strict",
                fixture.project.appendingPathComponent("build/TravelLockdown.app").path
            ],
            environment: environment
        )
        #expect(postPublishVerification.exitCode == 0)
    }

    @Test("failed publish leaves the previous verified recovery executable resolvable")
    func failedPublishRetainsPreviousRecoveryExecutable() throws {
        let fixture = try BuildScriptFixture(
            sourceScript: packageRoot.appendingPathComponent("scripts/build-app.sh"),
            sourcePlist: packageRoot.appendingPathComponent("App/Info.plist"),
            seedVerifiedRelease: true,
            failPublishVerification: true
        )
        defer { fixture.remove() }

        let result = try runProcess(
            executable: URL(fileURLWithPath: "/bin/zsh"),
            arguments: [fixture.script.path],
            currentDirectory: fixture.unrelatedDirectory,
            environment: fixture.environment()
        )

        #expect(result.exitCode != 0)
        #expect(fixture.publishVerificationCheckpointWasReached())
        #expect(fixture.postSwitchFailureWasInjected())
        #expect(try fixture.previousReleasePointersRemainValid())
        #expect(try fixture.recoveryBinaryContents() == "previous verified executable\n")
        #expect(try fixture.recoveryPathIsExecutableAndStrictlyVerified())
    }

    @Test("build script rejects a group-writable existing release directory before use")
    func buildScriptRejectsGroupWritableReleaseDirectory() throws {
        let fixture = try BuildScriptFixture(
            sourceScript: packageRoot.appendingPathComponent("scripts/build-app.sh"),
            sourcePlist: packageRoot.appendingPathComponent("App/Info.plist")
        )
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.releaseDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o777],
            ofItemAtPath: fixture.releaseDirectory.path
        )

        let result = try runProcess(
            executable: URL(fileURLWithPath: "/bin/zsh"),
            arguments: [fixture.script.path],
            currentDirectory: fixture.unrelatedDirectory,
            environment: fixture.environment()
        )

        #expect(result.exitCode == 73)
        #expect(
            FileManager.default.fileExists(
                atPath: fixture.project.appendingPathComponent("build").path
            ) == false
        )
        #expect(
            FileManager.default.fileExists(
                atPath: fixture.releaseDirectory.appendingPathComponent("TravelLockdown.app").path
            ) == false
        )
    }

    @Test("build script rejects a release directory beneath a group-writable parent")
    func buildScriptRejectsGroupWritableReleaseParent() throws {
        let fixture = try BuildScriptFixture(
            sourceScript: packageRoot.appendingPathComponent("scripts/build-app.sh"),
            sourcePlist: packageRoot.appendingPathComponent("App/Info.plist")
        )
        defer { fixture.remove() }
        let unsafeParent = fixture.root.appendingPathComponent("unsafe-parent", isDirectory: true)
        let unsafeRelease = unsafeParent.appendingPathComponent("release", isDirectory: true)
        try FileManager.default.createDirectory(
            at: unsafeParent,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o777],
            ofItemAtPath: unsafeParent.path
        )
        var environment = fixture.environment()
        environment["TRAVEL_LOCKDOWN_RELEASE_DIR"] = unsafeRelease.path

        let result = try runProcess(
            executable: URL(fileURLWithPath: "/bin/zsh"),
            arguments: [fixture.script.path],
            currentDirectory: fixture.unrelatedDirectory,
            environment: environment
        )

        #expect(result.exitCode == 73)
        #expect(
            FileManager.default.fileExists(
                atPath: fixture.project.appendingPathComponent("build").path
            ) == false
        )
        #expect(FileManager.default.fileExists(atPath: unsafeRelease.path) == false)
    }

    @Test("build script rejects an override whose parent symlink resolves inside the project")
    func buildScriptRejectsReleasePathResolvingIntoProject() throws {
        let fixture = try BuildScriptFixture(
            sourceScript: packageRoot.appendingPathComponent("scripts/build-app.sh"),
            sourcePlist: packageRoot.appendingPathComponent("App/Info.plist")
        )
        defer { fixture.remove() }
        let parentLink = fixture.root.appendingPathComponent("link-to-project", isDirectory: true)
        let unsafeRelease = parentLink.appendingPathComponent("release", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: parentLink,
            withDestinationURL: fixture.project
        )
        var environment = fixture.environment()
        environment["TRAVEL_LOCKDOWN_RELEASE_DIR"] = unsafeRelease.path

        let result = try runProcess(
            executable: URL(fileURLWithPath: "/bin/zsh"),
            arguments: [fixture.script.path],
            currentDirectory: fixture.unrelatedDirectory,
            environment: environment
        )

        #expect(result.exitCode == 73)
        #expect(
            FileManager.default.fileExists(
                atPath: fixture.project.appendingPathComponent("build").path
            ) == false
        )
        #expect(FileManager.default.fileExists(atPath: fixture.project.appendingPathComponent("release").path) == false)
    }

    @Test("build script rejects a symlinked release directory before use")
    func buildScriptRejectsSymlinkedReleaseDirectory() throws {
        let fixture = try BuildScriptFixture(
            sourceScript: packageRoot.appendingPathComponent("scripts/build-app.sh"),
            sourcePlist: packageRoot.appendingPathComponent("App/Info.plist")
        )
        defer { fixture.remove() }
        let target = fixture.root.appendingPathComponent("safe-target", isDirectory: true)
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createSymbolicLink(
            at: fixture.releaseDirectory,
            withDestinationURL: target
        )

        let result = try runProcess(
            executable: URL(fileURLWithPath: "/bin/zsh"),
            arguments: [fixture.script.path],
            currentDirectory: fixture.unrelatedDirectory,
            environment: fixture.environment()
        )

        #expect(result.exitCode == 73)
        #expect(
            FileManager.default.fileExists(
                atPath: fixture.project.appendingPathComponent("build").path
            ) == false
        )
        #expect(
            FileManager.default.fileExists(
                atPath: target.appendingPathComponent("TravelLockdown.app").path
            ) == false
        )
    }

    @Test("the exposed build path remains strictly verifiable after real signing")
    func publishedBuildPathPassesRealStrictVerification() throws {
        let fixture = try BuildScriptFixture(
            sourceScript: packageRoot.appendingPathComponent("scripts/build-app.sh"),
            sourcePlist: packageRoot.appendingPathComponent("App/Info.plist"),
            useFakeCodesign: false
        )
        defer { fixture.remove() }

        let result = try runProcess(
            executable: URL(fileURLWithPath: "/bin/zsh"),
            arguments: [fixture.script.path],
            currentDirectory: fixture.unrelatedDirectory,
            environment: fixture.environment()
        )

        #expect(result.exitCode == 0)
        let buildDestination = try FileManager.default.destinationOfSymbolicLink(
            atPath: fixture.project.appendingPathComponent("build").path
        )
        #expect(URL(fileURLWithPath: buildDestination).lastPathComponent == "current")
        #expect(
            URL(fileURLWithPath: buildDestination).deletingLastPathComponent()
                .resolvingSymlinksInPath()
                == fixture.releaseDirectory.resolvingSymlinksInPath()
        )

        let postPublishVerification = try runProcess(
            executable: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: [
                "--verify",
                "--deep",
                "--strict",
                fixture.project.appendingPathComponent("build/TravelLockdown.app").path
            ]
        )
        #expect(postPublishVerification.exitCode == 0)
    }
}

private func fullyRestoredResult() -> RestoreResult {
    RestoreResult(
        expectedIDs: [.bluetooth],
        statuses: [
            RestorationStatus(
                id: .bluetooth,
                matchesSnapshot: true,
                detail: "restored"
            )
        ]
    )
}

private final class RestoreCallCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}

private final class TextSink: @unchecked Sendable {
    private let lock = NSLock()
    private var storedText = ""

    func write(_ value: String) {
        lock.withLock { storedText += value }
    }

    var text: String {
        lock.withLock { storedText }
    }
}

private enum RestoreDiagnosticFixtureError: Error, LocalizedError {
    case localizedSecret

    var errorDescription: String? {
        "localized secret must never print"
    }
}

private final class RestoreCoordinatorFake: @unchecked Sendable, LockdownCoordinating {
    private let result: RestoreResult?
    private let error: CoordinatorError?
    private let lock = NSLock()
    private var storedRestoreCallCount = 0

    init(result: RestoreResult) {
        self.result = result
        error = nil
    }

    init(error: CoordinatorError) {
        result = nil
        self.error = error
    }

    var restoreCallCount: Int {
        lock.withLock { storedRestoreCallCount }
    }

    func enable(dryRun: Bool) async throws -> CoordinatorResult {
        throw RestoreCoordinatorFakeError.unexpectedOperation
    }

    func restore() async throws -> RestoreResult {
        lock.withLock { storedRestoreCallCount += 1 }
        if let error {
            throw error
        }
        return result!
    }

    func status() async -> LockdownStatus {
        .make(controls: [])
    }

    func hasRecoveryState() async -> Bool {
        true
    }
}

private enum RestoreCoordinatorFakeError: Error {
    case unexpectedOperation
}

private struct ProcessResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

private func runZsh(_ script: URL, arguments: [String] = []) throws -> ProcessResult {
    try runProcess(
        executable: URL(fileURLWithPath: "/bin/zsh"),
        arguments: [script.path] + arguments
    )
}

private func runProcess(
    executable: URL,
    arguments: [String],
    currentDirectory: URL? = nil,
    environment: [String: String]? = nil
) throws -> ProcessResult {
    let process = Process()
    let stdout = Pipe()
    let stderr = Pipe()
    process.executableURL = executable
    process.arguments = arguments
    process.currentDirectoryURL = currentDirectory
    process.environment = environment
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()
    return ProcessResult(
        exitCode: process.terminationStatus,
        stdout: String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
        stderr: String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    )
}

private struct BuildScriptFixture {
    let root: URL
    let project: URL
    let script: URL
    let fakeBin: URL
    let unrelatedDirectory: URL
    let releaseDirectory: URL
    let publishVerificationCheckpoint: URL
    let postSwitchFailureCheckpoint: URL
    let candidateVerificationCount: URL
    let failPublishVerification: Bool

    init(
        sourceScript: URL,
        sourcePlist: URL,
        useFakeCodesign: Bool = true,
        seedVerifiedRelease: Bool = false,
        failPublishVerification: Bool = false
    ) throws {
        let manager = FileManager.default
        root = manager.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("TravelLockdownBuildTests-\(UUID().uuidString)")
        project = root.appendingPathComponent("project", isDirectory: true)
        let scripts = project.appendingPathComponent("scripts", isDirectory: true)
        let app = project.appendingPathComponent("App", isDirectory: true)
        let assets = project.appendingPathComponent("Assets", isDirectory: true)
        fakeBin = root.appendingPathComponent("fake-bin", isDirectory: true)
        unrelatedDirectory = root.appendingPathComponent("unrelated", isDirectory: true)
        releaseDirectory = root.appendingPathComponent("stable-release", isDirectory: true)
        publishVerificationCheckpoint = root.appendingPathComponent(
            "publish-verification-checkpoint"
        )
        postSwitchFailureCheckpoint = root.appendingPathComponent(
            "post-switch-failure-checkpoint"
        )
        candidateVerificationCount = root.appendingPathComponent(
            "candidate-verification-count"
        )
        self.failPublishVerification = failPublishVerification
        for directory in [scripts, app, assets, fakeBin, unrelatedDirectory] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        script = scripts.appendingPathComponent("build-app.sh")
        try manager.copyItem(at: sourceScript, to: script)
        try manager.copyItem(at: sourcePlist, to: app.appendingPathComponent("Info.plist"))
        let sourceLogo = sourcePlist
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Assets/gamechangers-ai.png")
        try manager.copyItem(
            at: sourceLogo,
            to: assets.appendingPathComponent("gamechangers-ai.png")
        )

        try Self.writeExecutable(
            """
            #!/bin/zsh
            [[ "$*" == "build -c release" ]] || exit 88
            mkdir -p .build/release
            print '#!/bin/zsh' > .build/release/TravelLockdown
            print 'exit 0' >> .build/release/TravelLockdown
            chmod 755 .build/release/TravelLockdown
            """,
            to: fakeBin.appendingPathComponent("swift")
        )
        if useFakeCodesign {
            try Self.writeExecutable(
                """
                #!/bin/zsh
                target_dir=${4:h}
                resolved_target_dir=${target_dir:A}
                expected_release=${TRAVEL_LOCKDOWN_EXPECTED_RELEASE_DIR:A}
                [[ "$resolved_target_dir" == "$expected_release" \
                   || "$resolved_target_dir" == "$expected_release"/* ]] || exit 92
                case "$1" in
                  --force)
                    /usr/bin/xattr -p com.apple.FinderInfo "$4" >/dev/null 2>&1 && exit 90
                    /usr/bin/xattr -wx com.apple.FinderInfo 0000000000000000200000000000000000000000000000000000000000000000 "$4"
                    exit 0
                    ;;
                  --verify)
                    /usr/bin/xattr -p com.apple.FinderInfo "$4" >/dev/null 2>&1 && exit 91
                    resolved_target=${4:A}
                    previous_app="$expected_release/versions/version-old/TravelLockdown.app"
                    if [[ "$resolved_target" == "$expected_release"/versions/version-*/TravelLockdown.app \
                       && "$resolved_target" != "$previous_app" ]]; then
                      verification_count=0
                      [[ -f "$TRAVEL_LOCKDOWN_CANDIDATE_VERIFY_COUNT_FILE" ]] \
                        && verification_count=$(<"$TRAVEL_LOCKDOWN_CANDIDATE_VERIFY_COUNT_FILE")
                      (( verification_count += 1 ))
                      print "$verification_count" \
                        > "$TRAVEL_LOCKDOWN_CANDIDATE_VERIFY_COUNT_FILE"
                      if (( verification_count == 2 )); then
                        print reached > "$TRAVEL_LOCKDOWN_PUBLISH_CHECKPOINT_FILE"
                      fi
                      if [[ "${TRAVEL_LOCKDOWN_FAIL_PUBLISH_VERIFICATION:-0}" == "1" \
                         && -f "$TRAVEL_LOCKDOWN_PUBLISH_CHECKPOINT_FILE" \
                         && "$verification_count" == "3" ]]; then
                        current_pointer="$expected_release/current"
                        build_app="$TRAVEL_LOCKDOWN_EXPECTED_BUILD_APP"
                        [[ "${current_pointer:A}/TravelLockdown.app" == "$resolved_target" \
                           && "${build_app:A}" == "$resolved_target" ]] || exit 98
                        print injected > "$TRAVEL_LOCKDOWN_POST_SWITCH_FAILURE_FILE"
                        exit 97
                      fi
                    fi
                    exit 0
                    ;;
                  *) exit 89 ;;
                esac
                """,
                to: fakeBin.appendingPathComponent("codesign")
            )
        }

        if seedVerifiedRelease {
            let previousVersion = releaseDirectory.appendingPathComponent(
                "versions/version-old",
                isDirectory: true
            )
            let binary = previousVersion.appendingPathComponent(
                "TravelLockdown.app/Contents/MacOS/TravelLockdown"
            )
            try manager.createDirectory(
                at: binary.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try Data("previous verified executable\n".utf8).write(to: binary)
            try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
            try manager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: previousVersion.path
            )
            try manager.createSymbolicLink(
                atPath: releaseDirectory.appendingPathComponent("current").path,
                withDestinationPath: "versions/version-old"
            )
            try manager.createSymbolicLink(
                at: project.appendingPathComponent("build"),
                withDestinationURL: try Self.canonicalURL(releaseDirectory)
                    .appendingPathComponent("current")
            )
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func environment() -> [String: String] {
        var values = [
            "PATH": "\(fakeBin.path):/usr/bin:/bin:/usr/sbin:/sbin",
            "TRAVEL_LOCKDOWN_RELEASE_DIR": releaseDirectory.path,
            "TRAVEL_LOCKDOWN_EXPECTED_RELEASE_DIR": releaseDirectory.path,
            "TRAVEL_LOCKDOWN_PUBLISH_CHECKPOINT_FILE": publishVerificationCheckpoint.path,
            "TRAVEL_LOCKDOWN_POST_SWITCH_FAILURE_FILE": postSwitchFailureCheckpoint.path,
            "TRAVEL_LOCKDOWN_CANDIDATE_VERIFY_COUNT_FILE": candidateVerificationCount.path,
            "TRAVEL_LOCKDOWN_EXPECTED_BUILD_APP": project
                .appendingPathComponent("build/TravelLockdown.app").path
        ]
        if failPublishVerification {
            values["TRAVEL_LOCKDOWN_FAIL_PUBLISH_VERIFICATION"] = "1"
        }
        return values
    }

    func recoveryBinaryContents() throws -> String {
        try String(
            contentsOf: project.appendingPathComponent(
                "build/TravelLockdown.app/Contents/MacOS/TravelLockdown"
            ),
            encoding: .utf8
        )
    }

    func publishVerificationCheckpointWasReached() -> Bool {
        FileManager.default.fileExists(atPath: publishVerificationCheckpoint.path)
    }

    func postSwitchFailureWasInjected() -> Bool {
        FileManager.default.fileExists(atPath: postSwitchFailureCheckpoint.path)
    }

    func previousReleasePointersRemainValid() throws -> Bool {
        let current = releaseDirectory.appendingPathComponent("current")
        let build = project.appendingPathComponent("build")
        let currentDestination = try FileManager.default.destinationOfSymbolicLink(
            atPath: current.path
        )
        let buildDestination = try FileManager.default.destinationOfSymbolicLink(
            atPath: build.path
        )
        let canonicalCurrent = try Self.canonicalURL(releaseDirectory)
            .appendingPathComponent("current").path
        return currentDestination == "versions/version-old"
            && buildDestination == canonicalCurrent
            && current.resolvingSymlinksInPath().lastPathComponent == "version-old"
            && build.resolvingSymlinksInPath().lastPathComponent == "version-old"
    }

    func recoveryPathIsExecutableAndStrictlyVerified() throws -> Bool {
        let app = project.appendingPathComponent("build/TravelLockdown.app")
        let binary = app.appendingPathComponent("Contents/MacOS/TravelLockdown")
        var verificationEnvironment = environment()
        verificationEnvironment.removeValue(forKey: "TRAVEL_LOCKDOWN_FAIL_PUBLISH_VERIFICATION")
        let verification = try runProcess(
            executable: fakeBin.appendingPathComponent("codesign"),
            arguments: ["--verify", "--deep", "--strict", app.path],
            environment: verificationEnvironment
        )
        return FileManager.default.isExecutableFile(atPath: binary.path)
            && verification.exitCode == 0
    }

    private static func writeExecutable(_ contents: String, to url: URL) throws {
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private static func canonicalURL(_ url: URL) throws -> URL {
        guard let canonical = Darwin.realpath(url.path, nil) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        defer { free(canonical) }
        return URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
    }
}

private struct RecoveryScriptFixture {
    let root: URL
    let script: URL

    init(sourceScript: URL) throws {
        let manager = FileManager.default
        root = manager.temporaryDirectory
            .appendingPathComponent("TravelLockdownPackagingTests-\(UUID().uuidString)")
        let scripts = root.appendingPathComponent("scripts", isDirectory: true)
        let binaryDirectory = root.appendingPathComponent(
            "build/TravelLockdown.app/Contents/MacOS",
            isDirectory: true
        )
        try manager.createDirectory(at: scripts, withIntermediateDirectories: true)
        try manager.createDirectory(at: binaryDirectory, withIntermediateDirectories: true)

        script = scripts.appendingPathComponent("recover-travel-lockdown.sh")
        try manager.copyItem(at: sourceScript, to: script)

        let fakeBinary = binaryDirectory.appendingPathComponent("TravelLockdown")
        try Data("#!/bin/zsh\nprint \"fake app received:$*\"\nexit 23\n".utf8).write(to: fakeBinary)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeBinary.path)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
