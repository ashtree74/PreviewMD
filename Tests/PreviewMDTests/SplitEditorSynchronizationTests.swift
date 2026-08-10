#if canImport(XCTest)
import XCTest
@testable import PreviewMD

@MainActor
final class SplitEditorSynchronizationTests: XCTestCase {
    func testRoutesScrollAndSelectionInBothDirectionsForTheSameDocument() {
        let synchronizer = SplitEditorSynchronizer()
        let source = SourceEndpointSpy()
        let preview = PreviewEndpointSpy()
        let documentID = UUID()
        synchronizer.attachSource(source, documentID: documentID)
        synchronizer.attachPreview(preview, documentID: documentID)

        let sourceScroll = SplitEditorScrollPosition(sourceLine: 18.5)
        let sourceSelection = SplitEditorSelection(
            range: NSRange(location: 42, length: 7)
        )
        synchronizer.sourceDidScroll(sourceScroll, documentID: documentID)
        synchronizer.sourceDidChangeSelection(
            sourceSelection,
            documentID: documentID
        )

        XCTAssertEqual(preview.scrollPositions, [sourceScroll])
        XCTAssertEqual(preview.selections, [sourceSelection])
        synchronizer.previewDidBecomeReady(documentID: documentID)
        XCTAssertEqual(preview.selections, [sourceSelection, sourceSelection])

        let previewScroll = SplitEditorScrollPosition(sourceLine: 9)
        let previewSelection = SplitEditorSelection(
            range: NSRange(location: 12, length: 0)
        )
        synchronizer.previewDidScroll(previewScroll, documentID: documentID)
        synchronizer.previewDidChangeSelection(
            previewSelection,
            documentID: documentID
        )

        XCTAssertEqual(source.scrollPositions, [previewScroll])
        XCTAssertEqual(source.selections, [previewSelection])
        synchronizer.sourceDidBecomeReady(documentID: documentID)
        XCTAssertEqual(source.selections, [previewSelection, previewSelection])
    }

    func testDoesNotRoutePositionsAcrossDocuments() {
        let synchronizer = SplitEditorSynchronizer()
        let source = SourceEndpointSpy()
        let preview = PreviewEndpointSpy()
        synchronizer.attachSource(source, documentID: UUID())
        synchronizer.attachPreview(preview, documentID: UUID())

        synchronizer.sourceDidScroll(
            SplitEditorScrollPosition(sourceLine: 12),
            documentID: UUID()
        )
        synchronizer.previewDidChangeSelection(
            SplitEditorSelection(range: NSRange(location: 4, length: 2)),
            documentID: UUID()
        )

        XCTAssertTrue(source.selections.isEmpty)
        XCTAssertTrue(preview.scrollPositions.isEmpty)
    }
}

@MainActor
private final class SourceEndpointSpy: SplitSourceSynchronizationEndpoint {
    var scrollPositions: [SplitEditorScrollPosition] = []
    var selections: [SplitEditorSelection] = []

    func applyPreviewScrollPosition(_ position: SplitEditorScrollPosition) {
        scrollPositions.append(position)
    }

    func applyPreviewSelection(_ selection: SplitEditorSelection) {
        selections.append(selection)
    }
}

@MainActor
private final class PreviewEndpointSpy: SplitPreviewSynchronizationEndpoint {
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
