import Foundation
import AppKit
import CoreText

enum TimestampDisplayStyle: String, CaseIterable, Identifiable {
    case startOnly
    case startAndEnd
    var id: String { rawValue }
}

enum TimestampSpacing: Int, CaseIterable, Identifiable {
    case automatic = 0
    case seconds15 = 15
    case seconds30 = 30
    case seconds60 = 60
    var id: Int { rawValue }
}

private func timestampedBody(_ result: WorkerResult, style: TimestampDisplayStyle, spacing: TimestampSpacing) -> String {
    let segments = result.segments.filter { meaningfulText($0.text) }
    guard !segments.isEmpty else { return "" }

    // Automatic keeps Whisper's natural segmentation. Larger intervals merge
    // consecutive segments into compact reading blocks to save space in TXT/PDF.
    if spacing == .automatic {
        return segments.map { segment in
            let label = style == .startOnly
                ? "[\(stamp(segment.start))]"
                : "[\(stamp(segment.start)) --> \(stamp(segment.end))]"
            return "\(label) \(segment.text.trimmingCharacters(in: .whitespacesAndNewlines))"
        }.joined(separator: "\n")
    }

    let interval = Double(spacing.rawValue)
    var lines: [String] = []
    var groupStart = segments[0].start
    var groupEnd = segments[0].end
    var parts: [String] = []

    func flush() {
        guard !parts.isEmpty else { return }
        let label = style == .startOnly
            ? "[\(stamp(groupStart))]"
            : "[\(stamp(groupStart)) --> \(stamp(groupEnd))]"
        lines.append("\(label) " + parts.joined(separator: " "))
        parts.removeAll(keepingCapacity: true)
    }

    for segment in segments {
        if !parts.isEmpty && segment.start - groupStart >= interval {
            flush()
            groupStart = segment.start
            groupEnd = segment.end
        }
        if parts.isEmpty {
            groupStart = segment.start
            groupEnd = segment.end
        }
        parts.append(segment.text.trimmingCharacters(in: .whitespacesAndNewlines))
        groupEnd = max(groupEnd, segment.end)
    }
    flush()
    return lines.joined(separator: "\n\n")
}

func stamp(_ seconds: Double) -> String {
    let ms = Int((seconds * 1000).rounded())
    let h = ms / 3_600_000
    let m = (ms % 3_600_000) / 60_000
    let s = (ms % 60_000) / 1000
    let milli = ms % 1000
    return h > 0 ? String(format: "%02d:%02d:%02d.%03d", h, m, s, milli) : String(format: "%02d:%02d.%03d", m, s, milli)
}


private func meaningfulText(_ text: String) -> Bool {
    let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty else { return false }
    return !cleaned.allSatisfy { ".…·-–—_ ".contains($0) }
}

func txtContent(_ result: WorkerResult, timestamps: Bool, title: String, timestampStyle: TimestampDisplayStyle = .startAndEnd, timestampSpacing: TimestampSpacing = .automatic) -> String {
    let header = title.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n"
    if !timestamps {
        return header + result.text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }
    return header + timestampedBody(result, style: timestampStyle, spacing: timestampSpacing) + "\n"
}

func formattedTranscriptBody(_ result: WorkerResult, timestamps: Bool, timestampStyle: TimestampDisplayStyle, timestampSpacing: TimestampSpacing) -> String {
    if !timestamps { return result.text.trimmingCharacters(in: .whitespacesAndNewlines) }
    return timestampedBody(result, style: timestampStyle, spacing: timestampSpacing)
}

func srtContent(_ result: WorkerResult) -> String {
    func srtStamp(_ seconds: Double) -> String {
        let ms = Int((seconds * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, (ms % 3_600_000) / 60_000, (ms % 60_000) / 1000, ms % 1000)
    }
    return result.segments.filter { meaningfulText($0.text) }.enumerated().map { i, s in
        "\(i + 1)\n\(srtStamp(s.start)) --> \(srtStamp(s.end))\n\(s.text.trimmingCharacters(in: .whitespaces))\n"
    }.joined(separator: "\n")
}

/// Creates a real multi-page A4 PDF. The source filename (without extension)
/// is used as the document heading and every page receives a page number.
func writePDF(title: String, text: String, to url: URL, polishInterface: Bool = true, bodyFontSize: CGFloat = 9) throws {
    var mediaBox = CGRect(x: 0, y: 0, width: 595.28, height: 841.89) // A4, 72 dpi
    let metadata: [CFString: Any] = [
        kCGPDFContextTitle: title,
        kCGPDFContextCreator: "LocalTranscriber"
    ]
    guard let consumer = CGDataConsumer(url: url as CFURL),
          let context = CGContext(consumer: consumer, mediaBox: &mediaBox, metadata as CFDictionary) else {
        throw NSError(domain: "LocalTranscriber.PDF", code: 1, userInfo: [NSLocalizedDescriptionKey: polishInterface ? "Nie udało się utworzyć pliku PDF." : "Could not create the PDF file."])
    }

    let document = NSMutableAttributedString(string: "")
    let titleStyle: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 17, weight: .semibold),
        .foregroundColor: NSColor.textColor
    ]
    let bodyParagraphStyle = NSMutableParagraphStyle()
    bodyParagraphStyle.alignment = .justified
    bodyParagraphStyle.lineBreakMode = .byWordWrapping

    let bodyStyle: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: bodyFontSize, weight: .regular),
        .foregroundColor: NSColor.textColor,
        .paragraphStyle: bodyParagraphStyle
    ]
    document.append(NSAttributedString(string: title.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n", attributes: titleStyle))
    document.append(NSAttributedString(string: text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n", attributes: bodyStyle))

    let framesetter = CTFramesetterCreateWithAttributedString(document as CFAttributedString)
    let margin: CGFloat = 50
    let footerHeight: CGFloat = 28
    let contentRect = CGRect(
        x: margin,
        y: margin + footerHeight,
        width: mediaBox.width - 2 * margin,
        height: mediaBox.height - 2 * margin - footerHeight
    )

    var location = 0
    var pageNumber = 1
    while location < document.length {
        context.beginPDFPage(nil)

        let path = CGMutablePath()
        path.addRect(contentRect)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: location, length: 0), path, nil)
        CTFrameDraw(frame, context)

        let visible = CTFrameGetVisibleStringRange(frame)
        guard visible.length > 0 else {
            context.endPDFPage()
            break
        }
        location += visible.length

        let footerText = NSAttributedString(
            string: (polishInterface ? "Strona " : "Page ") + "\(pageNumber)",
            attributes: [
                .font: NSFont.systemFont(ofSize: 9),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
        let footerLine = CTLineCreateWithAttributedString(footerText as CFAttributedString)
        let footerWidth = CGFloat(CTLineGetTypographicBounds(footerLine, nil, nil, nil))
        context.textPosition = CGPoint(x: (mediaBox.width - footerWidth) / 2, y: margin - 8)
        CTLineDraw(footerLine, context)

        context.endPDFPage()
        pageNumber += 1
    }

    context.closePDF()
}
