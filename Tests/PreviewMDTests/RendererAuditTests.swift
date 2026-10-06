import AppKit
import Foundation
import PDFKit
import WebKit
import XCTest
@testable import PreviewMD

@MainActor
final class RendererAuditTests: XCTestCase, WKNavigationDelegate {
    private var navigationExpectation: XCTestExpectation?

    func testPDFIncludesRichEditsAndRestoresCurrentContentAndLayout() async throws {
        let webView = try await makeEditor("Original text")
        let result = try await webView.callAsyncJavaScript(
            """
            const article = document.getElementById('preview-document');
            article.querySelector('p').textContent = 'Latest unsaved edit';
            article.dispatchEvent(new InputEvent('input', {bubbles: true}));
            window.previewmdSetLayout(960, false, 48, false);
            await window.previewmdPreparePDF({theme:'light', style:'modern'}, 515, 761);
            return article.textContent;
            """, contentWorld: .page
        )
        XCTAssertTrue((result as? String)?.contains("Latest unsaved edit") == true)
        let pdf = try await webView.pdf(configuration: WKPDFConfiguration())
        XCTAssertTrue(PDFDocument(data: pdf)?.string?.contains("Latest unsaved edit") == true)
        let restored = try await webView.callAsyncJavaScript(
            """
            await window.previewmdFinishPrint();
            return {
              markdown: window.previewmdFlushEditor(),
              width: document.documentElement.style.getPropertyValue('--reading-width'),
              inset: document.documentElement.style.getPropertyValue('--top-inset'),
              editable: document.getElementById('preview-document').isContentEditable,
            };
            """, contentWorld: .page
        )
        let output = try XCTUnwrap(restored as? [String: Any])
        XCTAssertEqual(output["markdown"] as? String, "Latest unsaved edit\n")
        XCTAssertEqual(output["width"] as? String, "960px")
        XCTAssertEqual(output["inset"] as? String, "48px")
        XCTAssertEqual(output["editable"] as? Bool, true)
    }

    func testOutlineUsesTheRenderedHeadingGrammarAndIdentifiers() async throws {
        let markdown = """
        ---
        title: metadata
        ---

        Intro
        =====

          ## Indented **section**

        > ### Quoted section

        ````markdown
        ```
        # Not a heading
        ````

        ## Real section
        """
        let webView = try await makeEditor(markdown)
        let result = try await webView.callAsyncJavaScript(
            """
            const parsed = window.previewmdOutlineForMarkdown(markdown);
            const rendered = Array.from(document.querySelectorAll('#preview-document h1,h2,h3,h4,h5,h6'));
            return { parsed, ids: rendered.map(h => h.id), titles: rendered.map(h => {
              const content = h.cloneNode(true);
              content.querySelectorAll('.heading-anchor, .katex-mathml').forEach(node => node.remove());
              return content.textContent.trim();
            }) };
            """, arguments: ["markdown": markdown], contentWorld: .page
        )
        let output = try XCTUnwrap(result as? [String: Any])
        let headings = try XCTUnwrap(output["parsed"] as? [[String: Any]])
        XCTAssertEqual(headings.compactMap { $0["id"] as? String }, output["ids"] as? [String])
        XCTAssertEqual(headings.compactMap { $0["title"] as? String }, ["Intro", "Indented section", "Quoted section", "Real section"])
        XCTAssertEqual(headings.compactMap { $0["level"] as? Int }, [1, 2, 3, 2])
        XCTAssertEqual(output["titles"] as? [String], ["Intro", "Indented section", "Quoted section", "Real section"])
    }

    func testRenderedOutlineReachesTheOpenedDocumentThroughTheWebKitBridge() async throws {
        let markdown = "Intro\n=====\n\n  ## Indented **section**\n\n> ### Quoted section\n"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreviewMDOutlineBridge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("Outline.md")
        try markdown.write(to: fileURL, atomically: true, encoding: .utf8)
        let suiteName = "PreviewMDOutlineBridge.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = AppState(defaults: defaults)
        state.liveReloadEnabled = false
        state.open(url: fileURL)
        let document = try XCTUnwrap(state.currentDocument)
        XCTAssertEqual(document.content, markdown)

        let outlineReady = expectation(description: "Rendered headings arrive through WebKit")
        let coordinator = MarkdownWebView.Coordinator(
            documentID: document.id, documentURL: document.url,
            openMarkdown: state.open(url:),
            onContentChange: { id, content, boundary in
                state.updateContent(content, for: id, origin: .richEditor, startsNewUndoGroup: boundary)
            },
            splitSynchronizer: SplitEditorSynchronizer(),
            isSplitSynchronizationEnabled: false,
            onOutlineChange: { headings, id, content in
                XCTAssertEqual(id, document.id)
                XCTAssertEqual(content, document.content)
                state.updateOutline(headings, for: id, content: content)
                outlineReady.fulfill()
            }
        )
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(coordinator, name: "outlineChange")
        configuration.userContentController.add(coordinator, name: "editorChange")
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), configuration: configuration)
        defer {
            configuration.userContentController.removeScriptMessageHandler(forName: "outlineChange")
            configuration.userContentController.removeScriptMessageHandler(forName: "editorChange")
        }
        webView.navigationDelegate = coordinator
        coordinator.webView = webView
        coordinator.loadShell(baseURL: directory, initialPayload: payload(document.content, documentID: document.id), in: webView)
        try await coordinator.prepareForOutput()
        await fulfillment(of: [outlineReady], timeout: 5)
        XCTAssertEqual(state.currentOutline.map(\.title), ["Intro", "Indented section", "Quoted section"])
        XCTAssertEqual(state.currentOutline.map(\.level), [1, 2, 3])
        XCTAssertEqual(state.currentOutline.map(\.id), ["heading-0", "heading-1", "heading-2"])
    }

    func testHiddenPreviewDefersDOMRebuildButRefreshesOutlineAndSaveUsesSource() async throws {
        let webView = try await makeEditor("# Original\n\nOriginal body")
        let documentID = UUID()
        let outlineReady = expectation(description: "Hidden source outline parsed")
        var outline: [OutlineHeading] = []
        let coordinator = MarkdownWebView.Coordinator(
            documentID: documentID, documentURL: nil,
            openMarkdown: { _ in }, onContentChange: { _, _, _ in },
            splitSynchronizer: SplitEditorSynchronizer(),
            isSplitSynchronizationEnabled: false, isVisible: false,
            onOutlineChange: { headings, id, content in
                XCTAssertEqual(id, documentID)
                XCTAssertEqual(content, "New heading\n===========\n\nLatest source body")
                outline = headings
                outlineReady.fulfill()
            }
        )
        coordinator.webView = webView
        coordinator.webView(webView, didFinish: nil)
        let newPayload = payload("New heading\n===========\n\nLatest source body", documentID: documentID)
        coordinator.update(newPayload, in: webView)
        await fulfillment(of: [outlineReady], timeout: 5)
        XCTAssertEqual(outline.map(\.title), ["New heading"])
        let original = try await webView.evaluateJavaScript("document.getElementById('preview-document').textContent")
        XCTAssertTrue((original as? String)?.contains("Original body") == true)

        let controller = RendererController()
        controller.attach(webView, documentID: documentID, isVisible: false)
        let flushed = expectation(description: "Source-only save skips stale rich editor")
        controller.flushMarkdown(for: documentID) { markdown in
            XCTAssertNil(markdown)
            flushed.fulfill()
        }
        await fulfillment(of: [flushed], timeout: 1)

        coordinator.isVisible = true
        coordinator.update(newPayload, in: webView)
        let visible = try await webView.callAsyncJavaScript(
            """
            await new Promise(resolve => setTimeout(resolve, 50));
            return document.getElementById('preview-document').textContent;
            """, contentWorld: .page
        )
        XCTAssertTrue((visible as? String)?.contains("Latest source body") == true)
        XCTAssertFalse((visible as? String)?.contains("Original body") == true)
    }

    func testTablesSettleAtFinalColumnWidthWithoutGutterOverflow() async throws {
        let webView = try await makeEditor("| A | B | C | D |\n| - | - | - | - |\n| one | two | three | four |")
        webView.setFrameSize(NSSize(width: 1650, height: 700))
        for width in [560, 1100, 560, 1100] {
            let result = try await webView.callAsyncJavaScript(
                """
                window.previewmdSetLayout(width, false, 0, false);
                await new Promise(resolve => setTimeout(resolve, 300));
                const wrapper = document.querySelector('.table-scroll');
                const article = document.getElementById('preview-document');
                const style = getComputedStyle(article);
                const columnWidth = article.clientWidth - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight);
                const viewport = wrapper.querySelector('.table-viewport');
                return { wide: wrapper.classList.contains('is-wide'), columnWidth, client:viewport.clientWidth, scroll:viewport.scrollWidth };
                """, arguments: ["width": width], contentWorld: .page
            )
            let output = try XCTUnwrap(result as? [String: Any])
            let columnWidth = try XCTUnwrap(output["columnWidth"] as? Double)
            XCTAssertEqual(output["wide"] as? Bool, 576 > columnWidth + 1)
            XCTAssertEqual(output["client"] as? Int, output["scroll"] as? Int)
        }
    }

    func testExpandedTableUsesAvailableSpaceWithoutNearFitScrolling() async throws {
        let webView = try await makeEditor("""
        | Area | Status | Owner | Progress |
        | :--- | :---: | :--- | ---: |
        | Native macOS shell | ✅ Ready | Design | 100% |
        | Markdown reading and editing | ✅ Ready | Platform | 100% |
        | Diagrams, math, and code | ✅ Ready | Content | 100% |
        | Agent edit review | ✅ Ready | Automation | 100% |
        | Quick Look and PDF export | ✅ Ready | Files | 100% |
        """)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 980, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        NSApplication.shared.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeFirstResponder(nil)
        defer { window.close() }
        var sweep: [[String: Any]] = []
        var expanded = false
        for (windowWidth, readingWidth, expected) in [
            (980, 902, "near-fit"), (1800, 560, "roomy"),
            (520, 480, "narrow"), (980, 902, "near-fit")
        ] {
            window.setContentSize(NSSize(width: CGFloat(windowWidth), height: 700))
            webView.setFrameSize(NSSize(width: CGFloat(windowWidth), height: 700))
            webView.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(webView.bounds.width, CGFloat(windowWidth))
            let result = try await webView.callAsyncJavaScript(
                """
                window.previewmdSetLayout(readingWidth, false, 0, false);
                await new Promise(resolve => setTimeout(resolve, 300));
                // Headless WebKit can suspend animation frames. Finish the
                // width transition and use the editor's public layout hook.
                const article = document.getElementById('preview-document');
                article.getAnimations().forEach(animation => animation.finish());
                window.previewmdRefreshTableLayout();
                const wrapper = document.querySelector('.table-scroll');
                if (!expanded) wrapper.querySelector('.table-expand').click();
                const viewport = wrapper.querySelector('.table-viewport');
                const sizer = wrapper.querySelector('.table-sizer');
                const gutter = parseFloat(wrapper.style.getPropertyValue('--table-leading-gutter'));
                const shell = document.getElementById('preview-shell');
                const shellStyle = getComputedStyle(shell);
                const expectedArticleWidth = Math.min(readingWidth, shell.clientWidth - parseFloat(shellStyle.paddingLeft) - parseFloat(shellStyle.paddingRight));
                return {
                  windowWidth: window.innerWidth,
                  articleWidth: article.getBoundingClientRect().width, expectedArticleWidth,
                  available: wrapper.getBoundingClientRect().width - gutter,
                  minimum: parseFloat(sizer.style.minWidth),
                  smallestColumn: Math.min(...Array.from(wrapper.querySelectorAll('th')).map(cell => cell.getBoundingClientRect().width)),
                  buttonBottom: wrapper.querySelector('.table-expand').getBoundingClientRect().bottom,
                  headerTop: wrapper.querySelector('th').getBoundingClientRect().top,
                  client: viewport.clientWidth, scroll: viewport.scrollWidth,
                  right: sizer.getBoundingClientRect().right,
                  viewportRight: viewport.getBoundingClientRect().right,
                  expanded: wrapper.querySelector('.table-expand').getAttribute('aria-expanded')
                };
                """, arguments: ["readingWidth": readingWidth, "expanded": expanded], contentWorld: .page
            )
            expanded = true
            let metrics = try XCTUnwrap(result as? [String: Any])
            sweep.append(metrics)
            XCTAssertEqual(metrics["windowWidth"] as? Int, windowWidth)
            XCTAssertEqual(metrics["articleWidth"] as? Double ?? .nan, metrics["expectedArticleWidth"] as? Double ?? .nan, accuracy: 0.1)
            let available = try XCTUnwrap(metrics["available"] as? Double)
            let minimum = try XCTUnwrap(metrics["minimum"] as? Double)
            let client = try XCTUnwrap(metrics["client"] as? Int)
            let scroll = try XCTUnwrap(metrics["scroll"] as? Int)
            XCTAssertEqual(metrics["expanded"] as? String, "true")
            XCTAssertGreaterThanOrEqual(minimum, 576)
            XCTAssertGreaterThanOrEqual(metrics["smallestColumn"] as? Double ?? 0, 144)
            XCTAssertLessThanOrEqual(metrics["buttonBottom"] as? Double ?? .infinity, metrics["headerTop"] as? Double ?? -.infinity,
                                     "The expansion action must not cover headers at any width")
            switch expected {
            case "near-fit":
                XCTAssertGreaterThan(available, 576)
                XCTAssertLessThan(available, 880)
                XCTAssertEqual(client, scroll, "Near-fit table must fit: \(metrics)")
                XCTAssertEqual(minimum, available, accuracy: 0.1)
                XCTAssertEqual(metrics["right"] as? Double ?? .nan, metrics["viewportRight"] as? Double ?? .nan, accuracy: 1)
            case "roomy":
                XCTAssertGreaterThan(available, 880)
                XCTAssertEqual(minimum, 880)
                XCTAssertEqual(client, scroll)
            default:
                XCTAssertLessThan(available, 576)
                XCTAssertEqual(minimum, 576)
                XCTAssertGreaterThan(scroll, client, "Unreadably small surfaces must still scroll")
            }
            if let path = ProcessInfo.processInfo.environment["PREVIEWMD_TABLE_SNAPSHOTS"] {
                let directory = URL(fileURLWithPath: path, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let configuration = WKSnapshotConfiguration()
                configuration.rect = NSRect(x: 0, y: 0, width: CGFloat(windowWidth), height: 400)
                let snapshot = try await webView.takeSnapshot(configuration: configuration)
                let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(snapshot.tiffRepresentation)))
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("table-\(expected)-\(sweep.count).png"))
                try JSONSerialization.data(withJSONObject: sweep, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("geometry.json"))
            }
        }
        let collapsed = try await webView.callAsyncJavaScript(
            """
            const wrapper = document.querySelector('.table-scroll');
            wrapper.querySelector('.table-expand').click();
            const viewport = wrapper.querySelector('.table-viewport');
            return { expanded: wrapper.querySelector('.table-expand').getAttribute('aria-expanded'),
              minimum: wrapper.querySelector('.table-sizer').style.minWidth,
              client: viewport.clientWidth, scroll: viewport.scrollWidth };
            """, contentWorld: .page
        )
        let metrics = try XCTUnwrap(collapsed as? [String: Any])
        XCTAssertEqual(metrics["expanded"] as? String, "false")
        XCTAssertEqual(metrics["minimum"] as? String, "576px")
        XCTAssertEqual(metrics["client"] as? Int, metrics["scroll"] as? Int)
    }

    func testHiddenSourceIsRenderedBeforePDFPreparationAndRestoredAfterward() async throws {
        let webView = try await makeEditor("Old source")
        let coordinator = outputCoordinator(in: webView, visible: false)
        coordinator.update(payload("Latest source-only edit"), in: webView)
        try await coordinator.prepareForOutput()
        _ = try await webView.callAsyncJavaScript(
            "await window.previewmdPreparePDF({theme:'light', style:'modern'}, 515, 761); return true;",
            contentWorld: .page
        )
        let pdf = try await webView.pdf(configuration: WKPDFConfiguration())
        XCTAssertTrue(PDFDocument(data: pdf)?.string?.contains("Latest source-only edit") == true)
        let restored = try await webView.callAsyncJavaScript(
            "await window.previewmdFinishPrint(); return window.previewmdFlushEditor();",
            contentWorld: .page
        )
        XCTAssertEqual(restored as? String, "Latest source-only edit")
    }

    func testCopyAndDOCXCommandsSynchronizeTheHiddenPreviewBeforeReadingItsContent() async throws {
        for copy in [false, true] {
            let webView = try await makeEditor("Old source")
            let coordinator = outputCoordinator(in: webView, visible: false)
            let id = UUID()
            coordinator.documentID = id
            coordinator.update(payload("Latest source-only edit", documentID: id), in: webView)
            _ = try await webView.evaluateJavaScript("""
            window.auditOutput = null;
            window.previewmdAdvancedCopy = window.previewmdExportDOCX = function () {
              window.auditOutput = window.previewmdFlushEditor();
              return true;
            };
            true;
            """)
            let controller = RendererController()
            controller.attach(webView, documentID: id, isVisible: false) {
                try await coordinator.prepareForOutput()
            }
            if copy { controller.advancedCopy(.markdown, suggestedName: "Document") }
            else { controller.exportDOCX(suggestedName: "Document") }
            let output = try await webView.callAsyncJavaScript(
                """
                const deadline = Date.now() + 3000;
                while (window.auditOutput === null && Date.now() < deadline) {
                  await new Promise(resolve => setTimeout(resolve, 10));
                }
                return window.auditOutput;
                """, contentWorld: .page
            )
            XCTAssertEqual(output as? String, "Latest source-only edit")
            withExtendedLifetime(controller) {}
        }
    }

    func testSaveWaitsForAnAsynchronousRenderAndUsesTheLatestQueuedSource() async throws {
        let webView = try await makeEditor("Old source")
        let id = UUID()
        let coordinator = outputCoordinator(in: webView, visible: true)
        coordinator.documentID = id
        _ = try await webView.evaluateJavaScript("""
        const originalRender = window.previewmdRender;
        window.auditRenderStarted = false;
        window.previewmdRender = async function (options) {
          window.auditRenderStarted = true;
          await new Promise(resolve => setTimeout(resolve, 150));
          return originalRender(options);
        };
        true;
        """)
        coordinator.update(payload("First source edit", documentID: id), in: webView)
        let started = try await webView.callAsyncJavaScript(
            """
            const deadline = Date.now() + 3000;
            while (!window.auditRenderStarted && Date.now() < deadline) {
              await new Promise(resolve => setTimeout(resolve, 10));
            }
            return window.auditRenderStarted;
            """, contentWorld: .page
        )
        XCTAssertEqual(started as? Bool, true)
        coordinator.update(payload("Latest queued source", documentID: id), in: webView)
        let controller = RendererController()
        controller.attach(webView, documentID: id) { try await coordinator.prepareForOutput() }
        let flushed = expectation(description: "Save awaits the newest render")
        controller.flushMarkdown(for: id) { markdown in
            XCTAssertEqual(markdown, "Latest queued source")
            flushed.fulfill()
        }
        await fulfillment(of: [flushed], timeout: 5)
        withExtendedLifetime(controller) {}
    }

    func testUndoToRenderedContentReplacesAnOlderHiddenPendingEdit() async throws {
        let webView = try await makeEditor("Original source")
        let coordinator = outputCoordinator(in: webView, visible: true)
        let original = payload("Original source")
        coordinator.update(original, in: webView)
        try await coordinator.prepareForOutput()
        coordinator.isVisible = false
        coordinator.update(payload("Discarded hidden edit"), in: webView)
        coordinator.update(original, in: webView)
        try await coordinator.prepareForOutput()
        let markdown = try await webView.evaluateJavaScript("window.previewmdFlushEditor()")
        XCTAssertEqual(markdown as? String, "Original source")
    }

    func testRichInputDuringDeferredDiagramRenderingSurvivesRenderCompletionAndSave() async throws {
        let webView = try await makeEditor("Old source")
        let id = UUID()
        let coordinator = outputCoordinator(in: webView, visible: true)
        coordinator.documentID = id
        _ = try await webView.evaluateJavaScript("""
        window.auditDiagramPending = false;
        window.mermaid.render = async function () {
          window.auditDiagramPending = true;
          await new Promise(resolve => setTimeout(resolve, 150));
          window.auditDiagramPending = false;
          return { svg: '<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20"><rect width="20" height="20"/></svg>' };
        };
        true;
        """)
        coordinator.update(payload("Paragraph\n\n```mermaid\ngraph TD; A-->B\n```", documentID: id), in: webView)
        let editedDuringRender = try await webView.callAsyncJavaScript(
            """
            const deadline = Date.now() + 3000;
            while (!window.auditDiagramPending && Date.now() < deadline) {
              await new Promise(resolve => setTimeout(resolve, 10));
            }
            const wasPending = window.auditDiagramPending;
            const article = document.getElementById('preview-document');
            article.querySelector('p').textContent = 'Typed before the diagram finished';
            article.dispatchEvent(new InputEvent('input', { bubbles: true }));
            await new Promise(resolve => setTimeout(resolve, 10));
            return wasPending;
            """, contentWorld: .page
        )
        XCTAssertEqual(editedDuringRender as? Bool, true)
        let controller = RendererController()
        controller.attach(webView, documentID: id) { try await coordinator.prepareForOutput() }
        let flushed = expectation(description: "Save keeps typing performed during diagram rendering")
        controller.flushMarkdown(for: id) { markdown in
            XCTAssertTrue(markdown?.contains("Typed before the diagram finished") == true)
            XCTAssertFalse(markdown?.contains("Paragraph") == true)
            flushed.fulfill()
        }
        await fulfillment(of: [flushed], timeout: 5)
        withExtendedLifetime(controller) {}
    }

    private func outputCoordinator(in webView: WKWebView, visible: Bool) -> MarkdownWebView.Coordinator {
        let coordinator = MarkdownWebView.Coordinator(
            documentID: UUID(), documentURL: nil,
            openMarkdown: { _ in }, onContentChange: { _, _, _ in },
            splitSynchronizer: SplitEditorSynchronizer(),
            isSplitSynchronizationEnabled: false, isVisible: visible
        )
        coordinator.webView = webView
        coordinator.webView(webView, didFinish: nil)
        return coordinator
    }

    func testReadingStatisticsTrackUnicodeTextChanges() {
        var text = MarkdownText(wrappedValue: "one\n👩🏽‍💻 two")
        XCTAssertEqual(text.wordCount, 3)
        XCTAssertEqual(text.characterCount, "one\n👩🏽‍💻 two".count)
        text.wrappedValue = ""
        XCTAssertEqual(text.wordCount, 0)
        XCTAssertEqual(text.characterCount, 0)
        text.wrappedValue = "zażółć\t世界"
        XCTAssertEqual(text.wordCount, 2)
        XCTAssertEqual(text.characterCount, "zażółć\t世界".count)
    }

    private func payload(_ markdown: String, documentID: UUID = UUID()) -> MarkdownWebView.RenderPayload {
        MarkdownWebView.RenderPayload(
            documentID: documentID.uuidString, markdown: markdown, revision: 1,
            editable: true, theme: "light", readingStyle: "modern", customReadingPreset: nil,
            systemDark: false, readingWidth: 820, readingWidthIsFluid: false,
            paperCanvas: false, zoom: 1, searchText: "", outlineTarget: nil, topInset: 0
        )
    }

    private func makeEditor(_ markdown: String) async throws -> WKWebView {
        let options = payload(markdown)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        webView.navigationDelegate = self
        let loaded = expectation(description: "Renderer loaded")
        navigationExpectation = loaded
        webView.loadHTMLString(RendererAssets.shellHTML(for: options), baseURL: Bundle.module.resourceURL)
        await fulfillment(of: [loaded], timeout: 5)
        navigationExpectation = nil
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(options)) as? [String: Any])
        _ = try await webView.callAsyncJavaScript("await window.previewmdRender(options); return true;", arguments: ["options": object], contentWorld: .page)
        return webView
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        navigationExpectation?.fulfill()
    }
}
