import AppKit
import SwiftUI

/// A native, wrapping source editor with lightweight Markdown coloring.
/// It deliberately keeps plain text as the source of truth; attributes are
/// presentation-only and are reapplied after edits or external reloads.
struct MarkdownSourceEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let textView = NSTextView()
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
        textView.textContainerInset = NSSize(width: 16, height: 14)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.backgroundColor = .clear
        textView.string = text
        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.highlight()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let textView = context.coordinator.textView else { return }
        let contentChanged = textView.string != text
        let appearanceChanged = context.coordinator.lastAppearanceName
            != textView.effectiveAppearance.name
        if contentChanged {
            let selection = textView.selectedRange()
            textView.string = text
            textView.setSelectedRange(
                NSRange(
                    location: min(selection.location, (text as NSString).length),
                    length: 0
                )
            )
        }
        if contentChanged || appearanceChanged {
            context.coordinator.highlight()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        weak var textView: NSTextView?
        var lastAppearanceName: NSAppearance.Name?
        private var scheduledHighlight: DispatchWorkItem?

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            text.wrappedValue = textView.string
            scheduleHighlight()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            textView.typingAttributes = baseAttributes(for: textView)
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
