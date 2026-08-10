import Foundation

struct FolderTreeItem: Identifiable, Equatable, Sendable {
    let url: URL
    let children: [FolderTreeItem]?
    let modificationDate: Date?

    var id: String { url.standardizedFileURL.path }
    var title: String { url.lastPathComponent }
    var isDirectory: Bool { children != nil }

    var flattenedFiles: [FolderTreeItem] {
        guard let children else { return [self] }
        return children.flatMap(\.flattenedFiles)
    }
}

enum MarkdownFolderTree {
    private static let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isRegularFileKey,
        .isSymbolicLinkKey,
        .isHiddenKey,
        .isPackageKey,
        .contentModificationDateKey,
    ]

    static func contents(of rootURL: URL) throws -> [FolderTreeItem] {
        let root = rootURL.standardizedFileURL
        let values = try root.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        return try children(of: root, isRoot: true)
    }

    private static func children(
        of directory: URL,
        isRoot: Bool = false
    ) throws -> [FolderTreeItem] {
        try Task.checkCancellation()

        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles]
            )
        } catch {
            if isRoot { throw error }
            return []
        }

        var directories: [FolderTreeItem] = []
        var files: [FolderTreeItem] = []

        for url in urls {
            try Task.checkCancellation()
            guard !url.lastPathComponent.hasPrefix("."),
                  let values = try? url.resourceValues(forKeys: resourceKeys),
                  values.isHidden != true
            else { continue }

            if values.isDirectory == true {
                guard values.isSymbolicLink != true,
                      values.isPackage != true
                else { continue }

                let nested = try children(of: url)
                if !nested.isEmpty {
                    directories.append(
                        FolderTreeItem(
                            url: url,
                            children: nested,
                            modificationDate: values.contentModificationDate
                        )
                    )
                }
            } else if (values.isRegularFile == true || values.isSymbolicLink == true),
                      MarkdownFileSupport.accepts(url) {
                files.append(
                    FolderTreeItem(
                        url: url,
                        children: nil,
                        modificationDate: values.contentModificationDate
                    )
                )
            }
        }

        let ordered: ([FolderTreeItem]) -> [FolderTreeItem] = { items in
            items.sorted {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        }
        return ordered(directories) + ordered(files)
    }
}
