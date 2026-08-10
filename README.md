# PreviewMD

A native macOS Markdown reader with a print-inspired preview, editing, tabs, outline navigation, search, and PDF export.

## Highlights

- GitHub Flavored Markdown, tables, task lists, alerts, footnotes, and compact Shields badges
- Direct rich-text editing in the rendered document, including Markdown typing shortcuts
- Frontmatter metadata rendered as an editable card above the document title
- A contextual selection toolbar for text, links, images, tables, code, diagrams, and math
- A left-margin `+` menu on empty lines for inserting every supported Markdown block
- Mermaid diagrams and charts
- KaTeX inline and display math
- Syntax highlighting with copy buttons
- Preview, syntax-colored source, and live split modes with native line wrapping
- A focus mode that strips every control except the page and the width ruler
- Tabs, recent files, pinning, drag and drop, local images and relative links
- Automatic disk updates for files changed by external editors, with protection for unsaved work
- Fixed reading widths and a fluid Window mode that follows all available space
- Modern, Classic, Editorial, and named custom reading styles with offline system typography
- Native macOS sidebar, toolbar, menus, keyboard shortcuts, and dark mode
- Sidebar tabs for recent files, a folder tree, and a sortable recursive file list
- Finder Quick Look previews for Markdown files after installation
- A4, Letter, Legal, and A5 PDF export with orientation, margins, style, and light/dark appearance
- Printing that always uses a legible light appearance
- Fully offline rendering

## Run

```bash
swift run PreviewMD
```

## Build a macOS app bundle

```bash
./scripts/build-app.sh
open dist/PreviewMD.app
```

The project targets macOS 14 or newer and builds a Universal 2 application for
Apple Silicon and Intel with Swift Package Manager. The bundle includes a
sandboxed Quick Look extension at
`Contents/PlugIns/PreviewMDQuickLook.appex`; both the app and extension are
Universal 2 and are signed together.

To wrap an existing app bundle in the same installer image used for releases:

```bash
./scripts/create-dmg.sh
```

The DMG presents the standard drag-to-Applications layout and tells the user to
open PreviewMD once after copying it. Finder is used to write the window layout,
so the terminal may ask for permission to automate Finder on the first run.

After a user copies PreviewMD to Applications and opens it once, macOS
registers the bundled Quick Look extension. Pressing Space on `.md`,
`.markdown`, `.mdown`, or `.mkd` files then shows the rendered document. For a
document that references a local image beside it, macOS gives the extension
access only to the selected Markdown file; Quick Look shows a clear prompt to
open PreviewMD, where the image renders normally.

If macOS already remembers Xcode or another editor for Markdown, choose
**PreviewMD → Settings → Files → Use PreviewMD as Default**. The Open button in
Finder Quick Look will then target PreviewMD.

Use **File → Open Folder…** (⇧⌘O) to browse a documentation folder. PreviewMD
shows its supported Markdown and text documents as a collapsible tree in the
left sidebar, prunes directories that contain no supported documents, and opens
selected files in the existing tab bar. Opening a folder never opens a README
or another document automatically. Drop a folder anywhere in the main window
to open it the same way.

A local development build can be registered without copying the app:

```bash
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f dist/PreviewMD.app
pluginkit -a dist/PreviewMD.app/Contents/PlugIns/PreviewMDQuickLook.appex
```

## Create a signed and notarized release

The release script expects the `Developer ID Application: Astrography Sp. z
o.o. (4NZF9USX28)` signing identity and a `PreviewMD-Notary` keychain profile.
Create the profile once:

```bash
xcrun notarytool store-credentials "PreviewMD-Notary" \
  --apple-id "YOUR_APPLE_ACCOUNT_EMAIL" \
  --team-id "4NZF9USX28"
```

Use an app-specific password when prompted. Then build, sign, notarize, staple,
verify, and package the release:

```bash
./scripts/release-app.sh
```

The primary distributable DMG and a fallback ZIP are written to `dist/`. The app
is notarized and stapled before it is copied into the image; the final DMG is
then signed, notarized, stapled, and assessed by Gatekeeper as a second check.

## Keyboard shortcuts

| Action | Shortcut |
| --- | --- |
| New Markdown | `⌘N` |
| Open Markdown | `⌘O` |
| Open Folder | `⌘⇧O` |
| Save | `⌘S` |
| Save As | `⌘⇧S` |
| Undo / redo | `⌘Z` / `⌘⇧Z` |
| Bold / italic / link | `⌘B` / `⌘I` / `⌘K` |
| Find in preview | `⌘F` |
| Export PDF | `⌘⇧E` |
| Next reading style | `⌘⌥T` |
| Focus mode | `⌘⇧F` |
| Toggle outline | `⌘⌥I` |
| Close tab | `⌘W` |
| Actual size | `⌘0` |
| Zoom in/out | `⌘+` / `⌘-` |

## Third-party rendering libraries

PreviewMD vendors pinned browser distributions of Markdown-it, markdown-it-footnote, Mermaid, KaTeX, and Highlight.js. They are bundled as local resources so document rendering does not require an internet connection.
