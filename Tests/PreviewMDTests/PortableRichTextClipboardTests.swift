#if canImport(XCTest)
import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import PreviewMD

@MainActor
final class PortableRichTextClipboardTests: XCTestCase {
    func testAssetEmbeddingMatchesWholeIDsAndReplacesUnresolvedPlaceholders() {
        let short = PortableRichTextClipboard.EmbeddedAsset(
            id: "asset-1",
            mimeType: "image/png",
            data: Data([0x01]),
            width: 1,
            height: 1
        )
        let long = PortableRichTextClipboard.EmbeddedAsset(
            id: "asset-10",
            mimeType: "image/png",
            data: Data([0x02]),
            width: 1,
            height: 1
        )
        let html = """
        <img src="previewmd-copy-asset:asset-1">
        <img src="previewmd-copy-asset:asset-10">
        <img src="previewmd-copy-asset:asset-unresolved">
        """

        let result = PortableRichTextClipboard.htmlEmbeddingAssets(
            html,
            assets: [short, long]
        )

        XCTAssertTrue(result.contains("data:image/png;base64,AQ=="))
        XCTAssertTrue(result.contains("data:image/png;base64,Ag=="))
        XCTAssertTrue(result.contains("data:image/png;base64,"))
        XCTAssertFalse(result.contains(PortableRichTextClipboard.assetURLPrefix))
    }

    func testWritesHTMLRTFRTFDAndPlainTextWithEmbeddedRasterAsset() throws {
        let assetID = "asset-diagram"
        let png = PortableRichTextClipboard.fallbackAsset(
            id: assetID,
            label: "Diagram",
            width: 120,
            height: 40
        ).data
        let html = """
        <!doctype html><html><body>
        <p>Before <strong>diagram</strong></p>
        <table><tr><th>A</th><th>B</th></tr><tr><td>1</td><td>2</td></tr></table>
        <img src="\(PortableRichTextClipboard.assetURLPrefix)\(assetID)" \
        alt="Diagram" width="120" height="40">
        </body></html>
        """
        let asset = PortableRichTextClipboard.EmbeddedAsset(
            id: assetID,
            mimeType: "image/png",
            data: png,
            width: 120,
            height: 40
        )
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("PreviewMDTests.\(UUID().uuidString)")
        )

        XCTAssertTrue(
            PortableRichTextClipboard.write(
                html: html,
                plainText: "Before diagram\nA\tB\n1\t2\nDiagram",
                assets: [asset],
                standaloneAssetID: nil,
                to: pasteboard
            )
        )
        XCTAssertEqual(
            pasteboard.string(forType: .string),
            "Before diagram\nA\tB\n1\t2\nDiagram"
        )

        let embeddedHTML = try XCTUnwrap(pasteboard.string(forType: .html))
        XCTAssertTrue(embeddedHTML.contains("data:image/png;base64,"))
        XCTAssertFalse(embeddedHTML.contains(PortableRichTextClipboard.assetURLPrefix))
        XCTAssertNil(pasteboard.data(forType: .rtf))

        let rtfd = try XCTUnwrap(pasteboard.data(forType: .rtfd))
        let attributed = try NSAttributedString(
            data: rtfd,
            options: [.documentType: NSAttributedString.DocumentType.rtfd],
            documentAttributes: nil
        )
        var attachmentCount = 0
        attributed.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: attributed.length)
        ) { value, _, _ in
            if value is NSTextAttachment {
                attachmentCount += 1
            }
        }
        XCTAssertEqual(attachmentCount, 1)
        XCTAssertTrue(attributed.string.contains("Before diagram"))
        XCTAssertTrue(attributed.string.contains("A"))
        XCTAssertTrue(attributed.string.contains("2"))
    }

    func testTextOnlySelectionStillOffersClassicRTF() {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("PreviewMDTests.\(UUID().uuidString)")
        )

        XCTAssertTrue(
            PortableRichTextClipboard.write(
                html: "<html><body><p>Hello <strong>world</strong></p></body></html>",
                plainText: "Hello world",
                assets: [],
                standaloneAssetID: nil,
                to: pasteboard
            )
        )

        XCTAssertNotNil(pasteboard.data(forType: .rtf))
        XCTAssertNotNil(pasteboard.data(forType: .rtfd))
        XCTAssertNotNil(pasteboard.string(forType: .html))
    }

    func testStandaloneDiagramAddsDirectSVGRepresentation() {
        let id = "asset-only"
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"10\"/>"
        let asset = PortableRichTextClipboard.EmbeddedAsset(
            id: id,
            mimeType: "image/png",
            data: PortableRichTextClipboard.fallbackAsset(
                id: id,
                label: "Diagram",
                width: 10,
                height: 10
            ).data,
            width: 10,
            height: 10,
            standaloneSVG: Data(svg.utf8)
        )
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("PreviewMDTests.\(UUID().uuidString)")
        )

        XCTAssertTrue(
            PortableRichTextClipboard.write(
                html: "<html><body><img src=\"\(PortableRichTextClipboard.assetURLPrefix)\(id)\"></body></html>",
                plainText: "Diagram",
                assets: [asset],
                standaloneAssetID: id,
                to: pasteboard
            )
        )

        let svgType = NSPasteboard.PasteboardType(UTType.svg.identifier)
        XCTAssertEqual(pasteboard.data(forType: svgType), Data(svg.utf8))
        XCTAssertNotNil(pasteboard.data(forType: .tiff))
        XCTAssertNotNil(pasteboard.data(forType: .png))
    }

    func testFallbackAssetIsAPortablePNG() {
        let asset = PortableRichTextClipboard.fallbackAsset(
            id: "asset-fallback",
            label: "<Formula & \"source\">",
            width: 10,
            height: 10
        )
        XCTAssertEqual(asset.mimeType, "image/png")
        XCTAssertEqual(Array(asset.data.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
    }

    func testAdvancedCopyModesPublishOnlyTheRepresentationsTheyPromise() {
        let wordPasteboard = NSPasteboard(
            name: NSPasteboard.Name("PreviewMDTests.Word.\(UUID().uuidString)")
        )
        XCTAssertTrue(
            PortableRichTextClipboard.write(
                html: "<html><body><h1>Heading</h1></body></html>",
                plainText: "Heading",
                markdown: "# Heading",
                assets: [],
                standaloneAssetID: nil,
                format: .word,
                to: wordPasteboard
            )
        )
        XCTAssertNotNil(wordPasteboard.string(forType: .html))
        XCTAssertNotNil(wordPasteboard.string(forType: .string))
        XCTAssertNil(wordPasteboard.data(forType: .rtf))
        XCTAssertNil(wordPasteboard.data(forType: .rtfd))

        let markdownPasteboard = NSPasteboard(
            name: NSPasteboard.Name("PreviewMDTests.Markdown.\(UUID().uuidString)")
        )
        XCTAssertTrue(
            PortableRichTextClipboard.write(
                html: "<html><body><h1>Heading</h1></body></html>",
                plainText: "Heading",
                markdown: "# Heading",
                assets: [],
                standaloneAssetID: nil,
                format: .markdown,
                to: markdownPasteboard
            )
        )
        let markdownType = NSPasteboard.PasteboardType("net.daringfireball.markdown")
        XCTAssertEqual(markdownPasteboard.string(forType: markdownType), "# Heading")
        XCTAssertEqual(markdownPasteboard.string(forType: .string), "# Heading")
        XCTAssertNil(markdownPasteboard.string(forType: .html))
    }
}
#endif
