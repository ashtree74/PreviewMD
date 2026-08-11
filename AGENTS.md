# PreviewMD Project Instructions

## Product

PreviewMD is a native, professional macOS Markdown reader owned by Astrography
Sp. z o.o. and authored by Adam Jesionkiewicz (`adam@jesion.pl`).

- Keep the interface native, minimal, and consistent with current macOS design.
- The application targets macOS 14 or newer.
- Release builds must be Universal 2 (`arm64` and `x86_64`).
- The bundle identifier is `pl.jesion.previewmd`.
- The exported Markdown UTI is `pl.jesion.previewmd.markdown`.
- The About window must show the author, email, and copyright year 2026.
- The About window must also carry the bundled renderers' full license texts
  and copyright lines. The MIT and BSD licenses require those notices to ship
  with every copy, so they are compiled into the binary
  (`Acknowledgements.swift`), never left to a resource file or a repo-level
  Markdown file that packaging can silently drop. Upgrading a vendored library
  means updating its version and license text there in the same commit.

## Product invariants

Preserve these behaviors unless the user explicitly requests a change:

- A clean launch opens an empty state, not a default README or demo document.
- The empty state uses the PreviewMD application icon.
- The embedded showcase/demo must work on every supported Mac without relying
  on files from the development machine.
- Closing the final document tab returns to the empty state.
- Files opened from Finder or dropped on the Dock icon open as tabs in the
  existing main window rather than creating unnecessary windows.
- Drag and drop works across the main window.
- The left sidebar is collapsed by default.
- When opened, the left sidebar should start near 200 pt and remain compact
  like the sidebar in Preview rather than consuming document-reading space.
- Opening a folder shows a collapsible tree of its supported Markdown and text
  documents in the existing left sidebar. Empty/irrelevant directories, hidden
  files, packages, and symlinked directories stay out of the tree.
- Folder loading must not block the main thread, and opening a folder must not
  automatically open a README or any other document. Files selected from the
  tree open as tabs in the existing main window.
- The document inspector should also open near 200 pt, expanding only enough
  to keep outline and insight content usable.
- The document inspector is collapsed by default.
- Use the regular unified macOS toolbar, with a height comparable to Preview;
  do not switch the main window back to the compact toolbar style.
- Let the system own the sidebar and inspector surfaces. Do not stack custom
  translucent materials on top of `NavigationSplitView` or `.inspector`.
- Do not force a single opaque background across the window toolbar; the
  sidebar surface must continue through the title bar like system macOS apps.
- On macOS 26 and newer, keep the neutral detail background eligible for
  `backgroundExtensionEffect()` so the system sidebar can sample content.
- Paper canvas is disabled by default.
- Documents open immediately with the current saved appearance settings; do
  not briefly render with paper canvas or another default layout first.
- Reading width can be adjusted continuously with a clean width control.
- Narrow, comfortable, wide, and table/data presets remain available in the
  menu.
- Tables, Mermaid diagrams, KaTeX, code highlighting, local images, and
  relative links must continue to render offline.
- The application bundle includes a sandboxed Quick Look preview extension at
  `Contents/PlugIns/PreviewMDQuickLook.appex`. It supports both
  `pl.jesion.previewmd.markdown` and the common
  `net.daringfireball.markdown` UTI, renders with bundled resources, and must
  never require a separate plugin installation.
- Copying PreviewMD to Applications and opening it once must be sufficient to
  register Quick Look. Do not require users to run `pluginkit`, `qlmanage`, or
  another command.
- PreviewMD declares both Markdown UTIs as editable document types with the
  `Default` handler rank. Settings provides an explicit action to make
  PreviewMD the default Markdown app, which also controls Quick Look's Open
  button. Never silently replace a user's existing default application.
- Quick Look must replace inaccessible document-relative images with a clear
  open-in-PreviewMD message, never a broken-image glyph. This Finder sandbox
  limitation must not weaken local-image rendering inside the main app.
- Focus mode (⇧⌘F) hides every piece of chrome — sidebar, inspector, tab bar,
  toolbar and status bar — leaving the document column and the reading-width
  ruler, and nothing else. Leaving it restores the display mode it was entered
  from. Escape leaves it.
- Focus mode hides chrome inside the existing view hierarchy rather than
  swapping in a different one, so the web view is never rebuilt and the reader
  keeps their place in the document. Do not "simplify" this into a branch that
  replaces the workspace.
- The renderer names are an implementation detail: no user-facing surface —
  window, settings, showcase, rendered output or landing page — advertises which
  engines are bundled. They are named in the About window only, where their
  licenses require it.

## Landing page and mailing list

The landing page lives in `site/`. Run it with the dependency-free application
server:

```bash
python3 site/server.py
```

Do not use `python3 -m http.server` for normal landing-page development or
production because it does not provide the mailing-list endpoint.

Preserve these landing-page behaviors unless the user explicitly requests a
change:

- The email signup modal opens only after a visitor clicks any
  `[data-download]` link. It must not open automatically when the page loads.
- The modal opens after every download click, even if the visitor previously
  dismissed it. Do not suppress it with `sessionStorage`, `localStorage`, or a
  cookie.
- Clicking Download must still start the native release download; new releases
  use the DMG produced by `scripts/release-app.sh`. The signup modal must not
  gate the download.
- Closing the modal resets its form, error, and success states so it is ready
  for the next download click.

The form posts same-origin JSON (`{"email":"..."}`) to
`POST /api/subscribe`. `site/server.py` stores signups in SQLite. The default
database location is:

```text
.previewmd-data/subscribers.sqlite3
```

This directory is a sibling of `site/`, outside the server's public document
root, and is ignored by Git. Keep it outside `site/`; the database and mailing
list must never be downloadable through the frontend. Do not commit a database
containing subscriber addresses.

The database is created automatically on first server startup. The subscriber
table stores only the normalized email address and UTC signup time, treats
addresses case-insensitively, and ignores duplicates. Download clicks are
recorded in the same database as an aggregate count per release filename plus
the UTC time of the latest click; do not store IP addresses or associate a
click with a subscriber. Tracking is best-effort and must never gate the
release download. Production hosting must provide a persistent filesystem or
volume for `.previewmd-data/` and must back it up; static-only or ephemeral serverless
hosting will not preserve this SQLite database across deployments.

The landing server supports:

- `PORT` for the listening port (default `4173`).
- `PREVIEWMD_SITE_HOST` for the bind address (default `127.0.0.1`).
- `PREVIEWMD_SUBSCRIBERS_DB` for an alternate persistent database path.

When changing landing JavaScript or CSS, bump the corresponding asset query
version in `site/index.html` so deployed browsers do not retain stale behavior.
When changing the released app version, update `DOWNLOAD_FILE` in
`site/main.js`, every literal DMG filename and version string in
`site/index.html`, and the distributable DMG in `site/`. See `site/README.md`
for operational details.

## Building

For a local application bundle:

```bash
./scripts/build-app.sh
```

The local script builds Universal 2. Without
`PREVIEWMD_SIGNING_IDENTITY`, it uses an ad-hoc signature.

Do not replace the Universal 2 build with an architecture-specific binary.
After changing build configuration, verify:

```bash
lipo -info dist/PreviewMD.app/Contents/MacOS/PreviewMD
```

The result must contain both `x86_64` and `arm64`.

The embedded Quick Look executable must also remain Universal 2:

```bash
lipo -info \
  dist/PreviewMD.app/Contents/PlugIns/PreviewMDQuickLook.appex/Contents/MacOS/PreviewMDQuickLook
```

## Production signing and notarization

The production signing identity is:

```text
Developer ID Application: Astrography Sp. z o.o. (4NZF9USX28)
```

The Apple Developer Team ID is:

```text
4NZF9USX28
```

The local `notarytool` keychain profile is:

```text
PreviewMD-Notary
```

Never store Apple Account passwords, app-specific passwords, private keys,
certificate exports, or notarization credentials in this repository. The
notarization secret belongs only in the macOS Keychain.

Create a complete release with:

```bash
./scripts/release-app.sh
```

This script must continue to:

1. Build the Universal 2 application.
2. Sign it with Developer ID, Hardened Runtime, and a secure timestamp.
3. Verify the code signature.
4. Submit a ZIP to Apple using `notarytool`.
5. Wait for an `Accepted` result.
6. Staple and validate the notarization ticket.
7. Verify Gatekeeper reports `source=Notarized Developer ID`.
8. Produce a fallback ZIP containing the stapled application.
9. Create the drag-to-Applications DMG with its installation instructions.
10. Sign, notarize, staple, and validate the final DMG.
11. Verify Gatekeeper accepts the final DMG.

The primary public download is the image ending in `-macOS.dmg`. The archive
ending in `-macOS.zip` may be retained as a fallback, but do not link it from
the landing page. Never distribute the temporary archive ending in
`-notarization.zip`.

Before handing off a release, confirm:

```bash
codesign --verify --deep --strict --verbose=4 dist/PreviewMD.app
codesign --verify --strict --verbose=4 \
  dist/PreviewMD.app/Contents/PlugIns/PreviewMDQuickLook.appex
xcrun stapler validate dist/PreviewMD.app
spctl --assess --type execute --verbose=4 dist/PreviewMD.app
codesign --verify --verbose=2 dist/PreviewMD-<version>-<build>-macOS.dmg
xcrun stapler validate dist/PreviewMD-<version>-<build>-macOS.dmg
spctl --assess --type open --context context:primary-signature --verbose=4 \
  dist/PreviewMD-<version>-<build>-macOS.dmg
```

The most recently accepted release is PreviewMD `1.7 (11)`. Its application
notarization submission is `b1b8a901-4935-4443-a503-75653e545c9c`; the final
DMG submission is `1a455671-f7c8-4a6d-b8bf-97f2daf58410`.

## Versioning

Before each public release, update both values in `scripts/Info.plist`:

- `CFBundleShortVersionString` for the marketing version.
- `CFBundleVersion` for the monotonically increasing build number.

Do not reuse a previously distributed build number.
`scripts/build-app.sh` copies these two values into the Quick Look extension;
do not maintain a second independent release version there.

## Change discipline

- Preserve bundled renderer resources, the embedded showcase, and the Quick
  Look extension when editing packaging scripts.
- Avoid adding network dependencies to Markdown rendering.
- Do not weaken Hardened Runtime or Gatekeeper compatibility to work around a
  signing problem.
- Do not commit generated `.app`, notarization archives, release DMGs or ZIPs,
  signing material, or credentials unless the user explicitly requests
  artifact versioning.
