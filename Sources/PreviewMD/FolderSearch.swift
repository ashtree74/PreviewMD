import Foundation

struct FolderSearchResult: Identifiable, Equatable, Sendable {
    let url: URL
    let relativePath: String
    let snippet: String
    let matchCount: Int

    var id: String { url.standardizedFileURL.path }
    var title: String { url.deletingPathExtension().lastPathComponent }
}

enum MarkdownFolderSearch {
    private struct QueryComponent: Equatable {
        let value: String
        let isQuotedPhrase: Bool
    }

    private struct QueryPlan {
        let components: [QueryComponent]
        let preferredPhrase: String?

        init(_ query: String) {
            var parsed: [QueryComponent] = []
            var buffer = ""
            var isInsideQuotes = false
            var encounteredQuotes = false

            func appendBuffer(isQuotedPhrase: Bool) {
                let value = Self.collapseWhitespace(in: buffer)
                guard !value.isEmpty else {
                    buffer = ""
                    return
                }
                parsed.append(QueryComponent(value: value, isQuotedPhrase: isQuotedPhrase))
                buffer = ""
            }

            for character in query {
                if character == "\"" {
                    encounteredQuotes = true
                    if isInsideQuotes {
                        appendBuffer(isQuotedPhrase: true)
                    } else {
                        appendBuffer(isQuotedPhrase: false)
                    }
                    isInsideQuotes.toggle()
                } else if character.isWhitespace, !isInsideQuotes {
                    appendBuffer(isQuotedPhrase: false)
                } else {
                    buffer.append(character)
                }
            }
            appendBuffer(isQuotedPhrase: isInsideQuotes)

            var seen: Set<String> = []
            components = parsed.filter { component in
                seen.insert(Self.fold(component.value)).inserted
            }

            let wholeQuery = Self.collapseWhitespace(in: query)
            preferredPhrase = !encounteredQuotes && components.count > 1
                ? wholeQuery
                : nil
        }

        private static func collapseWhitespace(in value: String) -> String {
            value.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
        }

        private static func fold(_ value: String) -> String {
            value.folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: .current
            )
        }
    }

    private struct RankedResult {
        let result: FolderSearchResult
        let score: Int
    }

    static func search(
        query: String,
        rootURL: URL,
        items: [FolderTreeItem],
        contentOverrides: [String: String] = [:]
    ) throws -> [FolderSearchResult] {
        let plan = QueryPlan(query)
        guard !plan.components.isEmpty else { return [] }

        let ranked = try fileURLs(in: items).compactMap { url -> RankedResult? in
            try Task.checkCancellation()

            let path = url.standardizedFileURL.path
            let content: String
            if let override = contentOverrides[path] {
                content = override
            } else {
                guard let result = try? MarkdownFileIO.read(from: url) else { return nil }
                content = result.content
            }

            let foldedContent = fold(content)
            let componentCounts = plan.components.map {
                occurrenceCount(of: fold($0.value), in: foldedContent)
            }
            guard componentCounts.allSatisfy({ $0 > 0 }) else { return nil }

            let preferredPhraseCount = plan.preferredPhrase.map {
                occurrenceCount(of: fold($0), in: foldedContent)
            } ?? 0
            let quotedPhraseCount = zip(plan.components, componentCounts).reduce(0) {
                $0 + ($1.0.isQuotedPhrase ? $1.1 : 0)
            }
            let totalComponentCount = componentCounts.reduce(0, +)
            let score = preferredPhraseCount * 1_000
                + quotedPhraseCount * 200
                + totalComponentCount * 8
            let count = preferredPhraseCount > 0
                ? preferredPhraseCount
                : max(1, totalComponentCount)

            return RankedResult(
                result: FolderSearchResult(
                    url: url,
                    relativePath: relativePath(for: url, rootURL: rootURL),
                    snippet: bestSnippet(in: content, plan: plan),
                    matchCount: count
                ),
                score: score
            )
        }

        return ranked.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.result.relativePath.localizedStandardCompare(
                $1.result.relativePath
            ) == .orderedAscending
        }
        .map(\.result)
    }

    private static func fileURLs(in items: [FolderTreeItem]) -> [URL] {
        items.flatMap { item in
            if let children = item.children {
                return fileURLs(in: children)
            }
            return [item.url]
        }
    }

    private static func fold(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        )
    }

    private static func occurrenceCount(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let range = haystack.range(of: needle, range: searchRange) {
            count += 1
            searchRange = range.upperBound..<haystack.endIndex
        }
        return count
    }

    private static func relativePath(for url: URL, rootURL: URL) -> String {
        let rootComponents = rootURL.standardizedFileURL.pathComponents
        let fileComponents = url.standardizedFileURL.pathComponents
        guard fileComponents.starts(with: rootComponents) else {
            return url.lastPathComponent
        }
        return fileComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }

    private static func bestSnippet(in content: String, plan: QueryPlan) -> String {
        let lines = content.components(separatedBy: .newlines)
        var bestLine = ""
        var bestScore = -1

        for line in lines {
            let foldedLine = fold(line)
            let phraseHits = plan.preferredPhrase.map {
                occurrenceCount(of: fold($0), in: foldedLine)
            } ?? 0
            let componentHits = plan.components.reduce(0) { partial, component in
                partial + occurrenceCount(of: fold(component.value), in: foldedLine)
            }
            let distinctComponents = plan.components.reduce(0) { partial, component in
                partial + (foldedLine.contains(fold(component.value)) ? 1 : 0)
            }
            let score = phraseHits * 1_000 + distinctComponents * 100 + componentHits
            if score > bestScore {
                bestScore = score
                bestLine = line
            }
        }

        let collapsed = bestLine
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return "Match in document" }

        let preferredNeedles = [plan.preferredPhrase].compactMap { $0 }
            + plan.components.map(\.value)
        let anchor = preferredNeedles.compactMap { needle in
            collapsed.range(
                of: needle,
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
            )
        }.first

        let anchorOffset = anchor.map {
            collapsed.distance(from: collapsed.startIndex, to: $0.lowerBound)
        } ?? 0
        let maxLength = 176
        guard collapsed.count > maxLength else { return collapsed }

        let lowerOffset = max(0, min(anchorOffset - 48, collapsed.count - maxLength))
        let upperOffset = min(collapsed.count, lowerOffset + maxLength)
        let lower = collapsed.index(collapsed.startIndex, offsetBy: lowerOffset)
        let upper = collapsed.index(collapsed.startIndex, offsetBy: upperOffset)
        return (lowerOffset > 0 ? "…" : "")
            + collapsed[lower..<upper]
            + (upperOffset < collapsed.count ? "…" : "")
    }
}
