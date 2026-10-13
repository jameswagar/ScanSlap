import Foundation

public enum ScanSource: String, CaseIterable, Sendable {
    case front = "ADF Front"
    case back = "ADF Back"
    case duplex = "ADF Duplex"
}

public enum ScanColorMode: String, CaseIterable, Sendable {
    case color = "Color"
    case grayscale = "Gray"
    case lineart = "Lineart"
}

public struct ScanSettings: Equatable, Sendable {
    public var source: ScanSource
    public var colorMode: ScanColorMode
    public var resolution: Int

    public init(source: ScanSource = .duplex, colorMode: ScanColorMode = .color, resolution: Int = 300) {
        self.source = source
        self.colorMode = colorMode
        self.resolution = resolution
    }
}

public struct ProcessCommand: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]
    public let timeout: TimeInterval

    public init(
        executable: String,
        arguments: [String],
        environment: [String: String] = [:],
        timeout: TimeInterval = 600
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.timeout = timeout
    }
}

public struct ScanCommandBuilder: Sendable {
    private let executable: String

    public init() {
        self.executable = Self.defaultExecutable()
    }

    public init(executable: String) {
        self.executable = executable
    }

    private static func defaultExecutable() -> String {
        ["/opt/homebrew/bin/scanimage", "/usr/local/bin/scanimage"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? "/opt/homebrew/bin/scanimage"
    }

    public func scanCommand(
        settings: ScanSettings,
        batchPattern: URL,
        deviceIdentifier: String
    ) -> ProcessCommand {
        ProcessCommand(
            executable: executable,
            arguments: [
                "-d", deviceIdentifier,
                "--source", settings.source.rawValue,
                "--mode", settings.colorMode.rawValue,
                "--resolution", String(settings.resolution),
                "--page-width", "215.872",
                "--page-height", "0",
                "--format", "tiff",
                "--batch=\(batchPattern.path)"
            ],
            environment: [
                "SANE_CONFIG_DIR": NSHomeDirectory() + "/Library/Application Support/ScanSnap S300M/sane"
            ]
        )
    }

    public func discoveryCommand() -> ProcessCommand {
        ProcessCommand(
            executable: executable,
            arguments: ["-L"],
            environment: [
                "SANE_CONFIG_DIR": NSHomeDirectory() + "/Library/Application Support/ScanSnap S300M/sane"
            ],
            timeout: 30
        )
    }
}
