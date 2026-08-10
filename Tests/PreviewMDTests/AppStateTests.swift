#if canImport(XCTest)
import AppKit
import Combine
import Foundation
import XCTest
@testable import PreviewMD

@MainActor
final class AppStateTests: XCTestCase {
    func testFreshAppStartsWithAnEmptyWorkspace() throws {
        let state = try makeState()

        XCTAssertTrue(state.documents.isEmpty)
        XCTAssertNil(state.selectedDocumentID)
        XCTAssertNil(state.currentDocument)
        XCTAssertEqual(state.sidebarSelection, "")
    }

    func testNewDocumentIsExplicitAndUsesUniqueTitles() throws {
        let state = try makeState()

        state.newDocument()
        state.newDocument()

        XCTAssertEqual(state.documents.map(\.title), ["Untitled", "Untitled 2"])
        XCTAssertEqual(state.currentDocument?.title, "Untitled 2")
        XCTAssertNil(state.currentDocument?.url)
        XCTAssertFalse(state.currentDocument?.isDirty ?? true)
    }

    func testCleanDocumentAllowsTerminationWithoutPrompt() throws {
        let state = try makeState()
        state.newDocument()
        let prepared = expectation(description: "Prepared to terminate")

        state.prepareForTermination { shouldTerminate in
            XCTAssertTrue(shouldTerminate)
            prepared.fulfill()
        }

        wait(for: [prepared], timeout: 2)
    }

    func testClosingTheOnlyTabLeavesAnEmptyWorkspace() throws {
        let state = try makeState()
        state.openWelcome()
        let initialDocument = try XCTUnwrap(state.currentDocument)

        state.closeTab(initialDocument.id)

        XCTAssertTrue(state.documents.isEmpty)
        XCTAssertNil(state.selectedDocumentID)
        XCTAssertNil(state.currentDocument)
        XCTAssertEqual(state.sidebarSelection, "")
    }

    func testPaperCanvasDefaultsToHidden() throws {
        let state = try makeState()

        XCTAssertFalse(state.usesPaperCanvas)
    }

    func testReadingStyleDefaultsToModern() throws {
        let state = try makeState()

        XCTAssertEqual(state.readingStyle, .modern)
    }

    func testPreviewThemeControlsTheNativeInterfaceAppearance() {
        XCTAssertNil(PreviewTheme.system.preferredColorScheme)
        XCTAssertEqual(PreviewTheme.light.preferredColorScheme, .light)
        XCTAssertEqual(PreviewTheme.dark.preferredColorScheme, .dark)
    }

    func testReadingStylePersists() throws {
        let suiteName = "PreviewMDTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let state = AppState(defaults: defaults)
        state.readingStyle = .classic
        state.updatePreferences()

        let restoredState = AppState(defaults: defaults)
        XCTAssertEqual(restoredState.readingStyle, .classic)
    }

    func testShowcaseDocumentIsEmbeddedInTheExecutable() throws {
        let state = try makeState()

        state.openWelcome()

        let document = try XCTUnwrap(state.currentDocument)
        XCTAssertTrue(document.isSample)
        XCTAssertEqual(document.content, ShowcaseDocument.markdown)
        XCTAssertTrue(document.content.contains("```mermaid"))
        XCTAssertTrue(document.content.contains("| Native macOS shell |"))
    }

    func testCustomReadingWidthIsClamped() throws {
        let state = try makeState()

        state.setCustomReadingWidth(2_000)

        XCTAssertEqual(state.readingWidth, .custom)
        XCTAssertEqual(state.effectiveReadingWidth, 1_600)

        state.setCustomReadingWidth(400)

        XCTAssertEqual(state.effectiveReadingWidth, 560)
    }

    func testTableDataReadingWidthPresetUsesWideLayout() {
        XCTAssertEqual(ReadingWidth.data.cssValue, 1_440)
    }

    func testDropFilterAcceptsOnlySupportedLocalFiles() {
        XCTAssertTrue(
            MarkdownFileSupport.accepts(URL(fileURLWithPath: "/tmp/readme.md"))
        )
        XCTAssertTrue(
            MarkdownFileSupport.accepts(URL(fileURLWithPath: "/tmp/notes.MARKDOWN"))
        )
        XCTAssertFalse(
            MarkdownFileSupport.accepts(URL(fileURLWithPath: "/tmp/archive.pdf"))
        )
        XCTAssertFalse(
            MarkdownFileSupport.accepts(URL(string: "https://example.com/readme.md")!)
        )
        XCTAssertEqual(
            MarkdownDefaultApplication.commonMarkdownType.identifier,
            "net.daringfireball.markdown"
        )
    }

    func testContentRevisionChangesOnlyWhenContentChanges() throws {
        let state = try makeState()
        state.openWelcome()
        let document = try XCTUnwrap(state.currentDocument)

        state.updateContent(document.content, for: document.id)
        XCTAssertEqual(state.currentDocument?.contentRevision, 0)

        state.updateContent(document.content + "\nNew text", for: document.id)
        XCTAssertEqual(state.currentDocument?.contentRevision, 1)
        XCTAssertTrue(state.currentDocument?.isDirty == true)
    }

    func testUndoRedoUsesDocumentHistory() throws {
        let state = try makeState()
        state.openWelcome()
        let document = try XCTUnwrap(state.currentDocument)
        let original = document.content

        state.updateContent(
            "First",
            for: document.id,
            origin: .richEditor,
            startsNewUndoGroup: true
        )
        state.updateContent(
            "Second",
            for: document.id,
            origin: .richEditor,
            startsNewUndoGroup: true
        )
        state.undoCurrent()
        XCTAssertEqual(state.currentDocument?.content, "First")
        state.undoCurrent()
        XCTAssertEqual(state.currentDocument?.content, original)

        state.redoCurrent()
        XCTAssertEqual(state.currentDocument?.content, "First")
        state.redoCurrent()
        XCTAssertEqual(state.currentDocument?.content, "Second")
    }

    func testSourceTypingCoalescesIntoOneUndoStep() throws {
        let state = try makeState()
        state.newDocument()
        let document = try XCTUnwrap(state.currentDocument)

        state.updateContent("a", for: document.id, origin: .source)
        state.updateContent("ab", for: document.id, origin: .source)
        state.updateContent("abc", for: document.id, origin: .source)
        state.undoCurrent()

        XCTAssertEqual(state.currentDocument?.content, "")
    }

    func testOpeningAndSavingPreservesUTF8BOMAndCRLF() throws {
        let state = try makeState()
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreviewMD-format-\(UUID().uuidString).md")
        var original = Data([0xEF, 0xBB, 0xBF])
        original.append(Data("# Heading\r\n\r\nOriginal\r\n".utf8))
        try original.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        state.open(url: fileURL)
        let document = try XCTUnwrap(state.currentDocument)
        XCTAssertEqual(document.content, "# Heading\n\nOriginal\n")
        XCTAssertEqual(document.fileFormat.lineEnding, .carriageReturnLineFeed)
        XCTAssertTrue(document.fileFormat.hasUTF8ByteOrderMark)

        state.updateContent("# Heading\n\nEdited\n", for: document.id)
        let saved = expectation(description: "Saved")
        state.saveCurrent { success in
            XCTAssertTrue(success)
            saved.fulfill()
        }
        wait(for: [saved], timeout: 2)

        let result = try Data(contentsOf: fileURL)
        XCTAssertTrue(result.starts(with: [0xEF, 0xBB, 0xBF]))
        XCTAssertEqual(
            String(data: result.dropFirst(3), encoding: .utf8),
            "# Heading\r\n\r\nEdited\r\n"
        )
        XCTAssertFalse(state.currentDocument?.isDirty ?? true)

        state.updateContent("# Heading\n\nEdited twice\n", for: document.id)
        let savedAgain = expectation(description: "Saved again")
        state.saveCurrent { success in
            XCTAssertTrue(success)
            savedAgain.fulfill()
        }
        wait(for: [savedAgain], timeout: 2)

        let secondResult = try Data(contentsOf: fileURL)
        XCTAssertEqual(
            String(data: secondResult.dropFirst(3), encoding: .utf8),
            "# Heading\r\n\r\nEdited twice\r\n"
        )
    }

    func testReopeningClosedTabReadsTheCurrentDiskVersion() throws {
        let state = try makeState()
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreviewMD-reopen-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try "# Old version\n".write(to: fileURL, atomically: true, encoding: .utf8)

        state.open(url: fileURL)
        let firstID = try XCTUnwrap(state.currentDocument?.id)
        state.closeTab(firstID)
        try "# Changed outside PreviewMD\n".write(
            to: fileURL,
            atomically: true,
            encoding: .utf8
        )
        state.open(url: fileURL)

        XCTAssertNotEqual(state.currentDocument?.id, firstID)
        XCTAssertEqual(state.currentDocument?.content, "# Changed outside PreviewMD\n")
    }

    func testLiveReloadUpdatesCleanOpenDocument() throws {
        let state = try makeState()
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreviewMD-live-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try "First\n".write(to: fileURL, atomically: true, encoding: .utf8)
        state.open(url: fileURL)

        try "Written by another tool\n".write(to: fileURL, atomically: true, encoding: .utf8)
        state.pollForExternalChanges()

        XCTAssertEqual(state.currentDocument?.content, "Written by another tool\n")
        XCTAssertFalse(state.currentDocument?.hasExternalChanges ?? true)
    }

    func testLiveReloadNeverOverwritesUnsavedLocalChanges() throws {
        let state = try makeState()
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreviewMD-live-conflict-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try "Saved\n".write(to: fileURL, atomically: true, encoding: .utf8)
        state.open(url: fileURL)
        let document = try XCTUnwrap(state.currentDocument)
        state.updateContent("Local edit\n", for: document.id, origin: .source)

        try "External edit\n".write(to: fileURL, atomically: true, encoding: .utf8)
        state.pollForExternalChanges()

        XCTAssertEqual(state.currentDocument?.content, "Local edit\n")
        XCTAssertTrue(state.currentDocument?.hasExternalChanges == true)

        var publicationCount = 0
        let observation = state.objectWillChange.sink {
            publicationCount += 1
        }
        state.pollForExternalChanges()
        withExtendedLifetime(observation) {
            XCTAssertEqual(
                publicationCount,
                0,
                "An already-reported conflict must not invalidate open menus again"
            )
        }
    }

    func testFullWidthAndNamedCustomStylePersist() throws {
        let suiteName = "PreviewMDTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = AppState(defaults: defaults)
        var preset = CustomReadingPreset.starter
        preset.name = "RFP"

        state.readingWidth = .fullWidth
        state.saveCustomPreset(preset)
        state.updatePreferences()

        let restored = AppState(defaults: defaults)
        XCTAssertEqual(restored.readingWidth, .fullWidth)
        XCTAssertEqual(restored.readingStyle, .custom)
        XCTAssertEqual(restored.activeCustomReadingPreset?.name, "RFP")
    }

    func testEachNewCustomStyleGetsAUniqueIdentifier() throws {
        let state = try makeState()
        var first = CustomReadingPreset.starter
        first.name = "First"
        var second = CustomReadingPreset.starter
        second.name = "Second"

        XCTAssertNotEqual(first.id, second.id)

        state.saveCustomPreset(first)
        state.saveCustomPreset(second)

        XCTAssertEqual(state.customReadingPresets.map(\.name), ["First", "Second"])
    }

    func testReadingStyleShortcutCyclesWithoutAnOpenDocument() throws {
        let state = try makeState()
        XCTAssertNil(state.currentDocument)

        state.readingStyle = .modern
        state.cycleReadingStyle()
        XCTAssertEqual(state.readingStyle, .classic)
        state.cycleReadingStyle()
        XCTAssertEqual(state.readingStyle, .editorial)
        state.cycleReadingStyle()
        XCTAssertEqual(state.readingStyle, .modern)
    }

    func testPDFPageFormatsUsePhysicalPageDimensions() {
        let options = PDFExportOptions(
            pageFormat: .letter,
            orientation: .landscape,
            theme: .dark,
            style: .editorial,
            margins: .generous,
            customPreset: nil
        )

        XCTAssertEqual(options.printInfo.paperSize.width, 792, accuracy: 0.01)
        XCTAssertEqual(options.printInfo.paperSize.height, 612, accuracy: 0.01)
        XCTAssertEqual(options.printInfo.orientation, .landscape)
        XCTAssertEqual(options.printInfo.leftMargin, 58)
    }

    func testPDFStyleChoiceCanSelectAnySavedCustomPreset() {
        var first = CustomReadingPreset.starter
        first.name = "First"
        var second = CustomReadingPreset.starter
        second.name = "Second"

        let selection = PDFReadingStyleChoice.resolve(
            PDFReadingStyleChoice.key(for: second.id),
            customPresets: [first, second]
        )

        XCTAssertEqual(selection.style, .custom)
        XCTAssertEqual(selection.customPreset?.id, second.id)
        XCTAssertEqual(selection.customPreset?.name, "Second")
    }

    func testRendererShellStartsWithCurrentAppearance() {
        let payload = MarkdownWebView.RenderPayload(
            documentID: UUID().uuidString,
            markdown: "# Current settings",
            revision: 0,
            editable: true,
            theme: PreviewTheme.dark.rawValue,
            readingStyle: ReadingStyle.classic.rawValue,
            customReadingPreset: nil,
            systemDark: false,
            readingWidth: 1_440,
            readingWidthIsFluid: false,
            paperCanvas: false,
            zoom: 1.2,
            searchText: "",
            outlineTarget: nil,
            topInset: 0
        )

        let html = RendererAssets.shellHTML(for: payload)

        XCTAssertTrue(
            html.contains(
                #"<html lang="en" data-theme="dark" data-style="classic" data-paper="false" data-width="fixed" style="--reading-width: 1440px; --top-inset: 0.0px;">"#
            )
        )
    }

    func testSwitchingDocumentForcesRenderEvenWhenMarkdownMatches() {
        let first = MarkdownWebView.RenderPayload(
            documentID: UUID().uuidString,
            markdown: "Same contents",
            revision: 0,
            editable: true,
            theme: PreviewTheme.light.rawValue,
            readingStyle: ReadingStyle.modern.rawValue,
            customReadingPreset: nil,
            systemDark: false,
            readingWidth: 820,
            readingWidthIsFluid: false,
            paperCanvas: false,
            zoom: 1,
            searchText: "",
            outlineTarget: nil,
            topInset: 0
        )
        let reopened = MarkdownWebView.RenderPayload(
            documentID: UUID().uuidString,
            markdown: first.markdown,
            revision: first.revision,
            editable: first.editable,
            theme: first.theme,
            readingStyle: first.readingStyle,
            customReadingPreset: first.customReadingPreset,
            systemDark: first.systemDark,
            readingWidth: first.readingWidth,
            readingWidthIsFluid: first.readingWidthIsFluid,
            paperCanvas: first.paperCanvas,
            zoom: first.zoom,
            searchText: first.searchText,
            outlineTarget: first.outlineTarget,
            topInset: first.topInset
        )

        XCTAssertTrue(reopened.requiresFullRender(comparedTo: first))
    }

    func testDockOpenRequestWaitsForAppState() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreviewMD-\(UUID().uuidString).md")
        try "# Opened from Dock".write(to: fileURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let delegate = AppDelegate()
        delegate.application(NSApplication.shared, open: [fileURL])

        let state = try makeState()
        delegate.state = state

        XCTAssertEqual(state.currentDocument?.url?.standardizedFileURL, fileURL.standardizedFileURL)
        XCTAssertEqual(state.currentDocument?.content, "# Opened from Dock")
    }

    func testFocusModeNeedsSomethingToRead() throws {
        let state = try makeState()

        XCTAssertFalse(state.canEnterFocusMode)
        state.enterFocusMode()

        XCTAssertFalse(state.isFocusMode)
    }

    func testFocusModeReadsInPreviewAndGivesTheModeBack() throws {
        let state = try makeState()
        state.openWelcome()
        state.displayMode = .split
        state.isInspectorVisible = true

        state.enterFocusMode()

        XCTAssertTrue(state.isFocusMode)
        XCTAssertEqual(state.displayMode, .preview, "focus mode is for reading")
        XCTAssertFalse(state.isInspectorVisible)

        state.exitFocusMode()

        XCTAssertFalse(state.isFocusMode)
        XCTAssertEqual(state.displayMode, .split, "the mode being left behind should come back")
        XCTAssertTrue(state.isInspectorVisible, "the inspector should return after focus mode")
    }

    func testFocusModeTogglesAndDoesNotStackRestoreState() throws {
        let state = try makeState()
        state.openWelcome()
        state.displayMode = .source

        state.toggleFocusMode()
        // A second enter while already focused must not overwrite the saved mode
        // with `.preview`, which would strand the reader in it on exit.
        state.enterFocusMode()
        state.toggleFocusMode()

        XCTAssertFalse(state.isFocusMode)
        XCTAssertEqual(state.displayMode, .source)
    }

    func testClosingTheLastTabLeavesFocusMode() throws {
        let state = try makeState()
        state.openWelcome()
        state.isInspectorVisible = true
        state.enterFocusMode()
        let document = try XCTUnwrap(state.currentDocument)

        state.closeTab(document.id)

        XCTAssertTrue(state.documents.isEmpty)
        XCTAssertFalse(state.isFocusMode, "focus mode hides the chrome needed to open anything")
        XCTAssertFalse(state.isInspectorVisible, "the empty workspace must not retain an inspector")
    }

    private func makeState() throws -> AppState {
        let suiteName = "PreviewMDTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return AppState(defaults: defaults)
    }
}
#endif
