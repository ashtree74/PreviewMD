#if canImport(XCTest)
import AppKit
import Foundation
import XCTest
@testable import PreviewMD

@MainActor
final class DOCXDocumentWriterTests: XCTestCase {
    func testPackagePreservesHeadingsListsTablesLinksAndImagesSemantically() throws {
        let assetID = "asset-formula"
        let asset = PortableRichTextClipboard.fallbackAsset(
            id: assetID,
            label: "Formula",
            width: 180,
            height: 52
        )
        let html = """
        <!doctype html><html><body>
        <h1>Document title</h1><h2>Section</h2>
        <p>Text with <strong>bold</strong> and <a href="https://example.com">a link</a>.</p>
        <ul><li>Bullet one</li><li>Bullet two<ol><li>Nested number</li></ol></li></ul>
        <table><thead><tr><th>Name</th><th>Value</th></tr></thead>
        <tbody><tr><td>Alpha</td><td>42</td></tr></tbody></table>
        <p><img src="\(PortableRichTextClipboard.assetURLPrefix)\(assetID)" alt="Formula"></p>
        </body></html>
        """
        let data = try DOCXDocumentWriter.data(
            html: html,
            title: "Semantic document",
            assets: [asset]
        )
        let url = try temporaryDOCX(data)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let document = try packageEntry("word/document.xml", in: url)
        let styles = try packageEntry("word/styles.xml", in: url)
        let numbering = try packageEntry("word/numbering.xml", in: url)
        let relationships = try packageEntry("word/_rels/document.xml.rels", in: url)

        XCTAssertTrue(document.contains(#"<w:pStyle w:val="Heading1"/>"#))
        XCTAssertTrue(document.contains(#"<w:pStyle w:val="Heading2"/>"#))
        XCTAssertTrue(document.contains("<w:numPr>"))
        XCTAssertTrue(document.contains("<w:tbl>"))
        XCTAssertTrue(document.contains("<w:tblHeader/>"))
        XCTAssertTrue(document.contains("<w:drawing>"))
        XCTAssertTrue(document.contains("<w:hyperlink"))
        XCTAssertFalse(document.contains("previewmd-copy-asset:"))

        for level in 1...6 {
            XCTAssertTrue(styles.contains(#"w:styleId="Heading\#(level)""#))
            XCTAssertTrue(styles.contains(#"w:outlineLvl w:val="\#(level - 1)""#))
        }
        XCTAssertTrue(numbering.contains(#"w:numFmt w:val="bullet""#))
        XCTAssertTrue(numbering.contains(#"w:numFmt w:val="decimal""#))
        XCTAssertTrue(relationships.contains("relationships/image"))
        XCTAssertTrue(relationships.contains("relationships/hyperlink"))
        XCTAssertFalse(try packageEntryData("word/media/image1.png", in: url).isEmpty)
        for name in [
            "[Content_Types].xml",
            "_rels/.rels",
            "docProps/core.xml",
            "docProps/app.xml",
            "word/document.xml",
            "word/styles.xml",
            "word/numbering.xml",
            "word/_rels/document.xml.rels",
        ] {
            XCTAssertNoThrow(
                try XMLDocument(data: packageEntryData(name, in: url), options: [])
            )
        }
        try validateZIP(url)
    }

    func testDOCXClipboardPublishesARealFileURL() throws {
        let data = try DOCXDocumentWriter.data(
            html: "<html><body><h1>Title</h1><p>Body</p></body></html>",
            title: "Clipboard title",
            assets: []
        )
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("PreviewMDTests.\(UUID().uuidString)")
        )
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreviewMD-docx-clipboard-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let url = try DOCXDocumentWriter.copyFile(
            data: data,
            suggestedName: "Selection?.docx",
            to: pasteboard,
            temporaryRoot: temporaryRoot
        )

        XCTAssertEqual(url.pathExtension, "docx")
        XCTAssertEqual(url.lastPathComponent, "Selection-.docx")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(Array(try Data(contentsOf: url).prefix(4)), [0x50, 0x4B, 0x03, 0x04])
        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: nil
        ) as? [URL]
        XCTAssertEqual(urls?.first?.standardizedFileURL, url.standardizedFileURL)
    }

    func testOrderedListsPreserveTheirStartsAndRestartIndependently() throws {
        let package = try numberingPackage(html: """
        <ol start="4"><li>Four</li><li>Five</li></ol>
        <p>A separate list follows.</p>
        <ol><li>One</li><li>Two</li></ol>
        <ol start="9"><li>Nine</li></ol>
        <ol start="0"><li>Zero</li></ol>
        """)
        let four = try XCTUnwrap(package.paragraphs["Four"])
        let five = try XCTUnwrap(package.paragraphs["Five"])
        let one = try XCTUnwrap(package.paragraphs["One"])
        let two = try XCTUnwrap(package.paragraphs["Two"])
        let nine = try XCTUnwrap(package.paragraphs["Nine"])
        let zero = try XCTUnwrap(package.paragraphs["Zero"])

        XCTAssertEqual(four.id, five.id)
        XCTAssertEqual(one.id, two.id)
        XCTAssertEqual(Set([four.id, one.id, nine.id, zero.id]).count, 4)
        for (paragraph, start) in [(four, "4"), (one, "1"), (nine, "9"), (zero, "0")] {
            let instance = try XCTUnwrap(package.instances[paragraph.id])
            XCTAssertEqual(paragraph.level, "0")
            XCTAssertEqual(instance.abstractID, "1")
            XCTAssertEqual(instance.level, "0")
            XCTAssertEqual(instance.start, start)
        }
    }

    func testNestedListsHaveIndependentCountersAndKeepTheParentSequence() throws {
        let package = try numberingPackage(html: """
        <ol start="3">
          <li>Parent first<ol start="7"><li>Nested first</li><li>Nested second</li></ol></li>
          <li>Parent second<ol><li>Nested restart</li></ol></li>
          <li>Parent third</li>
        </ol>
        <ul><li>Bullet<ol start="0"><li>Nested zero</li></ol></li></ul>
        """)
        let parent = try XCTUnwrap(package.paragraphs["Parent first"])
        XCTAssertEqual(package.paragraphs["Parent second"]?.id, parent.id)
        XCTAssertEqual(package.paragraphs["Parent third"]?.id, parent.id)
        XCTAssertEqual(package.instances[parent.id]?.start, "3")

        let nested = try XCTUnwrap(package.paragraphs["Nested first"])
        let restart = try XCTUnwrap(package.paragraphs["Nested restart"])
        let zero = try XCTUnwrap(package.paragraphs["Nested zero"])
        XCTAssertEqual(package.paragraphs["Nested second"]?.id, nested.id)
        XCTAssertEqual(Set([parent.id, nested.id, restart.id, zero.id]).count, 4)
        for (paragraph, start) in [(nested, "7"), (restart, "1"), (zero, "0")] {
            let instance = try XCTUnwrap(package.instances[paragraph.id])
            XCTAssertEqual(paragraph.level, "1")
            XCTAssertEqual(instance.level, "1")
            XCTAssertEqual(instance.start, start)
            XCTAssertEqual(instance.abstractID, "1")
        }
        let bullet = try XCTUnwrap(package.paragraphs["Bullet"])
        XCTAssertEqual(package.instances[bullet.id]?.abstractID, "0")
        XCTAssertNil(package.instances[bullet.id]?.start)
    }

    func testInvalidListStartsFallBackToOne() throws {
        let package = try numberingPackage(html: """
        <ol start="invalid"><li>Invalid</li></ol>
        <ol start="999999999999999999999"><li>Too large</li></ol>
        """)
        for text in ["Invalid", "Too large"] {
            let paragraph = try XCTUnwrap(package.paragraphs[text])
            XCTAssertEqual(package.instances[paragraph.id]?.start, "1")
        }
    }

    private struct NumberedParagraph {
        let id: String
        let level: String
    }

    private struct NumberingInstance {
        let abstractID: String
        let level: String?
        let start: String?
    }

    private func numberingPackage(html: String) throws -> (
        paragraphs: [String: NumberedParagraph],
        instances: [String: NumberingInstance]
    ) {
        let data = try DOCXDocumentWriter.data(
            html: "<html><body>\(html)</body></html>",
            title: "Lists",
            assets: []
        )
        let url = try temporaryDOCX(data)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = try XMLDocument(data: packageEntryData("word/document.xml", in: url))
        let numbering = try XMLDocument(data: packageEntryData("word/numbering.xml", in: url))
        var paragraphs: [String: NumberedParagraph] = [:]
        for node in try document.nodes(forXPath: "//w:p[w:pPr/w:numPr]") {
            let text = try node.nodes(forXPath: ".//w:t").compactMap(\.stringValue).joined()
            paragraphs[text] = NumberedParagraph(
                id: try XCTUnwrap(node.nodes(forXPath: "./w:pPr/w:numPr/w:numId/@w:val").first?.stringValue),
                level: try XCTUnwrap(node.nodes(forXPath: "./w:pPr/w:numPr/w:ilvl/@w:val").first?.stringValue)
            )
        }
        var instances: [String: NumberingInstance] = [:]
        for node in try numbering.nodes(forXPath: "//w:num") {
            let id = try XCTUnwrap(node.nodes(forXPath: "./@w:numId").first?.stringValue)
            instances[id] = NumberingInstance(
                abstractID: try XCTUnwrap(node.nodes(forXPath: "./w:abstractNumId/@w:val").first?.stringValue),
                level: try node.nodes(forXPath: "./w:lvlOverride/@w:ilvl").first?.stringValue,
                start: try node.nodes(forXPath: "./w:lvlOverride/w:startOverride/@w:val").first?.stringValue
            )
        }
        return (paragraphs, instances)
    }

    private func temporaryDOCX(_ data: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreviewMD-docx-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Document.docx")
        try data.write(to: url)
        return url
    }

    private func packageEntry(_ name: String, in url: URL) throws -> String {
        let data = try packageEntryData(name, in: url)
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func packageEntryData(_ name: String, in url: URL) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        let archivePattern = name == "[Content_Types].xml"
            ? "[[]Content_Types].xml"
            : name
        process.arguments = ["-p", url.path, archivePattern]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "Could not read \(name)")
        return output.fileHandleForReading.readDataToEndOfFile()
    }

    private func validateZIP(_ url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-t", url.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
#endif
