import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Vision

public struct RecognizedText: Sendable {
    public let text: String
    public let normalizedBounds: CGRect

    public init(text: String, normalizedBounds: CGRect) {
        self.text = text
        self.normalizedBounds = normalizedBounds
    }
}

public protocol TextRecognizing: Sendable {
    func recognize(in image: CGImage) throws -> [RecognizedText]
}

public struct VisionTextRecognizer: TextRecognizing {
    public init() {}

    public func recognize(in image: CGImage) throws -> [RecognizedText] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return RecognizedText(text: candidate.string, normalizedBounds: observation.boundingBox)
        }
    }
}

public enum PDFAssemblerError: LocalizedError {
    case unreadableImage(URL)
    case cannotCreatePage(URL)
    case cannotWrite(URL)

    public var errorDescription: String? {
        switch self {
        case .unreadableImage(let url): "Could not read scanned page: \(url.lastPathComponent)"
        case .cannotCreatePage(let url): "Could not create a PDF page from: \(url.lastPathComponent)"
        case .cannotWrite(let url): "Could not save PDF to: \(url.path)"
        }
    }
}

public struct PDFAssembler: Sendable {
    private let textRecognizer: any TextRecognizing

    public init(textRecognizer: any TextRecognizing = VisionTextRecognizer()) {
        self.textRecognizer = textRecognizer
    }

    public func assemble(
        imageURLs: [URL],
        outputURL: URL,
        autoRotatePortrait: Bool,
        includeOCR: Bool = false
    ) throws {
        let document = PDFDocument()
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("ScanSlap-PDF-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        for (index, imageURL) in imageURLs.enumerated() {
            let prepared: PreparedScanImage
            do {
                prepared = try ScannedImageLoader.load(from: imageURL, autoRotatePortrait: autoRotatePortrait)
            } catch {
                throw PDFAssemblerError.unreadableImage(imageURL)
            }
            let text = includeOCR ? try textRecognizer.recognize(in: prepared.image) : []
            let pageURL = scratch.appendingPathComponent("page-\(index).pdf")
            try writePage(prepared: prepared, recognizedText: text, to: pageURL)
            guard let page = PDFDocument(url: pageURL)?.page(at: 0) else {
                throw PDFAssemblerError.cannotCreatePage(imageURL)
            }
            document.insert(page, at: index)
        }

        // PDFKit serialization; this is unrelated to browser DOM document.write().
        guard document.write(to: outputURL) else {
            throw PDFAssemblerError.cannotWrite(outputURL)
        }
    }

    private func writePage(prepared: PreparedScanImage, recognizedText: [RecognizedText], to url: URL) throws {
        let image = prepared.image
        var mediaBox = CGRect(
            x: 0,
            y: 0,
            width: CGFloat(image.width) / prepared.dpiWidth * 72,
            height: CGFloat(image.height) / prepared.dpiHeight * 72
        )
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw PDFAssemblerError.cannotWrite(url)
        }
        context.beginPDFPage(nil)
        context.interpolationQuality = .high
        context.draw(image, in: mediaBox)
        context.setTextDrawingMode(.invisible)
        for item in recognizedText where !item.text.isEmpty {
            let bounds = CGRect(
                x: item.normalizedBounds.minX * mediaBox.width,
                y: item.normalizedBounds.minY * mediaBox.height,
                width: item.normalizedBounds.width * mediaBox.width,
                height: item.normalizedBounds.height * mediaBox.height
            )
            let estimatedWidthFactor = max(CGFloat(item.text.count) * 0.58, 1)
            let fontSize = max(3, min(bounds.height * 0.72, bounds.width / estimatedWidthFactor))
            let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
            let attributes: [NSAttributedString.Key: Any] = [
                kCTFontAttributeName as NSAttributedString.Key: font,
                kCTForegroundColorFromContextAttributeName as NSAttributedString.Key: true
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: item.text, attributes: attributes))
            context.textPosition = CGPoint(x: bounds.minX, y: bounds.minY)
            CTLineDraw(line, context)
        }
        context.endPDFPage()
        context.closePDF()
    }
}
