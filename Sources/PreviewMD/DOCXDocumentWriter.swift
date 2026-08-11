import AppKit
import Foundation

/// Builds a small, standards-based WordprocessingML package without relying on
/// AppKit's Office Open XML exporter. AppKit preserves visual text attributes,
/// but flattens headings, lists, and tables; this writer keeps those structures
/// semantic so Pages and Word can map them to their native document models.
enum DOCXDocumentWriter {
    enum WriterError: LocalizedError {
        case invalidHTML
        case packageTooLarge
        case clipboardFileCreationFailed

        var errorDescription: String? {
            switch self {
            case .invalidHTML:
                "The rendered document could not be converted to DOCX."
            case .packageTooLarge:
                "The DOCX package is too large to create."
            case .clipboardFileCreationFailed:
                "The temporary DOCX file could not be placed on the clipboard."
            }
        }
    }

    static func data(
        html: String,
        title: String,
        assets: [PortableRichTextClipboard.EmbeddedAsset]
    ) throws -> Data {
        guard html.utf8.count <= 32 * 1_024 * 1_024,
              let document = try? XMLDocument(
                  data: Data(html.utf8),
                  options: [.documentTidyHTML, .nodePreserveWhitespace]
              ),
              let root = document.rootElement()
        else { throw WriterError.invalidHTML }

        let body = firstElement(named: "body", below: root) ?? root
        var builder = WordprocessingMLBuilder(
            title: title,
            assets: Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        )
        return try builder.package(body: body)
    }

    static func copyFile(
        data: Data,
        suggestedName: String,
        to pasteboard: NSPasteboard = .general,
        temporaryRoot: URL? = nil
    ) throws -> URL {
        let root = temporaryRoot ?? FileManager.default.temporaryDirectory
        let directory = root
            .appendingPathComponent("PreviewMD Clipboard", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let fileName = sanitizedFileName(suggestedName, fallback: "PreviewMD Selection")
        let url = directory.appendingPathComponent(fileName).appendingPathExtension("docx")
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw WriterError.clipboardFileCreationFailed
        }

        pasteboard.clearContents()
        guard pasteboard.writeObjects([url as NSURL]) else {
            throw WriterError.clipboardFileCreationFailed
        }
        return url
    }

    private static func sanitizedFileName(_ value: String, fallback: String) -> String {
        let withoutExtension = (value as NSString).deletingPathExtension
        let scalars = withoutExtension.unicodeScalars.map { scalar -> Character in
            Character("/:\\?%*|\"<>".unicodeScalars.contains(scalar) ? "-" : String(scalar))
        }
        let result = String(scalars)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(120)
        return result.isEmpty ? fallback : String(result)
    }

    private static func firstElement(named name: String, below node: XMLNode) -> XMLElement? {
        if let element = node as? XMLElement,
           element.name?.lowercased() == name {
            return element
        }
        for child in node.children ?? [] {
            if let match = firstElement(named: name, below: child) { return match }
        }
        return nil
    }
}

private struct WordprocessingMLBuilder {
    private struct Relationship {
        let id: String
        let type: String
        let target: String
        let targetMode: String?
    }

    private struct MediaFile {
        let path: String
        let data: Data
    }

    private let title: String
    private let assets: [String: PortableRichTextClipboard.EmbeddedAsset]
    private var relationships: [Relationship] = [
        Relationship(
            id: "rId1",
            type: "http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles",
            target: "styles.xml",
            targetMode: nil
        ),
        Relationship(
            id: "rId2",
            type: "http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering",
            target: "numbering.xml",
            targetMode: nil
        ),
    ]
    private var mediaFiles: [MediaFile] = []
    private var relationshipCounter = 3
    private var drawingCounter = 1

    init(
        title: String,
        assets: [String: PortableRichTextClipboard.EmbeddedAsset]
    ) {
        self.title = title
        self.assets = assets
    }

    mutating func package(body: XMLElement) throws -> Data {
        var bodyXML = blockChildren(of: body).joined()
        if bodyXML.isEmpty {
            bodyXML = paragraphXML(inline: "", style: "Normal")
        }
        let documentXML = documentXML(body: bodyXML)
        let relationshipXML = documentRelationshipsXML()

        var entries: [(String, Data)] = [
            ("[Content_Types].xml", Data(contentTypesXML.utf8)),
            ("_rels/.rels", Data(packageRelationshipsXML.utf8)),
            ("docProps/app.xml", Data(appPropertiesXML.utf8)),
            ("docProps/core.xml", Data(corePropertiesXML.utf8)),
            ("word/document.xml", Data(documentXML.utf8)),
            ("word/styles.xml", Data(stylesXML.utf8)),
            ("word/numbering.xml", Data(numberingXML.utf8)),
            ("word/_rels/document.xml.rels", Data(relationshipXML.utf8)),
        ]
        entries.append(contentsOf: mediaFiles.map { ($0.path, $0.data) })
        return try StoredZIPArchive.make(entries: entries)
    }

    private mutating func blockChildren(of parent: XMLNode) -> [String] {
        (parent.children ?? []).flatMap { blockXML(for: $0) }
    }

    private mutating func blockXML(for node: XMLNode, listLevel: Int = 0) -> [String] {
        if node.kind == .text {
            let text = node.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.isEmpty ? [] : [paragraphXML(inline: runXML(text), style: "Normal")]
        }
        guard let element = node as? XMLElement else { return [] }
        let tag = element.name?.lowercased() ?? ""
        switch tag {
        case "h1", "h2", "h3", "h4", "h5", "h6":
            return [paragraphXML(
                inline: inlineChildren(of: element),
                style: "Heading\(tag.dropFirst())",
                keepNext: true
            )]
        case "p":
            return [paragraphXML(inline: inlineChildren(of: element), style: "Normal")]
        case "ul":
            return listXML(element, ordered: false, level: listLevel)
        case "ol":
            return listXML(element, ordered: true, level: listLevel)
        case "table":
            return [tableXML(element)]
        case "blockquote":
            var quoted: [String] = []
            for child in element.children ?? [] {
                if let paragraph = child as? XMLElement,
                   paragraph.name?.lowercased() == "p" {
                    quoted.append(
                        paragraphXML(inline: inlineChildren(of: paragraph), style: "Quote")
                    )
                } else if child.kind == .text {
                    let text = child.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !text.isEmpty {
                        quoted.append(paragraphXML(inline: runXML(text), style: "Quote"))
                    }
                } else {
                    quoted.append(contentsOf: blockXML(for: child))
                }
            }
            return quoted.isEmpty
                ? [paragraphXML(inline: inlineChildren(of: element), style: "Quote")]
                : quoted
        case "pre":
            return [paragraphXML(
                inline: runXML(element.stringValue ?? "", properties: "<w:rStyle w:val=\"CodeChar\"/>") ,
                style: "Code"
            )]
        case "hr":
            return [#"<w:p><w:pPr><w:pBdr><w:bottom w:val="single" w:sz="6" w:space="8" w:color="C7C7CC"/></w:pBdr><w:spacing w:before="120" w:after="120"/></w:pPr></w:p>"#]
        case "img":
            let content = inlineXML(for: element, properties: InlineProperties())
            return [paragraphXML(inline: content, style: "Normal", alignment: "center")]
        case "br":
            return [paragraphXML(inline: "", style: "Normal")]
        case "head", "script", "style", "template":
            return []
        case "body", "article", "section", "main", "figure", "div", "header", "footer":
            let blocks = blockChildren(of: element)
            if !blocks.isEmpty { return blocks }
            let inline = inlineChildren(of: element)
            return inline.isEmpty ? [] : [paragraphXML(inline: inline, style: "Normal")]
        default:
            if hasBlockChild(element) { return blockChildren(of: element) }
            let inline = inlineChildren(of: element)
            return inline.isEmpty ? [] : [paragraphXML(inline: inline, style: "Normal")]
        }
    }

    private mutating func listXML(
        _ list: XMLElement,
        ordered: Bool,
        level: Int
    ) -> [String] {
        var result: [String] = []
        for child in list.children ?? [] {
            guard let item = child as? XMLElement,
                  item.name?.lowercased() == "li"
            else { continue }
            let inlineNodes = (item.children ?? []).filter { node in
                guard let element = node as? XMLElement else { return true }
                let name = element.name?.lowercased()
                return name != "ul" && name != "ol"
            }
            let inline = inlineNodes.map {
                inlineXML(for: $0, properties: InlineProperties())
            }.joined()
            result.append(numberedParagraphXML(
                inline: inline,
                numberID: ordered ? 2 : 1,
                level: min(8, level)
            ))
            for nested in item.children ?? [] {
                guard let nestedList = nested as? XMLElement else { continue }
                switch nestedList.name?.lowercased() {
                case "ul":
                    result.append(contentsOf: listXML(nestedList, ordered: false, level: level + 1))
                case "ol":
                    result.append(contentsOf: listXML(nestedList, ordered: true, level: level + 1))
                default:
                    break
                }
            }
        }
        return result
    }

    private mutating func tableXML(_ table: XMLElement) -> String {
        let rows = descendants(named: "tr", of: table)
        let columnCount = max(1, rows.map { directCells(of: $0).reduce(0) { partial, cell in
            partial + max(1, Int(cell.attribute(forName: "colspan")?.stringValue ?? "1") ?? 1)
        } }.max() ?? 1)
        let widths = tableColumnWidths(rows: rows, columnCount: columnCount)
        let grid = widths.map { "<w:gridCol w:w=\"\($0)\"/>" }.joined()
        let tableProperties = #"<w:tblPr><w:tblW w:w="9360" w:type="dxa"/><w:tblInd w:w="120" w:type="dxa"/><w:tblLayout w:type="fixed"/><w:tblBorders><w:top w:val="single" w:sz="6" w:color="C7CBD1"/><w:left w:val="single" w:sz="6" w:color="C7CBD1"/><w:bottom w:val="single" w:sz="6" w:color="C7CBD1"/><w:right w:val="single" w:sz="6" w:color="C7CBD1"/><w:insideH w:val="single" w:sz="6" w:color="D8DCE2"/><w:insideV w:val="single" w:sz="6" w:color="D8DCE2"/></w:tblBorders><w:tblCellMar><w:top w:w="80" w:type="dxa"/><w:start w:w="120" w:type="dxa"/><w:bottom w:w="80" w:type="dxa"/><w:end w:w="120" w:type="dxa"/></w:tblCellMar></w:tblPr>"#
        var rowXML = ""
        for (rowIndex, row) in rows.enumerated() {
            let cells = directCells(of: row)
            var columnIndex = 0
            var cellsXML = ""
            for cell in cells {
                let span = min(
                    columnCount - columnIndex,
                    max(1, Int(cell.attribute(forName: "colspan")?.stringValue ?? "1") ?? 1)
                )
                let width = widths[columnIndex..<min(columnCount, columnIndex + span)].reduce(0, +)
                let isHeader = rowIndex == 0 || cell.name?.lowercased() == "th"
                let spanXML = span > 1 ? "<w:gridSpan w:val=\"\(span)\"/>" : ""
                let shading = isHeader ? "<w:shd w:val=\"clear\" w:fill=\"F2F4F7\"/>" : ""
                let content = tableCellContent(cell, isHeader: isHeader)
                cellsXML += "<w:tc><w:tcPr><w:tcW w:w=\"\(width)\" w:type=\"dxa\"/>\(spanXML)\(shading)<w:vAlign w:val=\"top\"/></w:tcPr>\(content)</w:tc>"
                columnIndex += span
            }
            let headerProperties = rowIndex == 0
                ? "<w:trPr><w:tblHeader/></w:trPr>"
                : ""
            rowXML += "<w:tr>\(headerProperties)\(cellsXML)</w:tr>"
        }
        return "<w:tbl>\(tableProperties)<w:tblGrid>\(grid)</w:tblGrid>\(rowXML)</w:tbl>"
    }

    private mutating func tableCellContent(_ cell: XMLElement, isHeader: Bool) -> String {
        let childBlocks = (cell.children ?? []).filter { node in
            guard let element = node as? XMLElement else { return false }
            return Self.blockTags.contains(element.name?.lowercased() ?? "")
        }
        if !childBlocks.isEmpty {
            let blocks = childBlocks.flatMap { blockXML(for: $0) }
            return blocks.isEmpty ? paragraphXML(inline: "", style: "Normal") : blocks.joined()
        }
        let properties = InlineProperties(bold: isHeader)
        let inline = (cell.children ?? []).map { inlineXML(for: $0, properties: properties) }.joined()
        return paragraphXML(inline: inline, style: "TableText")
    }

    private func tableColumnWidths(rows: [XMLElement], columnCount: Int) -> [Int] {
        guard columnCount > 1 else { return [9360] }
        var weights = Array(repeating: 6.0, count: columnCount)
        for row in rows {
            var index = 0
            for cell in directCells(of: row) where index < columnCount {
                let span = max(1, Int(cell.attribute(forName: "colspan")?.stringValue ?? "1") ?? 1)
                if span == 1 {
                    let count = Double((cell.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).count)
                    weights[index] = max(weights[index], min(40, sqrt(max(1, count)) * 3.2))
                }
                index += span
            }
        }
        let minimum = min(1_080, 9360 / columnCount)
        let available = max(0, 9360 - minimum * columnCount)
        let total = weights.reduce(0, +)
        var widths = weights.map { minimum + Int((Double(available) * $0 / total).rounded()) }
        widths[widths.count - 1] += 9360 - widths.reduce(0, +)
        return widths
    }

    private struct InlineProperties {
        var bold = false
        var italic = false
        var underline = false
        var strike = false
        var superscript = false
        var isSubscript = false
        var code = false
        var hyperlink = false
    }

    private mutating func inlineChildren(
        of node: XMLNode,
        properties: InlineProperties = InlineProperties()
    ) -> String {
        (node.children ?? []).map { inlineXML(for: $0, properties: properties) }.joined()
    }

    private mutating func inlineXML(
        for node: XMLNode,
        properties: InlineProperties
    ) -> String {
        if node.kind == .text { return runXML(node.stringValue ?? "", properties: runProperties(properties)) }
        guard let element = node as? XMLElement else { return "" }
        let tag = element.name?.lowercased() ?? ""
        var next = properties
        switch tag {
        case "strong", "b": next.bold = true
        case "em", "i": next.italic = true
        case "u": next.underline = true
        case "s", "strike", "del": next.strike = true
        case "sup": next.superscript = true
        case "sub": next.isSubscript = true
        case "code": next.code = true
        case "br": return "<w:r><w:br/></w:r>"
        case "img": return imageRunXML(element)
        case "a":
            guard let href = element.attribute(forName: "href")?.stringValue,
                  let url = URL(string: href),
                  let scheme = url.scheme?.lowercased(),
                  ["http", "https", "mailto"].contains(scheme)
            else { return inlineChildren(of: element, properties: next) }
            next.hyperlink = true
            let content = inlineChildren(of: element, properties: next)
            let id = addRelationship(
                type: "http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink",
                target: href,
                targetMode: "External"
            )
            return "<w:hyperlink r:id=\"\(id)\">\(content)</w:hyperlink>"
        case "ul", "ol", "table", "p", "div", "section":
            return runXML(element.stringValue ?? "", properties: runProperties(next))
        default:
            break
        }
        return inlineChildren(of: element, properties: next)
    }

    private func runProperties(_ properties: InlineProperties) -> String {
        var result = ""
        if properties.code {
            result += "<w:rStyle w:val=\"CodeChar\"/>"
        } else if properties.hyperlink {
            result += "<w:rStyle w:val=\"Hyperlink\"/>"
        }
        if properties.bold { result += "<w:b/>" }
        if properties.italic { result += "<w:i/>" }
        if properties.underline { result += "<w:u w:val=\"single\"/>" }
        if properties.strike { result += "<w:strike/>" }
        if properties.superscript { result += "<w:vertAlign w:val=\"superscript\"/>" }
        if properties.isSubscript { result += "<w:vertAlign w:val=\"subscript\"/>" }
        return result
    }

    private func runXML(_ text: String, properties: String = "") -> String {
        guard !text.isEmpty else { return "" }
        let valid = text.unicodeScalars.filter { scalar in
            scalar.value == 0x9 || scalar.value == 0xA || scalar.value == 0xD ||
                scalar.value >= 0x20
        }
        let escaped = xmlEscape(String(String.UnicodeScalarView(valid)))
        let propertyXML = properties.isEmpty ? "" : "<w:rPr>\(properties)</w:rPr>"
        return "<w:r>\(propertyXML)<w:t xml:space=\"preserve\">\(escaped)</w:t></w:r>"
    }

    private mutating func imageRunXML(_ image: XMLElement) -> String {
        guard let source = image.attribute(forName: "src")?.stringValue,
              source.hasPrefix(PortableRichTextClipboard.assetURLPrefix),
              let asset = assets[String(source.dropFirst(PortableRichTextClipboard.assetURLPrefix.count))]
        else {
            let alt = image.attribute(forName: "alt")?.stringValue ?? "Image"
            return runXML("[\(alt)]")
        }
        let mediaIndex = mediaFiles.count + 1
        let path = "word/media/image\(mediaIndex).png"
        mediaFiles.append(MediaFile(path: path, data: asset.data))
        let relationshipID = addRelationship(
            type: "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image",
            target: "media/image\(mediaIndex).png",
            targetMode: nil
        )
        let drawingID = drawingCounter
        drawingCounter += 1
        let width = min(400, max(12, asset.width))
        let heightScale = width / max(1, asset.width)
        let height = min(8.5 * 72, max(12, asset.height * heightScale))
        let cx = Int((width * 12_700).rounded())
        let cy = Int((height * 12_700).rounded())
        let alt = xmlEscape(image.attribute(forName: "alt")?.stringValue ?? "Image")
        return """
        <w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0">
        <wp:extent cx="\(cx)" cy="\(cy)"/><wp:effectExtent l="0" t="0" r="0" b="0"/>
        <wp:docPr id="\(drawingID)" name="Image \(drawingID)" descr="\(alt)"/>
        <wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect="1"/></wp:cNvGraphicFramePr>
        <a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">
        <pic:pic><pic:nvPicPr><pic:cNvPr id="\(drawingID)" name="Image \(drawingID)" descr="\(alt)"/><pic:cNvPicPr/></pic:nvPicPr>
        <pic:blipFill><a:blip r:embed="\(relationshipID)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>
        <pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>
        </pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r>
        """
    }

    private func paragraphXML(
        inline: String,
        style: String,
        keepNext: Bool = false,
        alignment: String? = nil
    ) -> String {
        let alignmentXML = alignment.map { "<w:jc w:val=\"\($0)\"/>" } ?? ""
        let keepXML = keepNext ? "<w:keepNext/><w:keepLines/>" : ""
        let content = inline.isEmpty ? "<w:r><w:t/></w:r>" : inline
        return "<w:p><w:pPr><w:pStyle w:val=\"\(style)\"/>\(keepXML)\(alignmentXML)</w:pPr>\(content)</w:p>"
    }

    private func numberedParagraphXML(inline: String, numberID: Int, level: Int) -> String {
        let content = inline.isEmpty ? "<w:r><w:t/></w:r>" : inline
        return "<w:p><w:pPr><w:pStyle w:val=\"ListParagraph\"/><w:numPr><w:ilvl w:val=\"\(level)\"/><w:numId w:val=\"\(numberID)\"/></w:numPr></w:pPr>\(content)</w:p>"
    }

    private mutating func addRelationship(
        type: String,
        target: String,
        targetMode: String?
    ) -> String {
        let id = "rId\(relationshipCounter)"
        relationshipCounter += 1
        relationships.append(Relationship(id: id, type: type, target: target, targetMode: targetMode))
        return id
    }

    private func directCells(of row: XMLElement) -> [XMLElement] {
        (row.children ?? []).compactMap { child in
            guard let element = child as? XMLElement,
                  ["td", "th"].contains(element.name?.lowercased() ?? "")
            else { return nil }
            return element
        }
    }

    private func descendants(named name: String, of node: XMLNode) -> [XMLElement] {
        var result: [XMLElement] = []
        for child in node.children ?? [] {
            if let element = child as? XMLElement {
                if element.name?.lowercased() == name { result.append(element) }
                result.append(contentsOf: descendants(named: name, of: element))
            }
        }
        return result
    }

    private func hasBlockChild(_ node: XMLNode) -> Bool {
        (node.children ?? []).contains { child in
            guard let element = child as? XMLElement else { return false }
            return Self.blockTags.contains(element.name?.lowercased() ?? "")
        }
    }

    private static let blockTags: Set<String> = [
        "h1", "h2", "h3", "h4", "h5", "h6", "p", "ul", "ol", "table",
        "blockquote", "pre", "hr", "div", "section", "article", "figure",
    ]

    private func documentXML(body: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
         xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"
         xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"
         xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
         xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">
        <w:body>\(body)<w:sectPr><w:pgSz w:w="12240" w:h="15840"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="708" w:footer="708" w:gutter="0"/><w:cols w:space="708"/><w:docGrid w:linePitch="360"/></w:sectPr></w:body>
        </w:document>
        """
    }

    private func documentRelationshipsXML() -> String {
        let entries = relationships.map { relationship in
            let mode = relationship.targetMode.map { " TargetMode=\"\($0)\"" } ?? ""
            return "<Relationship Id=\"\(relationship.id)\" Type=\"\(relationship.type)\" Target=\"\(xmlEscape(relationship.target))\"\(mode)/>"
        }.joined()
        return "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(entries)</Relationships>"
    }

    private var contentTypesXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Default Extension="png" ContentType="image/png"/>
        <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
        <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
        <Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>
        <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
        <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>
        </Types>
        """
    }

    private var packageRelationshipsXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
        <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>
        </Relationships>
        """
    }

    private var corePropertiesXML: String {
        let date = ISO8601DateFormatter().string(from: Date())
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:dcmitype="http://purl.org/dc/dcmitype/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
        <dc:title>\(xmlEscape(title))</dc:title><dc:creator>PreviewMD</dc:creator><cp:lastModifiedBy>PreviewMD</cp:lastModifiedBy>
        <dcterms:created xsi:type="dcterms:W3CDTF">\(date)</dcterms:created><dcterms:modified xsi:type="dcterms:W3CDTF">\(date)</dcterms:modified>
        </cp:coreProperties>
        """
    }

    private var appPropertiesXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes"><Application>PreviewMD</Application><AppVersion>1.0</AppVersion></Properties>
        """
    }

    private var stylesXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri"/><w:sz w:val="22"/><w:szCs w:val="22"/><w:lang w:val="en-US"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="120" w:line="264" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>
        <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/><w:pPr><w:spacing w:after="120" w:line="264" w:lineRule="auto"/></w:pPr><w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri"/><w:sz w:val="22"/></w:rPr></w:style>
        <w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/><w:basedOn w:val="Normal"/><w:qFormat/><w:pPr><w:spacing w:after="40" w:line="264" w:lineRule="auto"/></w:pPr></w:style>
        <w:style w:type="paragraph" w:styleId="TableText"><w:name w:val="Table Text"/><w:basedOn w:val="Normal"/><w:pPr><w:spacing w:after="0" w:line="240" w:lineRule="auto"/></w:pPr></w:style>
        \(headingStyle(id: 1, name: "heading 1", size: 32, before: 320, after: 160, color: "2E74B5"))
        \(headingStyle(id: 2, name: "heading 2", size: 26, before: 240, after: 120, color: "2E74B5"))
        \(headingStyle(id: 3, name: "heading 3", size: 24, before: 160, after: 80, color: "1F4E79"))
        \(headingStyle(id: 4, name: "heading 4", size: 22, before: 140, after: 60, color: "1F4E79"))
        \(headingStyle(id: 5, name: "heading 5", size: 22, before: 120, after: 60, color: "334155"))
        \(headingStyle(id: 6, name: "heading 6", size: 20, before: 100, after: 40, color: "475569", italic: true))
        <w:style w:type="paragraph" w:styleId="Quote"><w:name w:val="Quote"/><w:basedOn w:val="Normal"/><w:qFormat/><w:pPr><w:ind w:left="360"/><w:spacing w:before="120" w:after="120"/><w:pBdr><w:left w:val="single" w:sz="18" w:space="8" w:color="94A3B8"/></w:pBdr></w:pPr><w:rPr><w:color w:val="475569"/><w:i/></w:rPr></w:style>
        <w:style w:type="paragraph" w:styleId="Code"><w:name w:val="Code"/><w:basedOn w:val="Normal"/><w:pPr><w:spacing w:before="120" w:after="120" w:line="240" w:lineRule="auto"/><w:shd w:val="clear" w:fill="F7F7F8"/><w:ind w:left="180" w:right="180"/></w:pPr><w:rPr><w:rFonts w:ascii="Menlo" w:hAnsi="Menlo"/><w:sz w:val="19"/></w:rPr></w:style>
        <w:style w:type="character" w:styleId="CodeChar"><w:name w:val="Code Char"/><w:rPr><w:rFonts w:ascii="Menlo" w:hAnsi="Menlo"/><w:sz w:val="19"/><w:shd w:val="clear" w:fill="F1F5F9"/></w:rPr></w:style>
        <w:style w:type="character" w:styleId="Hyperlink"><w:name w:val="Hyperlink"/><w:unhideWhenUsed/><w:rPr><w:color w:val="3F51C6"/><w:u w:val="single"/></w:rPr></w:style>
        </w:styles>
        """
    }

    private func headingStyle(
        id: Int,
        name: String,
        size: Int,
        before: Int,
        after: Int,
        color: String,
        italic: Bool = false
    ) -> String {
        let italicXML = italic ? "<w:i/>" : ""
        return "<w:style w:type=\"paragraph\" w:styleId=\"Heading\(id)\"><w:name w:val=\"\(name)\"/><w:basedOn w:val=\"Normal\"/><w:next w:val=\"Normal\"/><w:qFormat/><w:uiPriority w:val=\"\(8 + id)\"/><w:pPr><w:keepNext/><w:keepLines/><w:spacing w:before=\"\(before)\" w:after=\"\(after)\"/><w:outlineLvl w:val=\"\(id - 1)\"/></w:pPr><w:rPr><w:b/><w:color w:val=\"\(color)\"/><w:sz w:val=\"\(size)\"/><w:szCs w:val=\"\(size)\"/>\(italicXML)</w:rPr></w:style>"
    }

    private var numberingXML: String {
        let bulletLevels = (0...8).map { level in
            let bullet = ["•", "◦", "▪"][level % 3]
            let left = 720 + level * 360
            return "<w:lvl w:ilvl=\"\(level)\"><w:start w:val=\"1\"/><w:numFmt w:val=\"bullet\"/><w:lvlText w:val=\"\(bullet)\"/><w:lvlJc w:val=\"left\"/><w:pPr><w:tabs><w:tab w:val=\"num\" w:pos=\"\(left)\"/></w:tabs><w:ind w:left=\"\(left)\" w:hanging=\"360\"/></w:pPr><w:rPr><w:rFonts w:ascii=\"Arial\" w:hAnsi=\"Arial\"/></w:rPr></w:lvl>"
        }.joined()
        let decimalLevels = (0...8).map { level in
            let left = 720 + level * 360
            return "<w:lvl w:ilvl=\"\(level)\"><w:start w:val=\"1\"/><w:numFmt w:val=\"decimal\"/><w:lvlText w:val=\"%\(level + 1).\"/><w:lvlJc w:val=\"left\"/><w:pPr><w:tabs><w:tab w:val=\"num\" w:pos=\"\(left)\"/></w:tabs><w:ind w:left=\"\(left)\" w:hanging=\"360\"/></w:pPr></w:lvl>"
        }.joined()
        return "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:numbering xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:abstractNum w:abstractNumId=\"0\"><w:multiLevelType w:val=\"hybridMultilevel\"/>\(bulletLevels)</w:abstractNum><w:abstractNum w:abstractNumId=\"1\"><w:multiLevelType w:val=\"hybridMultilevel\"/>\(decimalLevels)</w:abstractNum><w:num w:numId=\"1\"><w:abstractNumId w:val=\"0\"/></w:num><w:num w:numId=\"2\"><w:abstractNumId w:val=\"1\"/></w:num></w:numbering>"
    }

    private func xmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

private enum StoredZIPArchive {
    private struct CentralRecord {
        let name: Data
        let crc: UInt32
        let size: UInt32
        let offset: UInt32
    }

    static func make(entries: [(String, Data)]) throws -> Data {
        var archive = Data()
        var records: [CentralRecord] = []
        for (nameString, contents) in entries {
            let name = Data(nameString.utf8)
            guard name.count <= Int(UInt16.max),
                  contents.count <= Int(UInt32.max),
                  archive.count <= Int(UInt32.max)
            else { throw DOCXDocumentWriter.WriterError.packageTooLarge }
            let crc = CRC32.checksum(contents)
            let offset = UInt32(archive.count)
            archive.appendLE(UInt32(0x0403_4B50))
            archive.appendLE(UInt16(20))
            archive.appendLE(UInt16(0x0800))
            archive.appendLE(UInt16(0))
            archive.appendLE(UInt16(0))
            archive.appendLE(UInt16(0x5C21))
            archive.appendLE(crc)
            archive.appendLE(UInt32(contents.count))
            archive.appendLE(UInt32(contents.count))
            archive.appendLE(UInt16(name.count))
            archive.appendLE(UInt16(0))
            archive.append(name)
            archive.append(contents)
            records.append(CentralRecord(name: name, crc: crc, size: UInt32(contents.count), offset: offset))
        }

        guard archive.count <= Int(UInt32.max), records.count <= Int(UInt16.max) else {
            throw DOCXDocumentWriter.WriterError.packageTooLarge
        }
        let centralOffset = UInt32(archive.count)
        for record in records {
            archive.appendLE(UInt32(0x0201_4B50))
            archive.appendLE(UInt16(20))
            archive.appendLE(UInt16(20))
            archive.appendLE(UInt16(0x0800))
            archive.appendLE(UInt16(0))
            archive.appendLE(UInt16(0))
            archive.appendLE(UInt16(0x5C21))
            archive.appendLE(record.crc)
            archive.appendLE(record.size)
            archive.appendLE(record.size)
            archive.appendLE(UInt16(record.name.count))
            archive.appendLE(UInt16(0))
            archive.appendLE(UInt16(0))
            archive.appendLE(UInt16(0))
            archive.appendLE(UInt16(0))
            archive.appendLE(UInt32(0))
            archive.appendLE(record.offset)
            archive.append(record.name)
        }
        let centralSize = UInt32(archive.count) - centralOffset
        archive.appendLE(UInt32(0x0605_4B50))
        archive.appendLE(UInt16(0))
        archive.appendLE(UInt16(0))
        archive.appendLE(UInt16(records.count))
        archive.appendLE(UInt16(records.count))
        archive.appendLE(centralSize)
        archive.appendLE(centralOffset)
        archive.appendLE(UInt16(0))
        return archive
    }
}

private enum CRC32 {
    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            var value = (crc ^ UInt32(byte)) & 0xFF
            for _ in 0..<8 {
                value = value & 1 == 1 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1
            }
            crc = (crc >> 8) ^ value
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
