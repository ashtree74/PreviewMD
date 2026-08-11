# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Read AGENTS.md first

`AGENTS.md` is the authoritative source for product invariants (empty-state
behavior, tabs-in-one-window, sidebar/inspector sizing, offline rendering, etc.),
the signing/notarization identity and workflow, and release discipline. Treat
those invariants as constraints on any change. This file covers what `AGENTS.md`
does not: architecture and the local dev/test loop.

## Commands

This is a Swift Package Manager project — there is no `.xcodeproj`. All commands
run from the repo root.

```bash
swift run PreviewMD          # build + launch the app for development
swift build                 # debug build (the only automated correctness gate)
swift test                  # run the XCTest suite (Tests/PreviewMDTests)
swift test --filter testCustomReadingWidthIsClamped   # run a single test
```

There is no configured linter/formatter; `swift build` is the compile gate.

For a distributable macOS app bundle and for signed/notarized releases, use
`./scripts/build-app.sh` and `./scripts/release-app.sh` — see `AGENTS.md` for the
full procedure and the required Universal 2 / notarization verification steps.
Do not hand-run `swift build --arch ...`; the scripts own bundle assembly, icon
generation (`scripts/render-icon.swift` → `build-icns.swift`), and `Info.plist`
copying.

## Architecture

A native macOS SwiftUI app (`.macOS(.v14)`) with a single-window scene. The
defining design decision: **Markdown is not rendered in Swift.** Swift owns
document state and chrome; a bundled WebKit renderer owns all Markdown/diagram/
math/code rendering, fully offline.

### State (`AppState.swift`)

`AppState` is a single `@MainActor ObservableObject` and the app's only source of
truth, injected via `.environmentObject`. It holds the open `documents` (tabs),
`selectedDocumentID`, appearance settings, and `recentDocuments`. Appearance
prefs and recents persist to `UserDefaults` (keys defined in `AppState`); recents
are pruned to existing files on load and capped at 18. Document-open dedups by
`standardizedFileURL` so re-opening a file selects the existing tab. `AppState`
also owns the `RendererController`, the bridge to the active `WKWebView` used for
PDF export.

### The Swift ↔ JS rendering bridge (`MarkdownWebView.swift` + `Resources/Renderer/renderer.js`)

This is the part that requires reading multiple files together.

- `MarkdownWebView` is an `NSViewRepresentable` wrapping a `WKWebView`. On
  creation it loads a **self-contained HTML shell** built by
  `RendererAssets.shellHTML(...)`, which inlines every vendored library
  (`markdown-it`, `markdown-it-footnote`, `highlight.js`, `katex`, `mermaid`)
  and CSS from `Resources/Renderer` directly into `<script>`/`<style>` tags.
  Nothing is fetched over the network — this is the offline-rendering invariant.
- All Swift→JS state travels as a single `RenderPayload` (Codable) encoded to JSON
  and pushed via `evaluateJavaScript` into `window.previewmd*` functions defined
  in `renderer.js`. JS→Swift uses narrow `WKScriptMessageHandler` channels:
  `copyText` for code-block plain text and `copyRichText` for portable
  HTML/RTFD selections (and RTF when it is lossless), plus the
  editor/image/split-sync channels registered in `MarkdownWebView`.
- **Full vs incremental updates matter for performance.** The `Coordinator`
  compares payloads with `RenderPayload.requiresFullRender`: only a change to
  `markdown`, `theme`, or `systemDark` triggers a full re-render
  (`window.previewmdRender`). Reading width, paper canvas, search text, and
  outline target are applied incrementally (`previewmdSetLayout`,
  `previewmdFind`, `previewmdScrollTo`) without re-parsing. `renderVersion`
  guards against stale async diagram renders. Preserve this split when editing.
- The `WKWebView` `baseURL` is the **document's parent directory** (or the bundle
  resource dir for the showcase), which is what makes relative images and links
  resolve. Changing `baseURL` forces a full shell reload; changing only payload
  fields does not. Link clicks are intercepted in `decidePolicyFor`: local
  Markdown opens as a new tab, http/https/mailto open in the system browser.
- KaTeX web-font URLs in the vendored CSS are rewritten at load time to absolute
  `Bundle.module` font URLs (`rewrittenKaTeXCSS`) so math fonts load from the
  bundle.

### Outline is computed twice and must stay in sync

`MarkdownOutline.headings` (Swift, `Models.swift`) scans the source for ATX
headings while tracking code-fence state and assigns IDs `heading-0`, `heading-1`,
… in document order. `renderer.js` independently assigns the *same* `heading-<n>`
IDs to rendered `<h*>` elements in the same order. The inspector's outline buttons
set `state.outlineTarget = "heading-<n>"`, which the renderer scrolls to. If you
change how either side numbers headings, change both or navigation breaks.

### App lifecycle and file opening (`PreviewMDApp.swift`)

`@main` defines one `Window` scene plus a `Settings` scene, with menu commands in
`PreviewMDCommands`. `AppDelegate` handles Finder/Dock open events; because macOS
can deliver `open(urls:)` before SwiftUI wires up `AppState`, it queues URLs in
`pendingOpenURLs` and flushes them once `state` is set (see the corresponding
test `testDockOpenRequestWaitsForAppState`). `applicationShouldTerminateAfterLastWindowClosed`
returns `false` so closing the window does not quit the app.

### View layer (`WorkspaceView.swift`)

One large file of `private` SwiftUI views: `NavigationSplitView` (sidebar +
detail) with a system `.inspector` for the outline. Detail hosts the tab bar,
the `DisplayMode` panes (`preview` / `split` / `source`), the floating
`ReadingWidthRuler`, and the status bar. The empty state (`EmptyWorkspace`) and
drop overlays live here too. Keep new UI native and system-owned per `AGENTS.md`.

### Showcase (`ShowcaseDocument.swift`)

The welcome/demo document is a Swift string literal embedded in the binary (not a
resource file), so the demo works on any Mac without dev-machine files.

## Testing notes

Tests are in `Tests/PreviewMDTests/AppStateTests.swift`, wrapped in
`#if canImport(XCTest)`, and are `@MainActor`. They construct `AppState` with an
isolated `UserDefaults` suite to avoid touching real preferences. They cover the
core invariants (empty launch, closing the last tab, width clamping, embedded
showcase, drop-file filtering, deferred Dock open) — when you change that
behavior, update these tests.
