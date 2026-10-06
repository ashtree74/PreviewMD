#if canImport(XCTest)
import AppKit
import Combine
import Foundation
import XCTest
@testable import PreviewMD

@MainActor
final class DocumentStateRegressionTests: XCTestCase {
    func testAtomicSavePreservesSymbolicLinkAndUpdatesItsTarget() throws {
        let root = try makeFolder()
        let target = try makeFile("target.md", content: "original\n", in: root)
        let link = root.appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let original = try MarkdownFileIO.read(from: link)

        let snapshot = try MarkdownFileIO.write("edited\n", to: link, format: original.format)

        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "edited\n")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
        XCTAssertEqual(snapshot.fingerprint, try FileSnapshot.capture(url: target).fingerprint)
    }

    func testOpeningTargetAndLinkUsesOneEditableDocumentAndSavesWithoutConflict() async throws {
        let root = try makeFolder()
        let target = try makeFile("target.md", content: "original\n", in: root)
        let link = root.appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        var errors: [String] = []
        let state = try makeState(errorPresenter: { errors.append($0) })
        state.open(url: link)
        let id = try XCTUnwrap(state.currentDocument?.id)
        state.open(url: target)
        XCTAssertEqual(state.documents.count, 1)
        XCTAssertEqual(state.currentDocument?.id, id)

        state.updateContent("edited\n", for: id, origin: .source)
        let saved = await saveCurrent(state)
        XCTAssertTrue(saved)
        await state.pollForExternalChanges()

        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "edited\n")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
        XCTAssertFalse(state.currentDocument?.hasExternalChanges ?? true)
        XCTAssertTrue(errors.isEmpty)
    }

    func testSaveAsToAlreadyOpenCleanTargetMergesItsTabAndPreservesLink() async throws {
        let root = try makeFolder()
        let source = try makeFile("source.md", content: "source\n", in: root)
        let target = try makeFile("target.md", content: "target\n", in: root)
        let link = root.appendingPathComponent("alias.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let state = try makeState(saveDestination: { _ in link })
        state.open(url: source)
        let id = try XCTUnwrap(state.currentDocument?.id)
        state.open(url: target)
        state.select(documentID: id)
        state.updateContent("replacement\n", for: id, origin: .source)

        let saved = await saveAs(state)

        XCTAssertTrue(saved)
        XCTAssertEqual(state.documents.count, 1)
        XCTAssertEqual(state.currentDocument?.id, id)
        XCTAssertEqual(state.currentDocument?.url, MarkdownFileIO.canonicalURL(for: target))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "replacement\n")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
    }

    func testSaveAsDoesNotReplaceAnotherTabsUnsavedChanges() async throws {
        let root = try makeFolder()
        let source = try makeFile("source.md", content: "source\n", in: root)
        let target = try makeFile("target.md", content: "target\n", in: root)
        var errors: [String] = []
        let state = try makeState(saveDestination: { _ in target }, errorPresenter: { errors.append($0) })
        state.open(url: source)
        let sourceID = try XCTUnwrap(state.currentDocument?.id)
        state.open(url: target)
        let targetID = try XCTUnwrap(state.currentDocument?.id)
        state.updateContent("unsaved target\n", for: targetID, origin: .source)
        state.select(documentID: sourceID)
        state.updateContent("replacement\n", for: sourceID, origin: .source)

        let saved = await saveAs(state)

        XCTAssertFalse(saved)
        XCTAssertEqual(state.documents.count, 2)
        XCTAssertEqual(state.documents.first(where: { $0.id == targetID })?.content, "unsaved target\n")
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "target\n")
        XCTAssertEqual(state.currentDocument?.url, MarkdownFileIO.canonicalURL(for: source))
        XCTAssertEqual(errors.count, 1)
    }

    func testDiscardingTabRemovesItsUnsavedContentFromFolderSearch() async throws {
        let root = try makeFolder()
        let file = try makeFile("note.md", content: "alpha\n", in: root)
        let state = try makeState(closeTabDecision: { _ in .discard })
        await openFolder(root, in: state)
        state.open(url: file)
        let id = try XCTUnwrap(state.currentDocument?.id)
        state.updateContent("beta\n", for: id, origin: .source)
        await search("beta", in: state)
        XCTAssertEqual(state.workspaceSearchResults.count, 1)

        state.closeTab(id)
        await waitFor { !state.isWorkspaceSearching }

        XCTAssertTrue(state.workspaceSearchResults.isEmpty)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "alpha\n")
    }

    func testSaveAsOutsideWorkspaceRemovesOldFilesContentOverride() async throws {
        let root = try makeFolder()
        let workspace = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let old = try makeFile("note.md", content: "alpha\n", in: workspace)
        let destination = root.appendingPathComponent("outside.md")
        let state = try makeState(saveDestination: { _ in destination })
        await openFolder(workspace, in: state)
        state.open(url: old)
        let id = try XCTUnwrap(state.currentDocument?.id)
        state.updateContent("beta\n", for: id, origin: .source)
        await search("beta", in: state)
        XCTAssertEqual(state.workspaceSearchResults.count, 1)

        let saved = await saveAs(state)
        await waitFor { !state.isWorkspaceSearching }

        XCTAssertTrue(saved)
        XCTAssertTrue(state.workspaceSearchResults.isEmpty)
        XCTAssertEqual(try String(contentsOf: old, encoding: .utf8), "alpha\n")
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "beta\n")
    }

    func testReloadRefreshesFolderSearchContentOverrideImmediately() async throws {
        let root = try makeFolder()
        let file = try makeFile("note.md", content: "alpha\n", in: root)
        let state = try makeState()
        await openFolder(root, in: state)
        state.open(url: file)
        await search("alpha", in: state)
        XCTAssertEqual(state.workspaceSearchResults.count, 1)
        try "beta\n".write(to: file, atomically: true, encoding: .utf8)

        state.reloadCurrent()
        await waitFor { !state.isWorkspaceSearching }

        XCTAssertEqual(state.currentDocument?.content, "beta\n")
        XCTAssertTrue(state.workspaceSearchResults.isEmpty)
    }

    func testWorkspaceSearchUsesUnsavedContentsOfFileOpenedThroughSymlink() async throws {
        let root = try makeFolder()
        let workspace = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let target = try makeFile("target.md", content: "alpha\n", in: root)
        let link = workspace.appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let state = try makeState()
        await openFolder(workspace, in: state)
        state.open(url: link)
        state.updateContent("beta\n", for: try XCTUnwrap(state.currentDocument?.id), origin: .source)

        await search("beta", in: state)

        XCTAssertEqual(state.workspaceSearchResults.first?.url.standardizedFileURL, link.standardizedFileURL)
        XCTAssertEqual(state.workspaceSearchResults.first?.snippet, "beta")
    }

    func testMissingWorkspaceReportsNonmodalErrorOnceAndRecovers() async throws {
        let root = try makeFolder()
        _ = try makeFile("note.md", content: "note\n", in: root)
        var errors: [String] = []
        let state = try makeState(errorPresenter: { errors.append($0) })
        await openFolder(root, in: state)
        try FileManager.default.removeItem(at: root)

        await state.pollForExternalChanges(now: Date().addingTimeInterval(10))
        await waitFor { state.workspaceFolderError != nil }
        XCTAssertTrue(errors.isEmpty)
        XCTAssertTrue(state.workspaceFolderItems.isEmpty)
        XCTAssertNotNil(state.workspaceFolderURL)

        var publicationCount = 0
        let observation = state.objectWillChange.sink { publicationCount += 1 }
        await state.pollForExternalChanges(now: Date().addingTimeInterval(20))
        try await Task.sleep(for: .milliseconds(150))
        withExtendedLifetime(observation) {
            XCTAssertEqual(publicationCount, 0)
        }
        XCTAssertTrue(errors.isEmpty)

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try makeFile("restored.md", content: "restored\n", in: root)
        state.refreshWorkspaceFolder()
        await waitFor { !state.isWorkspaceFolderLoading }
        XCTAssertNil(state.workspaceFolderError)
        XCTAssertEqual(state.workspaceFolderItems.map(\.title), ["restored.md"])
    }

    func testInvalidExternalUTF8DoesNotTriggerRepeatingModalAndRecoveryClearsConflict() async throws {
        let root = try makeFolder()
        let file = try makeFile("note.md", content: "saved\n", in: root)
        var errors: [String] = []
        let state = try makeState(errorPresenter: { errors.append($0) })
        state.open(url: file)
        try Data([0xFF]).write(to: file)

        await state.pollForExternalChanges()
        await state.pollForExternalChanges()

        XCTAssertEqual(state.currentDocument?.content, "saved\n")
        XCTAssertTrue(state.currentDocument?.hasExternalChanges == true)
        XCTAssertTrue(errors.isEmpty)
        try "saved\n".write(to: file, atomically: true, encoding: .utf8)
        await state.pollForExternalChanges()
        XCTAssertFalse(state.currentDocument?.hasExternalChanges ?? true)
    }

    func testPollingReadsOffMainThreadAndDoesNotOverwriteAnEditDuringTheRead() async throws {
        let root = try makeFolder()
        let file = try makeFile("note.md", content: "saved\n", in: root)
        let gate = PollReadGate()
        let state = try makeState(externalPollData: { try gate.read($0) })
        state.open(url: file)
        let id = try XCTUnwrap(state.currentDocument?.id)
        try "external\n".write(to: file, atomically: true, encoding: .utf8)
        let poll = Task { await state.pollForExternalChanges() }
        let started = await Task.detached { gate.waitUntilReadStarted() }.value
        XCTAssertTrue(started)

        await state.pollForExternalChanges()
        XCTAssertEqual(gate.readCount, 1, "A second polling pass must not start while the first read is pending")

        state.updateContent("local edit\n", for: id, origin: .source)
        gate.release.signal()
        await poll.value

        XCTAssertFalse(gate.wasReadOnMainThread)
        XCTAssertEqual(state.currentDocument?.content, "local edit\n")
        XCTAssertEqual(state.currentDocument?.lastSavedContent, "saved\n")
        XCTAssertTrue(state.currentDocument?.isDirty == true)
    }

    func testPendingPollCannotReloadTheOldFileAfterSaveAsChangesLocation() async throws {
        let root = try makeFolder()
        let original = try makeFile("original.md", content: "saved\n", in: root)
        let destination = root.appendingPathComponent("copy.md")
        let gate = PollReadGate()
        let state = try makeState(saveDestination: { _ in destination }, externalPollData: { try gate.read($0) })
        state.open(url: original)
        try "external\n".write(to: original, atomically: true, encoding: .utf8)
        let poll = Task { await state.pollForExternalChanges() }
        let started = await Task.detached { gate.waitUntilReadStarted() }.value
        XCTAssertTrue(started)

        let saved = await saveAs(state)
        gate.release.signal()
        await poll.value

        XCTAssertTrue(saved)
        XCTAssertEqual(state.currentDocument?.url, MarkdownFileIO.canonicalURL(for: destination))
        XCTAssertEqual(state.currentDocument?.content, "saved\n")
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "saved\n")
        XCTAssertFalse(state.currentDocument?.isDirty ?? true)
    }

    private func makeFolder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PreviewMD-state-regression-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func makeFile(_ name: String, content: String, in root: URL) throws -> URL {
        let file = root.appendingPathComponent(name)
        try content.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private func makeState(
        closeTabDecision: ((MarkdownDocument) -> TabCloseDecision)? = nil,
        saveDestination: ((MarkdownDocument) -> URL?)? = nil,
        errorPresenter: ((String) -> Void)? = nil,
        externalPollData: @escaping @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) }
    ) throws -> AppState {
        let suite = "PreviewMDStateRegression.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return AppState(
            defaults: defaults,
            closeTabDecision: closeTabDecision,
            saveDestination: saveDestination,
            errorPresenter: errorPresenter,
            externalPollData: externalPollData
        )
    }

    private func openFolder(_ root: URL, in state: AppState) async {
        state.openFolder(url: root)
        await waitFor { !state.isWorkspaceFolderLoading }
    }

    private func search(_ query: String, in state: AppState) async {
        state.setWorkspaceSearchQuery(query, immediately: true)
        await waitFor { !state.isWorkspaceSearching }
    }

    private func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for the asynchronous document state")
    }

    private func saveCurrent(_ state: AppState) async -> Bool {
        await withCheckedContinuation { continuation in
            state.saveCurrent { continuation.resume(returning: $0) }
        }
    }

    private func saveAs(_ state: AppState) async -> Bool {
        await withCheckedContinuation { continuation in
            state.saveCurrentAs { continuation.resume(returning: $0) }
        }
    }
}

private final class PollReadGate: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var readOnMainThread = false
    private var reads = 0

    var wasReadOnMainThread: Bool {
        lock.withLock { readOnMainThread }
    }

    var readCount: Int {
        lock.withLock { reads }
    }

    func waitUntilReadStarted() -> Bool {
        entered.wait(timeout: .now() + 3) == .success
    }

    func read(_ url: URL) throws -> Data {
        lock.withLock {
            readOnMainThread = Thread.isMainThread
            reads += 1
        }
        entered.signal()
        guard release.wait(timeout: .now() + 3) == .success else {
            throw CocoaError(.fileReadUnknown)
        }
        return try Data(contentsOf: url)
    }
}
#endif
