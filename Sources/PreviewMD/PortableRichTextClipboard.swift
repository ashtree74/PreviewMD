import AppKit
import Foundation
import UniformTypeIdentifiers

enum AdvancedCopyFormat: String, CaseIterable, Identifiable {
    case pages
    case word
    case semanticHTML
    case markdown
    case plainText
    case docxFile
    case image

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pages: "For Pages"
        case .word: "For Microsoft Word"
        case .semanticHTML: "Semantic HTML"
        case .markdown: "Markdown Source"
        case .plainText: "Plain Text"
        case .docxFile: "DOCX File"
        case .image: "Selected Object as Image"
        }
    }
}

/// Writes a portable, multi-representation selection to the macOS pasteboard.
///
/// WebKit's default rich copy contains renderer-specific layout nodes. Those
/// nodes only work while PreviewMD's stylesheets and fonts are present, so apps
/// such as Pages import them as broken grids of individually positioned spans.
/// The renderer instead supplies deliberately simple HTML plus self-contained
/// image assets; this type derives RTF and RTFD from that portable source.
enum PortableRichTextClipboard {
    static let assetURLPrefix = "previewmd-copy-asset:"

    struct EmbeddedAsset: Equatable {
        let id: String
        let mimeType: String
        let data: Data
        let width: Double
        let height: Double
        /// An optional source vector advertised only when this asset is the
        /// complete selection. It is deliberately not embedded into RTFD:
        /// Pages imports SVG attachments as their raw XML/CSS.
        let standaloneSVG: Data?

        init(
            id: String,
            mimeType: String,
            data: Data,
            width: Double,
            height: Double,
            standaloneSVG: Data? = nil
        ) {
            self.id = id
            self.mimeType = mimeType
            self.data = data
            self.width = width
            self.height = height
            self.standaloneSVG = standaloneSVG
        }
    }

    @discardableResult
    static func write(
        html: String,
        plainText: String,
        markdown: String? = nil,
        assets: [EmbeddedAsset],
        standaloneAssetID: String?,
        format: AdvancedCopyFormat? = nil,
        to pasteboard: NSPasteboard = .general
    ) -> Bool {
        let embeddedHTML = htmlEmbeddingAssets(html, assets: assets)
        let item = NSPasteboardItem()

        switch format {
        case .markdown:
            let source = markdown ?? plainText
            item.setString(
                source,
                forType: NSPasteboard.PasteboardType("net.daringfireball.markdown")
            )
            item.setString(source, forType: .string)
            pasteboard.clearContents()
            return pasteboard.writeObjects([item])
        case .plainText:
            item.setString(plainText, forType: .string)
            pasteboard.clearContents()
            return pasteboard.writeObjects([item])
        case .image:
            guard let standaloneAssetID,
                  let asset = assets.first(where: { $0.id == standaloneAssetID })
            else { return false }
            addStandaloneRepresentations(of: asset, to: item)
            item.setString(plainText, forType: .string)
            pasteboard.clearContents()
            return pasteboard.writeObjects([item])
        case .word, .semanticHTML:
            item.setString(embeddedHTML, forType: .html)
            item.setString(plainText, forType: .string)
            if let standaloneAssetID,
               let asset = assets.first(where: { $0.id == standaloneAssetID }) {
                addStandaloneRepresentations(of: asset, to: item)
            }
            pasteboard.clearContents()
            return pasteboard.writeObjects([item])
        case .docxFile:
            return false
        case .pages, .none:
            break
        }

        if let attributed = attributedString(from: embeddedHTML) {
            let range = NSRange(location: 0, length: attributed.length)
            if let rtfd = try? attributed.data(
                from: range,
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
            ) {
                item.setData(rtfd, forType: .rtfd)
            }
            // AppKit silently drops every image when exporting attributed text
            // to plain RTF (there is no \pict payload). Advertising that lossy
            // type makes Pages prefer it over RTFD, so only offer RTF when the
            // selection is genuinely text-only.
            if assets.isEmpty,
               let rtf = try? attributed.data(
                    from: range,
                    documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
                ) {
                item.setData(rtf, forType: .rtf)
            }
        }

        // HTML is kept alongside RTFD because non-AppKit destinations often
        // preserve semantic headings, tables, and links better from
        // public.html. Standard RTF/RTFD carries paragraph formatting but no
        // portable mapping to a destination app's named paragraph styles.
        item.setString(embeddedHTML, forType: .html)
        item.setString(plainText, forType: .string)

        if let standaloneAssetID,
           let asset = assets.first(where: { $0.id == standaloneAssetID }) {
            addStandaloneRepresentations(of: asset, to: item)
        }

        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }

    static func htmlEmbeddingAssets(
        _ html: String,
        assets: [EmbeddedAsset]
    ) -> String {
        var result = html
        for asset in assets {
            let dataURL = "data:\(asset.mimeType);base64,\(asset.data.base64EncodedString())"
            result = result.replacingOccurrences(
                of: assetURLPrefix + asset.id + "\"",
                with: dataURL + "\""
            )
        }

        // An oversized or malformed renderer payload must not leave a custom
        // PreviewMD URL behind: destinations would display a broken-image
        // glyph. Replace any unresolved placeholder with a self-contained,
        // neutral image while the alt text remains available to text clients.
        let unresolved = fallbackAsset(
            id: "unresolved",
            label: "Item",
            width: 96,
            height: 36
        )
        let fallbackURL = "data:\(unresolved.mimeType);base64,\(unresolved.data.base64EncodedString())"
        return result.replacingOccurrences(
            of: #"previewmd-copy-asset:[A-Za-z0-9-]+"#,
            with: fallbackURL,
            options: .regularExpression
        )
    }

    static func fallbackAsset(
        id: String,
        label: String,
        width: Double,
        height: Double
    ) -> EmbeddedAsset {
        let safeWidth = min(1_600, max(80, width.rounded(.up)))
        let safeHeight = min(400, max(32, height.rounded(.up)))
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(safeWidth),
            pixelsHigh: Int(safeHeight),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        let context = bitmap.flatMap(NSGraphicsContext.init(bitmapImageRep:))

        if let context {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            let bounds = NSRect(x: 0, y: 0, width: safeWidth, height: safeHeight)
            NSColor.white.setFill()
            bounds.fill()
            NSColor(calibratedWhite: 0.82, alpha: 1).setStroke()
            let border = NSBezierPath(
                roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                xRadius: 6,
                yRadius: 6
            )
            border.lineWidth = 1
            border.stroke()

            let fontSize = min(24, max(12, safeHeight * 0.32))
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize),
                .foregroundColor: NSColor(calibratedWhite: 0.15, alpha: 1),
                .paragraphStyle: paragraph,
            ]
            let verticalInset = max(3, (safeHeight - fontSize * 1.25) / 2)
            let textRect = bounds.insetBy(dx: 12, dy: verticalInset)
            (label as NSString).draw(in: textRect, withAttributes: attributes)
            NSGraphicsContext.restoreGraphicsState()
        }

        // This last-resort image is still a standards-compliant PNG even if
        // AppKit cannot allocate the requested bitmap.
        let transparentPixel = Data(
            base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScL5WQAAAABJRU5ErkJggg=="
        ) ?? Data()
        let png = bitmap?.representation(using: .png, properties: [:]) ?? transparentPixel
        return EmbeddedAsset(
            id: id,
            mimeType: "image/png",
            data: png,
            width: safeWidth,
            height: safeHeight
        )
    }

    private static func attributedString(from html: String) -> NSAttributedString? {
        try? NSAttributedString(
            data: Data(html.utf8),
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue,
            ],
            documentAttributes: nil
        )
    }

    private static func addStandaloneRepresentations(
        of asset: EmbeddedAsset,
        to item: NSPasteboardItem
    ) {
        if let svg = asset.standaloneSVG {
            item.setData(
                svg,
                forType: NSPasteboard.PasteboardType(UTType.svg.identifier)
            )
        }

        switch asset.mimeType {
        case "image/svg+xml":
            item.setData(
                asset.data,
                forType: NSPasteboard.PasteboardType(UTType.svg.identifier)
            )
            if let image = NSImage(data: asset.data),
               let tiff = image.tiffRepresentation {
                item.setData(tiff, forType: .tiff)
                if let png = pngData(fromTIFF: tiff) {
                    item.setData(png, forType: .png)
                }
            }
        case "image/png":
            item.setData(asset.data, forType: .png)
            if let image = NSImage(data: asset.data),
               let tiff = image.tiffRepresentation {
                item.setData(tiff, forType: .tiff)
            }
        default:
            break
        }
    }

    private static func pngData(fromTIFF data: Data) -> Data? {
        NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
    }

}
