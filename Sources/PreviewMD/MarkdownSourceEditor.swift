import AppKit
import SwiftUI

/// Keeps Markdown-specific typing behavior in the plain-text editor without
/// letting AppKit import presentation attributes from the pasteboard.
@MainActor
final class MarkdownSourceTextView: NSTextView {
    var synchronizedSelectionRange: NSRange? {
        didSet { needsDisplay = true }
    }

    override func insertNewline(_ sender: Any?) {
        let selection = selectedRange()
        guard selection.length == 0,
              let prefix = MarkdownTaskListEditing.continuationPrefix(
                in: string,
                atUTF16Offset: selection.location
              ) else {
            super.insertNewline(sender)
            return
        }

        insertText("\n\(prefix)", replacementRange: selection)
    }

    override func paste(_ sender: Any?) {
        guard pastePlainText(from: .general) else {
            super.paste(sender)
            return
        }
    }

    @discardableResult
    func pastePlainText(from pasteboard: NSPasteboard) -> Bool {
        guard let plainText = pasteboard.string(forType: .string) else {
            return false
        }
        insertText(plainText, replacementRange: selectedRange())
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let synchronizedSelectionRange,
              window?.firstResponder !== self,
              let layoutManager,
              let textContainer else { return }
        let sourceLength = (string as NSString).length
        let location = min(
            max(0, synchronizedSelectionRange.location),
            sourceLength
        )
        let length = min(
            max(0, synchronizedSelectionRange.length),
            sourceLength - location
        )
        let color = NSColor.controlAccentColor

        if length > 0 {
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: NSRange(location: location, length: length),
                actualCharacterRange: nil
            )
            let rect = layoutManager.boundingRect(
                forGlyphRange: glyphRange,
                in: textContainer
            ).offsetBy(
                dx: textContainerOrigin.x,
                dy: textContainerOrigin.y
            )
            guard rect.intersects(dirtyRect) else { return }
            color.withAlphaComponent(0.20).setFill()
            NSBezierPath(
                roundedRect: rect.insetBy(dx: -1, dy: -0.5),
                xRadius: 3,
                yRadius: 3
            ).fill()
            return
        }

        layoutManager.ensureLayout(for: textContainer)
        let caretRect: NSRect
        if location < sourceLength, layoutManager.numberOfGlyphs > 0 {
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: location)
            let glyphRect = layoutManager.boundingRect(
                forGlyphRange: NSRange(location: glyphIndex, length: 1),
                in: textContainer
            )
            let lineRect = layoutManager.lineFragmentUsedRect(
                forGlyphAt: glyphIndex,
                effectiveRange: nil
            )
            caretRect = NSRect(
                x: glyphRect.minX + textContainerOrigin.x,
                y: lineRect.minY + textContainerOrigin.y,
                width: 2,
                height: max(12, lineRect.height)
            )
        } else {
            let extra = layoutManager.extraLineFragmentRect
            caretRect = NSRect(
                x: extra.minX + textContainerOrigin.x,
                y: extra.minY + textContainerOrigin.y,
                width: 2,
                height: max(12, extra.height)
            )
        }
        guard caretRect.intersects(dirtyRect) else { return }
        color.withAlphaComponent(0.85).setFill()
        caretRect.fill()
    }
}

enum MarkdownTaskListEditing {
    private static let prefixExpression = try! NSRegularExpression(
        pattern: #"^([\t ]*(?:[-+*]|\d+[.)])[\t ]+)\[[ xX]\]([\t ]+)"#
    )

    static func continuationPrefix(
        in text: String,
        atUTF16Offset requestedOffset: Int
    ) -> String? {
        let source = text as NSString
        let offset = min(max(0, requestedOffset), source.length)
        var lineStart = 0
        var lineEnd = 0
        var contentsEnd = 0
        source.getLineStart(
            &lineStart,
            end: &lineEnd,
            contentsEnd: &contentsEnd,
            for: NSRange(location: offset, length: 0)
        )
        let lineRange = NSRange(
            location: lineStart,
            length: max(0, contentsEnd - lineStart)
        )
        guard let match = prefixExpression.firstMatch(
            in: text,
            range: lineRange
        ),
        match.range.location == lineStart,
        offset >= NSMaxRange(match.range) else {
            return nil
        }

        let contentRange = NSRange(
            location: NSMaxRange(match.range),
            length: max(0, contentsEnd - NSMaxRange(match.range))
        )
        guard !source.substring(with: contentRange)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty else {
            return nil
        }

        return source.substring(with: match.range(at: 1))
            + "[ ]"
            + source.substring(with: match.range(at: 2))
    }
}

/// Keeps the gutter separate from the scroll view's document tiling. SwiftUI
/// may temporarily stretch the overlay while revealing a zero-width source
/// pane, so the overlay itself draws only inside its declared gutter width.
@MainActor
final class MarkdownSourceContainerView: NSView {
    let scrollView: NSScrollView
    let lineNumberOverlay: MarkdownLineNumberRulerView

    init(
        scrollView: NSScrollView,
        lineNumberOverlay: MarkdownLineNumberRulerView
    ) {
        self.scrollView = scrollView
        self.lineNumberOverlay = lineNumberOverlay
        super.init(frame: .zero)
        addSubview(scrollView)
        addSubview(lineNumberOverlay)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        scrollView.tile()

        lineNumberOverlay.frame = NSRect(
            x: 0,
            y: 0,
            width: lineNumberOverlay.requiredWidth,
            height: bounds.height
        )
        guard let textView = scrollView.documentView as? NSTextView else {
            return
        }
        let desiredInset = NSSize(
            width: lineNumberOverlay.requiredWidth + 16,
            height: 14
        )
        if textView.textContainerInset != desiredInset {
            textView.textContainerInset = desiredInset
        }
    }
}

/// A native, wrapping source editor with lightweight Markdown coloring.
/// It deliberately keeps plain text as the source of truth; attributes are
/// presentation-only and are reapplied after edits or external reloads.
struct MarkdownSourceEditor: NSViewRepresentable {
    @Binding var text: String
    var documentID: UUID? = nil
    var splitSynchronizer: SplitEditorSynchronizer? = nil
    var isSplitSynchronizationEnabled = false

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            documentID: documentID,
            splitSynchronizer: splitSynchronizer,
            isSplitSynchronizationEnabled: isSplitSynchronizationEnabled
        )
    }

    func makeNSView(context: Context) -> MarkdownSourceContainerView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let textView = MarkdownSourceTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 56, height: 14)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.backgroundColor = .clear
        textView.string = text
        scrollView.documentView = textView

        let lineNumberRuler = MarkdownLineNumberRulerView(
            scrollView: scrollView,
            textView: textView
        )
        let container = MarkdownSourceContainerView(
            scrollView: scrollView,
            lineNumberOverlay: lineNumberRuler
        )

        context.coordinator.textView = textView
        context.coordinator.lineNumberRuler = lineNumberRuler
        context.coordinator.observeScrolling(in: scrollView)
        context.coordinator.updateSynchronization(
            documentID: documentID,
            splitSynchronizer: splitSynchronizer,
            isEnabled: isSplitSynchronizationEnabled
        )
        context.coordinator.highlight()
        return container
    }

    func updateNSView(
        _ container: MarkdownSourceContainerView,
        context: Context
    ) {
        context.coordinator.text = $text
        context.coordinator.updateSynchronization(
            documentID: documentID,
            splitSynchronizer: splitSynchronizer,
            isEnabled: isSplitSynchronizationEnabled
        )
        guard let textView = context.coordinator.textView else { return }
        let contentChanged = textView.string != text
        let appearanceChanged = context.coordinator.lastAppearanceName
            != textView.effectiveAppearance.name
        if contentChanged {
            let selection = textView.selectedRange()
            textView.string = text
            context.coordinator.withoutPublishingSelection {
                textView.setSelectedRange(
                    NSRange(
                        location: min(selection.location, (text as NSString).length),
                        length: 0
                    )
                )
            }
        }
        if contentChanged || appearanceChanged {
            context.coordinator.highlight()
            context.coordinator.lineNumberRuler?.reload()
        }
        if contentChanged,
           let documentID,
           isSplitSynchronizationEnabled {
            splitSynchronizer?.sourceDidBecomeReady(documentID: documentID)
        }
    }

    static func dismantleNSView(
        _ container: MarkdownSourceContainerView,
        coordinator: Coordinator
    ) {
        coordinator.stopObservingScrolling()
        if let splitSynchronizer = coordinator.splitSynchronizer {
            splitSynchronizer.detachSource(coordinator)
        }
    }

    @MainActor
    final class Coordinator: NSObject,
        NSTextViewDelegate,
        SplitSourceSynchronizationEndpoint
    {
        var text: Binding<String>
        weak var textView: NSTextView?
        weak var lineNumberRuler: MarkdownLineNumberRulerView?
        weak var scrollView: NSScrollView?
        weak var splitSynchronizer: SplitEditorSynchronizer?
        var documentID: UUID?
        var isSplitSynchronizationEnabled: Bool
        var lastAppearanceName: NSAppearance.Name?
        private var scheduledHighlight: DispatchWorkItem?
        private var scheduledScrollPublication: DispatchWorkItem?
        private var isApplyingRemoteScroll = false
        private var isApplyingRemoteSelection = false

        init(
            text: Binding<String>,
            documentID: UUID?,
            splitSynchronizer: SplitEditorSynchronizer?,
            isSplitSynchronizationEnabled: Bool
        ) {
            self.text = text
            self.documentID = documentID
            self.splitSynchronizer = splitSynchronizer
            self.isSplitSynchronizationEnabled = isSplitSynchronizationEnabled
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            text.wrappedValue = textView.string
            lineNumberRuler?.reload()
            scheduleHighlight()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            textView.typingAttributes = baseAttributes(for: textView)
            lineNumberRuler?.selectionDidChange()
            if !isApplyingRemoteSelection {
                (textView as? MarkdownSourceTextView)?.synchronizedSelectionRange = nil
            }
            guard isSplitSynchronizationEnabled,
                  !isApplyingRemoteSelection,
                  let documentID else { return }
            splitSynchronizer?.sourceDidChangeSelection(
                SplitEditorSelection(range: textView.selectedRange()),
                documentID: documentID
            )
        }

        func updateSynchronization(
            documentID: UUID?,
            splitSynchronizer: SplitEditorSynchronizer?,
            isEnabled: Bool
        ) {
            let wasEnabled = isSplitSynchronizationEnabled
            if let previous = self.splitSynchronizer,
               previous !== splitSynchronizer {
                previous.detachSource(self)
            }
            self.documentID = documentID
            self.splitSynchronizer = splitSynchronizer
            isSplitSynchronizationEnabled = isEnabled
            if wasEnabled && !isEnabled {
                (textView as? MarkdownSourceTextView)?.synchronizedSelectionRange = nil
            }
            if let splitSynchronizer, let documentID {
                splitSynchronizer.attachSource(self, documentID: documentID)
            }
        }

        func observeScrolling(in scrollView: NSScrollView) {
            stopObservingScrolling()
            self.scrollView = scrollView
            scrollView.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(scrollBoundsDidChange(_:)),
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView
            )
        }

        func stopObservingScrolling() {
            scheduledScrollPublication?.cancel()
            scheduledScrollPublication = nil
            if let scrollView {
                NotificationCenter.default.removeObserver(
                    self,
                    name: NSView.boundsDidChangeNotification,
                    object: scrollView.contentView
                )
            }
            scrollView = nil
        }

        @objc private func scrollBoundsDidChange(_ notification: Notification) {
            guard isSplitSynchronizationEnabled,
                  !isApplyingRemoteScroll,
                  documentID != nil else { return }
            scheduledScrollPublication?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.publishScrollPosition()
            }
            scheduledScrollPublication = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.016, execute: work)
        }

        private func publishScrollPosition() {
            guard isSplitSynchronizationEnabled,
                  !isApplyingRemoteScroll,
                  let documentID,
                  let position = currentScrollPosition() else { return }
            splitSynchronizer?.sourceDidScroll(position, documentID: documentID)
        }

        func currentScrollPosition() -> SplitEditorScrollPosition? {
            guard let textView,
                  let scrollView,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return nil }
            layoutManager.ensureLayout(for: textContainer)
            guard layoutManager.numberOfGlyphs > 0 else {
                return SplitEditorScrollPosition(sourceLine: 0)
            }
            let anchorY = scrollAnchor(
                forViewportHeight: scrollView.contentView.bounds.height
            )
            let visibleY = textView.visibleRect.minY + anchorY
            let containerPoint = NSPoint(
                x: 0,
                y: max(0, visibleY - textView.textContainerOrigin.y)
            )
            let glyphIndex = layoutManager.glyphIndex(
                for: containerPoint,
                in: textContainer
            )
            let characterIndex = min(
                layoutManager.characterIndexForGlyph(at: glyphIndex),
                (textView.string as NSString).length
            )
            let starts = MarkdownLineMap.lineStartOffsets(in: textView.string)
            let line = MarkdownLineMap.lineIndex(
                containingUTF16Offset: characterIndex,
                starts: starts
            )
            return SplitEditorScrollPosition(sourceLine: Double(line))
        }

        func applyPreviewScrollPosition(_ position: SplitEditorScrollPosition) {
            guard isSplitSynchronizationEnabled,
                  let textView,
                  let scrollView,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }
            let starts = MarkdownLineMap.lineStartOffsets(in: textView.string)
            guard !starts.isEmpty else { return }
            let lineIndex = min(
                max(0, Int(position.sourceLine.rounded(.down))),
                starts.count - 1
            )
            let characterIndex = min(
                starts[lineIndex],
                (textView.string as NSString).length
            )
            layoutManager.ensureLayout(for: textContainer)
            let lineRect: NSRect
            if characterIndex < (textView.string as NSString).length {
                let glyphIndex = layoutManager.glyphIndexForCharacter(at: characterIndex)
                lineRect = layoutManager.lineFragmentRect(
                    forGlyphAt: glyphIndex,
                    effectiveRange: nil
                )
            } else {
                lineRect = layoutManager.extraLineFragmentRect
            }
            let targetY = max(
                0,
                lineRect.midY + textView.textContainerOrigin.y
                    - scrollAnchor(
                        forViewportHeight: scrollView.contentView.bounds.height
                    )
            )
            isApplyingRemoteScroll = true
            textView.scroll(
                NSPoint(
                    x: textView.visibleRect.minX,
                    y: targetY
                )
            )
            scrollView.reflectScrolledClipView(scrollView.contentView)
            DispatchQueue.main.async { [weak self] in
                self?.isApplyingRemoteScroll = false
            }
        }

        func applyPreviewSelection(_ selection: SplitEditorSelection) {
            guard isSplitSynchronizationEnabled, let textView else { return }
            let length = (textView.string as NSString).length
            let location = min(max(0, selection.range.location), length)
            let selectionLength = min(
                max(0, selection.range.length),
                length - location
            )
            withoutPublishingSelection {
                (textView as? MarkdownSourceTextView)?.synchronizedSelectionRange = NSRange(
                    location: location,
                    length: selectionLength
                )
                textView.setSelectedRange(
                    NSRange(location: location, length: selectionLength)
                )
            }
        }

        func withoutPublishingSelection(_ action: () -> Void) {
            isApplyingRemoteSelection = true
            action()
            DispatchQueue.main.async { [weak self] in
                self?.isApplyingRemoteSelection = false
            }
        }

        private func scrollAnchor(forViewportHeight height: CGFloat) -> CGFloat {
            max(0, height * 0.5)
        }

        func scheduleHighlight() {
            scheduledHighlight?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.highlight()
            }
            scheduledHighlight = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.035, execute: work)
        }

        func highlight() {
            guard let textView, let storage = textView.textStorage else { return }
            lastAppearanceName = textView.effectiveAppearance.name
            let source = storage.string as NSString
            let fullRange = NSRange(location: 0, length: source.length)
            let selection = textView.selectedRange()
            let palette = Palette(textView: textView)

            storage.beginEditing()
            storage.setAttributes(baseAttributes(for: textView), range: fullRange)

            apply(#"(?m)^\s*(```|~~~).*$"#, color: palette.fence, to: storage, in: source)
            applyGroup(
                #"(?ms)^```[^\n]*\n(.*?)^```\s*$"#,
                group: 1,
                color: palette.code,
                to: storage,
                in: source
            )
            applyGroup(
                #"(?ms)^~~~[^\n]*\n(.*?)^~~~\s*$"#,
                group: 1,
                color: palette.code,
                to: storage,
                in: source
            )
            apply(#"(?m)^#{1,6}(?=\s).*$"#, color: palette.heading, to: storage, in: source)
            apply(#"(?m)^\s*>+\s?"#, color: palette.quote, to: storage, in: source)
            apply(#"(?m)^\s*(?:[-+*]|\d+\.)\s+(?:\[[ xX]\]\s+)?"#, color: palette.marker, to: storage, in: source)
            apply(#"(?m)^\s*\|?(?:[^\n|]*\|){2,}[^\n]*$"#, color: palette.table, to: storage, in: source)
            apply(#"(?m)^---\s*$"#, color: palette.frontmatter, to: storage, in: source)
            apply(#"(?m)^([A-Za-z0-9_.-]+)(?=:\s)"#, color: palette.frontmatter, to: storage, in: source)
            apply(#"`+[^`\n]+`+"#, color: palette.code, to: storage, in: source)
            apply(#"!?\[[^\]\n]+\](?=\([^\n)]+\))"#, color: palette.linkLabel, to: storage, in: source)
            apply(#"(?<=\])\([^\n)]+\)"#, color: palette.linkTarget, to: storage, in: source)
            apply(#"(?:\*\*|__|~~|(?<!\*)\*(?!\*)|(?<!_)_(?!_))"#, color: palette.emphasis, to: storage, in: source)
            apply(#"(?m)^\s*\[![A-Z]+\]"#, color: palette.alert, to: storage, in: source)
            apply(#"(?m)^\s*<!--.*?-->\s*$"#, color: palette.comment, to: storage, in: source)

            storage.endEditing()
            textView.setSelectedRange(selection)
            textView.typingAttributes = baseAttributes(for: textView)
        }

        private func baseAttributes(for textView: NSTextView) -> [NSAttributedString.Key: Any] {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 3
            paragraph.lineBreakMode = .byWordWrapping
            return [
                .font: NSFont.monospacedSystemFont(ofSize: 13.5, weight: .regular),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph,
            ]
        }

        private func apply(
            _ pattern: String,
            color: NSColor,
            to storage: NSTextStorage,
            in source: NSString
        ) {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { return }
            let range = NSRange(location: 0, length: source.length)
            expression.enumerateMatches(in: source as String, range: range) { match, _, _ in
                guard let match else { return }
                storage.addAttribute(.foregroundColor, value: color, range: match.range)
            }
        }

        private func applyGroup(
            _ pattern: String,
            group: Int,
            color: NSColor,
            to storage: NSTextStorage,
            in source: NSString
        ) {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { return }
            let range = NSRange(location: 0, length: source.length)
            expression.enumerateMatches(in: source as String, range: range) { match, _, _ in
                guard let match else { return }
                let groupRange = match.range(at: group)
                guard groupRange.location != NSNotFound else { return }
                storage.addAttribute(.foregroundColor, value: color, range: groupRange)
            }
        }
    }
}

/// UTF-16 offsets of logical source lines, matching AppKit's text-system
/// indexing. A trailing line break intentionally creates one final empty line.
struct MarkdownLineMap {
    static func lineStartOffsets(in text: String) -> [Int] {
        let source = text as NSString
        var offsets = [0]
        var index = 0

        while index < source.length {
            let character = source.character(at: index)
            switch character {
            case 0x000D: // CR or CRLF
                if index + 1 < source.length,
                   source.character(at: index + 1) == 0x000A {
                    index += 1
                }
                offsets.append(index + 1)
            case 0x000A, 0x0085, 0x2028, 0x2029:
                offsets.append(index + 1)
            default:
                break
            }
            index += 1
        }

        return offsets
    }

    static func lineIndex(containingUTF16Offset offset: Int, starts: [Int]) -> Int {
        guard !starts.isEmpty else { return 0 }
        var lowerBound = 0
        var upperBound = starts.count

        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            if starts[middle] <= offset {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }

        return max(0, lowerBound - 1)
    }
}

/// A fixed native gutter for the source editor. It follows the scroll view's
/// clip view, numbers logical lines rather than wrapped fragments, and keeps
/// its width stable until the document crosses a digit boundary.
@MainActor
final class MarkdownLineNumberRulerView: NSView {
    private weak var observedScrollView: NSScrollView?
    private weak var textView: NSTextView?
    private var lineStarts = [0]
    private var selectedLineIndex = 0
    private(set) var requiredWidth: CGFloat = 40

    private let regularFont = NSFont.monospacedDigitSystemFont(
        ofSize: 10.5,
        weight: .regular
    )
    private let selectedFont = NSFont.monospacedDigitSystemFont(
        ofSize: 10.5,
        weight: .semibold
    )
    private let minimumThickness: CGFloat = 40
    private let horizontalPadding: CGFloat = 9

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    init(scrollView: NSScrollView, textView: NSTextView) {
        self.observedScrollView = scrollView
        self.textView = textView
        super.init(frame: .zero)

        identifier = NSUserInterfaceItemIdentifier("MarkdownLineNumbers")
        setAccessibilityElement(true)
        setAccessibilityLabel("Line numbers")

        textView.postsFrameChangedNotifications = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(viewGeometryDidChange(_:)),
            name: NSView.frameDidChangeNotification,
            object: textView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(viewGeometryDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        reload()
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func reload() {
        guard let textView else { return }
        lineStarts = MarkdownLineMap.lineStartOffsets(in: textView.string)
        updateSelectedLine()
        updateThickness()
        needsDisplay = true
    }

    func selectionDidChange() {
        let previousSelection = selectedLineIndex
        updateSelectedLine()
        if previousSelection != selectedLineIndex {
            needsDisplay = true
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ rect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        gutterRect(intersecting: rect).fill()

        guard let textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer
        else {
            drawSeparator(in: rect)
            return
        }

        layoutManager.ensureLayout(for: textContainer)
        let textOrigin = textView.textContainerOrigin
        let visibleContainerRect = textView.visibleRect.offsetBy(
            dx: -textOrigin.x,
            dy: -textOrigin.y
        )
        let visibleGlyphRange = layoutManager.glyphRange(
            forBoundingRect: visibleContainerRect,
            in: textContainer
        )
        let visibleCharacterRange = layoutManager.characterRange(
            forGlyphRange: visibleGlyphRange,
            actualGlyphRange: nil
        )
        let firstLine = MarkdownLineMap.lineIndex(
            containingUTF16Offset: visibleCharacterRange.location,
            starts: lineStarts
        )
        let visibleCharacterLimit = NSMaxRange(visibleCharacterRange)
        let sourceLength = (textView.string as NSString).length

        var lineIndex = firstLine
        while lineIndex < lineStarts.count {
            let lineStart = lineStarts[lineIndex]
            if lineStart > visibleCharacterLimit, lineStart < sourceLength {
                break
            }

            if let fragment = lineFragmentRect(
                forCharacterAt: lineStart,
                sourceLength: sourceLength,
                layoutManager: layoutManager,
                textContainer: textContainer
            ) {
                let point = convert(
                    NSPoint(x: 0, y: textOrigin.y + fragment.minY),
                    from: textView
                )
                let lineRect = NSRect(
                    x: 0,
                    y: point.y,
                    width: max(0, requiredWidth - separatorWidth),
                    height: fragment.height
                )
                if lineRect.intersects(rect) {
                    drawLineNumber(lineIndex + 1, in: lineRect, selected: lineIndex == selectedLineIndex)
                }
            }

            lineIndex += 1
        }

        drawSeparator(in: rect)
    }

    @objc
    private func viewGeometryDidChange(_ notification: Notification) {
        needsDisplay = true
    }

    private func updateSelectedLine() {
        guard let textView else { return }
        selectedLineIndex = MarkdownLineMap.lineIndex(
            containingUTF16Offset: textView.selectedRange().location,
            starts: lineStarts
        )
    }

    private func updateThickness() {
        let widestNumber = "\(max(1, lineStarts.count))" as NSString
        let labelWidth = widestNumber.size(
            withAttributes: [.font: selectedFont]
        ).width
        let desiredThickness = max(
            minimumThickness,
            ceil(labelWidth) + horizontalPadding * 2
        )
        if abs(requiredWidth - desiredThickness) > 0.5 {
            requiredWidth = desiredThickness
            observedScrollView?.superview?.needsLayout = true
        }
    }

    private func lineFragmentRect(
        forCharacterAt characterIndex: Int,
        sourceLength: Int,
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer
    ) -> NSRect? {
        if characterIndex == sourceLength {
            guard layoutManager.extraLineFragmentTextContainer === textContainer else {
                return nil
            }
            return layoutManager.extraLineFragmentRect
        }

        guard characterIndex < sourceLength else { return nil }
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: characterIndex)
        return layoutManager.lineFragmentRect(
            forGlyphAt: glyphIndex,
            effectiveRange: nil
        )
    }

    private func drawLineNumber(_ lineNumber: Int, in lineRect: NSRect, selected: Bool) {
        if selected {
            NSColor.controlAccentColor.withAlphaComponent(
                usesDarkAppearance ? 0.16 : 0.10
            ).setFill()
            lineRect.fill()
        }

        let label = "\(lineNumber)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: selected ? selectedFont : regularFont,
            .foregroundColor: selected
                ? NSColor.controlAccentColor
                : NSColor.secondaryLabelColor,
        ]
        let size = label.size(withAttributes: attributes)
        let origin = NSPoint(
            x: floor(requiredWidth - horizontalPadding - size.width),
            y: floor(lineRect.minY + max(0, (lineRect.height - size.height) / 2))
        )
        label.draw(at: origin, withAttributes: attributes)
    }

    private var usesDarkAppearance: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private var separatorWidth: CGFloat {
        1 / max(1, window?.backingScaleFactor ?? 2)
    }

    private func drawSeparator(in rect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(
            x: requiredWidth - separatorWidth,
            y: rect.minY,
            width: separatorWidth,
            height: rect.height
        ).fill()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func gutterRect(intersecting rect: NSRect) -> NSRect {
        NSRect(
            x: 0,
            y: rect.minY,
            width: min(requiredWidth, bounds.width),
            height: rect.height
        )
    }
}

private struct Palette {
    let heading: NSColor
    let marker: NSColor
    let quote: NSColor
    let code: NSColor
    let fence: NSColor
    let table: NSColor
    let frontmatter: NSColor
    let linkLabel: NSColor
    let linkTarget: NSColor
    let emphasis: NSColor
    let alert: NSColor
    let comment: NSColor

    @MainActor
    init(textView: NSTextView) {
        let dark = textView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        heading = dark ? NSColor(calibratedRed: 0.51, green: 0.72, blue: 1, alpha: 1)
            : NSColor(calibratedRed: 0.08, green: 0.35, blue: 0.75, alpha: 1)
        marker = dark ? NSColor(calibratedRed: 0.95, green: 0.66, blue: 0.40, alpha: 1)
            : NSColor(calibratedRed: 0.70, green: 0.31, blue: 0.08, alpha: 1)
        quote = dark ? NSColor(calibratedRed: 0.54, green: 0.84, blue: 0.68, alpha: 1)
            : NSColor(calibratedRed: 0.06, green: 0.48, blue: 0.27, alpha: 1)
        code = dark ? NSColor(calibratedRed: 0.88, green: 0.70, blue: 1, alpha: 1)
            : NSColor(calibratedRed: 0.48, green: 0.19, blue: 0.67, alpha: 1)
        fence = marker
        table = dark ? NSColor(calibratedRed: 0.52, green: 0.78, blue: 0.95, alpha: 1)
            : NSColor(calibratedRed: 0.10, green: 0.48, blue: 0.68, alpha: 1)
        frontmatter = dark ? NSColor(calibratedRed: 0.94, green: 0.55, blue: 0.68, alpha: 1)
            : NSColor(calibratedRed: 0.70, green: 0.18, blue: 0.37, alpha: 1)
        linkLabel = heading
        linkTarget = dark ? NSColor(calibratedWhite: 0.58, alpha: 1)
            : NSColor(calibratedWhite: 0.42, alpha: 1)
        emphasis = code
        alert = frontmatter
        comment = dark ? NSColor(calibratedWhite: 0.50, alpha: 1)
            : NSColor(calibratedWhite: 0.48, alpha: 1)
    }
}
