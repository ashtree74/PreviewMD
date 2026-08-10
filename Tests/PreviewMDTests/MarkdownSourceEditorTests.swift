#if canImport(XCTest)
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
}
#endif
