import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ScanOutputFormat: String, CaseIterable, Identifiable, Sendable {
    case searchablePDF
    case imagePDF
    case jpeg
    case png
    case tiff

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .searchablePDF: "Searchable PDF"
        case .imagePDF: "Image-only PDF"
        case .jpeg: "JPEG pages"
        case .png: "PNG pages"
        case .tiff: "Multipage TIFF"
        }
    }
}

public struct ScanOutputResult: Sendable {
    public let outputURL: URL
    public let pageCount: Int
}

public enum ScanOutputWriterError: LocalizedError {
    case unreadableImage(URL)
    case cannotCreateDestination(URL)
    case cannotEncode(URL)
    case cannotTransformImage

    public var errorDescription: String? {
        switch self {
        case .unreadableImage(let url): "Could not read scanned page: \(url.lastPathComponent)"
        case .cannotCreateDestination(let url): "Could not create output at: \(url.path)"
        case .cannotEncode(let url): "Could not encode output at: \(url.path)"
        case .cannotTransformImage: "Could not rotate the scanned image without losing resolution."
        }
    }
}

public struct ScanOutputWriter: Sendable {
    private let pdfAssembler: PDFAssembler

    public init(pdfAssembler: PDFAssembler = PDFAssembler()) {
        self.pdfAssembler = pdfAssembler
    }

    public func write(
        imageURLs: [URL],
        destinationDirectory: URL,
        baseName: String,
        format: ScanOutputFormat,
        autoRotatePortrait: Bool
    ) throws -> ScanOutputResult {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let stagingRoot = destinationDirectory.appendingPathComponent(".ScanSlap-\(UUID().uuidString).partial", isDirectory: true)
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: false)
        do {
            let result: ScanOutputResult
            switch format {
            case .searchablePDF, .imagePDF:
                result = try writePDF(
                    imageURLs: imageURLs,
                    destinationDirectory: destinationDirectory,
                    stagingRoot: stagingRoot,
                    baseName: baseName,
                    searchable: format == .searchablePDF,
                    autoRotatePortrait: autoRotatePortrait
                )
            case .jpeg:
                result = try writePageFolder(
                    imageURLs: imageURLs,
                    destinationDirectory: destinationDirectory,
                    stagingRoot: stagingRoot,
                    baseName: baseName,
                    type: .jpeg,
                    pathExtension: "jpg",
                    autoRotatePortrait: autoRotatePortrait,
                    formatProperties: [kCGImageDestinationLossyCompressionQuality: 0.9]
                )
            case .png:
                result = try writePageFolder(
                    imageURLs: imageURLs,
                    destinationDirectory: destinationDirectory,
                    stagingRoot: stagingRoot,
                    baseName: baseName,
                    type: .png,
                    pathExtension: "png",
                    autoRotatePortrait: autoRotatePortrait,
                    formatProperties: [:]
                )
            case .tiff:
                result = try writeMultipageTIFF(
                    imageURLs: imageURLs,
                    destinationDirectory: destinationDirectory,
                    stagingRoot: stagingRoot,
                    baseName: baseName,
                    autoRotatePortrait: autoRotatePortrait
                )
            }
            try? fileManager.removeItem(at: stagingRoot)
            return result
        } catch {
            try? fileManager.removeItem(at: stagingRoot)
            throw error
        }
    }

    private func writePDF(
        imageURLs: [URL],
        destinationDirectory: URL,
        stagingRoot: URL,
        baseName: String,
        searchable: Bool,
        autoRotatePortrait: Bool
    ) throws -> ScanOutputResult {
        let finalURL = uniqueURL(in: destinationDirectory, baseName: baseName, pathExtension: "pdf", directory: false)
        let stagedURL = stagingRoot.appendingPathComponent(finalURL.lastPathComponent)
        try pdfAssembler.assemble(
            imageURLs: imageURLs,
            outputURL: stagedURL,
            autoRotatePortrait: autoRotatePortrait,
            includeOCR: searchable
        )
        try FileManager.default.moveItem(at: stagedURL, to: finalURL)
        return ScanOutputResult(outputURL: finalURL, pageCount: imageURLs.count)
    }

    private func writePageFolder(
        imageURLs: [URL],
        destinationDirectory: URL,
        stagingRoot: URL,
        baseName: String,
        type: UTType,
        pathExtension: String,
        autoRotatePortrait: Bool,
        formatProperties: [CFString: Any]
    ) throws -> ScanOutputResult {
        let finalFolder = uniqueURL(in: destinationDirectory, baseName: baseName, pathExtension: nil, directory: true)
        let stagedFolder = stagingRoot.appendingPathComponent(finalFolder.lastPathComponent, isDirectory: true)
        try FileManager.default.createDirectory(at: stagedFolder, withIntermediateDirectories: false)
        for (index, imageURL) in imageURLs.enumerated() {
            let pageURL = stagedFolder.appendingPathComponent(String(format: "page-%03d", index + 1)).appendingPathExtension(pathExtension)
            let prepared = try ScannedImageLoader.load(from: imageURL, autoRotatePortrait: autoRotatePortrait)
            guard let destination = CGImageDestinationCreateWithURL(pageURL as CFURL, type.identifier as CFString, 1, nil) else {
                throw ScanOutputWriterError.cannotCreateDestination(pageURL)
            }
            var properties = formatProperties
            properties[kCGImagePropertyDPIWidth] = prepared.dpiWidth
            properties[kCGImagePropertyDPIHeight] = prepared.dpiHeight
            CGImageDestinationAddImage(destination, prepared.image, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                throw ScanOutputWriterError.cannotEncode(pageURL)
            }
        }
        try FileManager.default.moveItem(at: stagedFolder, to: finalFolder)
        return ScanOutputResult(outputURL: finalFolder, pageCount: imageURLs.count)
    }

    private func writeMultipageTIFF(
        imageURLs: [URL],
        destinationDirectory: URL,
        stagingRoot: URL,
        baseName: String,
        autoRotatePortrait: Bool
    ) throws -> ScanOutputResult {
        let finalURL = uniqueURL(in: destinationDirectory, baseName: baseName, pathExtension: "tiff", directory: false)
        let stagedURL = stagingRoot.appendingPathComponent(finalURL.lastPathComponent)
        guard let destination = CGImageDestinationCreateWithURL(
            stagedURL as CFURL,
            UTType.tiff.identifier as CFString,
            imageURLs.count,
            nil
        ) else {
            throw ScanOutputWriterError.cannotCreateDestination(stagedURL)
        }
        for imageURL in imageURLs {
            let prepared = try ScannedImageLoader.load(from: imageURL, autoRotatePortrait: autoRotatePortrait)
            let properties: [CFString: Any] = [
                kCGImagePropertyDPIWidth: prepared.dpiWidth,
                kCGImagePropertyDPIHeight: prepared.dpiHeight,
                kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 5]
            ]
            CGImageDestinationAddImage(destination, prepared.image, properties as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else {
            throw ScanOutputWriterError.cannotEncode(stagedURL)
        }
        try FileManager.default.moveItem(at: stagedURL, to: finalURL)
        return ScanOutputResult(outputURL: finalURL, pageCount: imageURLs.count)
    }

    private func uniqueURL(
        in directory: URL,
        baseName: String,
        pathExtension: String?,
        directory isDirectory: Bool
    ) -> URL {
        let safeBase = baseName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
        var suffix = 1
        while true {
            let name = suffix == 1 ? safeBase : "\(safeBase) \(suffix)"
            var candidate = directory.appendingPathComponent(name, isDirectory: isDirectory)
            if let pathExtension { candidate.appendPathExtension(pathExtension) }
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            suffix += 1
        }
    }
}
