#if canImport(XCTest)
import AppKit
import SwiftUI
import XCTest
@testable import PreviewMD

final class MarkdownSourceEditorTests: XCTestCase {
    func testLineMapIncludesEmptyAndTrailingLines() {
        XCTAssertEqual(MarkdownLineMap.lineStartOffsets(in: ""), [0])
        XCTAssertEqual(MarkdownLineMap.lineStartOffsets(in: "one"), [0])
        XCTAssertEqual(
            MarkdownLineMap.lineStartOffsets(in: "one\n\nthree\n"),
            [0, 4, 5, 11]
        )
    }

    func testLineMapTreatsCRLFAsOneLineBreak() {
        XCTAssertEqual(
            MarkdownLineMap.lineStartOffsets(in: "one\r\ntwo\rthree"),
            [0, 5, 9]
        )
    }

    func testLineMapUsesUTF16OffsetsExpectedByAppKit() {
        XCTAssertEqual(
            MarkdownLineMap.lineStartOffsets(in: "🙂\nnext"),
            [0, 3]
        )
    }

    func testLineIndexFindsLogicalLineAtBoundaries() {
        let starts = [0, 4, 5, 11]

        XCTAssertEqual(
            MarkdownLineMap.lineIndex(containingUTF16Offset: 0, starts: starts),
            0
        )
        XCTAssertEqual(
            MarkdownLineMap.lineIndex(containingUTF16Offset: 4, starts: starts),
            1
        )
        XCTAssertEqual(
            MarkdownLineMap.lineIndex(containingUTF16Offset: 10, starts: starts),
            2
        )
        XCTAssertEqual(
            MarkdownLineMap.lineIndex(containingUTF16Offset: 11, starts: starts),
            3
        )
    }

    @MainActor
    func testSourceEditorReturnContinuesTaskListWithAnUncheckedItem() throws {
        _ = NSApplication.shared
        let source = "  - [x] Finished"
        let host = NSHostingView(
            rootView: MarkdownSourceEditor(text: .constant(source))
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        host.frame = window.contentView!.bounds
        host.layoutSubtreeIfNeeded()

        let scrollView = try XCTUnwrap(host.descendant(of: NSScrollView.self))
        let textView = try XCTUnwrap(scrollView.documentView as? NSTextView)
        textView.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        textView.insertNewline(nil)

        XCTAssertEqual(textView.string, "  - [x] Finished\n  - [ ] ")
    }

    @MainActor
    func testSourceEditorPasteIgnoresRichTextColor() throws {
        let textView = MarkdownSourceTextView()
        textView.isRichText = false
        textView.string = "Keep: here"
        textView.typingAttributes = [.foregroundColor: NSColor.labelColor]
        textView.setSelectedRange((textView.string as NSString).range(of: "here"))

        let styledText = NSAttributedString(
            string: "visible",
            attributes: [.foregroundColor: NSColor.white]
        )
        let rtf = try styledText.data(
            from: NSRange(location: 0, length: styledText.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("PreviewMDTests.\(UUID().uuidString)")
        )
        pasteboard.clearContents()
        pasteboard.setData(rtf, forType: .rtf)
        pasteboard.setString("visible", forType: .string)

        XCTAssertTrue(textView.pastePlainText(from: pasteboard))
        XCTAssertEqual(textView.string, "Keep: visible")
        let pastedColor = textView.textStorage?.attribute(
            .foregroundColor,
            at: (textView.string as NSString).range(of: "visible").location,
            effectiveRange: nil
        ) as? NSColor
        XCTAssertFalse(pastedColor?.isEqual(NSColor.white) == true)
    }

    @MainActor
    func testSourceEditorSynchronizesSelectionAndScrollWithPreview() throws {
        _ = NSApplication.shared
        let source = (0..<80)
            .map { "Line \($0) with enough source text" }
            .joined(separator: "\n")
        let documentID = UUID()
        let synchronizer = SplitEditorSynchronizer()
        let preview = SourceEditorPreviewEndpointSpy()
        let host = NSHostingView(
            rootView: MarkdownSourceEditor(
                text: .constant(source),
                documentID: documentID,
                splitSynchronizer: synchronizer,
                isSplitSynchronizationEnabled: true
            )
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        host.frame = window.contentView!.bounds
        host.layoutSubtreeIfNeeded()
        synchronizer.attachPreview(preview, documentID: documentID)

        let scrollView = try XCTUnwrap(host.descendant(of: NSScrollView.self))
        let textView = try XCTUnwrap(scrollView.documentView as? NSTextView)
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let localSelection = (source as NSString).range(of: "Line 4")
        textView.setSelectedRange(localSelection)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))

        XCTAssertEqual(
            preview.selections.last,
            SplitEditorSelection(range: localSelection)
        )

        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 420))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertGreaterThan(preview.scrollPositions.last?.sourceLine ?? 0, 10)

        let remoteSelection = (source as NSString).range(of: "Line 27")
        synchronizer.previewDidChangeSelection(
            SplitEditorSelection(range: remoteSelection),
            documentID: documentID
        )
        XCTAssertEqual(textView.selectedRange(), remoteSelection)
        XCTAssertEqual(
            (textView as? MarkdownSourceTextView)?.synchronizedSelectionRange,
            remoteSelection
        )

        synchronizer.previewDidScroll(
            SplitEditorScrollPosition(sourceLine: 55),
            documentID: documentID
        )
        XCTAssertGreaterThan(textView.visibleRect.minY, 500)
    }

    @MainActor
    func testSourceScrollPublicationUsesLogicalLineWhenLinesWrap() throws {
        _ = NSApplication.shared
        let source = (0..<80)
            .map { "Line \($0) " + String(repeating: "wrapped content ", count: 5) }
            .joined(separator: "\n")
        let documentID = UUID()
        let synchronizer = SplitEditorSynchronizer()
        let preview = SourceEditorPreviewEndpointSpy()
        let host = NSHostingView(
            rootView: MarkdownSourceEditor(
                text: .constant(source),
                documentID: documentID,
                splitSynchronizer: synchronizer,
                isSplitSynchronizationEnabled: true
            )
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        host.frame = window.contentView!.bounds
        host.layoutSubtreeIfNeeded()
        synchronizer.attachPreview(preview, documentID: documentID)

        let scrollView = try XCTUnwrap(host.descendant(of: NSScrollView.self))
        let textView = try XCTUnwrap(scrollView.documentView as? NSTextView)
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let textContainer = try XCTUnwrap(textView.textContainer)
        layoutManager.ensureLayout(for: textContainer)
        let targetLine = 30
        let targetRange = (source as NSString).range(of: "Line \(targetLine) ")
        let glyphIndex = layoutManager.glyphIndexForCharacter(
            at: targetRange.location
        )
        let lineRect = layoutManager.lineFragmentRect(
            forGlyphAt: glyphIndex,
            effectiveRange: nil
        )
        let anchor = min(72, max(24, scrollView.contentView.bounds.height * 0.08))
        textView.scroll(
            NSPoint(
                x: 0,
                y: lineRect.minY + textView.textContainerOrigin.y - anchor
            )
        )
        scrollView.reflectScrolledClipView(scrollView.contentView)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertEqual(
            preview.scrollPositions.last?.sourceLine ?? .nan,
            Double(targetLine),
            accuracy: 1
        )
    }

    @MainActor
    func testSourceEditorKeepsTextVisibleBesideLineNumberRuler() throws {
        _ = NSApplication.shared
        let source = "# Heading\n\nVisible source text"
        let layout = SourceEditorLayoutModel()
        let host = NSHostingView(
            rootView: SourceEditorLayoutHarness(
                source: source,
                layout: layout
            )
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.frame = window.contentView!.bounds
        host.layoutSubtreeIfNeeded()

        layout.sourceWidth = 640
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        host.layoutSubtreeIfNeeded()

        window.appearance = NSAppearance(named: .aqua)
        host.layoutSubtreeIfNeeded()

        let scrollView = try XCTUnwrap(host.descendant(of: NSScrollView.self))
        let textView = try XCTUnwrap(scrollView.documentView as? NSTextView)
        let container = try XCTUnwrap(
            scrollView.superview as? MarkdownSourceContainerView
        )
        let lineNumbers = container.lineNumberOverlay
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)

        XCTAssertTrue(lineNumbers.superview === container)
        XCTAssertFalse(lineNumbers.isOpaque)
        lineNumbers.frame.size.width = container.bounds.width
        XCTAssertEqual(
            lineNumbers.gutterRect(intersecting: lineNumbers.bounds).width,
            lineNumbers.requiredWidth,
            accuracy: 0.5
        )
        XCTAssertNil(lineNumbers.hitTest(NSPoint(x: 200, y: 20)))

        XCTAssertGreaterThan(textView.frame.width, 500)
        XCTAssertTrue(textView.visibleRect.intersects(textView.firstGlyphRect))

        let color = try XCTUnwrap(
            textView.textStorage?.attribute(
                .foregroundColor,
                at: (source as NSString).range(of: "Visible").location,
                effectiveRange: nil
            ) as? NSColor
        )
        let resolved = color.resolvedColor(with: textView.effectiveAppearance)
        XCTAssertLessThan(resolved.perceivedBrightness, 0.8)

        let headingColor = try XCTUnwrap(
            textView.textStorage?.attribute(
                .foregroundColor,
                at: 0,
                effectiveRange: nil
            ) as? NSColor
        ).resolvedColor(with: textView.effectiveAppearance)
        XCTAssertLessThan(headingColor.perceivedBrightness, 0.5)
    }
}

@MainActor
private final class SourceEditorLayoutModel: ObservableObject {
    @Published var sourceWidth: CGFloat = 0
}

private struct SourceEditorLayoutHarness: View {
    let source: String
    @ObservedObject var layout: SourceEditorLayoutModel

    var body: some View {
        HStack(spacing: 0) {
            MarkdownSourceEditor(text: .constant(source))
                .frame(width: layout.sourceWidth)
                .clipped()
            Spacer(minLength: 0)
        }
    }
}

private extension NSView {
    func descendant<ViewType: NSView>(of type: ViewType.Type) -> ViewType? {
        if let match = self as? ViewType {
            return match
        }
        return subviews.lazy.compactMap { $0.descendant(of: type) }.first
    }
}

private extension NSTextView {
    var firstGlyphRect: NSRect {
        guard let layoutManager, let textContainer, !string.isEmpty else {
            return .zero
        }
        let glyph = layoutManager.glyphIndexForCharacter(at: 0)
        return layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyph, length: 1),
            in: textContainer
        ).offsetBy(
            dx: textContainerOrigin.x,
            dy: textContainerOrigin.y
        )
    }
}

private extension NSColor {
    func resolvedColor(with appearance: NSAppearance) -> NSColor {
        var color = self
        appearance.performAsCurrentDrawingAppearance {
            color = usingColorSpace(.deviceRGB) ?? self
        }
        return color
    }

    var perceivedBrightness: CGFloat {
        guard let rgb = usingColorSpace(.deviceRGB) else { return 1 }
        return 0.2126 * rgb.redComponent
            + 0.7152 * rgb.greenComponent
            + 0.0722 * rgb.blueComponent
    }
}

@MainActor
private final class SourceEditorPreviewEndpointSpy:
    SplitPreviewSynchronizationEndpoint
{
    var scrollPositions: [SplitEditorScrollPosition] = []
    var selections: [SplitEditorSelection] = []

    func applySourceScrollPosition(_ position: SplitEditorScrollPosition) {
        scrollPositions.append(position)
    }

    func applySourceSelection(_ selection: SplitEditorSelection) {
        selections.append(selection)
    }
}
#endif
