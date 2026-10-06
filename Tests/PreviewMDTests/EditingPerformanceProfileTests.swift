import AppKit
import Foundation
import SwiftUI
import WebKit
import XCTest
@testable import PreviewMD

/// Opt-in profiling of the real workspace, with isolated preferences and a
/// disposable in-memory edit. Timing results are evidence, not CI thresholds.
@MainActor
final class EditingPerformanceProfileTests: XCTestCase {
    func testProfileNativeWorkspaceEditing() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let samplePath = environment["PREVIEWMD_PROFILE_SAMPLE"],
              let outputPath = environment["PREVIEWMD_PROFILE_OUTPUT"] else {
            throw XCTSkip("Set PREVIEWMD_PROFILE_SAMPLE and PREVIEWMD_PROFILE_OUTPUT to profile editing")
        }
        let sampleURL = URL(fileURLWithPath: samplePath)
        let markdown = try String(contentsOf: sampleURL, encoding: .utf8)
        var text = MarkdownText(wrappedValue: markdown)
        let paragraph = (markdown as NSString).range(of: "\n\n")
        let offset = paragraph.location == NSNotFound ? 0 : NSMaxRange(paragraph)
        var statisticsUpdate: [Double] = []
        for _ in 0..<16 {
            let replacement = (text.wrappedValue as NSString).replacingCharacters(in: NSRange(location: offset, length: 0), with: "x")
            let start = CFAbsoluteTimeGetCurrent()
            text.wrappedValue = replacement
            statisticsUpdate.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
        }
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.regular)
        let suite = "PreviewMDEditingProfile.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(defaults: defaults)
        state.liveReloadEnabled = false
        state.open(url: sampleURL)
        let documentID = try XCTUnwrap(state.currentDocument?.id)
        var stateUpdate: [Double] = []
        var lineMapUpdate: [Double] = []
        for _ in 0..<16 {
            let replacement = (state.currentDocument!.content as NSString).replacingCharacters(in: NSRange(location: offset, length: 0), with: "x")
            var start = CFAbsoluteTimeGetCurrent()
            state.updateContent(replacement, for: documentID, origin: .source)
            stateUpdate.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            start = CFAbsoluteTimeGetCurrent()
            XCTAssertGreaterThan(MarkdownLineMap.lineStartOffsets(in: replacement).count, 1)
            lineMapUpdate.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
        }
        let host = NSHostingView(rootView: WorkspaceView().environmentObject(state))
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1200, height: 760),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "PreviewMD editing profile — synthetic document"
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeFirstResponder(nil)
        defer { window.close() }
        var results: [[String: Any]] = []
        for (name, mode, rich) in [
            ("source", DisplayMode.source, false),
            ("preview", DisplayMode.preview, true),
            ("split-source", DisplayMode.split, false),
            ("split-preview", DisplayMode.split, true)
        ] {
            state.updateContent(markdown, for: documentID, origin: .source)
            state.displayMode = mode
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(500))
            let webView = try XCTUnwrap(descendant(of: WKWebView.self, in: host))
            if rich {
                XCTAssertTrue(window.makeFirstResponder(webView), "Rich typing requires the native web view to have focus")
                let flushed: String? = await withCheckedContinuation { continuation in
                    state.rendererController.flushMarkdown(for: documentID) { continuation.resume(returning: $0) }
                }
                XCTAssertNotNil(flushed, "Visible renderer must be ready before profiling")
            }
            _ = try await webView.evaluateJavaScript("""
            window.profileRenderCount = 0;
            if (!window.profileOriginalRender) {
              window.profileOriginalRender = window.previewmdRender;
              window.previewmdRender = function(options) {
                window.profileRenderCount++;
                return window.profileOriginalRender(options);
              };
            }
            true;
            """)
            let textView = try XCTUnwrap(descendant(of: MarkdownSourceTextView.self, in: host))
            if !rich {
                window.makeFirstResponder(textView)
                let paragraph = (markdown as NSString).range(of: "\n\n")
                let offset = paragraph.location == NSNotFound ? 0 : NSMaxRange(paragraph)
                textView.setSelectedRange(NSRange(location: offset, length: 0))
            }
            var synchronous: [Double] = []
            var committed: [Double] = []
            var stateCommitted: [Double] = []
            var nativeReadingStatistics: [Double] = []
            if !rich {
                for _ in 0..<16 {
                    let start = CFAbsoluteTimeGetCurrent()
                    let counts = MarkdownText(wrappedValue: textView.string)
                    XCTAssertGreaterThan(counts.wordCount, 0)
                    nativeReadingStatistics.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
                }
            }
            for _ in 0..<16 {
                let revision = try XCTUnwrap(state.currentDocument?.contentRevision)
                let start = CFAbsoluteTimeGetCurrent()
                if rich {
                    _ = try await webView.callAsyncJavaScript("""
                    const paragraph = document.querySelector('#preview-document > p');
                    if (!paragraph) throw new Error('No editable paragraph in the sample');
                    const range = document.createRange();
                    range.selectNodeContents(paragraph);
                    range.collapse(false);
                    const selection = window.getSelection();
                    selection.removeAllRanges(); selection.addRange(range);
                    paragraph.focus();
                    document.execCommand('insertText', false, 'x');
                    return true;
                    """, contentWorld: .page)
                } else {
                    textView.insertText("x", replacementRange: textView.selectedRange())
                }
                synchronous.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
                let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                while state.currentDocument?.contentRevision == revision {
                    guard ContinuousClock.now < deadline else {
                        XCTFail("Edit did not reach document state in \(name)")
                        return
                    }
                    try await Task.sleep(for: .milliseconds(1))
                }
                stateCommitted.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    DispatchQueue.main.async {
                        host.layoutSubtreeIfNeeded()
                        window.displayIfNeeded()
                        continuation.resume()
                    }
                }
                committed.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
                // Allow deferred highlighting and split preview updates to run
                // between inputs. Do not await web animation frames: an
                // occluded or zero-width web view can suspend those callbacks.
                try await Task.sleep(for: .milliseconds(60))
            }
            let renderCount = try await webView.evaluateJavaScript("window.profileRenderCount")
            XCTAssertGreaterThan(state.currentDocument?.contentRevision ?? 0, 0)
            results.append([
                "mode": name, "samples": committed.count,
                "insertion": statistics(synchronous),
                "documentCommit": statistics(stateCommitted),
                "documentCommitAndNativeDisplay": statistics(committed),
                "readingStatisticsFromNativeText": nativeReadingStatistics.isEmpty ? [:] : statistics(nativeReadingStatistics),
                "fullPreviewRenders": try XCTUnwrap(renderCount as? Int)
            ])
        }
        let report: [String: Any] = [
            "sampleUTF16Units": markdown.utf16.count,
            "sampleUTF8Bytes": markdown.utf8.count,
            "system": ProcessInfo.processInfo.operatingSystemVersionString,
            "window": ["width": 1200, "height": 760],
            "readingStatisticsUpdate": statistics(statisticsUpdate),
            "stateUpdateWithoutViews": statistics(stateUpdate),
            "lineMapUpdate": statistics(lineMapUpdate),
            "measurement": "Native insertion or WebKit insertText through document-state revision and the next native display pass; excludes physical screen presentation. WebKit insertion includes IPC. Inputs have a 60 ms pause for deferred work, excluded from timings.",
            "results": results
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        print("Editing profile written to \(outputPath)")
    }

    private func statistics(_ values: [Double]) -> [String: Double] {
        let sorted = values.sorted()
        return ["medianMs": sorted[sorted.count / 2], "p95Ms": sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1], "maxMs": sorted.last!]
    }

    private func descendant<T: NSView>(of type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { self.descendant(of: type, in: $0) }.first
    }
}
