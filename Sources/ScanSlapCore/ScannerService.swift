import Foundation

public enum ScannedPageCollector {
    public static func collect(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { url in
            let name = url.lastPathComponent.lowercased()
            return name.hasPrefix("scan-page-") && (name.hasSuffix(".tif") || name.hasSuffix(".tiff"))
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}

public enum ScannerServiceError: LocalizedError {
    case busy
    case scanFailed(String)
    case noPages
    case partialScan(pageCount: Int, recoveryURL: URL, detail: String)
    case outputFailed(recoveryURL: URL, detail: String)

    public var errorDescription: String? {
        switch self {
        case .busy: "The scanner is already in use."
        case .scanFailed(let detail): "Scanning failed: \(detail)"
        case .noPages: "No pages were scanned. Load paper in the feeder and try again."
        case .partialScan(let count, let url, let detail):
            "Scanning stopped after \(count) page\(count == 1 ? "" : "s"): \(detail) Raw pages were preserved at \(url.path)."
        case .outputFailed(let url, let detail):
            "The final file could not be created: \(detail) Raw pages were preserved at \(url.path)."
        }
    }
}

public struct ScanJobResult: Sendable {
    public let outputURL: URL
    public let pageCount: Int
}

public actor ScannerService {
    private let commandBuilder: ScanCommandBuilder
    private let runner: any ProcessRunning
    private let outputWriter: ScanOutputWriter
    private var isBusy = false

    public init(
        commandBuilder: ScanCommandBuilder = ScanCommandBuilder(),
        runner: any ProcessRunning = ProcessRunner(),
        outputWriter: ScanOutputWriter = ScanOutputWriter()
    ) {
        self.commandBuilder = commandBuilder
        self.runner = runner
        self.outputWriter = outputWriter
    }

    public func status() async -> ScannerStatus {
        guard !isBusy else { return .unavailable("Scanner is busy.") }
        do {
            let result = try await runner.run(commandBuilder.discoveryCommand())
            return ScannerStatusParser.parse(
                standardOutput: result.standardOutput,
                standardError: result.standardError,
                exitCode: result.exitCode
            )
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    public func scan(
        settings: ScanSettings,
        outputDirectory: URL,
        outputFormat: ScanOutputFormat = .searchablePDF,
        autoRotatePortrait: Bool = true
    ) async throws -> ScanJobResult {
        guard !isBusy else { throw ScannerServiceError.busy }
        isBusy = true
        defer { isBusy = false }

        let discovery = try await runner.run(commandBuilder.discoveryCommand())
        guard discovery.exitCode == 0,
              let deviceIdentifier = ScannerDiscoveryParser.deviceIdentifier(from: discovery.standardOutput) else {
            let detail = diagnostic(stderr: discovery.standardError, stdout: discovery.standardOutput)
            throw ScannerServiceError.scanFailed(detail)
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let workDirectory = fileManager.temporaryDirectory.appendingPathComponent("ScanSlap-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)

        let batchPattern = workDirectory.appendingPathComponent("scan-page-%03d.tiff")
        let command = commandBuilder.scanCommand(
            settings: settings,
            batchPattern: batchPattern,
            deviceIdentifier: deviceIdentifier
        )
        let processResult: ProcessResult
        do {
            processResult = try await runner.run(command)
        } catch {
            let pages = (try? ScannedPageCollector.collect(in: workDirectory)) ?? []
            if pages.isEmpty {
                try? fileManager.removeItem(at: workDirectory)
                throw error
            }
            let recovery = preserveRecoveryDirectory(workDirectory, in: outputDirectory)
            throw ScannerServiceError.partialScan(pageCount: pages.count, recoveryURL: recovery, detail: error.localizedDescription)
        }

        let pages = try ScannedPageCollector.collect(in: workDirectory)
        guard !pages.isEmpty else {
            try? fileManager.removeItem(at: workDirectory)
            if processResult.exitCode != 0 {
                throw ScannerServiceError.scanFailed(diagnostic(stderr: processResult.standardError, stdout: processResult.standardOutput))
            }
            throw ScannerServiceError.noPages
        }
        if processResult.exitCode != 0 {
            let recovery = preserveRecoveryDirectory(workDirectory, in: outputDirectory)
            throw ScannerServiceError.partialScan(
                pageCount: pages.count,
                recoveryURL: recovery,
                detail: diagnostic(stderr: processResult.standardError, stdout: processResult.standardOutput)
            )
        }

        do {
            let result = try outputWriter.write(
                imageURLs: pages,
                destinationDirectory: outputDirectory,
                baseName: outputBaseName(),
                format: outputFormat,
                autoRotatePortrait: autoRotatePortrait
            )
            try? fileManager.removeItem(at: workDirectory)
            return ScanJobResult(outputURL: result.outputURL, pageCount: result.pageCount)
        } catch {
            let recovery = preserveRecoveryDirectory(workDirectory, in: outputDirectory)
            throw ScannerServiceError.outputFailed(recoveryURL: recovery, detail: error.localizedDescription)
        }
    }

    private func diagnostic(stderr: String, stdout: String) -> String {
        [stderr, stdout]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "Unknown scanner error"
    }

    private func preserveRecoveryDirectory(_ source: URL, in outputDirectory: URL) -> URL {
        let destination = outputDirectory.appendingPathComponent("Scan Recovery \(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.moveItem(at: source, to: destination)
            return destination
        } catch {
            return source
        }
    }

    private func outputBaseName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Scan \(formatter.string(from: Date()))"
    }
}
