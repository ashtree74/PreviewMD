import AppKit
import Foundation
import UniformTypeIdentifiers

enum MarkdownFileSupport {
    static let supportedExtensions: Set<String> = [
        "md", "markdown", "mdown", "mkd", "txt"
    ]

    static func accepts(_ url: URL) -> Bool {
        url.isFileURL
            && supportedExtensions.contains(url.pathExtension.lowercased())
    }

    static func isFolder(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        return (try? url.resourceValues(forKeys: [.isDirectoryKey]))
            .flatMap(\.isDirectory) == true
    }
}

enum MarkdownDefaultApplication {
    static let commonMarkdownType = UTType(
        importedAs: "net.daringfireball.markdown",
        conformingTo: .plainText
    )

    static var isPreviewMD: Bool {
        guard let applicationURL = NSWorkspace.shared.urlForApplication(
            toOpen: commonMarkdownType
        ) else {
            return false
        }
        return Bundle(url: applicationURL)?.bundleIdentifier
            == Bundle.main.bundleIdentifier
    }

    static func makePreviewMD(
        completion: @escaping @Sendable ((any Error)?) -> Void
    ) {
        NSWorkspace.shared.setDefaultApplication(
            at: Bundle.main.bundleURL,
            toOpen: commonMarkdownType,
            completion: completion
        )
    }
}

enum DisplayMode: String, CaseIterable, Identifiable {
    case preview
    case split
    case source

    var id: String { rawValue }

    var title: String {
        switch self {
        case .preview: "Document"
        case .split: "Split"
        case .source: "Source"
        }
    }

    var symbol: String {
        switch self {
        case .preview: "doc.richtext"
        case .split: "rectangle.split.2x1"
        case .source: "chevron.left.forwardslash.chevron.right"
        }
    }
}

enum DocumentEditOrigin: Equatable {
    case source
    case richEditor
}

enum PreviewTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }
}

enum ReadingStyle: String, CaseIterable, Codable, Identifiable {
    case modern
    case classic
    case editorial
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .modern: "Modern"
        case .classic: "Classic"
        case .editorial: "Editorial"
        case .custom: "Custom"
        }
    }

    var subtitle: String {
        switch self {
        case .modern: "Clean system typography"
        case .classic: "Warm, literary serif"
        case .editorial: "Serif headlines, crisp body"
        case .custom: "Your saved reading preset"
        }
    }

    var symbol: String {
        switch self {
        case .modern: "textformat"
        case .classic: "character.book.closed"
        case .editorial: "newspaper"
        case .custom: "paintpalette"
        }
    }
}

enum ReadingFont: String, CaseIterable, Codable, Identifiable {
    case system
    case rounded
    case serif
    case mono

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System Sans"
        case .rounded: "Rounded Sans"
        case .serif: "System Serif"
        case .mono: "Monospaced"
        }
    }

    var cssFamily: String {
        switch self {
        case .system:
            #"-apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif"#
        case .rounded:
            #"ui-rounded, "SF Pro Rounded", -apple-system, sans-serif"#
        case .serif:
            #""New York", "Iowan Old Style", Charter, Georgia, ui-serif, serif"#
        case .mono:
            #""SFMono-Regular", "SF Mono", ui-monospace, Menlo, monospace"#
        }
    }
}

struct CustomReadingPreset: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var bodyFont: ReadingFont
    var headingFont: ReadingFont
    var bodySize: Double
    var lineHeight: Double
    var accentHex: String
    var lightPageHex: String
    var lightInkHex: String
    var darkPageHex: String
    var darkInkHex: String

    static var starter: CustomReadingPreset {
        CustomReadingPreset(
            id: UUID(),
            name: "My Style",
            bodyFont: .system,
            headingFont: .serif,
            bodySize: 16,
            lineHeight: 1.68,
            accentHex: "#5B5CE2",
            lightPageHex: "#FFFFFF",
            lightInkHex: "#24262D",
            darkPageHex: "#1D1E22",
            darkInkHex: "#ECECF1"
        )
    }

    var normalized: CustomReadingPreset {
        var copy = self
        copy.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if copy.name.isEmpty { copy.name = "My Style" }
        copy.bodySize = min(22, max(13, bodySize))
        copy.lineHeight = min(2.0, max(1.25, lineHeight))
        copy.accentHex = Self.validHex(accentHex, fallback: "#5B5CE2")
        copy.lightPageHex = Self.validHex(lightPageHex, fallback: "#FFFFFF")
        copy.lightInkHex = Self.validHex(lightInkHex, fallback: "#24262D")
        copy.darkPageHex = Self.validHex(darkPageHex, fallback: "#1D1E22")
        copy.darkInkHex = Self.validHex(darkInkHex, fallback: "#ECECF1")
        return copy
    }

    private static func validHex(_ value: String, fallback: String) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let candidate = normalized.hasPrefix("#") ? normalized : "#\(normalized)"
        guard candidate.range(
            of: #"^#[0-9A-F]{6}$"#,
            options: .regularExpression
        ) != nil else { return fallback }
        return candidate
    }
}

enum ReadingWidth: String, CaseIterable, Identifiable {
    case narrow
    case comfortable
    case wide
    case data
    case fullWidth
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .narrow: "Narrow"
        case .comfortable: "Comfortable"
        case .wide: "Wide"
        case .data: "Table / Data"
        case .fullWidth: "Window"
        case .custom: "Custom"
        }
    }

    var cssValue: Int {
        switch self {
        case .narrow: 680
        case .comfortable: 820
        case .wide: 1060
        case .data: 1440
        case .fullWidth: 1600
        case .custom: 820
        }
    }

    var symbol: String {
        switch self {
        case .narrow: "text.alignleft"
        case .comfortable: "doc.text"
        case .wide: "arrow.left.and.right"
        case .data: "tablecells"
        case .fullWidth: "arrow.left.and.right.square"
        case .custom: "slider.horizontal.3"
        }
    }
}

enum SidebarMode: String, CaseIterable, Identifiable {
    case recent
    case tree
    case files

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recent: "Recent"
        case .tree: "Folder"
        case .files: "All Files"
        }
    }

    var symbol: String {
        switch self {
        case .recent: "clock.arrow.circlepath"
        case .tree: "folder"
        case .files: "doc.text.magnifyingglass"
        }
    }
}

enum WorkspaceFileSort: String, CaseIterable, Identifiable {
    case name
    case modified

    var id: String { rawValue }
    var title: String { self == .name ? "Name" : "Modified" }
}

struct MarkdownDocument: Identifiable, Equatable {
    let id: UUID
    var url: URL?
    var title: String
    var content: String
    var lastSavedContent: String
    /// Monotonically increasing in-memory revision shared by the source and
    /// rich editors. It prevents an edit echoed back from SwiftUI from
    /// rebuilding the web editor and moving its selection.
    var contentRevision = 0
    var fileFormat = MarkdownFileFormat.standard
    var diskSnapshot: FileSnapshot?
    var undoHistory: [String] = []
    var redoHistory: [String] = []
    var lastEditOrigin: DocumentEditOrigin?
    var lastEditAt: Date?
    var openedAt: Date
    var fileModifiedAt: Date?
    var isPinned: Bool
    var isSample: Bool
    var hasExternalChanges = false

    var isDirty: Bool {
        content != lastSavedContent
    }

    var wordCount: Int {
        content.split { $0.isWhitespace || $0.isNewline }.count
    }

    var characterCount: Int {
        content.count
    }

    var readingMinutes: Int {
        max(1, Int(ceil(Double(wordCount) / 220.0)))
    }

    var displayPath: String {
        guard let url else { return isSample ? "Built-in showcase" : "Unsaved document" }
        return url.deletingLastPathComponent().path(percentEncoded: false)
    }
}

struct RecentDocument: Codable, Identifiable, Equatable {
    var path: String
    var lastOpened: Date
    var isPinned: Bool

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var title: String { url.deletingPathExtension().lastPathComponent }
}

struct OutlineHeading: Identifiable, Equatable {
    let id: String
    let level: Int
    let title: String
}

enum MarkdownOutline {
    static func headings(in markdown: String) -> [OutlineHeading] {
        var headings: [OutlineHeading] = []
        var insideFence = false
        var fenceMarker = ""

        for line in markdown.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let marker = String(trimmed.prefix(3))
                if insideFence, marker == fenceMarker {
                    insideFence = false
                    fenceMarker = ""
                } else if !insideFence {
                    insideFence = true
                    fenceMarker = marker
                }
                continue
            }

            guard !insideFence else { continue }

            var hashCount = 0
            for character in line {
                if character == "#", hashCount < 6 {
                    hashCount += 1
                } else {
                    break
                }
            }

            guard hashCount > 0,
                  line.dropFirst(hashCount).first?.isWhitespace == true
            else { continue }

            var title = String(line.dropFirst(hashCount))
                .trimmingCharacters(in: .whitespaces)
            title = title.replacingOccurrences(
                of: #"\s+#+\s*$"#,
                with: "",
                options: .regularExpression
            )
            title = title.replacingOccurrences(
                of: #"[*_`~\[\]]"#,
                with: "",
                options: .regularExpression
            )

            guard !title.isEmpty else { continue }
            headings.append(
                OutlineHeading(
                    id: "heading-\(headings.count)",
                    level: hashCount,
                    title: title
                )
            )
        }

        return headings
    }
}
