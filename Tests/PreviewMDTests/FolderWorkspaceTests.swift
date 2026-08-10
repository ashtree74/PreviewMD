#if canImport(XCTest)
import Combine
import Foundation
import XCTest
@testable import PreviewMD

@MainActor
final class FolderWorkspaceTests: XCTestCase {
    func testFolderTreeKeepsMarkdownHierarchyAndPrunesOtherFiles() throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }

        try write("# Root", to: root.appendingPathComponent("README.md"))
        try write("plain", to: root.appendingPathComponent("notes.txt"))
        try write("binary", to: root.appendingPathComponent("image.png"))
        try write("hidden", to: root.appendingPathComponent(".private.md"))

        let guides = root.appendingPathComponent("Guides", isDirectory: true)
        let empty = root.appendingPathComponent("Empty", isDirectory: true)
        try FileManager.default.createDirectory(at: guides, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try write("# Start", to: guides.appendingPathComponent("Start.markdown"))
        try write("ignore", to: empty.appendingPathComponent("data.json"))

        let items = try MarkdownFolderTree.contents(of: root)

        XCTAssertEqual(items.map(\.title), ["Guides", "notes.txt", "README.md"])
        XCTAssertEqual(items.first?.children?.map(\.title), ["Start.markdown"])
        XCTAssertNil(items[1].children)
        XCTAssertFalse(items.flatMap(\.childrenOrSelf).contains { $0.title == "image.png" })
        XCTAssertFalse(items.contains { $0.title == "Empty" })
        XCTAssertFalse(items.contains { $0.title == ".private.md" })
    }

    func testFolderTreeSortsDirectoriesBeforeDocuments() throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }

        let zebra = root.appendingPathComponent("Zebra", isDirectory: true)
        let alpha = root.appendingPathComponent("Alpha", isDirectory: true)
        try FileManager.default.createDirectory(at: zebra, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: alpha, withIntermediateDirectories: true)
        try write("# Z", to: zebra.appendingPathComponent("z.md"))
        try write("# A", to: alpha.appendingPathComponent("a.md"))
        try write("# B", to: root.appendingPathComponent("b.md"))
        try write("# A", to: root.appendingPathComponent("a.md"))

        let items = try MarkdownFolderTree.contents(of: root)

        XCTAssertEqual(items.map(\.title), ["Alpha", "Zebra", "a.md", "b.md"])
    }

    func testOpeningFolderLoadsTreeWithoutOpeningADocument() async throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("# Document", to: root.appendingPathComponent("document.md"))
        let state = try makeState()

        state.openFolder(url: root)
        for _ in 0..<100 where state.isWorkspaceFolderLoading {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(state.workspaceFolderURL, root.standardizedFileURL)
        XCTAssertEqual(state.workspaceFolderItems.map(\.title), ["document.md"])
        XCTAssertTrue(state.documents.isEmpty)
        XCTAssertNil(state.selectedDocumentID)

        state.closeWorkspaceFolder()
        XCTAssertNil(state.workspaceFolderURL)
        XCTAssertTrue(state.workspaceFolderItems.isEmpty)
    }

    func testUnchangedLiveFolderScanDoesNotRepublishAppState() async throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("# Document", to: root.appendingPathComponent("document.md"))
        let state = try makeState()

        state.openFolder(url: root)
        for _ in 0..<100 where state.isWorkspaceFolderLoading {
            try await Task.sleep(for: .milliseconds(10))
        }

        var publicationCount = 0
        let observation = state.objectWillChange.sink {
            publicationCount += 1
        }
        state.pollForExternalChanges(now: .distantFuture)
        try await Task.sleep(for: .milliseconds(150))

        withExtendedLifetime(observation) {
            XCTAssertEqual(
                publicationCount,
                0,
                "An unchanged background scan must not invalidate open menus"
            )
        }
    }

    private func makeFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreviewMD-folder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ contents: String, to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeState() throws -> AppState {
        let suiteName = "PreviewMDFolderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return AppState(defaults: defaults)
    }
}

private extension FolderTreeItem {
    var childrenOrSelf: [FolderTreeItem] {
        [self] + (children ?? []).flatMap(\.childrenOrSelf)
    }
}
#endif
