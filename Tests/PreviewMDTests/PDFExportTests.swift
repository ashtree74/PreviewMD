#if canImport(XCTest)
import AppKit
import CoreGraphics
import Foundation
import PDFKit
import XCTest
@testable import PreviewMD

@MainActor
final class PDFExportTests: XCTestCase {
    func testPaginatorPreservesContentAcrossPhysicalPages() throws {
        let source = try makeSourcePDF()
        let layout = PDFCaptureLayout(
            width: 100,
            height: 200,
            pageBreaks: [0, 80, 180, 200]
        )

        let output = try PDFPaginator.paginate(
            sourceData: source,
            layout: layout,
            paperSize: NSSize(width: 120, height: 120),
            margins: 10
        )

        let document = try XCTUnwrap(PDFDocument(data: output))
        XCTAssertEqual(document.pageCount, 3)
        XCTAssertEqual(document.page(at: 0)?.bounds(for: .mediaBox).size, NSSize(width: 120, height: 120))
        XCTAssertTrue(document.page(at: 0)?.string?.contains("Top page") == true)
        XCTAssertTrue(document.page(at: 1)?.string?.contains("Second page") == true)
        XCTAssertTrue(document.page(at: 1)?.string?.contains("Bottom page") == true)
        let firstPage = try XCTUnwrap(document.page(at: 0))
        XCTAssertEqual(darkPixelCount(in: firstPage, yRange: 92 ..< 120), 0)
    }

    func testCaptureLayoutRejectsNonIncreasingPageBreaks() {
        XCTAssertFalse(
            PDFCaptureLayout(
                width: 100,
                height: 200,
                pageBreaks: [0, 100, 100, 200]
            ).isValid
        )
    }

    private func makeSourcePDF() throws -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
            throw TestPDFError.couldNotCreateContext
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 100, height: 200)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw TestPDFError.couldNotCreateContext
        }

        context.beginPDFPage(nil)
        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.black,
        ]
        ("Top page" as NSString).draw(at: NSPoint(x: 8, y: 175), withAttributes: attributes)
        ("Second page" as NSString).draw(at: NSPoint(x: 8, y: 105), withAttributes: attributes)
        ("Bottom page" as NSString).draw(at: NSPoint(x: 8, y: 25), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(x: 45, y: 105, width: 40, height: 10))
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    private func darkPixelCount(in page: PDFPage, yRange: Range<Int>) -> Int {
        let size = NSSize(width: 240, height: 240)
        let image = page.thumbnail(of: size, for: .mediaBox)
        guard let data = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data)
        else { return .max }

        let scale = bitmap.pixelsHigh / 120
        var count = 0
        for y in (yRange.lowerBound * scale) ..< (yRange.upperBound * scale) {
            for x in 0 ..< bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                if color.alphaComponent > 0.5
                    && color.redComponent + color.greenComponent + color.blueComponent < 1.5 {
                    count += 1
                }
            }
        }
        return count
    }

    private enum TestPDFError: Error {
        case couldNotCreateContext
    }
}
#endif
