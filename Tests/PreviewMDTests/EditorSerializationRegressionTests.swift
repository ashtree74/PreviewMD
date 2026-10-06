#if canImport(XCTest)
import Foundation
import WebKit
import XCTest
@testable import PreviewMD

@MainActor
final class EditorSerializationRegressionTests: XCTestCase, WKNavigationDelegate {
    private var navigationExpectation: XCTestExpectation?

    func testUnrelatedRichEditPreservesBlankLinesInsideCodeAndFrontmatter() async throws {
        let markdown = "---\nnotes: |\n  first\n\n\n\n  last\n---\n\nParagraph\n\n```text\nfirst\n\n\n\nlast\n```"
        let webView = try await makeEditor(markdown: markdown)
        let result = try await webView.callAsyncJavaScript(
            """
            const article = document.getElementById("preview-document");
            article.querySelector("p").textContent += " edited";
            article.dispatchEvent(new InputEvent("input", { bubbles: true }));
            const markdown = window.previewmdFlushEditor();
            const fragment = document.createElement("div");
            fragment.appendChild(article.querySelector(".code-card").cloneNode(true));
            return { markdown, fragment: window.previewmdSerializeFragment(fragment) };
            """,
            contentWorld: .page
        )
        let output = try XCTUnwrap(result as? [String: String])
        XCTAssertEqual(output["markdown"], markdown.replacingOccurrences(of: "Paragraph", with: "Paragraph edited") + "\n")
        XCTAssertEqual(output["fragment"], "```text\nfirst\n\n\n\nlast\n```")
    }

    func testUnrelatedRichEditKeepsLiteralMarkdownMarkersAsPlainText() async throws {
        let markdown = "\\# Literal heading" + "\n\n" + #"\> Literal quote"#
            + "\n\n" + #"1\. Literal list"# + "\n\n" + #"\- Literal bullet"#
            + "\n\n" + #"\~\~Literal strike\~\~"# + "\n\n" + #"\>No space"#
            + "\n\nSetext\n" + #"\="# + "\n\nTail"
        let webView = try await makeEditor(markdown: markdown)
        let result = try await webView.callAsyncJavaScript(
            """
            const article = document.getElementById("preview-document");
            article.lastElementChild.textContent += " edited";
            article.dispatchEvent(new InputEvent("input", { bubbles: true }));
            const markdown = window.previewmdFlushEditor();
            await window.previewmdRefreshEditor(markdown);
            // Refresh is normally fire-and-forget; this document has no diagrams.
            await new Promise((resolve) => setTimeout(resolve, 0));
            return {
              text: Array.from(article.children, (node) => node.textContent.trim()),
              tags: Array.from(article.children, (node) => node.tagName),
              formatted: !!article.querySelector("h1, blockquote, ol, ul, s, del"),
            };
            """,
            contentWorld: .page
        )
        let output = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(output["tags"] as? [String], Array(repeating: "P", count: 8))
        XCTAssertEqual(output["text"] as? [String], ["# Literal heading", "> Literal quote", "1. Literal list", "- Literal bullet", "~~Literal strike~~", ">No space", "Setext\n=", "Tail edited"])
        XCTAssertEqual(output["formatted"] as? Bool, false)
    }

    func testRichInlineCodePreservesSignificantSurroundingSpacesAfterReopening() async throws {
        let webView = try await makeEditor(markdown: "Before `code` after")
        let result = try await webView.callAsyncJavaScript(
            """
            const article = document.getElementById("preview-document");
            article.querySelector("code").textContent = " code ";
            article.dispatchEvent(new InputEvent("input", { bubbles: true }));
            const markdown = window.previewmdFlushEditor();
            window.previewmdRefreshEditor(markdown);
            await new Promise((resolve) => setTimeout(resolve, 0));
            return article.querySelector("code").textContent;
            """,
            contentWorld: .page
        )
        XCTAssertEqual(result as? String, " code ")
    }

    func testFormattingMultilineLiteralMarkersAsInlineCodeDoesNotAddBackslashes() async throws {
        for (source, expected) in [
            ("first\n\\# literal", "first # literal"),
            ("first\n\\> literal", "first > literal"),
            ("first\n1\\. literal", "first 1. literal"),
        ] {
            let webView = try await makeEditor(markdown: source)
            let result = try await webView.callAsyncJavaScript(
                """
                const paragraph = document.querySelector("#preview-document p");
                const range = document.createRange();
                range.selectNodeContents(paragraph);
                const selection = window.getSelection();
                selection.removeAllRanges();
                selection.addRange(range);
                document.querySelector('[data-editor-action="inline-code"]').click();
                const markdown = window.previewmdFlushEditor();
                window.previewmdRefreshEditor(markdown);
                await new Promise((resolve) => setTimeout(resolve, 0));
                return document.querySelector("#preview-document code").textContent;
                """,
                contentWorld: .page
            )
            XCTAssertEqual(result as? String, expected, source)
        }
    }

    func testRichSerializationTracksSuccessiveEditsAndCheckboxPropertyChanges() async throws {
        let webView = try await makeEditor(markdown: "Paragraph\n\n- [ ] Task\n\n```text\noriginal\n```")
        let result = try await webView.callAsyncJavaScript(
            """
            const article = document.getElementById("preview-document");
            const paragraph = article.querySelector("p");
            paragraph.textContent = "First edit";
            paragraph.dispatchEvent(new InputEvent("input", { bubbles: true }));
            window.previewmdFlushEditor();
            paragraph.textContent = "Second edit";
            paragraph.dispatchEvent(new InputEvent("input", { bubbles: true }));
            window.previewmdFlushEditor();
            const checkbox = article.querySelector("input[type=checkbox]");
            checkbox.checked = true;
            checkbox.dispatchEvent(new Event("change", { bubbles: true }));
            article.querySelector(".code-card code").textContent = "updated";
            article.dispatchEvent(new InputEvent("input", { bubbles: true }));
            return window.previewmdFlushEditor();
            """,
            contentWorld: .page
        )
        XCTAssertEqual(result as? String, "Second edit\n\n- [x] Task\n\n```text\nupdated\n```\n")
    }

    func testRichEditsPublishContentBeforeTheMatchingOutline() async throws {
        let webView = try await makeEditor(markdown: "# Heading\n\nParagraph")
        let result = try await webView.callAsyncJavaScript(
            """
            const calls = [];
            window.webkit = { messageHandlers: {
              editorChange: { postMessage: (body) => calls.push("content:" + body.markdown) },
            } };
            window.previewmdPublishOutline = (markdown) => calls.push("outline:" + markdown);
            const heading = document.querySelector("#preview-document h1");
            heading.firstChild.nodeValue = "Flushed heading";
            heading.dispatchEvent(new InputEvent("input", { bubbles: true }));
            window.previewmdFlushEditor();
            heading.firstChild.nodeValue = "Emitted heading";
            heading.dispatchEvent(new InputEvent("input", { bubbles: true }));
            await new Promise((resolve) => setTimeout(resolve, 10));
            return calls;
            """,
            contentWorld: .page
        )
        let calls = try XCTUnwrap(result as? [String])
        XCTAssertEqual(calls.count, 4)
        guard calls.count == 4 else { return }
        XCTAssertTrue(calls[0].hasPrefix("content:"))
        XCTAssertEqual(calls[1], calls[0].replacingOccurrences(of: "content:", with: "outline:"))
        XCTAssertTrue(calls[2].hasPrefix("content:"))
        XCTAssertEqual(calls[3], calls[2].replacingOccurrences(of: "content:", with: "outline:"))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        navigationExpectation?.fulfill()
    }

    private func makeEditor(markdown: String) async throws -> WKWebView {
        let payload = MarkdownWebView.RenderPayload(
            documentID: UUID().uuidString, markdown: markdown, revision: 0,
            editable: true, theme: "light", readingStyle: "modern",
            customReadingPreset: nil, systemDark: false, readingWidth: 820,
            readingWidthIsFluid: false, paperCanvas: false, zoom: 1,
            searchText: "", outlineTarget: nil, topInset: 0
        )
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        webView.navigationDelegate = self
        let loaded = expectation(description: "Renderer shell loaded")
        navigationExpectation = loaded
        webView.loadHTMLString(RendererAssets.shellHTML(for: payload), baseURL: Bundle.module.resourceURL)
        await fulfillment(of: [loaded], timeout: 5)
        navigationExpectation = nil
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
        _ = try await webView.callAsyncJavaScript("await window.previewmdRender(options); return true;", arguments: ["options": object], contentWorld: .page)
        return webView
    }
}
#endif
