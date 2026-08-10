import AppKit
import SwiftUI

@main
struct PreviewMDApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState()

    var body: some Scene {
        Window("PreviewMD", id: MainWindow.id) {
            WorkspaceView()
                .environmentObject(state)
                .previewWindowAppearance(state.theme)
                .frame(minWidth: 980, minHeight: 640)
                .onAppear {
                    appDelegate.state = state
                }
        }
        .defaultSize(width: 1360, height: 860)
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            PreviewMDCommands(state: state)
        }

        Settings {
            SettingsView()
                .environmentObject(state)
                .previewWindowAppearance(state.theme)
                .frame(width: 520, height: 450)
        }

        // Replaces the standard About panel, which cannot show the bundled
        // renderers' license texts. `.commandsRemoved` keeps it out of the
        // Window menu; it is reached only from the app menu.
        Window("About PreviewMD", id: AboutWindow.id) {
            AboutView()
                .previewWindowAppearance(state.theme)
        }
        .defaultSize(width: 560, height: 620)
        .windowResizability(.contentMinSize)
        .commandsRemoved()
    }
}

enum AboutWindow {
    static let id = "about"
}

enum MainWindow {
    static let id = "main"
}

@MainActor
enum MainWindowActions {
    static func createDocument(
        in state: AppState,
        openMainWindow: () -> Void,
        activateApplication: () -> Void
    ) {
        state.newDocument()
        openMainWindow()
        activateApplication()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var state: AppState? {
        didSet {
            openPendingURLsIfPossible()
        }
    }

    private var pendingOpenURLs: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        openOrQueue(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard let state else { return .terminateNow }

        state.prepareForTermination { shouldTerminate in
            sender.reply(toApplicationShouldTerminate: shouldTerminate)
        }
        return .terminateLater
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The menu bar finishes assembling a runloop turn after launch.
        DispatchQueue.main.async {
            self.adoptSidebarToggle()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Cheap insurance: if a slow cold start had AppKit insert its item after
        // the pass above, this catches it. The move is idempotent — once the
        // item is in the View menu there is nothing left to find.
        adoptSidebarToggle()
    }

    /// Moves AppKit's automatic "Toggle Sidebar" item into the View menu.
    ///
    /// AppKit inserts that item itself whenever the main menu has nothing wired
    /// to `toggleSidebar:`. Every SwiftUI command routes through a private
    /// `menuAction:` instead, so AppKit never finds one, and appends its item to
    /// the last menu in the bar — which is Help.
    ///
    /// Adopting AppKit's own item is better than declaring a SwiftUI button that
    /// forwards the selector: this one keeps the standard shortcut and, more
    /// importantly, the standard validation, so it greys out when the front
    /// window has no sidebar to toggle.
    private func adoptSidebarToggle() {
        let toggleSidebar = #selector(NSSplitViewController.toggleSidebar(_:))

        guard let mainMenu = NSApp.mainMenu,
              let viewMenu = mainMenu.items.first(where: { $0.title == "View" })?.submenu
        else { return }

        let menus = mainMenu.items.compactMap(\.submenu)
        guard let stray = menus.lazy
            .filter({ $0 !== viewMenu })
            .compactMap({ menu in menu.items.first { $0.action == toggleSidebar } })
            .first
        else { return }

        stray.menu?.removeItem(stray)
        viewMenu.insertItem(stray, at: 0)
        viewMenu.insertItem(.separator(), at: 1)
    }

    private func openOrQueue(_ urls: [URL]) {
        let supportedURLs = urls.filter(MarkdownFileSupport.accepts)
        guard !supportedURLs.isEmpty else { return }

        guard let state else {
            pendingOpenURLs.append(contentsOf: supportedURLs)
            return
        }

        supportedURLs.forEach(state.open)
    }

    private func openPendingURLsIfPossible() {
        guard let state, !pendingOpenURLs.isEmpty else { return }
        let urls = pendingOpenURLs
        pendingOpenURLs.removeAll()
        urls.forEach(state.open)
    }
}

struct PreviewMDCommands: Commands {
    @ObservedObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About PreviewMD") {
                openWindow(id: AboutWindow.id)
                NSApp.activate(ignoringOtherApps: true)
            }
        }

        CommandGroup(replacing: .newItem) {
            Button("New Markdown") {
                MainWindowActions.createDocument(
                    in: state,
                    openMainWindow: { openWindow(id: MainWindow.id) },
                    activateApplication: { NSApp.activate(ignoringOtherApps: true) }
                )
            }
            .keyboardShortcut("n")

            Button("Open…") {
                state.presentOpenPanel()
            }
            .keyboardShortcut("o")

            Button("Open Folder…") {
                state.presentFolderOpenPanel()
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])

            Divider()

            Button("Save") {
                state.saveCurrent()
            }
            .keyboardShortcut("s")
            .disabled(state.currentDocument == nil)

            Button("Save As…") {
                state.saveCurrentAs()
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(state.currentDocument == nil)

            Divider()

            Button("Export as PDF…") {
                state.exportPDF()
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(state.currentDocument == nil || state.displayMode == .source)
        }

        CommandGroup(replacing: .undoRedo) {
            Button("Undo") {
                state.undoCurrent()
            }
            .keyboardShortcut("z")
            .disabled(!state.canUndoCurrent)

            Button("Redo") {
                state.redoCurrent()
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!state.canRedoCurrent)
        }

        CommandGroup(replacing: .printItem) {
            Button("Print…") {
                state.printCurrent()
            }
            .keyboardShortcut("p")
            .disabled(state.currentDocument == nil || state.displayMode == .source)
        }

        CommandGroup(after: .printItem) {
            Button("Close Tab") {
                state.closeCurrentTab()
            }
            .keyboardShortcut("w")
            .disabled(state.currentDocument == nil)
        }

        // Find belongs in Edit by macOS convention, not in View next to the
        // display options.
        CommandGroup(after: .textEditing) {
            Button("Find…") {
                state.searchFieldFocusToken = UUID()
            }
            .keyboardShortcut("f")
            .disabled(state.currentDocument == nil || state.isFocusMode)
        }

        // Everything here belongs to the View menu, so it has to be a
        // CommandGroup rather than a CommandMenu("View"): SwiftUI already builds
        // a View menu for the split view, so a second menu of the same name sat
        // beside it in the menu bar.
        //
        // AppKit's own Toggle Sidebar item is not declared here — see
        // AppDelegate.adoptSidebarToggle().
        CommandGroup(replacing: .sidebar) {
            Button(state.isFocusMode ? "Exit Focus Mode" : "Enter Focus Mode") {
                state.toggleFocusMode()
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(!state.canEnterFocusMode)

            Divider()

            Picker("Display Mode", selection: $state.displayMode) {
                ForEach(DisplayMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.symbol).tag(mode)
                }
            }
            .disabled(state.isFocusMode)

            Button("Next Reading Style") {
                state.cycleReadingStyle()
            }

            Divider()

            Button(state.isInspectorVisible ? "Hide Outline" : "Show Outline") {
                state.isInspectorVisible.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(state.isFocusMode)

            Divider()

            Button("Actual Size") {
                state.zoom = 1
            }
            .keyboardShortcut("0")

            Button("Zoom In") {
                state.zoomIn()
            }
            .keyboardShortcut("+")

            Button("Zoom Out") {
                state.zoomOut()
            }
            .keyboardShortcut("-")
        }
    }
}
