import Darwin
import Foundation
import Security

enum PrivilegedCommand: CaseIterable, Equatable, Sendable {
    case firewallEnable
    case firewallDisable
    case firewallStealthEnable
    case firewallStealthDisable
    case firewallBlockAllEnable
    case firewallBlockAllDisable
    case wakeForNetworkAccessOff
    case wakeForNetworkAccessOn

    var executable: String {
        switch self {
        case .firewallEnable, .firewallDisable,
             .firewallStealthEnable, .firewallStealthDisable,
             .firewallBlockAllEnable, .firewallBlockAllDisable:
            "/usr/libexec/ApplicationFirewall/socketfilterfw"
        case .wakeForNetworkAccessOff, .wakeForNetworkAccessOn:
            "/usr/sbin/systemsetup"
        }
    }

    var arguments: [String] {
        switch self {
        case .firewallEnable:
            ["--setglobalstate", "on"]
        case .firewallDisable:
            ["--setglobalstate", "off"]
        case .firewallStealthEnable:
            ["--setstealthmode", "on"]
        case .firewallStealthDisable:
            ["--setstealthmode", "off"]
        case .firewallBlockAllEnable:
            ["--setblockall", "on"]
        case .firewallBlockAllDisable:
            ["--setblockall", "off"]
        case .wakeForNetworkAccessOff:
            ["-setwakeonnetworkaccess", "off"]
        case .wakeForNetworkAccessOn:
            ["-setwakeonnetworkaccess", "on"]
        }
    }
}

protocol AuthorizedCommandRunning: Sendable {
    func run(_ command: PrivilegedCommand) throws -> AuthorizedCommandResult
}

struct AuthorizedCommandResult: Equatable, Sendable {
    let exitCode: Int32?
    let stdout: String
    let stderr: String

    static func exited(_ result: CommandResult) -> AuthorizedCommandResult {
        AuthorizedCommandResult(
            exitCode: result.exitCode,
            stdout: result.stdout,
            stderr: result.stderr
        )
    }

    static func completionUnknown(
        stdout: String = "",
        stderr: String = ""
    ) -> AuthorizedCommandResult {
        AuthorizedCommandResult(exitCode: nil, stdout: stdout, stderr: stderr)
    }
}

struct AuthorizedExecutionOutput: Equatable, Sendable {
    let terminationStatus: Int32?
    let stdout: String
    let stderr: String
}

enum AuthorizationExecutionCapability: Equatable, Sendable {
    case unavailable
    case reportsTerminationStatus
    case launchesWithUnknownCompletion
}

protocol AuthorizationExecuting: Sendable {
    var capability: AuthorizationExecutionCapability { get }
    func execute(_ command: PrivilegedCommand) throws -> AuthorizedExecutionOutput
}

enum AuthorizedCommandError: Error, Equatable {
    case authorizationFailed(OSStatus)
    case executionFailed(OSStatus)
    case argumentEncodingFailed
    case mechanismUnavailable
    case completionStatusUnavailable
}

/// Executes only `PrivilegedCommand` values through macOS Authorization Services.
/// Callers cannot supply an executable, arguments, shell text, or UI command.
struct AuthorizationServicesCommandRunner: AuthorizedCommandRunning {
    private let executor: any AuthorizationExecuting

    init(executor: any AuthorizationExecuting = LegacyAuthorizationExecutor()) {
        self.executor = executor
    }

    func run(_ command: PrivilegedCommand) throws -> AuthorizedCommandResult {
        guard executor.capability != .unavailable else {
            throw AuthorizedCommandError.completionStatusUnavailable
        }
        let output = try executor.execute(command)
        return AuthorizedCommandResult(
            exitCode: output.terminationStatus,
            stdout: output.stdout,
            stderr: output.stderr
        )
    }
}

private struct LegacyAuthorizationExecutor: AuthorizationExecuting {
    let capability = AuthorizationExecutionCapability.launchesWithUnknownCompletion

    func execute(_ command: PrivilegedCommand) throws -> AuthorizedExecutionOutput {
        var authorization: AuthorizationRef?
        let createStatus = AuthorizationCreate(nil, nil, [], &authorization)
        guard createStatus == errAuthorizationSuccess, let authorization else {
            throw AuthorizedCommandError.authorizationFailed(createStatus)
        }
        defer { AuthorizationFree(authorization, []) }

        return try command.executable.withCString { executable in
            try kAuthorizationRightExecute.withCString { rightName in
                try executeAuthorized(
                    command,
                    authorization: authorization,
                    executable: executable,
                    rightName: rightName
                )
            }
        }
    }

    private func executeAuthorized(
        _ command: PrivilegedCommand,
        authorization: AuthorizationRef,
        executable: UnsafePointer<CChar>,
        rightName: UnsafePointer<CChar>
    ) throws -> AuthorizedExecutionOutput {
        var item = AuthorizationItem(
            name: rightName,
            valueLength: strlen(executable),
            value: UnsafeMutableRawPointer(mutating: executable),
            flags: 0
        )
        let copyStatus = withUnsafeMutablePointer(to: &item) { itemPointer in
            var rights = AuthorizationRights(count: 1, items: itemPointer)
            return AuthorizationCopyRights(
                authorization,
                &rights,
                nil,
                [.interactionAllowed, .extendRights],
                nil
            )
        }
        guard copyStatus == errAuthorizationSuccess else {
            throw AuthorizedCommandError.authorizationFailed(copyStatus)
        }

        let allocatedArguments = try command.arguments.map { argument in
            guard let value = strdup(argument) else {
                throw AuthorizedCommandError.argumentEncodingFailed
            }
            return value
        }
        defer { allocatedArguments.forEach { free($0) } }
        var arguments: [UnsafeMutablePointer<CChar>?] = allocatedArguments
        arguments.append(nil)
        var pipe: UnsafeMutablePointer<FILE>?
        guard let security = dlopen(
            "/System/Library/Frameworks/Security.framework/Security",
            RTLD_LAZY | RTLD_LOCAL
        ) else {
            throw AuthorizedCommandError.mechanismUnavailable
        }
        defer { dlclose(security) }
        guard let symbol = dlsym(security, "AuthorizationExecuteWithPrivileges") else {
            throw AuthorizedCommandError.mechanismUnavailable
        }
        typealias ExecuteWithPrivileges = @convention(c) (
            AuthorizationRef,
            UnsafePointer<CChar>,
            AuthorizationFlags,
            UnsafePointer<UnsafeMutablePointer<CChar>>,
            UnsafeMutablePointer<UnsafeMutablePointer<FILE>?>?
        ) -> OSStatus
        let executeWithPrivileges = unsafeBitCast(symbol, to: ExecuteWithPrivileges.self)
        let executeStatus = arguments.withUnsafeBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(
                to: UnsafeMutablePointer<CChar>.self,
                capacity: buffer.count
            ) { argumentPointer in
                executeWithPrivileges(
                    authorization,
                    executable,
                    [],
                    argumentPointer,
                    &pipe
                )
            }
        }
        guard executeStatus == errAuthorizationSuccess else {
            throw AuthorizedCommandError.executionFailed(executeStatus)
        }

        let output = pipe.map(Self.readToEnd) ?? ""
        // AuthorizationExecuteWithPrivileges exposes only authorization/launch status,
        // not the spawned tool's termination status. Preserve that uncertainty so the
        // public runner fails closed instead of fabricating exit code zero.
        return AuthorizedExecutionOutput(
            terminationStatus: nil,
            stdout: output,
            stderr: ""
        )
    }

    private static func readToEnd(_ pipe: UnsafeMutablePointer<FILE>) -> String {
        defer { fclose(pipe) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = fread(&buffer, 1, buffer.count, pipe)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return String(decoding: data, as: UTF8.self)
    }
}
