# Windows experiment

This folder is the first Windows slice for [issue 22](https://github.com/ashtree74/PreviewMD/issues/22). The window title is PreviewMD (Windows experiment). The macOS app stays the product.

## Build and run

From the repository root:

```powershell
dotnet test ports/windows/PreviewMD.Windows.sln
dotnet run --project ports/windows/PreviewMD.Windows/PreviewMD.Windows.csproj
```

The first screen has **Open** and **Showcase**. **Open** uses the Windows file picker for `.md` and `.markdown`. **Showcase** loads the bundled `welcome.md`. Drop a Markdown file on the window to open it. Ctrl+O opens the picker. Ctrl+W closes the current document, and closes the window when no document is open.

Right-click the empty screen for **Open** and **Showcase**. Right-click the document for **Open** and **Close document** on the web view menu.

Files you open are kept in the taskbar Jump List under Recent. Windows only shows that list when a Start menu shortcut carries the same app id, so the app creates PreviewMD (Windows experiment) in the Start menu. A second launch with one of those files uses the window that is already open.

Ctrl+Tab waits for tabs. The issue leaves tabs until after this slice.

To open a file without the picker:

```powershell
dotnet run --project ports/windows/PreviewMD.Windows/PreviewMD.Windows.csproj -- C:\docs\note.md
dotnet run --project ports/windows/PreviewMD.Windows/PreviewMD.Windows.csproj -- --showcase
```

An unpackaged build copies the Windows App SDK next to the executable, so `dotnet run` starts on a machine that does not already have that runtime. To build an MSIX instead, pass `-p:WindowsPackageType=MSIX`. That package expects the Windows App Runtime.

## What the slice keeps

The renderer in `Sources/PreviewMD/Resources/Renderer/` is copied unchanged. `ports/windows/renderer.sha256` pins every file. The build fails when the source tree or the copy disagrees with that list.

The shell calls `window.previewmdRender` with the same field names as the macOS app. Relative images use `previewmd-local-image`. The shell serves a file only when the path stays inside the open document's folder, the file is an image, and it is at most 100 MB. `http`, `https`, and `mailto` links open with `Launcher.LaunchUriAsync`. They do not render inside the window.

## What the slice leaves out

Tabs, editing, drag and drop, the Jump List, reading-width controls, focus mode, file watching, PDF, DOCX, signing, and the Store. Quick Look, the macOS toolbar, and Universal 2 stay on the Mac.

A directory junction inside the document folder can still point at a file outside that folder. This slice does not resolve junctions.
