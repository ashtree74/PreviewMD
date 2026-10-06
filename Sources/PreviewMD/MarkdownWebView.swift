import AppKit
import CoreGraphics
import Foundation
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

@MainActor
final class RendererController: ObservableObject {
    private weak var webView: WKWebView?
    private var attachedDocumentID: UUID?
    private var isEditorVisible = true
    private var synchronizeRenderer: (@MainActor () async throws -> Void)?
    // PDFKit's print operation can hand work to Quartz after `run()` returns.
    // Retain the immutable source and operation until a later print replaces them.
    private var activePrintDocument: PDFDocument?
    private var activePrintOperation: NSPrintOperation?

    func attach(
        _ webView: WKWebView,
        documentID: UUID,
        isVisible: Bool = true,
        synchronize: (@MainActor () async throws -> Void)? = nil
    ) {
        self.webView = webView
        attachedDocumentID = documentID
        isEditorVisible = isVisible
        synchronizeRenderer = synchronize
    }

    func flushMarkdown(
        for documentID: UUID,
        completion: @escaping (String?) -> Void
    ) {
        guard isEditorVisible, let webView, attachedDocumentID == documentID else {
            completion(nil)
            return
        }

        let synchronize = synchronizeRenderer
        Task { @MainActor [weak self, weak webView] in
            do {
                try await synchronize?()
                guard let self, let webView, self.isEditorVisible,
                      self.webView === webView, self.attachedDocumentID == documentID
                else { completion(nil); return }
                let result = try await webView.evaluateJavaScript(
                    "window.previewmdFlushEditor ? window.previewmdFlushEditor() : null"
                )
                guard self.isEditorVisible, self.webView === webView,
                      self.attachedDocumentID == documentID
                else { completion(nil); return }
                completion(result as? String)
            } catch {
                completion(nil)
            }
        }
    }

    func undo() {
        webView?.evaluateJavaScript("window.previewmdUndo && window.previewmdUndo();")
    }

    func redo() {
        webView?.evaluateJavaScript("window.previewmdRedo && window.previewmdRedo();")
    }

    func advancedCopy(_ format: AdvancedCopyFormat, suggestedName: String) {
        guard let webView else {
            NSSound.beep()
            return
        }
        let synchronize = synchronizeRenderer
        let documentID = attachedDocumentID
        Task { @MainActor [weak self, weak webView] in
            do {
                try await synchronize?()
                guard let self, let webView, self.webView === webView,
                      self.attachedDocumentID == documentID
                else { return }
                let value = try await webView.callAsyncJavaScript(
                    "return window.previewmdAdvancedCopy && window.previewmdAdvancedCopy(destination, suggestedName);",
                    arguments: ["destination": format.rawValue, "suggestedName": suggestedName],
                    contentWorld: .page
                )
                if (value as? Bool) != true { NSSound.beep() }
            } catch {
                NSSound.beep()
            }
        }
    }

    func exportDOCX(suggestedName: String) {
        guard let webView else {
            NSSound.beep()
            return
        }
        let synchronize = synchronizeRenderer
        let documentID = attachedDocumentID
        Task { @MainActor [weak self, weak webView] in
            do {
                try await synchronize?()
                guard let self, let webView, self.webView === webView,
                      self.attachedDocumentID == documentID
                else { return }
                let value = try await webView.callAsyncJavaScript(
                    "return window.previewmdExportDOCX && window.previewmdExportDOCX(suggestedName);",
                    arguments: ["suggestedName": suggestedName],
                    contentWorld: .page
                )
                if (value as? Bool) != true { NSSound.beep() }
            } catch {
                NSSound.beep()
            }
        }
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

        generatePDFData(in: webView, options: accessory.options) { result in
            switch result {
            case .success(let data):
                do {
                    try data.write(to: destinationURL, options: .atomic)
                    completion(nil)
                } catch {
                    completion(error)
                }
            case .failure(let error):
                completion(error)
            }
        }
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
        generatePDFData(in: webView, options: options) { [weak self] result in
            guard let self else {
                completion(RendererError.rendererUnavailable)
                return
            }
            switch result {
            case .success(let data):
                guard let document = PDFDocument(data: data),
                      let operation = document.printOperation(
                          for: options.printInfo,
                          scalingMode: .pageScaleDownToFit,
                          autoRotate: false
                      )
                else {
                    completion(RendererError.invalidPDFOutput)
                    return
                }
                activePrintDocument = document
                activePrintOperation = operation
                operation.showsPrintPanel = true
                operation.showsProgressPanel = true
                _ = operation.run()
                // Cancelling the native panel is not an application error.
                completion(nil)
            case .failure(let error):
                completion(error)
            }
        }
    }

    private func generatePDFData(
        in webView: WKWebView,
        options: PDFExportOptions,
        completion: @escaping (Result<Data, any Error>) -> Void
    ) {
        guard let data = try? JSONEncoder().encode(options),
              let arguments = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            completion(.failure(RendererError.invalidPrintOptions))
            return
        }

        let synchronize = synchronizeRenderer
        let documentID = attachedDocumentID
        Task { @MainActor [weak self, weak webView] in
            do {
                try await synchronize?()
            } catch {
                completion(.failure(error))
                return
            }
            guard let self, self.attachedDocumentID == documentID,
                  self.webView === webView else {
                completion(.failure(RendererError.rendererUnavailable))
                return
            }
            guard let webView else {
                completion(.failure(RendererError.rendererUnavailable))
                return
            }
            let printInfo = options.printInfo
            let captureSize = printInfo.printableContentSize
            let originalPageZoom = webView.pageZoom
            var rendererIsPrepared = true
            webView.pageZoom = 1
            do {
                let layoutJSON = try await webView.callAsyncJavaScript(
                    """
                    return await window.previewmdPreparePDF(
                        options,
                        contentWidth,
                        contentHeight
                    );
                    """,
                    arguments: [
                        "options": arguments,
                        "contentWidth": captureSize.width,
                        "contentHeight": captureSize.height,
                    ],
                    contentWorld: .page
                )
                guard let layoutJSON = layoutJSON as? String,
                      let layoutData = layoutJSON.data(using: .utf8),
                      let layout = try? JSONDecoder().decode(PDFCaptureLayout.self, from: layoutData),
                      layout.isValid
                else {
                    throw RendererError.invalidPDFLayout
                }

                let configuration = WKPDFConfiguration()
                configuration.rect = CGRect(
                    x: 0,
                    y: 0,
                    width: layout.width,
                    height: layout.height
                )
                configuration.allowTransparentBackground = false
                let sourceData = try await webView.pdf(configuration: configuration)

                try await finishPDFPreparation(in: webView)
                rendererIsPrepared = false
                webView.pageZoom = originalPageZoom

                let output = try PDFPaginator.paginate(
                    sourceData: sourceData,
                    layout: layout,
                    paperSize: printInfo.paperSize,
                    margins: options.margins.points
                )
                completion(.success(output))
            } catch {
                if rendererIsPrepared {
                    try? await finishPDFPreparation(in: webView)
                }
                webView.pageZoom = originalPageZoom
                completion(.failure(error))
            }
        }
    }

    private func finishPDFPreparation(in webView: WKWebView) async throws {
        _ = try await webView.callAsyncJavaScript(
            "await window.previewmdFinishPrint(); return true;",
            arguments: [:],
            contentWorld: .page
        )
    }

    private enum RendererError: LocalizedError {
        case rendererUnavailable
        case invalidPrintOptions
        case invalidPDFLayout
        case invalidPDFOutput

        var errorDescription: String? {
            switch self {
            case .rendererUnavailable:
                "The preview renderer is not available."
            case .invalidPrintOptions:
                "The PDF options could not be prepared."
            case .invalidPDFLayout:
                "The printable document layout could not be measured."
            case .invalidPDFOutput:
                "The PDF renderer did not produce a valid document."
            }
        }
    }
}

struct PDFCaptureLayout: Codable {
    let width: CGFloat
    let height: CGFloat
    let pageBreaks: [CGFloat]

    var isValid: Bool {
        width.isFinite && width > 0
            && height.isFinite && height > 0
            && pageBreaks.count >= 2
            && pageBreaks.first == 0
            && pageBreaks.last == height
            && zip(pageBreaks, pageBreaks.dropFirst()).allSatisfy(<)
    }
}

enum PDFPaginator {
    static func paginate(
        sourceData: Data,
        layout: PDFCaptureLayout,
        paperSize: NSSize,
        margins: CGFloat
    ) throws -> Data {
        guard let provider = CGDataProvider(data: sourceData as CFData),
              let document = CGPDFDocument(provider),
              document.numberOfPages == 1,
              let sourcePage = document.page(at: 1)
        else {
            throw PDFCompositionError.invalidSource
        }

        let sourceBox = sourcePage.getBoxRect(.mediaBox)
        let contentRect = CGRect(
            x: margins,
            y: margins,
            width: paperSize.width - (2 * margins),
            height: paperSize.height - (2 * margins)
        )
        guard sourceBox.width > 0, sourceBox.height > 0,
              contentRect.width > 0, contentRect.height > 0
        else {
            throw PDFCompositionError.invalidGeometry
        }

        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output as CFMutableData) else {
            throw PDFCompositionError.couldNotCreateOutput
        }
        var mediaBox = CGRect(origin: .zero, size: paperSize)
        let metadata = [kCGPDFContextCreator: "PreviewMD"] as CFDictionary
        guard let context = CGContext(
            consumer: consumer,
            mediaBox: &mediaBox,
            metadata
        ) else {
            throw PDFCompositionError.couldNotCreateOutput
        }

        let horizontalScale = contentRect.width / sourceBox.width
        let sourceUnitsPerLayoutPoint = sourceBox.height / layout.height
        for (start, end) in zip(layout.pageBreaks, layout.pageBreaks.dropFirst()) {
            let renderedHeight = (end - start) * sourceUnitsPerLayoutPoint * horizontalScale
            guard renderedHeight <= contentRect.height + 1 else {
                throw PDFCompositionError.invalidPageBreaks
            }

            context.beginPDFPage(nil)
            context.saveGState()
            context.clip(
                to: CGRect(
                    x: contentRect.minX,
                    y: contentRect.maxY - renderedHeight,
                    width: contentRect.width,
                    height: renderedHeight
                )
            )

            let sourceSegmentTop = sourceBox.maxY - (start * sourceUnitsPerLayoutPoint)
            context.translateBy(
                x: contentRect.minX - (sourceBox.minX * horizontalScale),
                y: contentRect.maxY - (sourceSegmentTop * horizontalScale)
            )
            context.scaleBy(x: horizontalScale, y: horizontalScale)
            context.drawPDFPage(sourcePage)
            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()

        let result = output as Data
        guard !result.isEmpty else {
            throw PDFCompositionError.couldNotCreateOutput
        }
        return result
    }

    private enum PDFCompositionError: LocalizedError {
        case invalidSource
        case invalidGeometry
        case invalidPageBreaks
        case couldNotCreateOutput

        var errorDescription: String? {
            switch self {
            case .invalidSource:
                "The web renderer returned an invalid PDF page."
            case .invalidGeometry:
                "The selected paper size and margins leave no printable area."
            case .invalidPageBreaks:
                "The document could not be divided into printable pages."
            case .couldNotCreateOutput:
                "The paginated PDF could not be created."
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

private extension NSPrintInfo {
    var printableContentSize: NSSize {
        NSSize(
            width: paperSize.width - leftMargin - rightMargin,
            height: paperSize.height - topMargin - bottomMargin
        )
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
    var isVisible = true
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
            isSplitSynchronizationEnabled: isSplitSynchronizationEnabled,
            isVisible: isVisible,
            onOutlineChange: state.updateOutline
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
        configuration.userContentController.add(context.coordinator, name: "copyRichText")
        configuration.userContentController.add(context.coordinator, name: "editorChange")
        configuration.userContentController.add(context.coordinator, name: "pickImage")
        configuration.userContentController.add(context.coordinator, name: "splitSync")
        configuration.userContentController.add(context.coordinator, name: "outlineChange")
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
        controller.attach(webView, documentID: documentID, isVisible: isVisible) { [weak coordinator = context.coordinator] in
            guard let coordinator else { throw CancellationError() }
            try await coordinator.prepareForOutput()
        }
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
        controller.attach(webView, documentID: documentID, isVisible: isVisible) { [weak coordinator = context.coordinator] in
            guard let coordinator else { throw CancellationError() }
            try await coordinator.prepareForOutput()
        }
        context.coordinator.documentID = documentID
        context.coordinator.documentURL = documentURL
        context.coordinator.localImageSchemeHandler.updateBaseURL(baseURL)
        context.coordinator.openMarkdown = state.open(url:)
        context.coordinator.onContentChange = onContentChange
        context.coordinator.onOutlineChange = state.updateOutline
        context.coordinator.isVisible = isVisible
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
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "copyRichText")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "editorChange")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "pickImage")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "splitSync")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "outlineChange")
        coordinator.outlineTask?.cancel()
        coordinator.renderTask?.cancel()
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
        var onOutlineChange: ([OutlineHeading], UUID, String) -> Void
        var isVisible: Bool
        fileprivate var outlineTask: Task<Void, Never>?
        fileprivate var renderTask: Task<Void, any Error>?
        private var renderGeneration = 0

        private enum OutputPreparationError: LocalizedError {
            case previewNotReady

            var errorDescription: String? {
                "The document preview did not finish loading."
            }
        }
        weak var splitSynchronizer: SplitEditorSynchronizer?
        var isSplitSynchronizationEnabled: Bool
        var basePath = ""
        let localImageSchemeHandler: LocalImageSchemeHandler

        private var isLoaded = false
        private var pendingPayload: RenderPayload?
        private var lastPayload: RenderPayload?
        private var lastEditorMarkdown: String?
        private var lastEditorDocumentID: UUID?
        private var richCopyGeneration = 0
        private var richCopyAssetToken = 0
        private var richCopyAssetTimeoutTask: Task<Void, Never>?
        private var richCopySnapshotsAvailable = true
        private var richCopySnapshotCount = 0
        private var richCopyPasteboardChangeCount = 0

        private struct RichCopyAsset {
            let id: String
            let label: String
            let width: Double
            let height: Double
            let displayWidth: Double
            let displayHeight: Double
            let svg: String
            let markup: String
        }

        private struct RichCopyRequest {
            let html: String
            let plainText: String
            let markdown: String
            let destination: String
            let suggestedName: String
            let standaloneAssetID: String?

            var format: AdvancedCopyFormat? {
                AdvancedCopyFormat(rawValue: destination)
            }

            var exportsDOCX: Bool { destination == "exportDOCX" }
        }

        init(
            documentID: UUID,
            documentURL: URL?,
            openMarkdown: @escaping (URL) -> Void,
            onContentChange: @escaping (UUID, String, Bool) -> Void,
            splitSynchronizer: SplitEditorSynchronizer,
            isSplitSynchronizationEnabled: Bool,
            isVisible: Bool = true,
            onOutlineChange: @escaping ([OutlineHeading], UUID, String) -> Void = { _, _, _ in }
        ) {
            self.documentID = documentID
            self.documentURL = documentURL
            self.openMarkdown = openMarkdown
            self.onContentChange = onContentChange
            self.splitSynchronizer = splitSynchronizer
            self.isSplitSynchronizationEnabled = isSplitSynchronizationEnabled
            self.isVisible = isVisible
            self.onOutlineChange = onOutlineChange
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
            if wasEnabled != isEnabled, isLoaded {
                webView?.evaluateJavaScript(
                    "window.previewmdSetSplitSynchronizationEnabled && window.previewmdSetSplitSynchronizationEnabled(\(isEnabled));"
                )
            }
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
            renderTask?.cancel()
            renderTask = nil
            renderGeneration += 1
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
            guard payload != lastPayload || pendingPayload != nil else { return }
            pendingPayload = payload
            guard isLoaded else { return }
            applyPendingPayload(in: webView)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            isLoaded = true
            webView.evaluateJavaScript(
                "window.previewmdSetSplitSynchronizationEnabled && window.previewmdSetSplitSynchronizationEnabled(\(isSplitSynchronizationEnabled));"
            )
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
                    richCopyGeneration += 1
                    richCopyAssetToken += 1
                    richCopyAssetTimeoutTask?.cancel()
                    richCopyAssetTimeoutTask = nil
                    webView?.evaluateJavaScript(
                        "window.previewmdFinishClipboardAssetSnapshot && "
                            + "window.previewmdFinishClipboardAssetSnapshot();"
                    )
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                case "copyRichText":
                    beginPortableRichCopy(message.body)
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
                case "outlineChange":
                    guard let body = message.body as? [String: Any],
                          let markdown = body["markdown"] as? String,
                          let headings = Self.outlineHeadings(body["headings"])
                    else { return }
                    onOutlineChange(headings, documentID, markdown)
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

        private func beginPortableRichCopy(_ messageBody: Any) {
            guard let body = messageBody as? [String: Any],
                  let html = body["html"] as? String,
                  let plainText = body["plainText"] as? String,
                  html.utf8.count <= 20 * 1_024 * 1_024,
                  plainText.utf8.count <= 10 * 1_024 * 1_024
            else { return }

            let request = RichCopyRequest(
                html: html,
                plainText: plainText,
                markdown: String((body["markdown"] as? String ?? plainText).prefix(10 * 1_024 * 1_024)),
                destination: body["destination"] as? String ?? "automatic",
                suggestedName: String((body["suggestedName"] as? String ?? "PreviewMD Document.docx").prefix(256)),
                standaloneAssetID: body["standaloneAssetID"] as? String
            )
            let assetDictionaries = body["assets"] as? [[String: Any]] ?? []
            let assets = assetDictionaries.prefix(512).compactMap(Self.richCopyAsset)
            richCopyGeneration += 1
            let generation = richCopyGeneration
            richCopyAssetToken += 1
            richCopyAssetTimeoutTask?.cancel()
            richCopyAssetTimeoutTask = nil
            richCopySnapshotsAvailable = true
            richCopySnapshotCount = 0
            webView?.evaluateJavaScript(
                "window.previewmdFinishClipboardAssetSnapshot && "
                    + "window.previewmdFinishClipboardAssetSnapshot();"
            )

            guard !assets.isEmpty else {
                finishPortableRichCopy(request, assets: [])
                return
            }

            // The native bridge owns this pasteboard transaction. Publish a
            // readable fallback immediately, then replace it only if no newer
            // copy occurred while WebKit was resolving the embedded assets.
            if !request.exportsDOCX {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(plainText, forType: .string)
            }
            richCopyPasteboardChangeCount = NSPasteboard.general.changeCount

            guard let webView else { return }
            resolvePortableCopyAssets(
                assets,
                at: 0,
                resolved: [],
                request: request,
                generation: generation,
                webView: webView
            )
        }

        private static func richCopyAsset(_ dictionary: [String: Any]) -> RichCopyAsset? {
            guard let id = dictionary["id"] as? String,
                  id.count <= 96,
                  id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
                  let width = number(dictionary["width"]),
                  let height = number(dictionary["height"]),
                  let displayWidth = number(dictionary["displayWidth"]),
                  let displayHeight = number(dictionary["displayHeight"]),
                  width.isFinite,
                  height.isFinite,
                  displayWidth.isFinite,
                  displayHeight.isFinite
            else { return nil }

            let label = String((dictionary["label"] as? String ?? "Item").prefix(4_096))
            let svg = dictionary["svg"] as? String ?? ""
            let markup = dictionary["markup"] as? String ?? ""
            guard svg.utf8.count <= 10 * 1_024 * 1_024,
                  markup.utf8.count <= 2 * 1_024 * 1_024
            else { return nil }
            let safeDisplayWidth = max(1, displayWidth)
            let safeDisplayHeight = max(1, displayHeight)
            let displayScale = min(
                1,
                420 / safeDisplayWidth,
                360 / safeDisplayHeight
            )
            return RichCopyAsset(
                id: id,
                label: label,
                width: min(2_400, max(1, width)),
                height: min(2_400, max(1, height)),
                displayWidth: safeDisplayWidth * displayScale,
                displayHeight: safeDisplayHeight * displayScale,
                svg: svg,
                markup: markup
            )
        }

        private func resolvePortableCopyAssets(
            _ assets: [RichCopyAsset],
            at index: Int,
            resolved: [PortableRichTextClipboard.EmbeddedAsset],
            request: RichCopyRequest,
            generation: Int,
            webView: WKWebView
        ) {
            guard generation == richCopyGeneration else { return }
            guard request.exportsDOCX ||
                    NSPasteboard.general.changeCount == richCopyPasteboardChangeCount
            else {
                richCopyAssetTimeoutTask?.cancel()
                richCopyAssetTimeoutTask = nil
                finishClipboardAssetSnapshot(in: webView)
                return
            }
            guard index < assets.count else {
                richCopyAssetTimeoutTask?.cancel()
                richCopyAssetTimeoutTask = nil
                finishClipboardAssetSnapshot(in: webView)
                finishPortableRichCopy(request, assets: resolved)
                return
            }

            let asset = assets[index]
            guard !asset.markup.isEmpty else {
                var next = resolved
                next.append(fallbackAsset(for: asset))
                resolvePortableCopyAssets(
                    assets,
                    at: index + 1,
                    resolved: next,
                    request: request,
                    generation: generation,
                    webView: webView
                )
                return
            }

            guard richCopySnapshotsAvailable, richCopySnapshotCount < 48 else {
                var next = resolved
                next.append(fallbackAsset(for: asset))
                resolvePortableCopyAssets(
                    assets,
                    at: index + 1,
                    resolved: next,
                    request: request,
                    generation: generation,
                    webView: webView
                )
                return
            }
            richCopySnapshotCount += 1

            richCopyAssetToken += 1
            let assetToken = richCopyAssetToken
            richCopyAssetTimeoutTask?.cancel()
            richCopyAssetTimeoutTask = Task { [weak self, weak webView] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled,
                      let self,
                      let webView
                else { return }
                self.completePortableCopyAsset(
                    pngData: nil,
                    asset: asset,
                    assets: assets,
                    index: index,
                    resolved: resolved,
                    request: request,
                    generation: generation,
                    assetToken: assetToken,
                    webView: webView
                )
            }

            webView.callAsyncJavaScript(
                """
                return await window.previewmdPrepareClipboardAssetSnapshot(
                  markup,
                  width,
                  height
                );
                """,
                arguments: [
                    "markup": asset.markup,
                    "width": asset.width,
                    "height": asset.height,
                ],
                in: nil,
                in: .page
            ) { [weak self, weak webView] result in
                guard let self,
                      let webView,
                      generation == self.richCopyGeneration,
                      assetToken == self.richCopyAssetToken
                else { return }
                guard case let .success(value) = result,
                      let frame = value as? [String: Any],
                      let x = Self.number(frame["x"]),
                      let y = Self.number(frame["y"]),
                      let width = Self.number(frame["width"]),
                      let height = Self.number(frame["height"]),
                      width > 0,
                      height > 0
                else {
                    self.completePortableCopyAsset(
                        pngData: nil,
                        asset: asset,
                        assets: assets,
                        index: index,
                        resolved: resolved,
                        request: request,
                        generation: generation,
                        assetToken: assetToken,
                        webView: webView
                    )
                    return
                }

                let configuration = WKSnapshotConfiguration()
                configuration.rect = NSRect(x: x, y: y, width: width, height: height)
                    .intersection(webView.bounds)
                configuration.snapshotWidth = NSNumber(
                    value: min(4_096, max(width, width * 3))
                )
                webView.takeSnapshot(with: configuration) { [weak self, weak webView] image, _ in
                    guard let self,
                          let webView,
                          generation == self.richCopyGeneration,
                          assetToken == self.richCopyAssetToken
                    else { return }
                    self.completePortableCopyAsset(
                        pngData: image.flatMap {
                            Self.pngData(
                                from: $0,
                                logicalSize: NSSize(
                                    width: asset.displayWidth,
                                    height: asset.displayHeight
                                )
                            )
                        },
                        asset: asset,
                        assets: assets,
                        index: index,
                        resolved: resolved,
                        request: request,
                        generation: generation,
                        assetToken: assetToken,
                        webView: webView
                    )
                }
            }
        }

        private func completePortableCopyAsset(
            pngData: Data?,
            asset: RichCopyAsset,
            assets: [RichCopyAsset],
            index: Int,
            resolved: [PortableRichTextClipboard.EmbeddedAsset],
            request: RichCopyRequest,
            generation: Int,
            assetToken: Int,
            webView: WKWebView
        ) {
            guard generation == richCopyGeneration,
                  assetToken == richCopyAssetToken
            else { return }
            richCopyAssetToken += 1
            richCopyAssetTimeoutTask?.cancel()
            richCopyAssetTimeoutTask = nil
            finishClipboardAssetSnapshot(in: webView)

            var next = resolved
            if let pngData {
                next.append(
                    PortableRichTextClipboard.EmbeddedAsset(
                        id: asset.id,
                        mimeType: "image/png",
                        data: pngData,
                        width: asset.displayWidth,
                        height: asset.displayHeight,
                        standaloneSVG: asset.svg.isEmpty ? nil : Data(asset.svg.utf8)
                    )
                )
            } else {
                // A failed or timed-out WebKit snapshot is usually systemic.
                // Do not spend another timeout on every formula in a large
                // selection; the remaining assets use readable PNG fallbacks.
                richCopySnapshotsAvailable = false
                next.append(fallbackAsset(for: asset))
            }
            resolvePortableCopyAssets(
                assets,
                at: index + 1,
                resolved: next,
                request: request,
                generation: generation,
                webView: webView
            )
        }

        private func finishPortableRichCopy(
            _ request: RichCopyRequest,
            assets: [PortableRichTextClipboard.EmbeddedAsset]
        ) {
            do {
                if request.exportsDOCX {
                    try exportDOCX(request: request, assets: assets)
                    return
                }
                if request.format == .docxFile {
                    let data = try DOCXDocumentWriter.data(
                        html: request.html,
                        title: (request.suggestedName as NSString).deletingPathExtension,
                        assets: assets
                    )
                    _ = try DOCXDocumentWriter.copyFile(
                        data: data,
                        suggestedName: request.suggestedName
                    )
                    return
                }
                let succeeded = PortableRichTextClipboard.write(
                    html: request.html,
                    plainText: request.plainText,
                    markdown: request.markdown,
                    assets: assets,
                    standaloneAssetID: request.standaloneAssetID,
                    format: request.format
                )
                if !succeeded { NSSound.beep() }
            } catch {
                presentDOCXError(error)
            }
        }

        private func exportDOCX(
            request: RichCopyRequest,
            assets: [PortableRichTextClipboard.EmbeddedAsset]
        ) throws {
            let panel = NSSavePanel()
            panel.title = "Export DOCX"
            panel.prompt = "Export"
            panel.nameFieldStringValue = request.suggestedName
            panel.allowedContentTypes = [
                UTType(importedAs: "org.openxmlformats.wordprocessingml.document")
            ]
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let destinationURL = panel.url else { return }
            let data = try DOCXDocumentWriter.data(
                html: request.html,
                title: destinationURL.deletingPathExtension().lastPathComponent,
                assets: assets
            )
            try data.write(to: destinationURL, options: .atomic)
        }

        private func presentDOCXError(_ error: any Error) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn’t create DOCX"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }

        private func finishClipboardAssetSnapshot(in webView: WKWebView) {
            webView.evaluateJavaScript(
                "window.previewmdFinishClipboardAssetSnapshot && "
                    + "window.previewmdFinishClipboardAssetSnapshot();"
            )
        }

        private static func pngData(from image: NSImage, logicalSize: NSSize) -> Data? {
            let width = max(1, Int(logicalSize.width.rounded(.up)))
            let height = max(1, Int(logicalSize.height.rounded(.up)))
            guard let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: width,
                pixelsHigh: height,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ), let context = NSGraphicsContext(bitmapImageRep: bitmap)
            else { return nil }

            // Render at 3× in WebKit, then supersample into the exact logical
            // pixel size. RTFD has no interoperable image-size metadata: Pages
            // treats each backing pixel as a point and ignores PNG density.
            // Downsampling here keeps text and lines clean without changing
            // their physical size in the destination.
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.imageInterpolation = .high
            image.draw(
                in: NSRect(x: 0, y: 0, width: width, height: height),
                from: NSRect(origin: .zero, size: image.size),
                operation: .copy,
                fraction: 1
            )
            NSGraphicsContext.restoreGraphicsState()
            bitmap.size = NSSize(width: width, height: height)
            return bitmap.representation(using: .png, properties: [:])
        }

        private func fallbackAsset(
            for asset: RichCopyAsset
        ) -> PortableRichTextClipboard.EmbeddedAsset {
            let fallback = PortableRichTextClipboard.fallbackAsset(
                id: asset.id,
                label: asset.label,
                width: asset.displayWidth,
                height: asset.displayHeight
            )
            return PortableRichTextClipboard.EmbeddedAsset(
                id: fallback.id,
                mimeType: fallback.mimeType,
                data: fallback.data,
                width: fallback.width,
                height: fallback.height,
                standaloneSVG: asset.svg.isEmpty ? nil : Data(asset.svg.utf8)
            )
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

        func prepareForOutput() async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !isLoaded {
                guard ContinuousClock.now < deadline else {
                    throw OutputPreparationError.previewNotReady
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            guard let webView else { throw CancellationError() }
            while true {
                if let task = renderTask {
                    try await task.value
                    continue
                }
                guard pendingPayload != nil else { return }
                applyPendingPayload(in: webView, forceRender: true)
            }
        }

        private func applyPendingPayload(in webView: WKWebView, forceRender: Bool = false) {
            guard let payload = pendingPayload else { return }

            guard isVisible || forceRender else {
                scheduleHiddenOutline(for: payload, in: webView)
                return
            }
            // Keep the latest payload queued until the current render finishes,
            // including its asynchronous diagrams and layout work.
            guard renderTask == nil else { return }
            outlineTask?.cancel()
            outlineTask = nil

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
            renderGeneration += 1
            let generation = renderGeneration
            renderTask = Task { @MainActor [weak self, weak webView] in
                guard let self, let webView else { throw CancellationError() }
                do {
                    try Task.checkCancellation()
                    _ = try await webView.callAsyncJavaScript(
                        "await window.previewmdRender(\(json)); return true;",
                        arguments: [:],
                        contentWorld: .page
                    )
                    try Task.checkCancellation()
                } catch {
                    if self.renderGeneration == generation {
                        self.renderTask = nil
                        self.lastPayload = nil
                        if self.pendingPayload == nil { self.pendingPayload = payload }
                    }
                    throw error
                }
                guard self.renderGeneration == generation else { return }
                self.renderTask = nil
                if self.isVisible { self.applyPendingPayload(in: webView) }
            }
        }

        private func scheduleHiddenOutline(for payload: RenderPayload, in webView: WKWebView) {
            outlineTask?.cancel()
            outlineTask = Task { @MainActor [weak self, weak webView] in
                do {
                    try await Task.sleep(for: .milliseconds(100))
                    guard let self, let webView, !self.isVisible,
                          self.pendingPayload == payload else { return }
                    let result = try await webView.callAsyncJavaScript(
                        "return window.previewmdOutlineForMarkdown(markdown);",
                        arguments: ["markdown": payload.markdown],
                        contentWorld: .page
                    )
                    guard !Task.isCancelled, !self.isVisible,
                          self.pendingPayload == payload,
                          let headings = Self.outlineHeadings(result) else { return }
                    self.onOutlineChange(headings, self.documentID, payload.markdown)
                } catch {
                    // A hidden outline refresh is superseded by newer edits or
                    // the full render when the preview becomes visible.
                }
            }
        }

        private static func outlineHeadings(_ value: Any?) -> [OutlineHeading]? {
            guard let entries = value as? [[String: Any]] else { return nil }
            var headings: [OutlineHeading] = []
            for entry in entries {
                guard let id = entry["id"] as? String,
                      let level = entry["level"] as? Int,
                      (1...6).contains(level), let title = entry["title"] as? String
                else { return nil }
                headings.append(OutlineHeading(id: id, level: level, title: title))
            }
            return headings
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
