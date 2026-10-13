import Foundation
import AppKit
import ImageIO
import PDFKit
import ScanSlapCore
import UniformTypeIdentifiers

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

struct StaticTextRecognizer: TextRecognizing {
    func recognize(in image: CGImage) throws -> [RecognizedText] {
        [RecognizedText(text: "Searchable page", normalizedBounds: CGRect(x: 0.1, y: 0.4, width: 0.7, height: 0.2))]
    }
}

struct FixtureScannerRunner: ProcessRunning {
    let fixtureURL: URL
    let scanExitCode: Int32
    let corruptPage: Bool

    func run(_ command: ProcessCommand) async throws -> ProcessResult {
        if command.arguments == ["-L"] {
            return ProcessResult(
                standardOutput: "device `epjitsu:libusb:000:042' is a FUJITSU ScanSnap S300M scanner\n",
                standardError: "",
                exitCode: 0
            )
        }
        let batch = command.arguments.first { $0.hasPrefix("--batch=") }!.dropFirst("--batch=".count)
        let outputPath = String(batch).replacingOccurrences(of: "%03d", with: "001")
        if corruptPage {
            try Data("not a tiff".utf8).write(to: URL(fileURLWithPath: outputPath))
        } else {
            try FileManager.default.copyItem(at: fixtureURL, to: URL(fileURLWithPath: outputPath))
        }
        return ProcessResult(
            standardOutput: "Scanned page 1",
            standardError: scanExitCode == 0 ? "" : "document feeder jam",
            exitCode: scanExitCode
        )
    }
}

func writeWhiteTIFF(width: Int, height: Int, dpi: Int, to url: URL) throws {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, [
        kCGImagePropertyDPIWidth: dpi,
        kCGImagePropertyDPIHeight: dpi
    ] as CFDictionary)
    expect(CGImageDestinationFinalize(destination), "TIFF fixture is written")
}

func renderedDarkPixelCount(pdfURL: URL, width: Int = 255, height: Int = 330) -> Int {
    guard let page = PDFDocument(url: pdfURL)?.page(at: 0) else { return Int.max }
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bytesPerRow = width * 4
    var pixels = [UInt8](repeating: 255, count: bytesPerRow * height)
    return pixels.withUnsafeMutableBytes { rawBuffer in
        let context = CGContext(
            data: rawBuffer.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        )!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let box = page.bounds(for: .mediaBox)
        context.scaleBy(x: CGFloat(width) / box.width, y: CGFloat(height) / box.height)
        page.draw(with: .mediaBox, to: context)
        let bytes = rawBuffer.bindMemory(to: UInt8.self)
        var count = 0
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            if bytes[offset] < 245 || bytes[offset + 1] < 245 || bytes[offset + 2] < 245 { count += 1 }
        }
        return count
    }
}

let settings = ScanSettings(source: .duplex, colorMode: .color, resolution: 300)
let output = URL(fileURLWithPath: "/tmp/scan-side-%03d.tiff")
let deviceIdentifier = ScannerDiscoveryParser.deviceIdentifier(
    from: "device `epjitsu:libusb:000:042' is a FUJITSU ScanSnap S300M scanner\n"
)
expect(deviceIdentifier == "epjitsu:libusb:000:042", "discovery returns the current USB device identifier")
let command = ScanCommandBuilder(executable: "/opt/homebrew/bin/scanimage").scanCommand(
    settings: settings,
    batchPattern: output,
    deviceIdentifier: deviceIdentifier!
)
expect(command.executable == "/opt/homebrew/bin/scanimage", "scanimage executable")
expect(command.environment["SANE_CONFIG_DIR"] == NSHomeDirectory() + "/Library/Application Support/ScanSnap S300M/sane", "SANE config")
expect(command.arguments == [
    "-d", "epjitsu:libusb:000:042", "--source", "ADF Duplex",
    "--mode", "Color", "--resolution", "300", "--page-width", "215.872",
    "--page-height", "0", "--format", "tiff", "--batch=/tmp/scan-side-%03d.tiff"
], "duplex color arguments")

let detected = ScannerStatusParser.parse(
    standardOutput: "device `epjitsu:libusb:000:009' is a FUJITSU ScanSnap S300M scanner\n",
    standardError: "",
    exitCode: 0
)
expect(detected == .ready, "detected scanner is ready")

let unavailable = ScannerStatusParser.parse(
    standardOutput: "",
    standardError: "No scanners were identified",
    exitCode: 0
)
expect(unavailable == .unavailable("No scanners were identified"), "missing scanner is unavailable")

let largeOutputCommand = ProcessCommand(
    executable: "/usr/bin/python3",
    arguments: ["-c", "import sys; sys.stdout.write('x' * 1048576)"],
    timeout: 10
)
let largeOutputResult = try await ProcessRunner().run(largeOutputCommand)
expect(largeOutputResult.exitCode == 0 && largeOutputResult.standardOutput.utf8.count == 1_048_576, "process runner drains large output without deadlock")

let ignoresTerminationCommand = ProcessCommand(
    executable: "/usr/bin/python3",
    arguments: ["-c", "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(5)"],
    timeout: 0.5
)
let timeoutStarted = Date()
do {
    _ = try await ProcessRunner().run(ignoresTerminationCommand)
    expect(false, "timeout terminates a process that ignores SIGTERM")
} catch ProcessRunnerError.timedOut {
    expect(Date().timeIntervalSince(timeoutStarted) < 1.5, "timeout escalates promptly to SIGKILL")
} catch {
    expect(false, "timeout reports the expected error")
}

let cancellationTask = Task {
    try await ProcessRunner().run(ProcessCommand(
        executable: "/usr/bin/python3",
        arguments: ["-c", "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(5)"],
        timeout: 10
    ))
}
try await Task.sleep(for: .milliseconds(300))
let cancellationStarted = Date()
cancellationTask.cancel()
do {
    _ = try await cancellationTask.value
    expect(false, "cancellation terminates a process that ignores SIGTERM")
} catch ProcessRunnerError.cancelled {
    expect(Date().timeIntervalSince(cancellationStarted) < 1.5, "cancellation escalates promptly to SIGKILL")
} catch {
    expect(false, "cancellation reports the expected error")
}

let preCancelledTask = Task {
    try await ProcessRunner().run(ProcessCommand(executable: "/bin/sleep", arguments: ["5"], timeout: 10))
}
preCancelledTask.cancel()
do {
    _ = try await preCancelledTask.value
    expect(false, "a pre-cancelled process task does not launch")
} catch ProcessRunnerError.cancelled {
    expect(true, "pre-cancelled process task exits safely")
} catch {
    expect(false, "pre-cancelled process task reports cancellation")
}

let fixtureDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
var fixtureURLs: [URL] = []
for index in 1...2 {
    let image = NSImage(size: NSSize(width: 200, height: 300))
    image.lockFocus()
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: 200, height: 300).fill()
    NSColor.black.setFill()
    NSString(string: "Page \(index)").draw(at: NSPoint(x: 30, y: 150))
    image.unlockFocus()
    let url = fixtureDirectory.appendingPathComponent("page-\(index).tiff")
    try image.tiffRepresentation!.write(to: url)
    fixtureURLs.append(url)
}
let pdfURL = fixtureDirectory.appendingPathComponent("result.pdf")
try PDFAssembler().assemble(imageURLs: fixtureURLs, outputURL: pdfURL, autoRotatePortrait: false)
expect(PDFDocument(url: pdfURL)?.pageCount == 2, "PDF contains all scanned pages")
let searchablePDFURL = fixtureDirectory.appendingPathComponent("searchable.pdf")
try PDFAssembler(textRecognizer: StaticTextRecognizer()).assemble(
    imageURLs: [fixtureURLs[0]],
    outputURL: searchablePDFURL,
    autoRotatePortrait: false,
    includeOCR: true
)
let searchableString = PDFDocument(url: searchablePDFURL)?.string ?? ""
expect(searchableString.contains("Searchable page"), "OCR text is embedded and searchable")

let outputDirectory = fixtureDirectory.appendingPathComponent("outputs")
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
let outputWriter = ScanOutputWriter(pdfAssembler: PDFAssembler(textRecognizer: StaticTextRecognizer()))
let jpegResult = try outputWriter.write(
    imageURLs: fixtureURLs,
    destinationDirectory: outputDirectory,
    baseName: "JPEG Scan",
    format: .jpeg,
    autoRotatePortrait: false
)
var isDirectory: ObjCBool = false
expect(FileManager.default.fileExists(atPath: jpegResult.outputURL.path, isDirectory: &isDirectory) && isDirectory.boolValue, "JPEG output is a page folder")
let jpegPages = try FileManager.default.contentsOfDirectory(at: jpegResult.outputURL, includingPropertiesForKeys: nil)
expect(jpegPages.map(\.pathExtension).sorted() == ["jpg", "jpg"], "JPEG output contains numbered pages")
let jpegSource = CGImageSourceCreateWithURL(jpegPages[0] as CFURL, nil)
let jpegType = jpegSource.flatMap { source in CGImageSourceGetType(source).map { UTType($0 as String) } }
expect(jpegType == .jpeg, "JPEG page has JPEG encoding")

let pngResult = try outputWriter.write(
    imageURLs: fixtureURLs,
    destinationDirectory: outputDirectory,
    baseName: "PNG Scan",
    format: .png,
    autoRotatePortrait: false
)
let pngPages = try FileManager.default.contentsOfDirectory(at: pngResult.outputURL, includingPropertiesForKeys: nil)
expect(pngPages.map(\.pathExtension).sorted() == ["png", "png"], "PNG output contains numbered pages")

let tiffResult = try outputWriter.write(
    imageURLs: fixtureURLs,
    destinationDirectory: outputDirectory,
    baseName: "TIFF Scan",
    format: .tiff,
    autoRotatePortrait: false
)
let tiffSource = CGImageSourceCreateWithURL(tiffResult.outputURL as CFURL, nil)
expect(tiffSource.map(CGImageSourceGetCount) == 2, "TIFF output contains all pages")

let landscapeURL = fixtureDirectory.appendingPathComponent("landscape-300dpi.tiff")
try writeWhiteTIFF(width: 3000, height: 1500, dpi: 300, to: landscapeURL)
let rotatedResult = try outputWriter.write(
    imageURLs: [landscapeURL],
    destinationDirectory: outputDirectory,
    baseName: "Rotated PNG",
    format: .png,
    autoRotatePortrait: true
)
let rotatedPageURL = try FileManager.default.contentsOfDirectory(at: rotatedResult.outputURL, includingPropertiesForKeys: nil)[0]
let rotatedSource = CGImageSourceCreateWithURL(rotatedPageURL as CFURL, nil)!
let rotatedImage = CGImageSourceCreateImageAtIndex(rotatedSource, 0, nil)!
expect(rotatedImage.width == 1500 && rotatedImage.height == 3000, "rotation preserves native pixel dimensions")
let rotatedProperties = CGImageSourceCopyPropertiesAtIndex(rotatedSource, 0, nil) as? [CFString: Any]
expect((rotatedProperties?[kCGImagePropertyDPIWidth] as? NSNumber)?.intValue == 300, "image output preserves DPI metadata")

let letterURL = fixtureDirectory.appendingPathComponent("letter-300dpi.tiff")
try writeWhiteTIFF(width: 2550, height: 3300, dpi: 300, to: letterURL)
let letterPDF = try outputWriter.write(
    imageURLs: [letterURL],
    destinationDirectory: outputDirectory,
    baseName: "Letter PDF",
    format: .imagePDF,
    autoRotatePortrait: false
)
let letterBounds = PDFDocument(url: letterPDF.outputURL)!.page(at: 0)!.bounds(for: .mediaBox)
expect(abs(letterBounds.width - 612) < 1 && abs(letterBounds.height - 792) < 1, "PDF page dimensions derive from scan DPI")
let searchableLetterPDF = try outputWriter.write(
    imageURLs: [letterURL],
    destinationDirectory: outputDirectory,
    baseName: "Searchable Letter PDF",
    format: .searchablePDF,
    autoRotatePortrait: false
)
expect(PDFDocument(url: searchableLetterPDF.outputURL)?.string?.contains("Searchable page") == true, "searchable PDF retains OCR text")
expect(renderedDarkPixelCount(pdfURL: searchableLetterPDF.outputURL) == 0, "OCR text layer is visually invisible")

let batchDirectory = fixtureDirectory.appendingPathComponent("batch")
try FileManager.default.createDirectory(at: batchDirectory, withIntermediateDirectories: true)
try Data().write(to: batchDirectory.appendingPathComponent("scan-page-002.tiff"))
try Data().write(to: batchDirectory.appendingPathComponent("notes.txt"))
try Data().write(to: batchDirectory.appendingPathComponent("scan-page-001.tiff"))
let collected = try ScannedPageCollector.collect(in: batchDirectory)
expect(collected.map(\.lastPathComponent) == ["scan-page-001.tiff", "scan-page-002.tiff"], "scanned pages are filtered and ordered")

let recoveryOutput = fixtureDirectory.appendingPathComponent("recovery-output")
let partialService = ScannerService(
    commandBuilder: ScanCommandBuilder(executable: "/opt/homebrew/bin/scanimage"),
    runner: FixtureScannerRunner(fixtureURL: letterURL, scanExitCode: 5, corruptPage: false)
)
do {
    _ = try await partialService.scan(settings: settings, outputDirectory: recoveryOutput, outputFormat: .imagePDF)
    expect(false, "partial scan must not be reported as success")
} catch ScannerServiceError.partialScan(let count, let recoveryURL, _) {
    expect(count == 1 && FileManager.default.fileExists(atPath: recoveryURL.path), "partial scan preserves recoverable page")
} catch {
    expect(false, "partial scan reports the expected error")
}

let corruptService = ScannerService(
    commandBuilder: ScanCommandBuilder(executable: "/opt/homebrew/bin/scanimage"),
    runner: FixtureScannerRunner(fixtureURL: letterURL, scanExitCode: 0, corruptPage: true)
)
do {
    _ = try await corruptService.scan(settings: settings, outputDirectory: recoveryOutput, outputFormat: .imagePDF)
    expect(false, "output failure must not be reported as success")
} catch ScannerServiceError.outputFailed(let recoveryURL, _) {
    expect(FileManager.default.fileExists(atPath: recoveryURL.path), "output failure preserves raw scanner page")
} catch {
    expect(false, "output failure reports the expected error")
}

print("PASS: ScanSlapCoreSpec")
