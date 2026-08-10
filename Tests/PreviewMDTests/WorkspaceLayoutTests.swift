#if canImport(XCTest)
import Foundation
import XCTest

final class WorkspaceLayoutTests: XCTestCase {
    func testStableDocumentWorkspaceLetsFocusBlurReachToolbarRegion() throws {
        let source = try workspaceSource()
        let workspaceStart = try XCTUnwrap(
            source.range(of: "private struct DocumentWorkspace")
        )
        let workspaceTail = source[workspaceStart.lowerBound...]
        let workspaceEnd = try XCTUnwrap(
            workspaceTail.range(of: "private struct SplitDivider")
        )
        let workspace = String(workspaceTail[..<workspaceEnd.lowerBound])

        XCTAssertTrue(workspace.contains(".ignoresSafeArea("))
        XCTAssertTrue(
            workspace.contains("state.isFocusMode ? .container : []")
        )
        XCTAssertTrue(workspace.contains("edges: .top"))
    }

    func testSidebarUsesViewTabsInsteadOfBrandBlock() throws {
        let source = try workspaceSource()
        let sidebarStart = try XCTUnwrap(
            source.range(of: "private struct SidebarView")
        )
        let sidebarTail = source[sidebarStart.lowerBound...]
        let sidebarEnd = try XCTUnwrap(
            sidebarTail.range(of: "private struct FolderSectionHeader")
        )
        let sidebar = String(sidebarTail[..<sidebarEnd.lowerBound])

        XCTAssertTrue(sidebar.contains("SidebarModePicker(selection: $state.sidebarMode)"))
        XCTAssertTrue(sidebar.contains("SidebarMode.allCases"))
        XCTAssertFalse(sidebar.contains("BrandHeader()"))
        XCTAssertFalse(sidebar.contains("PREVIEWMD"))
        XCTAssertFalse(sidebar.contains("by Jesion"))
        XCTAssertFalse(sidebar.contains("Showcase"))
        XCTAssertFalse(sidebar.contains("openWelcome"))
    }

    func testSidebarModesUseNamedNativeTooltipSegments() throws {
        let source = try workspaceSource()

        XCTAssertTrue(source.contains("SidebarModePicker(selection: $state.sidebarMode)"))
        XCTAssertTrue(source.contains("control.setToolTip(mode.title, forSegment: segment)"))
        XCTAssertTrue(source.contains("FolderSearchSidebar()"))
    }

    func testFocusControlFollowsReadingAppearanceInToolbar() throws {
        let source = try workspaceSource()
        let toolbarStart = try XCTUnwrap(source.range(of: "private struct ToolbarUtilities"))
        let toolbarTail = source[toolbarStart.lowerBound...]
        let toolbarEnd = try XCTUnwrap(
            toolbarTail.range(of: "private struct SidebarView")
        )
        let toolbar = String(toolbarTail[..<toolbarEnd.lowerBound])

        let appearance = try XCTUnwrap(toolbar.range(of: "Label(\"Reading appearance\""))
        let focus = try XCTUnwrap(toolbar.range(of: "Label(\"Focus\""))
        let reload = try XCTUnwrap(toolbar.range(of: "Label(\"Reload\""))

        XCTAssertLessThan(appearance.lowerBound, focus.lowerBound)
        XCTAssertLessThan(focus.lowerBound, reload.lowerBound)
    }

    func testReadingWidthRulerOffersPresetsInsteadOfFitTablesAction() throws {
        let source = try workspaceSource()
        let rulerStart = try XCTUnwrap(
            source.range(of: "private struct ReadingWidthRuler")
        )
        let rulerTail = source[rulerStart.lowerBound...]
        let rulerEnd = try XCTUnwrap(
            rulerTail.range(of: "private struct SourceEditor")
        )
        let ruler = String(rulerTail[..<rulerEnd.lowerBound])

        XCTAssertTrue(ruler.contains("Menu {"))
        XCTAssertTrue(ruler.contains("Picker(\"Reading width\""))
        XCTAssertTrue(ruler.contains("ReadingWidth.allCases"))
        XCTAssertTrue(ruler.contains("state.readingWidth = .fullWidth"))
        XCTAssertTrue(ruler.contains(".pickerStyle(.inline)"))
        XCTAssertTrue(ruler.contains(".labelsHidden()"))
        XCTAssertFalse(ruler.contains("Fit tables"))
        XCTAssertFalse(ruler.contains("fitWideContent"))
    }

    func testSourceModeUsesWrappingSyntaxColoredEditor() throws {
        let source = try workspaceSource()
        let editorStart = try XCTUnwrap(
            source.range(of: "private struct SourceEditor")
        )
        let editor = String(source[editorStart.lowerBound...])

        XCTAssertTrue(editor.contains("MarkdownSourceEditor("))
        XCTAssertFalse(editor.contains("TextEditor("))

        let sourceEditorURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/PreviewMD/MarkdownSourceEditor.swift")
        let sourceEditor = try String(contentsOf: sourceEditorURL, encoding: .utf8)
        XCTAssertTrue(sourceEditor.contains("hasHorizontalScroller = false"))
        XCTAssertTrue(sourceEditor.contains("widthTracksTextView = true"))
        XCTAssertTrue(sourceEditor.contains("NSRegularExpression"))
        XCTAssertTrue(sourceEditor.contains("hasVerticalRuler = true"))
        XCTAssertTrue(sourceEditor.contains("MarkdownLineNumberRulerView"))
    }

    func testAppearanceToolbarUsesRealSubmenusAndShowsStyleShortcut() throws {
        let source = try workspaceSource()
        let utilitiesStart = try XCTUnwrap(
            source.range(of: "private struct ToolbarUtilities")
        )
        let utilitiesTail = source[utilitiesStart.lowerBound...]
        let utilitiesEnd = try XCTUnwrap(
            utilitiesTail.range(of: "private struct CustomStyleEditor")
        )
        let utilities = String(utilitiesTail[..<utilitiesEnd.lowerBound])

        XCTAssertTrue(utilities.contains("Label(\"Theme\""))
        XCTAssertTrue(utilities.contains("Label(\"Reading width\""))
        XCTAssertFalse(utilities.contains("Picker(\"Theme\""))
        XCTAssertFalse(utilities.contains("Picker(\"Reading width\""))
        XCTAssertTrue(
            utilities.contains(
                #".keyboardShortcut("t", modifiers: [.command, .option])"#
            )
        )

        let appSource = try previewMDAppSource()
        let shortcut = #".keyboardShortcut("t", modifiers: [.command, .option])"#
        let occurrences = (source + appSource).components(separatedBy: shortcut).count - 1
        XCTAssertEqual(occurrences, 1, "The shortcut must have one active menu owner")
    }

    private func workspaceSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/PreviewMD/WorkspaceView.swift")

        return try String(contentsOf: url, encoding: .utf8)
    }

    private func previewMDAppSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/PreviewMD/PreviewMDApp.swift")

        return try String(contentsOf: url, encoding: .utf8)
    }
}
#endif
