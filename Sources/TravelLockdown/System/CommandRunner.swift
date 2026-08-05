import Foundation

struct CommandResult: Equatable, Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

protocol CommandRunning: Sendable {
    func run(executable: String, arguments: [String]) throws -> CommandResult
}

struct ProcessCommandRunner: CommandRunning {
    func run(executable: String, arguments: [String]) throws -> CommandResult {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = standardOutput
        process.standardError = standardError

        try process.run()

        let outputCapture = CommandOutputCapture()
        let errorCapture = CommandOutputCapture()
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            outputCapture.read(from: standardOutput.fileHandleForReading)
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            errorCapture.read(from: standardError.fileHandleForReading)
            readers.leave()
        }

        process.waitUntilExit()
        readers.wait()

        return CommandResult(
            exitCode: process.terminationStatus,
            stdout: outputCapture.string,
            stderr: errorCapture.string
        )
    }
}

private final class CommandOutputCapture: @unchecked Sendable {
    private var data = Data()

    var string: String {
        String(decoding: data, as: UTF8.self)
    }

    func read(from handle: FileHandle) {
        data = handle.readDataToEndOfFile()
    }
}
