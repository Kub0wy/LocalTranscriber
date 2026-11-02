import AppKit
import PDFKit
import XCTest
@testable import LocalTranscriber

final class PDFExportTests: XCTestCase {
    @MainActor
    func testPDFTextRendersDarkUnderDarkAppearance() throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalTranscriber-PDF-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let previousAppearance = NSAppearance.current
        NSAppearance.current = try XCTUnwrap(NSAppearance(named: .darkAqua))
        defer { NSAppearance.current = previousAppearance }

        try writePDF(
            title: "LocalTranscriber PDF Test",
            text: "This text must be visible.",
            to: outputURL,
            polishInterface: false,
            bodyFontSize: 14
        )

        let document = try XCTUnwrap(PDFDocument(url: outputURL))
        let page = try XCTUnwrap(document.page(at: 0))
        let pageRef = try XCTUnwrap(page.pageRef)
        let bounds = page.bounds(for: .mediaBox)
        let width = Int(bounds.width.rounded(.up))
        let height = Int(bounds.height.rounded(.up))
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 255, count: height * bytesPerRow)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        let context = try XCTUnwrap(
            CGContext(
                data: &pixels,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo.rawValue
            )
        )
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.drawPDFPage(pageRef)

        // Inspect only the document content area, excluding the page-number footer.
        // Dark text has RGB luminance well below the white page background.
        var darkPixelCount = 0
        for y in 70..<(height - 40) {
            for x in 40..<(width - 40) {
                let offset = y * bytesPerRow + x * 4
                let red = Double(pixels[offset])
                let green = Double(pixels[offset + 1])
                let blue = Double(pixels[offset + 2])
                let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
                if luminance < 180 {
                    darkPixelCount += 1
                }
            }
        }

        XCTAssertGreaterThan(
            darkPixelCount,
            100,
            "Expected visible dark title/body pixels on the white PDF page"
        )
    }
}
