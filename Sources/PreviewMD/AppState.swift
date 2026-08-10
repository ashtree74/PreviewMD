import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppState: ObservableObject {
    @Published var documents: [MarkdownDocument] = []
    @Published var selectedDocumentID: UUID?
    @Published var recentDocuments: [RecentDocument] = []
    @Published var displayMode: DisplayMode = .preview
    @Published var theme: PreviewTheme = .system
    @Published var readingStyle: ReadingStyle = .modern
    @Published var customReadingPresets: [CustomReadingPreset] = []
    @Published var selectedCustomPresetID: UUID?
    @Published var editingCustomPreset: CustomReadingPreset?
    @Published var readingWidth: ReadingWidth = .comfortable
    @Published var customReadingWidth: Double = 820
    @Published var usesPaperCanvas = false
    @Published var isInspectorVisible = false
    /// Distraction-free reading: every piece of chrome is hidden except the
    /// document column and the reading-width ruler. Deliberately not persisted —
    /// it is a thing you do to a session, not a preference.
    @Published private(set) var isFocusMode = false
    @Published var searchText = ""
    @Published var zoom: Double = 1
    @Published var outlineTarget: String?
    @Published var searchFieldFocusToken = UUID()
    @Published var sidebarSelection = ""
    @Published var sidebarMode: SidebarMode = .recent
    @Published var workspaceFileSort: WorkspaceFileSort = .name
    @Published var workspaceSortAscending = true
    @Published var liveReloadEnabled = true
    @Published var errorMessage: String?
    @Published private(set) var workspaceFolderURL: URL?
    @Published private(set) var workspaceFolderItems: [FolderTreeItem] = []
    @Published private(set) var isWorkspaceFolderLoading = false

    let rendererController = RendererController()

    private let defaults: UserDefaults
    private let recentKey = "recentDocuments.v1"
    private let themeKey = "previewTheme"
    private let styleKey = "readingStyle"
    private let customStylesKey = "customReadingPresets.v1"
    private let selectedCustomStyleKey = "selectedCustomReadingPreset"
    private let widthKey = "readingWidth"
    private let customWidthKey = "customReadingWidth"
    private let paperKey = "usesPaperCanvas"
    private let liveReloadKey = "liveReloadEnabled"
    private var workspaceFolderRequestID = UUID()
    private var workspaceFolderLoadTask: Task<Void, Never>?
    private var lastWorkspaceLiveRefresh = Date.distantPast

    /// Restored when focus mode ends, so entering it to read does not quietly
    /// throw away the split/source view or inspector you were working with.
    private var displayModeBeforeFocus: DisplayMode?
    private var inspectorVisibilityBeforeFocus: Bool?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loadPreferences()
        loadRecentDocuments()
        startLiveReloadPolling()
    }

    var currentDocumentIndex: Int? {
        guard let selectedDocumentID else { return nil }
        return documents.firstIndex { $0.id == selectedDocumentID }
    }

    var currentDocument: MarkdownDocument? {
        guard let currentDocumentIndex else { return nil }
        return documents[currentDocumentIndex]
    }

    var currentOutline: [OutlineHeading] {
        guard let currentDocument else { return [] }
        return MarkdownOutline.headings(in: currentDocument.content)
    }

    var effectiveReadingWidth: Int {
        if readingWidth == .custom {
            return Int(customReadingWidth.rounded())
        }
        return readingWidth.cssValue
    }

    var activeCustomReadingPreset: CustomReadingPreset? {
        guard readingStyle == .custom else { return nil }
        if let selectedCustomPresetID,
           let preset = customReadingPresets.first(where: { $0.id == selectedCustomPresetID }) {
            return preset.normalized
        }
        return customReadingPresets.first?.normalized
    }

    var workspaceFiles: [FolderTreeItem] {
        let files = workspaceFolderItems.flatMap(\.flattenedFiles)
        return files.sorted { lhs, rhs in
            let result: ComparisonResult
            switch workspaceFileSort {
            case .name:
                result = lhs.title.localizedStandardCompare(rhs.title)
            case .modified:
                let left = lhs.modificationDate ?? .distantPast
                let right = rhs.modificationDate ?? .distantPast
                if left == right {
                    result = lhs.title.localizedStandardCompare(rhs.title)
                } else {
                    result = left < right ? .orderedAscending : .orderedDescending
                }
            }
            return workspaceSortAscending
                ? result == .orderedAscending
                : result == .orderedDescending
        }
    }

    func bindingForCurrentContent() -> Binding<String> {
        Binding(
            get: { [weak self] in
                self?.currentDocument?.content ?? ""
            },
            set: { [weak self] newValue in
                guard let self, let documentID = self.selectedDocumentID else { return }
                self.updateContent(newValue, for: documentID, origin: .source)
            }
        )
    }

    func updateContent(
        _ content: String,
        for documentID: UUID,
        origin: DocumentEditOrigin = .richEditor,
        startsNewUndoGroup: Bool = false
    ) {
        guard let index = documents.firstIndex(where: { $0.id == documentID }),
              documents[index].content != content
        else { return }

        let now = Date()
        let coalescesTyping =
            !startsNewUndoGroup
            && documents[index].lastEditOrigin == origin
            && now.timeIntervalSince(documents[index].lastEditAt ?? .distantPast) < 0.8

        if !coalescesTyping {
            documents[index].undoHistory.append(documents[index].content)
            if documents[index].undoHistory.count > 100 {
                documents[index].undoHistory.removeFirst(
                    documents[index].undoHistory.count - 100
                )
            }
        }
        documents[index].redoHistory.removeAll()
        documents[index].content = content
        documents[index].contentRevision &+= 1
        documents[index].lastEditOrigin = origin
        documents[index].lastEditAt = now
    }

    var canUndoCurrent: Bool {
        currentDocument?.undoHistory.isEmpty == false
    }

    var canRedoCurrent: Bool {
        currentDocument?.redoHistory.isEmpty == false
    }

    func undoCurrent() {
        guard let index = currentDocumentIndex,
              let previous = documents[index].undoHistory.popLast()
        else { return }

        documents[index].redoHistory.append(documents[index].content)
        documents[index].content = previous
        documents[index].contentRevision &+= 1
        documents[index].lastEditOrigin = nil
        documents[index].lastEditAt = nil
    }

    func redoCurrent() {
        guard let index = currentDocumentIndex,
              let next = documents[index].redoHistory.popLast()
        else { return }

        documents[index].undoHistory.append(documents[index].content)
        documents[index].content = next
        documents[index].contentRevision &+= 1
        documents[index].lastEditOrigin = nil
        documents[index].lastEditAt = nil
    }

    func openWelcome() {
        if let existing = documents.first(where: { $0.isSample }) {
            selectedDocumentID = existing.id
            sidebarSelection = "welcome"
            return
        }

        let content = ShowcaseDocument.markdown
        let document = MarkdownDocument(
            id: UUID(),
            url: nil,
            title: "Welcome to PreviewMD",
            content: content,
            lastSavedContent: content,
            openedAt: Date(),
            fileModifiedAt: nil,
            isPinned: true,
            isSample: true
        )
        documents.insert(document, at: 0)
        selectedDocumentID = document.id
        sidebarSelection = "welcome"
    }

    func newDocument() {
        let existingTitles = Set(documents.map(\.title))
        var title = "Untitled"
        var suffix = 2
        while existingTitles.contains(title) {
            title = "Untitled \(suffix)"
            suffix += 1
        }

        let document = MarkdownDocument(
            id: UUID(),
            url: nil,
            title: title,
            content: "",
            lastSavedContent: "",
            openedAt: Date(),
            fileModifiedAt: nil,
            isPinned: false,
            isSample: false
        )
        documents.append(document)
        selectedDocumentID = document.id
        sidebarSelection = ""
        searchText = ""
    }

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.title = "Open Markdown"
        panel.prompt = "Open"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = Self.markdownContentTypes
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            panel.urls.forEach { self?.open(url: $0) }
        }
    }

    func presentFolderOpenPanel() {
        let panel = NSOpenPanel()
        panel.title = "Open Folder"
        panel.prompt = "Open"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.folder]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.openFolder(url: url)
        }
    }

    func openFolder(url: URL) {
        sidebarMode = .tree
        loadFolder(at: url.standardizedFileURL, clearsExistingItems: true)
    }

    func refreshWorkspaceFolder() {
        guard let workspaceFolderURL else { return }
        loadFolder(at: workspaceFolderURL, clearsExistingItems: false)
    }

    func closeWorkspaceFolder() {
        workspaceFolderLoadTask?.cancel()
        workspaceFolderLoadTask = nil
        workspaceFolderRequestID = UUID()
        workspaceFolderURL = nil
        workspaceFolderItems = []
        isWorkspaceFolderLoading = false
        sidebarMode = .recent
    }

    private func loadFolder(
        at url: URL,
        clearsExistingItems: Bool,
        showsLoading: Bool = true
    ) {
        var isDirectory: ObjCBool = false
        guard url.isFileURL,
              FileManager.default.fileExists(
                atPath: url.path,
                isDirectory: &isDirectory
              ),
              isDirectory.boolValue
        else {
            present(error: "Couldn’t open “\(url.lastPathComponent)” as a folder.")
            return
        }

        let requestID = UUID()
        workspaceFolderLoadTask?.cancel()
        workspaceFolderRequestID = requestID
        // Silent live scans run every two seconds. Reassigning the same
        // @Published URL still emits objectWillChange, which causes SwiftUI to
        // rebuild any open native menus and detach their submenus.
        if workspaceFolderURL != url {
            workspaceFolderURL = url
        }
        if clearsExistingItems {
            workspaceFolderItems = []
        }
        if showsLoading {
            isWorkspaceFolderLoading = true
        }

        workspaceFolderLoadTask = Task { [weak self] in
            let scanTask = Task.detached(priority: .userInitiated) {
                try MarkdownFolderTree.contents(of: url)
            }
            await withTaskCancellationHandler {
                do {
                    let items = try await scanTask.value
                    guard let self,
                          self.workspaceFolderRequestID == requestID,
                          self.workspaceFolderURL == url
                    else { return }
                    if self.workspaceFolderItems != items {
                        self.workspaceFolderItems = items
                    }
                    if showsLoading {
                        self.isWorkspaceFolderLoading = false
                    }
                    self.workspaceFolderLoadTask = nil
                } catch is CancellationError {
                    guard let self, self.workspaceFolderRequestID == requestID else { return }
                    if showsLoading {
                        self.isWorkspaceFolderLoading = false
                    }
                    self.workspaceFolderLoadTask = nil
                } catch {
                    guard let self, self.workspaceFolderRequestID == requestID else { return }
                    if showsLoading {
                        self.isWorkspaceFolderLoading = false
                    }
                    self.workspaceFolderLoadTask = nil
                    if showsLoading {
                        self.present(
                            error: "Couldn’t read “\(url.lastPathComponent)”. \(error.localizedDescription)"
                        )
                    }
                }
            } onCancel: {
                scanTask.cancel()
            }
        }
    }

    func open(url: URL) {
        guard url.isFileURL else {
            NSWorkspace.shared.open(url)
            return
        }

        let normalizedURL = url.standardizedFileURL
        if let existing = documents.first(where: { $0.url?.standardizedFileURL == normalizedURL }) {
            selectedDocumentID = existing.id
            sidebarSelection = normalizedURL.path
            touchRecent(normalizedURL)
            return
        }

        do {
            let readResult = try MarkdownFileIO.read(from: normalizedURL)
            let recent = recentDocuments.first { $0.path == normalizedURL.path }
            let document = MarkdownDocument(
                id: UUID(),
                url: normalizedURL,
                title: normalizedURL.deletingPathExtension().lastPathComponent,
                content: readResult.content,
                lastSavedContent: readResult.content,
                fileFormat: readResult.format,
                diskSnapshot: readResult.snapshot,
                openedAt: Date(),
                fileModifiedAt: readResult.snapshot.modificationDate,
                isPinned: recent?.isPinned ?? false,
                isSample: false
            )
            documents.append(document)
            selectedDocumentID = document.id
            sidebarSelection = normalizedURL.path
            touchRecent(normalizedURL)
            searchText = ""
        } catch {
            present(error: "Couldn’t open “\(normalizedURL.lastPathComponent)”. \(error.localizedDescription)")
        }
    }

    func select(documentID: UUID) {
        selectedDocumentID = documentID
        if let document = documents.first(where: { $0.id == documentID }) {
            sidebarSelection = document.isSample ? "welcome" : (document.url?.path ?? "")
        }
        searchText = ""
    }

    func closeTab(_ id: UUID) {
        if selectedDocumentID == id {
            rendererController.flushMarkdown(for: id) { [weak self] markdown in
                guard let self else { return }
                if let markdown {
                    self.updateContent(markdown, for: id)
                }
                self.confirmCloseTab(id)
            }
        } else {
            confirmCloseTab(id)
        }
    }

    private func confirmCloseTab(_ id: UUID) {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        let document = documents[index]

        if document.isDirty {
            let alert = NSAlert()
            alert.messageText = "Save changes to “\(document.title)”?"
            alert.informativeText = "Your changes will be lost if you close this tab without saving."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Don’t Save")
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                selectedDocumentID = id
                saveCurrent { [weak self] saved in
                    guard saved else { return }
                    self?.removeTab(id)
                }
                return
            } else if response == .alertSecondButtonReturn {
                return
            }
        }

        removeTab(id)
    }

    private func removeTab(_ id: UUID) {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        documents.remove(at: index)

        if selectedDocumentID == id {
            if documents.indices.contains(index) {
                selectedDocumentID = documents[index].id
            } else {
                selectedDocumentID = documents.last?.id
            }
        }

        if documents.isEmpty {
            selectedDocumentID = nil
            sidebarSelection = ""
            searchText = ""
            outlineTarget = nil
            // Nothing left to read, and focus mode hides the chrome needed to
            // open something else.
            exitFocusMode()
            isInspectorVisible = false
        } else if let currentDocument {
            sidebarSelection = currentDocument.isSample
                ? "welcome"
                : (currentDocument.url?.path ?? "")
        }
    }

    func closeCurrentTab() {
        guard let selectedDocumentID else { return }
        closeTab(selectedDocumentID)
    }

    // MARK: - Focus mode

    var canEnterFocusMode: Bool {
        currentDocument != nil
    }

    func toggleFocusMode() {
        isFocusMode ? exitFocusMode() : enterFocusMode()
    }

    func enterFocusMode() {
        guard canEnterFocusMode, !isFocusMode else { return }
        // Focus mode is for reading, so it shows the preview. Remember the mode
        // being left behind rather than stranding the reader in it afterwards.
        displayModeBeforeFocus = displayMode
        inspectorVisibilityBeforeFocus = isInspectorVisible
        displayMode = .preview
        isInspectorVisible = false
        searchText = ""
        isFocusMode = true
    }

    func exitFocusMode() {
        guard isFocusMode else { return }
        isFocusMode = false
        if let previous = displayModeBeforeFocus {
            displayMode = previous
            displayModeBeforeFocus = nil
        }
        if let wasVisible = inspectorVisibilityBeforeFocus {
            isInspectorVisible = wasVisible
            inspectorVisibilityBeforeFocus = nil
        }
    }

    func saveCurrent(completion: ((Bool) -> Void)? = nil) {
        guard let documentID = selectedDocumentID else {
            completion?(false)
            return
        }

        rendererController.flushMarkdown(for: documentID) { [weak self] markdown in
            guard let self else {
                completion?(false)
                return
            }
            if let markdown {
                self.updateContent(markdown, for: documentID)
            }
            self.save(documentID: documentID, completion: completion)
        }
    }

    private func save(documentID: UUID, completion: ((Bool) -> Void)?) {
        guard let index = documents.firstIndex(where: { $0.id == documentID }) else {
            completion?(false)
            return
        }
        if documents[index].url == nil || documents[index].isSample {
            saveAs(documentID: documentID, completion: completion)
            return
        }

        guard let url = documents[index].url else {
            completion?(false)
            return
        }
        if hasExternalChanges(at: url, comparedTo: documents[index].diskSnapshot) {
            resolveSaveConflict(documentID: documentID, url: url, completion: completion)
            return
        }

        write(documentID: documentID, to: url, completion: completion)
    }

    func saveCurrentAs(completion: ((Bool) -> Void)? = nil) {
        guard let documentID = selectedDocumentID else {
            completion?(false)
            return
        }

        rendererController.flushMarkdown(for: documentID) { [weak self] markdown in
            guard let self else {
                completion?(false)
                return
            }
            if let markdown {
                self.updateContent(markdown, for: documentID)
            }
            self.saveAs(documentID: documentID, completion: completion)
        }
    }

    func prepareForTermination(completion: @escaping (Bool) -> Void) {
        guard let selectedDocumentID else {
            confirmAndSaveDirtyDocuments(completion: completion)
            return
        }

        rendererController.flushMarkdown(for: selectedDocumentID) { [weak self] markdown in
            guard let self else {
                completion(false)
                return
            }
            if let markdown {
                self.updateContent(markdown, for: selectedDocumentID)
            }
            self.confirmAndSaveDirtyDocuments(completion: completion)
        }
    }

    private func saveAs(documentID: UUID, completion: ((Bool) -> Void)?) {
        guard let index = documents.firstIndex(where: { $0.id == documentID }) else {
            completion?(false)
            return
        }
        let panel = NSSavePanel()
        panel.title = "Save Markdown"
        panel.prompt = "Save"
        panel.nameFieldStringValue = documents[index].isSample
            ? "PreviewMD Showcase.md"
            : "\(documents[index].title).md"
        panel.allowedContentTypes = Self.markdownContentTypes
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else {
            completion?(false)
            return
        }
        write(documentID: documentID, to: url, updatesLocation: true, completion: completion)
    }

    private func confirmAndSaveDirtyDocuments(
        completion: @escaping (Bool) -> Void
    ) {
        let dirtyIDs = documents.filter(\.isDirty).map(\.id)
        guard !dirtyIDs.isEmpty else {
            completion(true)
            return
        }

        let alert = NSAlert()
        alert.messageText = dirtyIDs.count == 1
            ? "Save changes before quitting?"
            : "Save changes to \(dirtyIDs.count) documents before quitting?"
        alert.informativeText = "Unsaved changes will be lost if you quit without saving."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save All")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit Without Saving")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            saveDirtyDocuments(dirtyIDs[...], completion: completion)
        case .alertThirdButtonReturn:
            completion(true)
        default:
            completion(false)
        }
    }

    private func saveDirtyDocuments(
        _ remaining: ArraySlice<UUID>,
        completion: @escaping (Bool) -> Void
    ) {
        guard let documentID = remaining.first else {
            completion(true)
            return
        }

        selectedDocumentID = documentID
        save(documentID: documentID) { [weak self] saved in
            guard let self, saved else {
                completion(false)
                return
            }
            self.saveDirtyDocuments(remaining.dropFirst(), completion: completion)
        }
    }

    func reloadCurrent() {
        guard let documentID = selectedDocumentID else { return }
        rendererController.flushMarkdown(for: documentID) { [weak self] markdown in
            guard let self else { return }
            if let markdown {
                self.updateContent(markdown, for: documentID)
            }
            self.confirmReload(documentID: documentID)
        }
    }

    private func confirmReload(documentID: UUID) {
        guard let index = documents.firstIndex(where: { $0.id == documentID }) else {
            return
        }

        if documents[index].isDirty {
            let alert = NSAlert()
            alert.messageText = "Reload from disk?"
            alert.informativeText = "Unsaved changes in this tab will be discarded."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Reload")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        _ = reload(documentID: documentID)
    }

    @discardableResult
    private func reload(documentID: UUID) -> Bool {
        guard let index = documents.firstIndex(where: { $0.id == documentID }),
              let url = documents[index].url
        else { return false }

        do {
            let readResult = try MarkdownFileIO.read(from: url)
            documents[index].content = readResult.content
            documents[index].lastSavedContent = readResult.content
            documents[index].contentRevision &+= 1
            documents[index].undoHistory.removeAll()
            documents[index].redoHistory.removeAll()
            documents[index].lastEditOrigin = nil
            documents[index].lastEditAt = nil
            documents[index].fileFormat = readResult.format
            documents[index].diskSnapshot = readResult.snapshot
            documents[index].fileModifiedAt = readResult.snapshot.modificationDate
            documents[index].hasExternalChanges = false
            return true
        } catch {
            present(error: "Couldn’t reload “\(url.lastPathComponent)”. \(error.localizedDescription)")
            return false
        }
    }

    private func write(
        documentID: UUID,
        to url: URL,
        updatesLocation: Bool = false,
        completion: ((Bool) -> Void)?
    ) {
        guard let index = documents.firstIndex(where: { $0.id == documentID }) else {
            completion?(false)
            return
        }

        do {
            let snapshot = try MarkdownFileIO.write(
                documents[index].content,
                to: url,
                format: documents[index].fileFormat
            )
            if updatesLocation {
                documents[index].url = url
                documents[index].title = url.deletingPathExtension().lastPathComponent
                documents[index].isSample = false
                if selectedDocumentID == documentID {
                    sidebarSelection = url.path
                }
            }
            documents[index].lastSavedContent = documents[index].content
            documents[index].diskSnapshot = snapshot
            documents[index].fileModifiedAt = snapshot.modificationDate
            documents[index].hasExternalChanges = false
            touchRecent(url)
            if updatesLocation, isInsideWorkspaceFolder(url) {
                refreshWorkspaceFolder()
            }
            completion?(true)
        } catch {
            present(error: "Couldn’t save “\(url.lastPathComponent)”. \(error.localizedDescription)")
            completion?(false)
        }
    }

    private func hasExternalChanges(
        at url: URL,
        comparedTo snapshot: FileSnapshot?
    ) -> Bool {
        guard let snapshot else { return false }
        guard let current = try? FileSnapshot.capture(url: url) else { return true }
        // Atomic replacement can make metadata timestamps settle a moment
        // after the write. The content fingerprint is the authoritative signal
        // and avoids a false conflict on two consecutive saves.
        return current.fingerprint != snapshot.fingerprint
    }

    private func isInsideWorkspaceFolder(_ url: URL) -> Bool {
        guard let workspaceFolderURL else { return false }
        let rootComponents = workspaceFolderURL.standardizedFileURL.pathComponents
        let fileComponents = url.standardizedFileURL.pathComponents
        return fileComponents.count > rootComponents.count
            && fileComponents.starts(with: rootComponents)
    }

    private func resolveSaveConflict(
        documentID: UUID,
        url: URL,
        completion: ((Bool) -> Void)?
    ) {
        let alert = NSAlert()
        alert.messageText = "“\(url.lastPathComponent)” changed on disk."
        alert.informativeText = "Choose which version to keep before saving."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Overwrite")
        alert.addButton(withTitle: "Save As…")
        alert.addButton(withTitle: "Reload")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            write(documentID: documentID, to: url, completion: completion)
        case .alertSecondButtonReturn:
            saveAs(documentID: documentID, completion: completion)
        case .alertThirdButtonReturn:
            selectedDocumentID = documentID
            completion?(reload(documentID: documentID))
        default:
            completion?(false)
        }
    }

    func togglePin(for recent: RecentDocument) {
        guard let index = recentDocuments.firstIndex(where: { $0.path == recent.path }) else { return }
        recentDocuments[index].isPinned.toggle()
        if let documentIndex = documents.firstIndex(where: { $0.url?.path == recent.path }) {
            documents[documentIndex].isPinned = recentDocuments[index].isPinned
        }
        sortAndSaveRecents()
    }

    func removeRecent(_ recent: RecentDocument) {
        recentDocuments.removeAll { $0.path == recent.path }
        saveRecents()
    }

    func exportPDF() {
        guard let currentDocument else { return }
        rendererController.exportPDF(
            suggestedName: "\(currentDocument.title).pdf",
            initialStyle: readingStyle,
            customPresets: customReadingPresets,
            selectedCustomPresetID: selectedCustomPresetID
        ) { [weak self] error in
            if let error {
                self?.present(error: "Couldn’t export PDF. \(error.localizedDescription)")
            }
        }
    }

    func printCurrent() {
        rendererController.printDocument(
            style: readingStyle,
            customPreset: activeCustomReadingPreset
        ) { [weak self] error in
            if let error {
                self?.present(error: "Couldn’t print. \(error.localizedDescription)")
            }
        }
    }

    func zoomIn() {
        zoom = min(1.6, (zoom + 0.1).rounded(toPlaces: 1))
    }

    func zoomOut() {
        zoom = max(0.7, (zoom - 0.1).rounded(toPlaces: 1))
    }

    func setCustomReadingWidth(_ value: Double) {
        customReadingWidth = min(1600, max(560, (value / 10).rounded() * 10))
        readingWidth = .custom
    }

    func cycleReadingStyle() {
        var styles: [ReadingStyle] = [.modern, .classic, .editorial]
        if !customReadingPresets.isEmpty { styles.append(.custom) }
        guard let index = styles.firstIndex(of: readingStyle) else {
            readingStyle = styles[0]
            return
        }
        readingStyle = styles[(index + 1) % styles.count]
    }

    func beginNewCustomPreset() {
        editingCustomPreset = .starter
    }

    func beginEditingCustomPreset(_ preset: CustomReadingPreset) {
        editingCustomPreset = preset
    }

    func saveCustomPreset(_ preset: CustomReadingPreset) {
        let preset = preset.normalized
        if let index = customReadingPresets.firstIndex(where: { $0.id == preset.id }) {
            customReadingPresets[index] = preset
        } else {
            customReadingPresets.append(preset)
        }
        selectedCustomPresetID = preset.id
        readingStyle = .custom
        editingCustomPreset = nil
        updatePreferences()
    }

    func deleteCustomPreset(_ preset: CustomReadingPreset) {
        customReadingPresets.removeAll { $0.id == preset.id }
        if selectedCustomPresetID == preset.id {
            selectedCustomPresetID = customReadingPresets.first?.id
        }
        if customReadingPresets.isEmpty {
            readingStyle = .modern
        }
        editingCustomPreset = nil
        updatePreferences()
    }

    func updatePreferences() {
        defaults.set(theme.rawValue, forKey: themeKey)
        defaults.set(readingStyle.rawValue, forKey: styleKey)
        if let data = try? JSONEncoder().encode(customReadingPresets.map(\.normalized)) {
            defaults.set(data, forKey: customStylesKey)
        }
        defaults.set(selectedCustomPresetID?.uuidString, forKey: selectedCustomStyleKey)
        defaults.set(readingWidth.rawValue, forKey: widthKey)
        defaults.set(customReadingWidth, forKey: customWidthKey)
        defaults.set(usesPaperCanvas, forKey: paperKey)
        defaults.set(liveReloadEnabled, forKey: liveReloadKey)
    }

    private func loadPreferences() {
        if let rawTheme = defaults.string(forKey: themeKey),
           let savedTheme = PreviewTheme(rawValue: rawTheme) {
            theme = savedTheme
        }
        if let rawStyle = defaults.string(forKey: styleKey),
           let savedStyle = ReadingStyle(rawValue: rawStyle) {
            readingStyle = savedStyle
        }
        if let data = defaults.data(forKey: customStylesKey),
           let presets = try? JSONDecoder().decode([CustomReadingPreset].self, from: data) {
            customReadingPresets = presets.map(\.normalized)
        }
        if let rawID = defaults.string(forKey: selectedCustomStyleKey) {
            selectedCustomPresetID = UUID(uuidString: rawID)
        }
        if readingStyle == .custom, customReadingPresets.isEmpty {
            readingStyle = .modern
        }
        if let rawWidth = defaults.string(forKey: widthKey),
           let savedWidth = ReadingWidth(rawValue: rawWidth) {
            readingWidth = savedWidth
        }
        if defaults.object(forKey: customWidthKey) != nil {
            customReadingWidth = min(
                1600,
                max(560, defaults.double(forKey: customWidthKey))
            )
        }
        if defaults.object(forKey: paperKey) != nil {
            usesPaperCanvas = defaults.bool(forKey: paperKey)
        }
        if defaults.object(forKey: liveReloadKey) != nil {
            liveReloadEnabled = defaults.bool(forKey: liveReloadKey)
        }
    }

    private func startLiveReloadPolling() {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(750))
                guard let self else { return }
                self.pollForExternalChanges()
            }
        }
    }

    func pollForExternalChanges(now: Date = Date()) {
        guard liveReloadEnabled else { return }

        for index in documents.indices {
            guard let url = documents[index].url,
                  let savedSnapshot = documents[index].diskSnapshot,
                  let currentSnapshot = try? FileSnapshot.capture(url: url),
                  currentSnapshot.fingerprint != savedSnapshot.fingerprint
            else { continue }

            if documents[index].isDirty {
                // Keep the conflict visible without publishing the same value
                // on every 750 ms polling pass. Repeated publication also
                // invalidates open menu hierarchies.
                if !documents[index].hasExternalChanges {
                    documents[index].hasExternalChanges = true
                }
            } else {
                _ = reload(documentID: documents[index].id)
            }
        }

        if let workspaceFolderURL,
           !isWorkspaceFolderLoading,
           now.timeIntervalSince(lastWorkspaceLiveRefresh) >= 2 {
            lastWorkspaceLiveRefresh = now
            loadFolder(
                at: workspaceFolderURL,
                clearsExistingItems: false,
                showsLoading: false
            )
        }
    }

    private func loadRecentDocuments() {
        guard let data = defaults.data(forKey: recentKey),
              let decoded = try? JSONDecoder().decode([RecentDocument].self, from: data)
        else { return }

        recentDocuments = decoded.filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
        sortAndSaveRecents()
    }

    private func touchRecent(_ url: URL) {
        let path = url.standardizedFileURL.path
        let existingPin = recentDocuments.first(where: { $0.path == path })?.isPinned ?? false
        recentDocuments.removeAll { $0.path == path }
        recentDocuments.append(
            RecentDocument(path: path, lastOpened: Date(), isPinned: existingPin)
        )
        sortAndSaveRecents()
    }

    private func sortAndSaveRecents() {
        recentDocuments.sort {
            if $0.isPinned != $1.isPinned { return $0.isPinned && !$1.isPinned }
            return $0.lastOpened > $1.lastOpened
        }
        if recentDocuments.count > 18 {
            recentDocuments = Array(recentDocuments.prefix(18))
        }
        saveRecents()
    }

    private func saveRecents() {
        guard let data = try? JSONEncoder().encode(recentDocuments) else { return }
        defaults.set(data, forKey: recentKey)
    }

    private func present(error: String) {
        errorMessage = error
        let alert = NSAlert()
        alert.messageText = "PreviewMD"
        alert.informativeText = error
        alert.alertStyle = .warning
        alert.runModal()
    }

    private static var markdownContentTypes: [UTType] {
        MarkdownFileSupport.supportedExtensions.compactMap {
            UTType(filenameExtension: $0)
        }
    }

}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let divisor = pow(10.0, Double(places))
        return (self * divisor).rounded() / divisor
    }
}
