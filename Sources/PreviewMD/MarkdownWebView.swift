import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import WebKit

@MainActor
final class RendererController: ObservableObject {
    private weak var webView: WKWebView?
    private var attachedDocumentID: UUID?

    func attach(_ webView: WKWebView, documentID: UUID) {
        self.webView = webView
        attachedDocumentID = documentID
    }

    func flushMarkdown(
        for documentID: UUID,
        completion: @escaping (String?) -> Void
    ) {
        guard let webView, attachedDocumentID == documentID else {
            completion(nil)
            return
        }

        webView.evaluateJavaScript(
            "window.previewmdFlushEditor ? window.previewmdFlushEditor() : null"
        ) { result, _ in
            Task { @MainActor in
                completion(result as? String)
            }
        }
    }

    func undo() {
        webView?.evaluateJavaScript("window.previewmdUndo && window.previewmdUndo();")
    }

    func redo() {
        webView?.evaluateJavaScript("window.previewmdRedo && window.previewmdRedo();")
    }

    func exportPDF(
        suggestedName: String,
        initialStyle: ReadingStyle,
        customPresets: [CustomReadingPreset],
        selectedCustomPresetID: UUID?,
        completion: @escaping ((any Error)?) -> Void
    ) {
        guard let webView else {
            completion(RendererError.rendererUnavailable)
            return
        }

        let panel = NSSavePanel()
        panel.title = "Export PDF"
        panel.prompt = "Export"
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        let accessory = PDFExportAccessoryView(
            initialStyle: initialStyle,
            customPresets: customPresets,
            selectedCustomPresetID: selectedCustomPresetID
        )
        panel.accessoryView = accessory

        guard panel.runModal() == .OK, let destinationURL = panel.url else {
            return
        }

        runPrintOperation(
            in: webView,
            options: accessory.options,
            destinationURL: destinationURL,
            showsPrintPanel: false,
            completion: completion
        )
    }

    func printDocument(
        style: ReadingStyle,
        customPreset: CustomReadingPreset?,
        completion: @escaping ((any Error)?) -> Void
    ) {
        guard let webView else {
            completion(RendererError.rendererUnavailable)
            return
        }
        // Physical printing is intentionally light even when the on-screen
        // document or a PDF export uses a dark grade.
        let options = PDFExportOptions(
            pageFormat: .a4,
            orientation: .portrait,
            theme: .light,
            style: style,
            margins: .normal,
            customPreset: customPreset
        )
        runPrintOperation(
            in: webView,
            options: options,
            destinationURL: nil,
            showsPrintPanel: true,
            completion: completion
        )
    }

    private func runPrintOperation(
        in webView: WKWebView,
        options: PDFExportOptions,
        destinationURL: URL?,
        showsPrintPanel: Bool,
        completion: @escaping ((any Error)?) -> Void
    ) {
        guard let data = try? JSONEncoder().encode(options),
              let arguments = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            completion(RendererError.invalidPrintOptions)
            return
        }

        Task { @MainActor [weak webView] in
            guard let webView else {
                completion(RendererError.rendererUnavailable)
                return
            }
            do {
                _ = try await webView.callAsyncJavaScript(
                    "await window.previewmdPreparePrint(options); return true;",
                    arguments: ["options": arguments],
                    contentWorld: .page
                )
                let printInfo = options.printInfo
                if let destinationURL {
                    printInfo.jobDisposition = .save
                    printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = destinationURL
                }
                let operation = webView.printOperation(with: printInfo)
                operation.showsPrintPanel = showsPrintPanel
                operation.showsProgressPanel = true
                let succeeded = operation.run()
                _ = try? await webView.callAsyncJavaScript(
                    "await window.previewmdFinishPrint(); return true;",
                    arguments: [:],
                    contentWorld: .page
                )
                completion(
                    succeeded || showsPrintPanel
                        ? nil
                        : RendererError.printCancelledOrFailed
                )
            } catch {
                _ = try? await webView.callAsyncJavaScript(
                    "await window.previewmdFinishPrint(); return true;",
                    arguments: [:],
                    contentWorld: .page
                )
                completion(error)
            }
        }
    }

    private enum RendererError: LocalizedError {
        case rendererUnavailable
        case invalidPrintOptions
        case printCancelledOrFailed

        var errorDescription: String? {
            switch self {
            case .rendererUnavailable:
                "The preview renderer is not available."
            case .invalidPrintOptions:
                "The PDF options could not be prepared."
            case .printCancelledOrFailed:
                "The print operation was cancelled or failed."
            }
        }
    }
}

enum PDFPageFormat: String, CaseIterable, Codable {
    case a4
    case letter
    case legal
    case a5

    var title: String {
        switch self {
        case .a4: "A4"
        case .letter: "US Letter"
        case .legal: "US Legal"
        case .a5: "A5"
        }
    }

    var paperSize: NSSize {
        switch self {
        case .a4: NSSize(width: 595.28, height: 841.89)
        case .letter: NSSize(width: 612, height: 792)
        case .legal: NSSize(width: 612, height: 1008)
        case .a5: NSSize(width: 419.53, height: 595.28)
        }
    }
}

enum PDFOrientation: String, CaseIterable, Codable {
    case portrait
    case landscape

    var title: String { self == .portrait ? "Portrait" : "Landscape" }
}

enum PDFExportTheme: String, CaseIterable, Codable {
    case light
    case dark

    var title: String { self == .light ? "Light" : "Dark" }
}

enum PDFMargins: String, CaseIterable, Codable {
    case narrow
    case normal
    case generous

    var title: String {
        switch self {
        case .narrow: "Narrow"
        case .normal: "Normal"
        case .generous: "Generous"
        }
    }

    var points: CGFloat {
        switch self {
        case .narrow: 24
        case .normal: 40
        case .generous: 58
        }
    }
}

struct PDFExportOptions: Codable {
    var pageFormat: PDFPageFormat
    var orientation: PDFOrientation
    var theme: PDFExportTheme
    var style: ReadingStyle
    var margins: PDFMargins
    var customPreset: CustomReadingPreset?

    var printInfo: NSPrintInfo {
        let info = NSPrintInfo()
        info.paperSize = pageFormat.paperSize
        info.orientation = orientation == .portrait ? .portrait : .landscape
        info.topMargin = margins.points
        info.bottomMargin = margins.points
        info.leftMargin = margins.points
        info.rightMargin = margins.points
        info.horizontalPagination = .automatic
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.dictionary()[NSPrintInfo.AttributeKey.headerAndFooter] = false
        return info
    }
}

enum PDFReadingStyleChoice {
    private static let stylePrefix = "style:"
    private static let presetPrefix = "preset:"

    static func key(for style: ReadingStyle, selectedPresetID: UUID?) -> String {
        if style == .custom, let selectedPresetID {
            return presetPrefix + selectedPresetID.uuidString
        }
        return stylePrefix + style.rawValue
    }

    static func key(for presetID: UUID) -> String {
        presetPrefix + presetID.uuidString
    }

    static func resolve(
        _ key: String?,
        customPresets: [CustomReadingPreset]
    ) -> (style: ReadingStyle, customPreset: CustomReadingPreset?) {
        if let key, key.hasPrefix(presetPrefix),
           let id = UUID(uuidString: String(key.dropFirst(presetPrefix.count))),
           let preset = customPresets.first(where: { $0.id == id }) {
            return (.custom, preset.normalized)
        }
        if let key, key.hasPrefix(stylePrefix),
           let style = ReadingStyle(rawValue: String(key.dropFirst(stylePrefix.count))),
           style != .custom {
            return (style, nil)
        }
        return (.modern, nil)
    }
}

@MainActor
private final class PDFExportAccessoryView: NSView {
    private let pagePopup = NSPopUpButton()
    private let orientationPopup = NSPopUpButton()
    private let themePopup = NSPopUpButton()
    private let stylePopup = NSPopUpButton()
    private let marginsPopup = NSPopUpButton()
    private let customPresets: [CustomReadingPreset]

    init(
        initialStyle: ReadingStyle,
        customPresets: [CustomReadingPreset],
        selectedCustomPresetID: UUID?
    ) {
        self.customPresets = customPresets.map(\.normalized)
        super.init(frame: NSRect(x: 0, y: 0, width: 390, height: 160))

        configure(pagePopup, cases: PDFPageFormat.allCases, title: \.title, raw: \.rawValue)
        configure(orientationPopup, cases: PDFOrientation.allCases, title: \.title, raw: \.rawValue)
        configure(themePopup, cases: PDFExportTheme.allCases, title: \.title, raw: \.rawValue)
        configure(marginsPopup, cases: PDFMargins.allCases, title: \.title, raw: \.rawValue)

        stylePopup.removeAllItems()
        for style in ReadingStyle.allCases where style != .custom {
            stylePopup.addItem(withTitle: style.title)
            stylePopup.lastItem?.representedObject = PDFReadingStyleChoice.key(
                for: style,
                selectedPresetID: nil
            )
        }
        for preset in self.customPresets {
            stylePopup.addItem(withTitle: preset.name)
            stylePopup.lastItem?.representedObject = PDFReadingStyleChoice.key(for: preset.id)
        }
        select(
            rawValue: PDFReadingStyleChoice.key(
                for: initialStyle,
                selectedPresetID: selectedCustomPresetID ?? self.customPresets.first?.id
            ),
            in: stylePopup
        )

        let grid = NSGridView(views: [
            [label("Page"), pagePopup],
            [label("Orientation"), orientationPopup],
            [label("Appearance"), themePopup],
            [label("Reading style"), stylePopup],
            [label("Margins"), marginsPopup],
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 7
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            grid.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            grid.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { nil }

    var options: PDFExportOptions {
        let styleChoice = PDFReadingStyleChoice.resolve(
            stylePopup.selectedItem?.representedObject as? String,
            customPresets: customPresets
        )
        return PDFExportOptions(
            pageFormat: selected(PDFPageFormat.self, in: pagePopup) ?? .a4,
            orientation: selected(PDFOrientation.self, in: orientationPopup) ?? .portrait,
            theme: selected(PDFExportTheme.self, in: themePopup) ?? .light,
            style: styleChoice.style,
            margins: selected(PDFMargins.self, in: marginsPopup) ?? .normal,
            customPreset: styleChoice.customPreset
        )
    }

    private func label(_ title: String) -> NSTextField {
        let field = NSTextField(labelWithString: title)
        field.alignment = .right
        field.textColor = .secondaryLabelColor
        return field
    }

    private func configure<T: RawRepresentable>(
        _ popup: NSPopUpButton,
        cases: [T],
        title: KeyPath<T, String>,
        raw: KeyPath<T, String>
    ) {
        popup.removeAllItems()
        for value in cases {
            popup.addItem(withTitle: value[keyPath: title])
            popup.lastItem?.representedObject = value[keyPath: raw]
        }
    }

    private func select(rawValue: String, in popup: NSPopUpButton) {
        if let item = popup.itemArray.first(where: { $0.representedObject as? String == rawValue }) {
            popup.select(item)
        }
    }

    private func selected<T: RawRepresentable>(
        _ type: T.Type,
        in popup: NSPopUpButton
    ) -> T? where T.RawValue == String {
        guard let raw = popup.selectedItem?.representedObject as? String else { return nil }
        return T(rawValue: raw)
    }
}

struct MarkdownWebView: NSViewRepresentable {
    let documentID: UUID
    let markdown: String
    let revision: Int
    let isEditable: Bool
    let documentURL: URL?
    let theme: PreviewTheme
    let readingStyle: ReadingStyle
    let customReadingPreset: CustomReadingPreset?
    let readingWidth: Int
    let readingWidthIsFluid: Bool
    let usesPaperCanvas: Bool
    let zoom: Double
    let searchText: String
    let outlineTarget: String?
    let externalChanges: [ExternalChangeHunk]
    let externalChangeSelection: Int?
    let topInset: Double
    let controller: RendererController
    let splitSynchronizer: SplitEditorSynchronizer
    let isSplitSynchronizationEnabled: Bool
    let onContentChange: (UUID, String, Bool) -> Void
    let onDropFiles: ([URL]) -> Void
    let onDropTargeted: (Bool) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var state: AppState

    func makeCoordinator() -> Coordinator {
        Coordinator(
            documentID: documentID,
            documentURL: documentURL,
            openMarkdown: state.open(url:),
            onContentChange: onContentChange,
            splitSynchronizer: splitSynchronizer,
            isSplitSynchronizationEnabled: isSplitSynchronizationEnabled
        )
    }

    private var renderPayload: RenderPayload {
        RenderPayload(
            documentID: documentID.uuidString,
            markdown: markdown,
            revision: revision,
            editable: isEditable,
            theme: theme.rawValue,
            readingStyle: readingStyle.rawValue,
            customReadingPreset: customReadingPreset,
            systemDark: colorScheme == .dark,
            readingWidth: readingWidth,
            readingWidthIsFluid: readingWidthIsFluid,
            paperCanvas: usesPaperCanvas,
            zoom: zoom,
            searchText: searchText,
            outlineTarget: outlineTarget,
            externalChanges: externalChanges,
            externalChangeSelection: externalChangeSelection,
            topInset: topInset
        )
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.userContentController.add(context.coordinator, name: "copyText")
        configuration.userContentController.add(context.coordinator, name: "editorChange")
        configuration.userContentController.add(context.coordinator, name: "pickImage")
        configuration.userContentController.add(context.coordinator, name: "splitSync")
        configuration.setURLSchemeHandler(
            context.coordinator.localImageSchemeHandler,
            forURLScheme: LocalImageSchemeHandler.scheme
        )

        let webView = MarkdownDropWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsMagnification = true
        webView.underPageBackgroundColor = .clear
        webView.onDropFiles = onDropFiles
        webView.onDropTargeted = onDropTargeted
        context.coordinator.webView = webView
        splitSynchronizer.attachPreview(
            context.coordinator,
            documentID: documentID
        )
        controller.attach(webView, documentID: documentID)
        let initialPayload = renderPayload
        webView.pageZoom = initialPayload.zoom
        context.coordinator.loadShell(
            baseURL: baseURL,
            initialPayload: initialPayload,
            in: webView
        )
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        controller.attach(webView, documentID: documentID)
        context.coordinator.documentID = documentID
        context.coordinator.documentURL = documentURL
        context.coordinator.localImageSchemeHandler.updateBaseURL(baseURL)
        context.coordinator.openMarkdown = state.open(url:)
        context.coordinator.onContentChange = onContentChange
        context.coordinator.updateSynchronization(
            splitSynchronizer: splitSynchronizer,
            isEnabled: isSplitSynchronizationEnabled
        )
        if let dropWebView = webView as? MarkdownDropWebView {
            dropWebView.onDropFiles = onDropFiles
            dropWebView.onDropTargeted = onDropTargeted
        }

        let payload = renderPayload
        let newBasePath = baseURL.path
        if context.coordinator.basePath != newBasePath {
            context.coordinator.loadShell(
                baseURL: baseURL,
                initialPayload: payload,
                in: webView
            )
        } else {
            context.coordinator.update(payload, in: webView)
        }
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "copyText")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "editorChange")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "pickImage")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "splitSync")
        coordinator.splitSynchronizer?.detachPreview(coordinator)
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        if let dropWebView = webView as? MarkdownDropWebView {
            dropWebView.onDropFiles = nil
            dropWebView.onDropTargeted = nil
        }
    }

    private var baseURL: URL {
        documentURL?.deletingLastPathComponent()
            ?? Bundle.module.resourceURL
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    }

    struct RenderPayload: Codable, Equatable {
        let documentID: String
        let markdown: String
        let revision: Int
        let editable: Bool
        let theme: String
        let readingStyle: String
        let customReadingPreset: CustomReadingPreset?
        let systemDark: Bool
        let readingWidth: Int
        let readingWidthIsFluid: Bool
        let paperCanvas: Bool
        let zoom: Double
        let searchText: String
        let outlineTarget: String?
        let externalChanges: [ExternalChangeHunk]
        let externalChangeSelection: Int?
        /// Height of the window toolbar the page has to clear in focus mode,
        /// where the web view extends underneath it. Layout-only, so it travels
        /// through `previewmdSetLayout` and never forces a re-render.
        let topInset: Double

        init(
            documentID: String,
            markdown: String,
            revision: Int,
            editable: Bool,
            theme: String,
            readingStyle: String,
            customReadingPreset: CustomReadingPreset?,
            systemDark: Bool,
            readingWidth: Int,
            readingWidthIsFluid: Bool,
            paperCanvas: Bool,
            zoom: Double,
            searchText: String,
            outlineTarget: String?,
            externalChanges: [ExternalChangeHunk] = [],
            externalChangeSelection: Int? = nil,
            topInset: Double
        ) {
            self.documentID = documentID
            self.markdown = markdown
            self.revision = revision
            self.editable = editable
            self.theme = theme
            self.readingStyle = readingStyle
            self.customReadingPreset = customReadingPreset
            self.systemDark = systemDark
            self.readingWidth = readingWidth
            self.readingWidthIsFluid = readingWidthIsFluid
            self.paperCanvas = paperCanvas
            self.zoom = zoom
            self.searchText = searchText
            self.outlineTarget = outlineTarget
            self.externalChanges = externalChanges
            self.externalChangeSelection = externalChangeSelection
            self.topInset = topInset
        }

        func requiresFullRender(comparedTo other: Self) -> Bool {
            documentID != other.documentID
                || markdown != other.markdown
                || theme != other.theme
                || readingStyle != other.readingStyle
                || customReadingPreset != other.customReadingPreset
                || systemDark != other.systemDark
                || externalChanges != other.externalChanges
        }

        var initialTheme: String {
            if theme == PreviewTheme.dark.rawValue
                || (theme == PreviewTheme.system.rawValue && systemDark) {
                return PreviewTheme.dark.rawValue
            }
            return PreviewTheme.light.rawValue
        }

        var rootHTMLAttributes: String {
            let paperValue = paperCanvas ? "true" : "false"
            let widthValue = readingWidthIsFluid ? "fluid" : "fixed"
            let customVariables: String
            if readingStyle == ReadingStyle.custom.rawValue,
                let preset = customReadingPreset?.normalized {
                let bodyFont = preset.bodyFont.cssFamily.replacingOccurrences(of: "\"", with: "'")
                let headingFont = preset.headingFont.cssFamily.replacingOccurrences(of: "\"", with: "'")
                let pageHex = initialTheme == "dark" ? preset.darkPageHex : preset.lightPageHex
                let inkHex = initialTheme == "dark" ? preset.darkInkHex : preset.lightInkHex
                customVariables = " --font-body: \(bodyFont); --font-display: \(headingFont);" +
                    " --body-size: \(preset.bodySize)px; --body-leading: \(preset.lineHeight);" +
                    " --accent: \(preset.accentHex); --page: \(pageHex);" +
                    " --ink: \(inkHex);"
            } else {
                customVariables = ""
            }
            return """
            data-theme="\(initialTheme)" data-style="\(readingStyle)" data-paper="\(paperValue)" \
            data-width="\(widthValue)" style="--reading-width: \(readingWidth)px; --top-inset: \(topInset)px;\(customVariables)"
            """
        }
    }

    @MainActor
    final class Coordinator: NSObject,
        WKNavigationDelegate,
        WKScriptMessageHandler,
        WKUIDelegate,
        SplitPreviewSynchronizationEndpoint
    {
        weak var webView: WKWebView?
        var documentID: UUID
        var documentURL: URL?
        var openMarkdown: (URL) -> Void
        var onContentChange: (UUID, String, Bool) -> Void
        weak var splitSynchronizer: SplitEditorSynchronizer?
        var isSplitSynchronizationEnabled: Bool
        var basePath = ""
        let localImageSchemeHandler: LocalImageSchemeHandler

        private var isLoaded = false
        private var pendingPayload: RenderPayload?
        private var lastPayload: RenderPayload?
        private var lastEditorMarkdown: String?
        private var lastEditorDocumentID: UUID?

        init(
            documentID: UUID,
            documentURL: URL?,
            openMarkdown: @escaping (URL) -> Void,
            onContentChange: @escaping (UUID, String, Bool) -> Void,
            splitSynchronizer: SplitEditorSynchronizer,
            isSplitSynchronizationEnabled: Bool
        ) {
            self.documentID = documentID
            self.documentURL = documentURL
            self.openMarkdown = openMarkdown
            self.onContentChange = onContentChange
            self.splitSynchronizer = splitSynchronizer
            self.isSplitSynchronizationEnabled = isSplitSynchronizationEnabled
            self.localImageSchemeHandler = LocalImageSchemeHandler(
                baseURL: documentURL?.deletingLastPathComponent()
                    ?? Bundle.module.resourceURL
                    ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            )
        }

        func updateSynchronization(
            splitSynchronizer: SplitEditorSynchronizer,
            isEnabled: Bool
        ) {
            let wasEnabled = isSplitSynchronizationEnabled
            if let previous = self.splitSynchronizer,
               previous !== splitSynchronizer {
                previous.detachPreview(self)
            }
            self.splitSynchronizer = splitSynchronizer
            isSplitSynchronizationEnabled = isEnabled
            if wasEnabled && !isEnabled, isLoaded {
                webView?.evaluateJavaScript(
                    "window.previewmdClearSplitSynchronization && "
                        + "window.previewmdClearSplitSynchronization();"
                )
            }
            splitSynchronizer.attachPreview(self, documentID: documentID)
        }

        func loadShell(
            baseURL: URL,
            initialPayload: RenderPayload,
            in webView: WKWebView
        ) {
            basePath = baseURL.path
            localImageSchemeHandler.updateBaseURL(baseURL)
            isLoaded = false
            lastPayload = nil
            pendingPayload = initialPayload
            webView.pageZoom = initialPayload.zoom
            webView.loadHTMLString(
                RendererAssets.shellHTML(for: initialPayload),
                baseURL: baseURL
            )
        }

        func update(_ payload: RenderPayload, in webView: WKWebView) {
            guard payload != lastPayload else { return }
            pendingPayload = payload
            guard isLoaded else { return }
            applyPendingPayload(in: webView)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            isLoaded = true
            applyPendingPayload(in: webView)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            guard navigationAction.navigationType == .linkActivated,
                  let url = navigationAction.request.url
            else {
                decisionHandler(.allow)
                return
            }

            if MarkdownFileSupport.accepts(url) {
                openMarkdown(url)
                decisionHandler(.cancel)
                return
            }

            if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.allow)
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptTextInputPanelWithPrompt prompt: String,
            defaultText: String?,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping @MainActor (String?) -> Void
        ) {
            let field = NSTextField(
                frame: NSRect(x: 0, y: 0, width: 360, height: 24)
            )
            field.stringValue = defaultText ?? ""
            field.placeholderString = prompt

            let alert = NSAlert()
            alert.messageText = prompt
            alert.alertStyle = .informational
            alert.accessoryView = field
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")

            if alert.runModal() == .alertFirstButtonReturn {
                completionHandler(field.stringValue)
            } else {
                completionHandler(nil)
            }
        }

        nonisolated func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            MainActor.assumeIsolated {
                switch message.name {
                case "copyText":
                    guard let text = message.body as? String else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                case "editorChange":
                    guard let body = message.body as? [String: Any],
                          let markdown = body["markdown"] as? String
                    else { return }
                    lastEditorMarkdown = markdown
                    lastEditorDocumentID = documentID
                    let historyBoundary = body["historyBoundary"] as? Bool ?? false
                    onContentChange(documentID, markdown, historyBoundary)
                case "pickImage":
                    guard let webView else { return }
                    presentImagePicker(in: webView)
                case "splitSync":
                    receiveSplitSyncMessage(message.body)
                default:
                    break
                }
            }
        }

        private func receiveSplitSyncMessage(_ messageBody: Any) {
            guard isSplitSynchronizationEnabled,
                  let body = messageBody as? [String: Any],
                  let kind = body["kind"] as? String else { return }
            switch kind {
            case "scroll":
                guard let line = Self.number(body["sourceLine"]) else { return }
                splitSynchronizer?.previewDidScroll(
                    SplitEditorScrollPosition(sourceLine: line),
                    documentID: documentID
                )
            case "selection":
                guard let startValue = Self.number(body["start"]),
                      let endValue = Self.number(body["end"]) else { return }
                let start = max(0, Int(startValue))
                let end = max(start, Int(endValue))
                splitSynchronizer?.previewDidChangeSelection(
                    SplitEditorSelection(
                        range: NSRange(location: start, length: end - start)
                    ),
                    documentID: documentID
                )
            case "ready":
                splitSynchronizer?.previewDidBecomeReady(documentID: documentID)
            default:
                break
            }
        }

        func applySourceScrollPosition(_ position: SplitEditorScrollPosition) {
            guard isSplitSynchronizationEnabled, isLoaded, let webView else { return }
            webView.evaluateJavaScript(
                "window.previewmdApplySplitScrollPosition && "
                    + "window.previewmdApplySplitScrollPosition({sourceLine: "
                    + String(position.sourceLine)
                    + "});"
            )
        }

        func applySourceSelection(_ selection: SplitEditorSelection) {
            guard isSplitSynchronizationEnabled, isLoaded, let webView else { return }
            let start = selection.range.location
            let end = NSMaxRange(selection.range)
            webView.evaluateJavaScript(
                "window.previewmdApplySplitSelection && "
                    + "window.previewmdApplySplitSelection({start: \(start), end: \(end)});"
            )
        }

        private static func number(_ value: Any?) -> Double? {
            (value as? NSNumber)?.doubleValue
        }

        private func presentImagePicker(in webView: WKWebView) {
            let panel = NSOpenPanel()
            panel.title = "Choose Image"
            panel.prompt = "Insert"
            panel.canChooseDirectories = false
            panel.canChooseFiles = true
            panel.allowsMultipleSelection = false
            panel.allowedContentTypes = [.image]

            let handleResponse: (NSApplication.ModalResponse) -> Void = {
                [weak self, weak webView] response in
                guard let self, let webView else { return }
                guard response == .OK, let imageURL = panel.url else {
                    webView.evaluateJavaScript(
                        "window.previewmdCancelPickedImage && window.previewmdCancelPickedImage();"
                    )
                    return
                }

                let source = Self.markdownImageSource(
                    for: imageURL,
                    relativeTo: self.documentURL
                )
                let alt = imageURL.deletingPathExtension().lastPathComponent
                guard let sourceJSON = self.javaScriptJSON(source),
                      let altJSON = self.javaScriptJSON(alt)
                else { return }
                webView.evaluateJavaScript(
                    "window.previewmdInsertPickedImage && window.previewmdInsertPickedImage(\(sourceJSON), \(altJSON));"
                )
            }

            if let window = webView.window {
                panel.beginSheetModal(for: window, completionHandler: handleResponse)
            } else {
                panel.begin(completionHandler: handleResponse)
            }
        }

        static func markdownImageSource(
            for imageURL: URL,
            relativeTo documentURL: URL?
        ) -> String {
            guard let documentURL else {
                return imageURL.standardizedFileURL.absoluteString
            }

            let baseComponents =
                documentURL
                .deletingLastPathComponent()
                .standardizedFileURL
                .pathComponents
            let imageComponents = imageURL.standardizedFileURL.pathComponents
            var commonCount = 0
            while commonCount < min(baseComponents.count, imageComponents.count),
                  baseComponents[commonCount] == imageComponents[commonCount] {
                commonCount += 1
            }

            guard commonCount > 0 else {
                return imageURL.standardizedFileURL.absoluteString
            }

            let parentComponents = Array(
                repeating: "..",
                count: baseComponents.count - commonCount
            )
            let childComponents = Array(imageComponents.dropFirst(commonCount))
            let relativePath = (parentComponents + childComponents).joined(separator: "/")
            var allowed = CharacterSet.urlPathAllowed
            allowed.remove(charactersIn: "#?<>()[\\]")
            return relativePath.addingPercentEncoding(withAllowedCharacters: allowed)
                ?? relativePath
        }

        private func applyPendingPayload(in webView: WKWebView) {
            guard let payload = pendingPayload else { return }

            pendingPayload = nil
            webView.pageZoom = payload.zoom

            if let previous = lastPayload,
               !payload.requiresFullRender(comparedTo: previous) {
                lastPayload = payload

                if payload.readingWidth != previous.readingWidth
                    || payload.readingWidthIsFluid != previous.readingWidthIsFluid
                    || payload.paperCanvas != previous.paperCanvas
                    || payload.topInset != previous.topInset {
                    webView.evaluateJavaScript(
                        "window.previewmdSetLayout(\(payload.readingWidth), \(payload.paperCanvas), \(payload.topInset), \(payload.readingWidthIsFluid));"
                    )
                }

                if payload.searchText != previous.searchText,
                   let searchJSON = javaScriptJSON(payload.searchText) {
                    webView.evaluateJavaScript("window.previewmdFind(\(searchJSON));")
                }

                if let target = payload.outlineTarget,
                   target != previous.outlineTarget,
                   let targetJSON = javaScriptJSON(target) {
                    webView.evaluateJavaScript("window.previewmdScrollTo(\(targetJSON));")
                }

                if payload.editable != previous.editable {
                    webView.evaluateJavaScript(
                        "window.previewmdSetEditable && window.previewmdSetEditable(\(payload.editable));"
                    )
                }

                if payload.externalChangeSelection != previous.externalChangeSelection,
                   let selectionJSON = javaScriptJSON(payload.externalChangeSelection) {
                    webView.evaluateJavaScript(
                        "window.previewmdSelectExternalChange && window.previewmdSelectExternalChange(\(selectionJSON), true);"
                    )
                }
                return
            }

            if let previous = lastPayload,
               payload.documentID == previous.documentID,
               payload.documentID == lastEditorDocumentID?.uuidString,
               payload.markdown == lastEditorMarkdown,
               payload.theme == previous.theme,
               payload.readingStyle == previous.readingStyle,
               payload.systemDark == previous.systemDark {
                lastPayload = payload
                lastEditorMarkdown = nil
                lastEditorDocumentID = nil
                webView.evaluateJavaScript(
                    "window.previewmdSetEditable && window.previewmdSetEditable(\(payload.editable));"
                )
                return
            }

            guard let data = try? JSONEncoder().encode(payload),
                  let json = String(data: data, encoding: .utf8)
            else { return }

            lastPayload = payload
            lastEditorMarkdown = nil
            lastEditorDocumentID = nil
            webView.evaluateJavaScript("window.previewmdRender(\(json));")
        }

        private func javaScriptJSON<T: Encodable>(_ value: T) -> String? {
            guard let data = try? JSONEncoder().encode(value) else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }
}

@MainActor
private final class MarkdownDropWebView: WKWebView {
    var onDropFiles: (([URL]) -> Void)?
    var onDropTargeted: ((Bool) -> Void)?

    override init(frame: NSRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard !supportedURLs(from: sender).isEmpty else {
            onDropTargeted?(false)
            return super.draggingEntered(sender)
        }
        onDropTargeted?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard !supportedURLs(from: sender).isEmpty else {
            onDropTargeted?(false)
            return super.draggingUpdated(sender)
        }
        onDropTargeted?(true)
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        onDropTargeted?(false)
        super.draggingExited(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = supportedURLs(from: sender)
        guard !urls.isEmpty else {
            onDropTargeted?(false)
            return super.performDragOperation(sender)
        }

        onDropTargeted?(false)
        onDropFiles?(urls)
        return true
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        onDropTargeted?(false)
        super.concludeDragOperation(sender)
    }

    private func supportedURLs(from draggingInfo: any NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        let objects = draggingInfo.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: options
        ) ?? []

        return objects
            .compactMap { ($0 as? NSURL) as URL? }
            .filter(MarkdownFileSupport.accepts)
    }
}

enum RendererAssets {
    private static let markdownIt = script(named: "markdown-it.min")
    private static let footnotes = script(named: "markdown-it-footnote.min")
    private static let highlight = script(named: "highlight.min")
    private static let katex = script(named: "katex.min")
    private static let autoRender = script(named: "auto-render.min")
    private static let mermaid = script(named: "mermaid.min")
    private static let renderer = script(named: "renderer")
    private static let diagramEditor = script(named: "diagram-editor")
    private static let editor = script(named: "editor")
    private static let baseCSS = text(named: "renderer", extension: "css")
    private static let katexCSS = rewrittenKaTeXCSS()

    static func shellHTML(for initialPayload: MarkdownWebView.RenderPayload) -> String {
        return """
        <!doctype html>
        <html lang="en" \(initialPayload.rootHTMLAttributes)>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
          <style>\(katexCSS)</style>
          <style>\(baseCSS)</style>
        </head>
        <body>
          <div id="reading-progress"></div>
          <!-- The blurred edge focus mode reads under. It lives in the page
               because a native effect view cannot blur a web view's content —
               the page renders out of process, so AppKit has nothing to sample. -->
          <div id="top-blur" aria-hidden="true"></div>
          <main id="preview-shell" aria-live="polite">
            <article id="preview-document"></article>
          </main>
          <div id="render-error" hidden></div>
          <script>window.previewmdLocalImageScheme = "\(LocalImageSchemeHandler.scheme)";</script>
          <script>\(markdownIt)</script>
          <script>\(footnotes)</script>
          <script>\(highlight)</script>
          <script>\(katex)</script>
          <script>\(autoRender)</script>
          <script>\(mermaid)</script>
          <script>\(renderer)</script>
          <script>\(diagramEditor)</script>
          <script>\(editor)</script>
        </body>
        </html>
        """
    }

    private static func script(named name: String) -> String {
        text(named: name, extension: "js")
            .replacingOccurrences(of: "</script>", with: "<\\/script>")
    }

    private static func text(named name: String, extension fileExtension: String) -> String {
        guard let url = Bundle.module.url(
            forResource: name,
            withExtension: fileExtension,
            subdirectory: "Renderer"
        ) else {
            return ""
        }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private static func rewrittenKaTeXCSS() -> String {
        let css = text(named: "katex.min", extension: "css")
        guard let fontsURL = Bundle.module.url(
            forResource: "fonts",
            withExtension: nil,
            subdirectory: "Renderer"
        ) else {
            return css
        }
        let prefix = fontsURL.absoluteString
        return css.replacingOccurrences(of: "url(fonts/", with: "url(\(prefix)/")
    }
}
