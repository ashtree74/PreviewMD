#if canImport(XCTest)
import AppKit
import SwiftUI
import XCTest
@testable import PreviewMD

@MainActor
final class SourceHighlightingRegressionTests: XCTestCase {
    func testIncrementalSourceReplacementPreservesUnicodeAndLineBoundaries() throws {
        for (previous, current) in [
            ("before 🙂 after", "before 🙃 after"),
            ("before 👩🏽‍💻 after", "before 👩‍💻 after"),
            ("e\u{301}", "e"), ("e", "e\u{301}"),
            ("🇵🇱🇫🇷", "🇵🇱🇩🇪"), ("a\r\nb", "a\nb"),
            ("a\nb", "ab"), ("", "🙂"), ("🙂", ""),
            ("\u{10000}a", "\u{10400}a"), ("same", "same")
        ] {
            let storage = NSTextStorage(string: previous)
            if let ranges = MarkdownSourceHighlighting.changedTextRanges(from: previous, to: current) {
                storage.replaceCharacters(in: ranges.previous, with: (current as NSString).substring(with: ranges.current))
            }
            XCTAssertEqual(storage.string, current)
        }
    }

    func testRichEchoChangesOnlyAffectedSourceTextAndKeepsOtherColors() async throws {
        _ = NSApplication.shared
        let source = "# Heading\n\nPlain line\n\n" + String(repeating: "Unchanged line\n", count: 200)
        let host = NSHostingView(rootView: MarkdownSourceEditor(text: .constant(source)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        defer { window.close() }
        let textView = try XCTUnwrap(findTextView(in: host))
        let storage = try XCTUnwrap(textView.textStorage)
        let headingColor = storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        let observer = AttributeEditObserver()
        storage.delegate = observer
        let changed = source.replacingOccurrences(of: "Plain line", with: "Plain linex")
        host.rootView = MarkdownSourceEditor(text: .constant(changed))
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(textView.string, changed)
        XCTAssertFalse(observer.characterRanges.isEmpty)
        XCTAssertTrue(observer.characterRanges.allSatisfy { $0.length < 100 })
        XCTAssertTrue(observer.attributeRanges.allSatisfy { $0.length < 100 })
        XCTAssertEqual(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, headingColor)
    }

    private func findTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView { return textView }
        return view.subviews.lazy.compactMap { self.findTextView(in: $0) }.first
    }

    func testSingleLineEditDoesNotRestyleTheWholeDocument() throws {
        _ = NSApplication.shared
        let source = "# Heading\n\n" + (0..<2_000).map { "Plain line \($0)" }.joined(separator: "\n")
        let textView = NSTextView()
        textView.string = source
        let coordinator = MarkdownSourceEditor.Coordinator(
            text: .constant(source), documentID: nil,
            splitSynchronizer: nil, isSplitSynchronizationEnabled: false
        )
        coordinator.textView = textView
        coordinator.highlight()
        let storage = try XCTUnwrap(textView.textStorage)
        let observer = AttributeEditObserver()
        storage.delegate = observer

        let range = (textView.string as NSString).range(of: "Plain line 1\n")
        storage.replaceCharacters(in: NSRange(location: range.location, length: 5), with: "Other")
        observer.attributeRanges.removeAll()
        coordinator.highlight()

        XCTAssertFalse(observer.attributeRanges.isEmpty)
        XCTAssertTrue(observer.attributeRanges.allSatisfy { $0.length < 100 })
        let headingColor = storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertFalse(headingColor?.isEqual(NSColor.labelColor) == true)
    }

    func testIncrementalHighlightingRetainsCodeColorAndHandlesFenceRemoval() throws {
        _ = NSApplication.shared
        let textView = NSTextView()
        textView.string = "# Heading\n\n```text\nfirst\nsecond\n```\n\nTail"
        let coordinator = MarkdownSourceEditor.Coordinator(
            text: .constant(textView.string), documentID: nil,
            splitSynchronizer: nil, isSplitSynchronizationEnabled: false
        )
        coordinator.textView = textView
        coordinator.highlight()
        let storage = try XCTUnwrap(textView.textStorage)
        let originalCodeColor = storage.attribute(.foregroundColor, at: (textView.string as NSString).range(of: "second").location, effectiveRange: nil) as? NSColor
        storage.replaceCharacters(in: (textView.string as NSString).range(of: "second"), with: "changed")
        coordinator.highlight()
        let newCodeColor = storage.attribute(.foregroundColor, at: (textView.string as NSString).range(of: "changed").location, effectiveRange: nil) as? NSColor
        XCTAssertEqual(originalCodeColor, newCodeColor)

        storage.replaceCharacters(in: (textView.string as NSString).range(of: "```text\n"), with: "")
        coordinator.highlight()
        let afterFenceRemoval = storage.attribute(.foregroundColor, at: (textView.string as NSString).range(of: "changed").location, effectiveRange: nil) as? NSColor
        XCTAssertEqual(afterFenceRemoval, NSColor.labelColor)
    }
}

private final class AttributeEditObserver: NSObject, NSTextStorageDelegate {
    var attributeRanges: [NSRange] = []
    var characterRanges: [NSRange] = []

    func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        if editedMask.contains(.editedAttributes) {
            attributeRanges.append(editedRange)
        }
        if editedMask.contains(.editedCharacters) {
            characterRanges.append(editedRange)
        }
    }
}
#endif
