import Combine
import Foundation

struct SplitEditorScrollPosition: Equatable {
    let sourceLine: Double
}

struct SplitEditorSelection: Equatable {
    let range: NSRange
}

@MainActor
protocol SplitSourceSynchronizationEndpoint: AnyObject {
    func applyPreviewScrollPosition(_ position: SplitEditorScrollPosition)
    func applyPreviewSelection(_ selection: SplitEditorSelection)
}

@MainActor
protocol SplitPreviewSynchronizationEndpoint: AnyObject {
    func applySourceScrollPosition(_ position: SplitEditorScrollPosition)
    func applySourceSelection(_ selection: SplitEditorSelection)
}

/// Routes positions between the native source editor and the rendered editor.
/// Endpoints suppress notifications while applying remote state, so updates do
/// not bounce indefinitely between AppKit and WebKit.
@MainActor
final class SplitEditorSynchronizer: ObservableObject {
    private weak var sourceEndpoint: (any SplitSourceSynchronizationEndpoint)?
    private weak var previewEndpoint: (any SplitPreviewSynchronizationEndpoint)?
    private var sourceDocumentID: UUID?
    private var previewDocumentID: UUID?
    private var latestSourceScroll: (UUID, SplitEditorScrollPosition)?
    private var latestSelection: (UUID, SplitEditorSelection, SelectionOrigin)?

    private enum SelectionOrigin {
        case source
        case preview
    }

    func attachSource(
        _ endpoint: any SplitSourceSynchronizationEndpoint,
        documentID: UUID
    ) {
        sourceEndpoint = endpoint
        sourceDocumentID = documentID
    }

    func attachPreview(
        _ endpoint: any SplitPreviewSynchronizationEndpoint,
        documentID: UUID
    ) {
        previewEndpoint = endpoint
        previewDocumentID = documentID
    }

    func detachSource(_ endpoint: any SplitSourceSynchronizationEndpoint) {
        guard sourceEndpoint === endpoint else { return }
        sourceEndpoint = nil
        sourceDocumentID = nil
    }

    func detachPreview(_ endpoint: any SplitPreviewSynchronizationEndpoint) {
        guard previewEndpoint === endpoint else { return }
        previewEndpoint = nil
        previewDocumentID = nil
    }

    func sourceDidScroll(
        _ position: SplitEditorScrollPosition,
        documentID: UUID
    ) {
        guard sourceDocumentID == documentID else { return }
        latestSourceScroll = (documentID, position)
        guard previewDocumentID == documentID else { return }
        previewEndpoint?.applySourceScrollPosition(position)
    }

    func previewDidScroll(
        _ position: SplitEditorScrollPosition,
        documentID: UUID
    ) {
        guard previewDocumentID == documentID,
              sourceDocumentID == documentID else { return }
        sourceEndpoint?.applyPreviewScrollPosition(position)
    }

    func sourceDidChangeSelection(
        _ selection: SplitEditorSelection,
        documentID: UUID
    ) {
        guard sourceDocumentID == documentID else { return }
        latestSelection = (documentID, selection, .source)
        guard previewDocumentID == documentID else { return }
        previewEndpoint?.applySourceSelection(selection)
    }

    func previewDidChangeSelection(
        _ selection: SplitEditorSelection,
        documentID: UUID
    ) {
        guard previewDocumentID == documentID,
              sourceDocumentID == documentID else { return }
        latestSelection = (documentID, selection, .preview)
        sourceEndpoint?.applyPreviewSelection(selection)
    }

    /// A source edit rebuilds rendered DOM. Reapply the last native position
    /// after that render so the counterpart highlight does not disappear.
    func previewDidBecomeReady(documentID: UUID) {
        guard previewDocumentID == documentID else { return }
        if let (selectionDocumentID, selection, origin) = latestSelection,
           selectionDocumentID == documentID,
           origin == .source {
            previewEndpoint?.applySourceSelection(selection)
        }
        if let (scrollDocumentID, position) = latestSourceScroll,
           scrollDocumentID == documentID {
            previewEndpoint?.applySourceScrollPosition(position)
        }
    }

    /// SwiftUI can deliver the rich-editor selection before its markdown
    /// binding reaches AppKit. Apply it again once the native text is current.
    func sourceDidBecomeReady(documentID: UUID) {
        guard sourceDocumentID == documentID else { return }
        if let (selectionDocumentID, selection, origin) = latestSelection,
           selectionDocumentID == documentID,
           origin == .preview {
            sourceEndpoint?.applyPreviewSelection(selection)
        }
    }
}
