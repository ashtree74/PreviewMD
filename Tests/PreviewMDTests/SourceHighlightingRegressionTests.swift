#if canImport(XCTest)
import AppKit
import SwiftUI
import XCTest
@testable import PreviewMD

@MainActor
final class SourceHighlightingRegressionTests: XCTestCase {
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

    func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        if editedMask.contains(.editedAttributes) {
            attributeRanges.append(editedRange)
        }
    }
}
#endif
