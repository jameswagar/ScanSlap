import Darwin
import Foundation

public enum ScannerStatus: Equatable, Sendable {
    case checking
    case ready
    case unavailable(String)
}

public enum ScannerDiscoveryParser {
    public static func deviceIdentifier(from output: String) -> String? {
        let pattern = #"device `([^']+)' is a FUJITSU ScanSnap S300M scanner"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              let range = Range(match.range(at: 1), in: output) else {
            return nil
        }
        return String(output[range])
    }
}

public enum ScannerStatusParser {
    public static func parse(standardOutput: String, standardError: String, exitCode: Int32) -> ScannerStatus {
        if exitCode == 0 && ScannerDiscoveryParser.deviceIdentifier(from: standardOutput) != nil {
            return .ready
        }
        let message = [standardError, standardOutput]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "ScanSnap S300M not found"
        return .unavailable(message)
    }
}

public struct ProcessResult: Sendable {
    public let standardOutput: String
    public let standardError: String
    public let exitCode: Int32

    public init(standardOutput: String, standardError: String, exitCode: Int32) {
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.exitCode = exitCode
    }
}

public enum ProcessRunnerError: LocalizedError {
    case executableMissing(String)
    case timedOut(TimeInterval)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .executableMissing(let path): "Required scanner tool is missing: \(path)"
        case .timedOut(let seconds): "Scanner command timed out after \(Int(seconds)) seconds."
        case .cancelled: "Scanner command was cancelled."
        }
    }
}

private final class ProcessExecutionState: @unchecked Sendable {
    enum StopReason { case timeout, cancellation }

    private let lock = NSLock()
    private var process: Process?
    private var completed = false
    private var stopReason: StopReason?

    func attachRunningProcess(_ process: Process) {
        lock.lock()
        if !completed { self.process = process }
        let shouldStop = !completed && stopReason != nil
        lock.unlock()
        if shouldStop { stop(process) }
    }

    func requestStop(_ reason: StopReason) {
        lock.lock()
        guard !completed, stopReason == nil else { lock.unlock(); return }
        stopReason = reason
        let process = process
        lock.unlock()
        if let process { stop(process) }
    }

    private func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) { [weak self, weak process] in
            guard let self, let process else { return }
            self.lock.lock()
            let shouldForce = !self.completed && self.process === process && process.isRunning
            self.lock.unlock()
            if shouldForce { Darwin.kill(process.processIdentifier, SIGKILL) }
        }
    }

    func finish() -> StopReason?? {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return nil }
        completed = true
        process = nil
        return .some(stopReason)
    }
}

public protocol ProcessRunning: Sendable {
    func run(_ command: ProcessCommand) async throws -> ProcessResult
}

public struct ProcessRunner: ProcessRunning, Sendable {
    public init() {}

    public func run(_ command: ProcessCommand) async throws -> ProcessResult {
        if Task.isCancelled { throw ProcessRunnerError.cancelled }
        guard FileManager.default.isExecutableFile(atPath: command.executable) else {
            throw ProcessRunnerError.executableMissing(command.executable)
        }

        let state = ProcessExecutionState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ScanSlap-Process-\(UUID().uuidString)")
                let stdoutURL = directory.appendingPathComponent("stdout")
                let stderrURL = directory.appendingPathComponent("stderr")
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
                    FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
                    let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
                    let stderrHandle = try FileHandle(forWritingTo: stderrURL)
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: command.executable)
                    process.arguments = command.arguments
                    process.standardOutput = stdoutHandle
                    process.standardError = stderrHandle
                    process.environment = ProcessInfo.processInfo.environment.merging(command.environment) { _, new in new }
                    process.terminationHandler = { terminated in
                        guard let wrappedReason = state.finish() else { return }
                        try? stdoutHandle.close()
                        try? stderrHandle.close()
                        let stdout = (try? Data(contentsOf: stdoutURL)) ?? Data()
                        let stderr = (try? Data(contentsOf: stderrURL)) ?? Data()
                        try? FileManager.default.removeItem(at: directory)
                        switch wrappedReason {
                        case .some(.timeout): continuation.resume(throwing: ProcessRunnerError.timedOut(command.timeout))
                        case .some(.cancellation): continuation.resume(throwing: ProcessRunnerError.cancelled)
                        case .none:
                            continuation.resume(returning: ProcessResult(
                                standardOutput: String(decoding: stdout, as: UTF8.self),
                                standardError: String(decoding: stderr, as: UTF8.self),
                                exitCode: terminated.terminationStatus
                            ))
                        }
                    }
                    try process.run()
                    state.attachRunningProcess(process)
                    DispatchQueue.global().asyncAfter(deadline: .now() + command.timeout) {
                        state.requestStop(.timeout)
                    }
                } catch {
                    if state.finish() != nil {
                        try? FileManager.default.removeItem(at: directory)
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            state.requestStop(.cancellation)
        }
    }
}
