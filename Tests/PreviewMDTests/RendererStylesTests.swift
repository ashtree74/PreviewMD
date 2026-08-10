#if canImport(XCTest)
import Foundation
import XCTest

final class RendererStylesTests: XCTestCase {
    func testTaskCheckboxesScaleWithTextAndUseLineCenteredPositioning() throws {
        let css = try rendererCSS()
        let checkboxRule = try declarations(
            after: """
            .task-list-item > input,
            .task-list-item > p > input
            """,
            in: css
        )

        XCTAssertTrue(checkboxRule.contains("top: calc((1lh - var(--task-checkbox-size)) / 2);"))
        XCTAssertTrue(checkboxRule.contains("width: var(--task-checkbox-size);"))
        XCTAssertTrue(checkboxRule.contains("height: var(--task-checkbox-size);"))
        XCTAssertTrue(checkboxRule.contains("margin: 0;"))
        XCTAssertTrue(checkboxRule.contains("font: inherit;"))
    }

    func testTaskCheckmarkIsCenteredInsideItsControl() throws {
        let css = try rendererCSS()
        let checkmarkRule = try declarations(
            after: """
            .task-list-item > input:checked::after,
            .task-list-item > p > input:checked::after
            """,
            in: css
        )

        XCTAssertTrue(checkmarkRule.contains("top: 50%;"))
        XCTAssertTrue(checkmarkRule.contains("left: 50%;"))
        XCTAssertTrue(checkmarkRule.contains("translate(-50%, -56%)"))
        XCTAssertTrue(checkmarkRule.contains("solid var(--page)"))
    }

    func testTablesKeepReadableColumnsInsideScrollableViewport() throws {
        let css = try rendererCSS()
        let viewportRule = try declarations(after: ".table-viewport", in: css)
        let tableRule = try declarations(after: "table", in: css)
        let cellsRule = try declarations(
            after: """
            th,
            td
            """,
            in: css
        )

        XCTAssertTrue(viewportRule.contains("overflow-x: auto;"))
        XCTAssertTrue(tableRule.contains("width: 100%;"))
        XCTAssertTrue(tableRule.contains("min-width: 100%;"))
        XCTAssertTrue(cellsRule.contains("min-width: 9rem;"))
        XCTAssertTrue(cellsRule.contains("overflow-wrap: break-word;"))
        XCTAssertTrue(cellsRule.contains("word-break: normal;"))
    }

    func testTablesUseThemeAwareAlternatingRowBackgrounds() throws {
        let css = try rendererCSS()
        let stripedRowRule = try declarations(after: "tbody tr:nth-child(even)", in: css)

        XCTAssertTrue(stripedRowRule.contains("color-mix(in srgb, var(--line) 34%, var(--page))"))
    }

    func testFluidWidthTracksTheWindowInsteadOfPixelPreset() throws {
        let css = try rendererCSS()
        let rule = try declarations(
            after: #":root[data-width="fluid"] #preview-document"#,
            in: css
        )

        XCTAssertTrue(rule.contains("width: 100%;"))
        XCTAssertTrue(rule.contains("max-width: none;"))
    }

    func testBadgesAreCompactInlineImages() throws {
        let css = try rendererCSS()
        let rule = try declarations(after: "img.markdown-badge", in: css)

        XCTAssertTrue(rule.contains("display: inline-block;"))
        XCTAssertTrue(rule.contains("height: 20px;"))
        XCTAssertTrue(rule.contains("box-shadow: none;"))
    }

    func testPrintColorsFollowExplicitExportTheme() throws {
        let css = try rendererCSS()
        XCTAssertTrue(css.contains(#":root[data-theme="light"]"#))
        XCTAssertTrue(css.contains("background: var(--page);"))
        XCTAssertFalse(css.contains("body,\n  #preview-shell {\n    background: white;"))
    }

    func testPDFCaptureUsesNativeMarginsInsteadOfZeroPageMargins() throws {
        let css = try rendererCSS()
        XCTAssertFalse(css.contains("@page {\n    margin: 0;"))
        XCTAssertTrue(css.contains(#":root[data-pdf-export="true"] #preview-document"#))
        XCTAssertTrue(css.contains("width: var(--pdf-content-width);"))
    }

    private func rendererCSS() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/PreviewMD/Resources/Renderer/renderer.css")

        return try String(contentsOf: url, encoding: .utf8)
    }

    private func declarations(after selector: String, in css: String) throws -> String {
        let selectorWithBrace = selector + " {"
        let selectorRange = try XCTUnwrap(
            css.range(of: selectorWithBrace),
            "Missing CSS selector: \(selector)"
        )
        let ruleTail = css[selectorRange.upperBound...]
        let closingBrace = try XCTUnwrap(
            ruleTail.firstIndex(of: "}"),
            "Unclosed CSS rule: \(selector)"
        )
        return String(ruleTail[..<closingBrace])
    }
}
#endif
