import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceView: View {
    @EnvironmentObject private var state: AppState
    @State private var columnVisibility: NavigationSplitViewVisibility = .detailOnly
    @State private var columnVisibilityBeforeFocus: NavigationSplitViewVisibility?
    @State private var isDropTargeted = false
    @State private var isSearchPresented = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 208, max: 280)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .inspector(isPresented: inspectorPresentation) {
            OutlineInspector()
                .inspectorColumnWidth(min: 180, ideal: 200, max: 232)
        }
        .searchable(
            text: $state.searchText,
            isPresented: $isSearchPresented,
            placement: .toolbar,
            prompt: "Find"
        )
        // Focus mode keeps this hierarchy and only hides the chrome, so the web
        // view is never rebuilt and the reader keeps their place in the page.
        // No solid bar in focus mode — the blurred edge below it is the whole
        // transition, and a background would put a hard band back on top of it.
        .toolbarBackground(state.isFocusMode ? .hidden : .automatic, for: .windowToolbar)
        .focusModeEscape(isActive: state.isFocusMode) {
            state.exitFocusMode()
        }
        .onChange(of: state.isFocusMode) {
            if state.isFocusMode {
                columnVisibilityBeforeFocus = columnVisibility
                // Forced through a different value first: the split view can be
                // restored open behind SwiftUI's back, and assigning the value
                // it already holds would collapse nothing.
                columnVisibility = .all
                DispatchQueue.main.async {
                    if state.isFocusMode {
                        columnVisibility = .detailOnly
                    }
                }
                isSearchPresented = false
            } else if let restored = columnVisibilityBeforeFocus {
                columnVisibilityBeforeFocus = nil
                columnVisibility = restored
            }
        }
        // Focus mode empties the toolbar rather than removing it. The bar keeps
        // its system material, so the page scrolls up underneath it the way it
        // does everywhere else in macOS, and the window keeps its buttons.
        .toolbar {
            if !state.isFocusMode {
                ToolbarItem(placement: .navigation) {
                    Menu {
                        Button("Open Markdown…") {
                            state.presentOpenPanel()
                        }
                        Button("Open Folder…") {
                            state.presentFolderOpenPanel()
                        }
                    } label: {
                        Label("Open", systemImage: "folder.badge.plus")
                    }
                    .help("Open Markdown or a folder")
                }

                // The principal slot holds the display picker and nothing else.
                // Anything added beside it makes SwiftUI drag the split view's
                // sidebar button across to sit next to it, out of the sidebar
                // column where it belongs.
                ToolbarItem(placement: .principal) {
                    Picker("Display mode", selection: $state.displayMode) {
                        ForEach(DisplayMode.allCases) { mode in
                            Image(systemName: mode.symbol)
                                .help(mode.title)
                                .tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 136)
                    .disabled(state.currentDocument == nil)
                }

                ToolbarItem(placement: .primaryAction) {
                    ToolbarUtilities()
                }
            }
        }
        // The toolbar itself has no items in focus mode. Keeping the exit
        // control in the existing detail hierarchy prevents AppKit from moving
        // it into the leading group when the inspector closes and the toolbar
        // is rebuilt.
        .overlay(alignment: .topTrailing) {
            if state.isFocusMode {
                Button {
                    state.exitFocusMode()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .help("Leave focus mode (Esc)")
                .padding(.top, 9)
                .padding(.trailing, 12)
            }
        }
        .onChange(of: state.searchFieldFocusToken) {
            guard state.currentDocument != nil else { return }
            isSearchPresented = true
        }
        .onChange(of: state.theme) {
            state.updatePreferences()
        }
        .onChange(of: state.readingStyle) {
            state.updatePreferences()
        }
        .onChange(of: state.readingWidth) {
            state.updatePreferences()
        }
        .onChange(of: state.customReadingWidth) {
            state.updatePreferences()
        }
        .onChange(of: state.usesPaperCanvas) {
            state.updatePreferences()
        }
        .onChange(of: state.selectedCustomPresetID) {
            state.updatePreferences()
        }
        .onChange(of: state.liveReloadEnabled) {
            state.updatePreferences()
        }
        .onChange(of: state.selectedDocumentID) {
            NSApplication.shared.mainWindow?.title = state.currentDocument?.title ?? "PreviewMD"
            if state.currentDocument == nil {
                isSearchPresented = false
            }
        }
        .onChange(of: state.workspaceFolderURL) {
            if state.workspaceFolderURL != nil, !state.isFocusMode {
                columnVisibility = .all
            }
        }
        .sheet(item: $state.editingCustomPreset) { preset in
            CustomStyleEditor(initialPreset: preset)
                .environmentObject(state)
        }
    }

    @ViewBuilder
    private var detail: some View {
        ZStack {
            DetailBackground()

            VStack(spacing: 0) {
                if !state.documents.isEmpty && !state.isFocusMode {
                    DocumentTabBar()
                }

                if let document = state.currentDocument {
                    DocumentWorkspace(document: document)
                        .id(document.id)
                } else {
                    EmptyWorkspace()
                }
            }

            if isDropTargeted {
                DropOverlay()
                    .transition(.opacity)
            }
        }
        // Attached to the detail column, never to the NavigationSplitView: a
        // background on the split view changes how the toolbar divides itself
        // between sidebar and detail, and pushes the sidebar button to the wrong
        // side of it.
        .background(
            FocusWindowChrome(
                isFocusMode: state.isFocusMode,
                sidebarVisibility: columnVisibility,
                inspectorVisibility: state.isInspectorVisible
            )
        )
        .dropDestination(for: URL.self) { urls, _ in
            let folders = urls.filter(MarkdownFileSupport.isFolder)
            let accepted = urls.filter(MarkdownFileSupport.accepts)
            if let folder = folders.first {
                state.openFolder(url: folder)
            }
            accepted.forEach(state.open)
            return !folders.isEmpty || !accepted.isEmpty
        } isTargeted: { targeted in
            withAnimation(.easeOut(duration: 0.16)) {
                isDropTargeted = targeted
            }
        }
    }

    private var inspectorPresentation: Binding<Bool> {
        Binding(
            get: {
                state.currentDocument != nil && state.isInspectorVisible
            },
            set: { newValue in
                state.isInspectorVisible = newValue
            }
        )
    }
}

enum FocusMetrics {
    /// Height of the unified toolbar the page has to clear in focus mode.
    static let toolbarHeight: Double = 52
}

/// A transparent strip that drags the window, for the band the toolbar shares
/// with the page in focus mode.
///
/// `mouseDownCanMoveWindow` is what AppKit consults under the pointer, and the
/// web view answers no. The focus exit control is layered above this view, so
/// it keeps receiving its clicks.
private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
    }
}

@MainActor
final class ToolbarItemVisibilityController: NSObject {
    private struct ItemState {
        let item: NSToolbarItem
        let view: NSView?
        let isBordered: Bool
        let searchFieldWasHidden: Bool?
        let searchFieldAlpha: CGFloat?
        let searchFieldWidth: CGFloat?
        let searchFieldWidthConstraint: NSLayoutConstraint?
        let searchContainer: NSView?
        let searchContainerWasHidden: Bool?
        let searchContainerAlpha: CGFloat?
    }

    private final class CollapsedItemView: NSView {
        override var intrinsicContentSize: NSSize { .zero }
    }

    private let identifiers: Set<NSToolbarItem.Identifier>
    private var itemStates: [ObjectIdentifier: ItemState] = [:]
    private weak var observedToolbar: NSToolbar?
    private var isEnforcingHidden = false
    private var afterToolbarChange: (@MainActor () -> Void)?

    init(identifiers: Set<NSToolbarItem.Identifier>) {
        self.identifiers = identifiers
        super.init()
    }

    func enforceHidden(
        from toolbar: NSToolbar,
        afterToolbarChange: @escaping @MainActor () -> Void = {}
    ) {
        if observedToolbar !== toolbar {
            stopEnforcingHidden()
            observedToolbar = toolbar
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(toolbarDidAddItem),
                name: NSToolbar.willAddItemNotification,
                object: toolbar
            )
        }
        self.afterToolbarChange = afterToolbarChange
        isEnforcingHidden = true
        hideItems(in: toolbar)
        toolbar.validateVisibleItems()
        afterToolbarChange()
    }

    func stopEnforcingHidden() {
        let toolbar = observedToolbar
        if let toolbar {
            NotificationCenter.default.removeObserver(
                self,
                name: NSToolbar.willAddItemNotification,
                object: toolbar
            )
        }
        isEnforcingHidden = false
        observedToolbar = nil
        afterToolbarChange = nil
        restoreHiddenItems()
        toolbar?.validateVisibleItems()
        DispatchQueue.main.async { [weak toolbar] in
            toolbar?.validateVisibleItems()
        }
    }

    func hideItems(in toolbar: NSToolbar) {
        for item in toolbar.items {
            let identifier = item.itemIdentifier
            guard identifiers.contains(identifier) else { continue }
            let key = ObjectIdentifier(item)
            if itemStates[key] == nil {
                let searchItem = item as? NSSearchToolbarItem
                let searchContainer = searchItem?.searchField.superview
                itemStates[key] = ItemState(
                    item: item,
                    view: item.view,
                    isBordered: item.isBordered,
                    searchFieldWasHidden: searchItem?.searchField.isHidden,
                    searchFieldAlpha: searchItem?.searchField.alphaValue,
                    searchFieldWidth: searchItem?.preferredWidthForSearchField,
                    searchFieldWidthConstraint: searchItem?.searchField.widthAnchor.constraint(
                        equalToConstant: 0
                    ),
                    searchContainer: searchContainer,
                    searchContainerWasHidden: searchContainer?.isHidden,
                    searchContainerAlpha: searchContainer?.alphaValue
                )
            }

            item.isBordered = false
            if let searchItem = item as? NSSearchToolbarItem {
                itemStates[key]?.searchContainer?.isHidden = true
                itemStates[key]?.searchContainer?.alphaValue = 0
                searchItem.searchField.isHidden = true
                searchItem.searchField.alphaValue = 0
                searchItem.preferredWidthForSearchField = 0
                itemStates[key]?.searchFieldWidthConstraint?.isActive = true
            } else {
                let collapsedView = CollapsedItemView(frame: .zero)
                collapsedView.translatesAutoresizingMaskIntoConstraints = false
                item.view = collapsedView
            }
        }
    }

    private func restoreHiddenItems() {
        for state in itemStates.values {
            state.item.isBordered = state.isBordered
            if let searchItem = state.item as? NSSearchToolbarItem {
                state.searchFieldWidthConstraint?.isActive = false
                if let wasHidden = state.searchContainerWasHidden {
                    state.searchContainer?.isHidden = wasHidden
                }
                if let alpha = state.searchContainerAlpha {
                    state.searchContainer?.alphaValue = alpha
                }
                if let wasHidden = state.searchFieldWasHidden {
                    searchItem.searchField.isHidden = wasHidden
                }
                if let alpha = state.searchFieldAlpha {
                    searchItem.searchField.alphaValue = alpha
                }
                if let width = state.searchFieldWidth {
                    searchItem.preferredWidthForSearchField = width
                }
            } else {
                state.item.view = state.view
            }
        }
        itemStates.removeAll()
    }

    @objc private func toolbarDidAddItem(_ notification: Notification) {
        guard isEnforcingHidden,
              let toolbar = notification.object as? NSToolbar,
              toolbar === observedToolbar
        else {
            return
        }
        // SwiftUI can still be in the middle of inserting a batch of toolbar
        // items. Hide the focus-mode exclusions on the next main-queue pass,
        // after that insertion has completed.
        DispatchQueue.main.async { [weak self, weak toolbar] in
            guard let self, let toolbar,
                  self.isEnforcingHidden,
                  toolbar === self.observedToolbar
            else {
                return
            }
            self.hideItems(in: toolbar)
            toolbar.validateVisibleItems()
            self.afterToolbarChange?()
        }
    }
}

/// Owns the parts of the window SwiftUI will not hand over.
///
/// SwiftUI cannot hide its search item for one state without rebuilding the
/// view hierarchy, and dynamic removal of the split-view toggle is ignored on
/// supported macOS releases. Their item identity remains intact: focus mode
/// collapses their existing views, then restores the exact same items and
/// properties on exit without asking SwiftUI to reconstruct either one.
private struct FocusWindowChrome: NSViewRepresentable {
    let isFocusMode: Bool
    /// Not read directly — it makes the representable update if SwiftUI rebuilds
    /// the toolbar while changing the split-view columns.
    let sidebarVisibility: NavigationSplitViewVisibility
    /// Closing the inspector also rebuilds the toolbar after focus mode begins.
    /// Keeping this input explicit makes the representable follow that lifecycle.
    let inspectorVisibility: Bool

    private static let systemSidebarToggle = NSToolbarItem.Identifier(
        "com.apple.SwiftUI.navigationSplitView.toggleSidebar"
    )
    private static let systemSearchField = NSToolbarItem.Identifier("com.apple.SwiftUI.search")

    @MainActor
    final class Coordinator {
        /// The title as the window had it before focus mode blanked it. Putting
        /// a title of our own choosing back would change the toolbar's layout:
        /// the leading region is sized around it, and a longer string pushes the
        /// sidebar button across the split.
        var restoredTitle: String?
        /// Whether the window has actually been put into focus mode. Until it
        /// has, this type must not touch the window at all — writing styleMask
        /// or titlebarSeparatorStyle makes AppKit rebuild the title bar, and the
        /// rebuild reassigns toolbar items between the sidebar and the detail.
        var didEnterFocus = false
        /// SwiftUI's unified window already carries this flag. Focus mode must
        /// remove it on exit only when it added the flag itself; otherwise the
        /// restored window is not the same window configuration it entered with.
        var addedFullSizeContentView = false
        /// `.automatic` is not necessarily the value chosen by the system or a
        /// future window style, so restore the exact separator state we found.
        var restoredSeparatorStyle: NSTitlebarSeparatorStyle?
        private var titleObservation: NSKeyValueObservation?
        /// Keep the system items alive but hidden so SwiftUI can restore the
        /// toolbar without having to reconstruct its sidebar and search items.
        let toolbarItems: ToolbarItemVisibilityController

        init() {
            toolbarItems = ToolbarItemVisibilityController(
                identifiers: [systemSidebarToggle, systemSearchField]
            )
        }

        func enforceBlankTitle(in window: NSWindow) {
            guard titleObservation == nil else { return }
            titleObservation = window.observe(\.title, options: [.new]) { [weak self, weak window] _, change in
                guard !(change.newValue ?? "").isEmpty else { return }
                Task { @MainActor [weak self, weak window] in
                    guard let self, let window, self.didEnterFocus else { return }
                    FocusWindowChrome.applyFocusedWindowChrome(to: window)
                }
            }
        }

        func stopEnforcingBlankTitle() {
            titleObservation?.invalidate()
            titleObservation = nil
        }

    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.isHidden = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let focused = isFocusMode
        let coordinator = context.coordinator
        // Not in a window yet on the first pass.
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }

            // Nothing to do until focus mode has actually been used.
            guard focused || coordinator.didEnterFocus else { return }

            // `titlebarAppearsTransparent` stays false on purpose: the bar has
            // to keep its material, because that material is what blurs the text
            // passing beneath it. Only the content area is extended upwards.
            // Changing the style mask makes AppKit recompute the frame from the
            // content rect, which can shift the window's top edge. Only change
            // it if this window did not already use a full-size content view,
            // and put the frame back exactly as it was.
            let frame = window.frame
            if focused {
                if !coordinator.didEnterFocus {
                    coordinator.addedFullSizeContentView = !window.styleMask.contains(.fullSizeContentView)
                    coordinator.restoredSeparatorStyle = window.titlebarSeparatorStyle
                }
                if coordinator.addedFullSizeContentView {
                    window.styleMask.insert(.fullSizeContentView)
                }
                coordinator.didEnterFocus = true
            } else {
                if coordinator.addedFullSizeContentView {
                    window.styleMask.remove(.fullSizeContentView)
                }
                coordinator.addedFullSizeContentView = false
                coordinator.didEnterFocus = false
            }
            if window.frame != frame {
                window.setFrame(frame, display: true)
            }
            if focused {
                if coordinator.restoredTitle == nil {
                    coordinator.restoredTitle = window.title
                }
                coordinator.enforceBlankTitle(in: window)
                Self.applyFocusedWindowChrome(to: window)
            } else if let restored = coordinator.restoredTitle {
                coordinator.stopEnforcingBlankTitle()
                window.title = restored
                coordinator.restoredTitle = nil
            }
            // The hairline under the bar is what makes the text look clipped
            // rather than passing beneath it. Mail draws no such line.
            if !focused {
                window.titlebarSeparatorStyle = coordinator.restoredSeparatorStyle ?? .automatic
                coordinator.restoredSeparatorStyle = nil
            }

            if focused {
                guard let toolbar = window.toolbar else { return }
                coordinator.toolbarItems.enforceHidden(from: toolbar) { [weak window] in
                    guard let window else { return }
                    Self.applyFocusedWindowChrome(to: window)
                }
            } else {
                coordinator.toolbarItems.stopEnforcingHidden()
            }
        }
    }

    private static func applyFocusedWindowChrome(to window: NSWindow) {
        window.title = ""
        if window.titlebarSeparatorStyle != .none {
            window.titlebarSeparatorStyle = .none
        }
        if let titlebarView = window.standardWindowButton(.closeButton)?.superview {
            titlebarView.needsLayout = true
            titlebarView.layoutSubtreeIfNeeded()
            titlebarView.needsDisplay = true
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.toolbarItems.stopEnforcingHidden()
        coordinator.stopEnforcingBlankTitle()
    }
}

private extension View {
    /// Leaves focus mode on a bare Escape.
    ///
    /// A local event monitor rather than `onExitCommand`, because the web view
    /// owns first responder while you are reading and SwiftUI's key handling
    /// never sees the key.
    func focusModeEscape(isActive: Bool, perform action: @escaping () -> Void) -> some View {
        modifier(FocusModeEscape(isActive: isActive, action: action))
    }
}

private struct FocusModeEscape: ViewModifier {
    let isActive: Bool
    let action: () -> Void

    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onChange(of: isActive, initial: true) { _, active in
                active ? install() : remove()
            }
            .onDisappear(perform: remove)
    }

    private func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
            guard event.keyCode == 53, // Escape
                  event.modifierFlags.intersection(modifiers).isEmpty
            else {
                return event
            }
            action()
            return nil // swallow it, so nothing else reacts to the same press
        }
    }

    private func remove() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }
}

private struct DetailBackground: View {
    var body: some View {
        if #available(macOS 26.0, *) {
            Color(nsColor: .windowBackgroundColor)
                .backgroundExtensionEffect()
                .ignoresSafeArea()
        } else {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()
        }
    }
}

private struct ToolbarUtilities: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ControlGroup {
            Menu {
                Section("Reading style") {
                    ForEach(ReadingStyle.allCases.filter { $0 != .custom }) { style in
                        Button {
                            state.readingStyle = style
                        } label: {
                            Label(
                                style.title,
                                systemImage: state.readingStyle == style
                                    ? "checkmark"
                                    : style.symbol
                            )
                        }
                    }
                }

                if !state.customReadingPresets.isEmpty {
                    Section("Custom presets") {
                        ForEach(state.customReadingPresets) { preset in
                            Button {
                                state.selectedCustomPresetID = preset.id
                                state.readingStyle = .custom
                            } label: {
                                Label(
                                    preset.name,
                                    systemImage: state.readingStyle == .custom
                                        && state.selectedCustomPresetID == preset.id
                                        ? "checkmark"
                                        : "paintpalette"
                                )
                            }
                        }
                    }
                }

                Section {
                    Button("New Custom Style…") {
                        state.beginNewCustomPreset()
                    }
                    if let preset = state.activeCustomReadingPreset {
                        Button("Edit “\(preset.name)”…") {
                            state.beginEditingCustomPreset(preset)
                        }
                    }
                    Button("Next Style", systemImage: "arrow.triangle.2.circlepath") {
                        state.cycleReadingStyle()
                    }
                    .keyboardShortcut("t", modifiers: [.command, .option])
                }

                Divider()

                Menu {
                    ForEach(PreviewTheme.allCases) { theme in
                        Button {
                            state.theme = theme
                        } label: {
                            Label(
                                theme.title,
                                systemImage: state.theme == theme
                                    ? "checkmark"
                                    : theme.symbol
                            )
                        }
                    }
                } label: {
                    Label("Theme", systemImage: state.theme.symbol)
                }

                Divider()

                Menu {
                    ForEach(ReadingWidth.allCases) { width in
                        Button {
                            state.readingWidth = width
                        } label: {
                            Label(
                                width == .custom
                                    ? "Custom — \(Int(state.customReadingWidth)) px"
                                    : width.title,
                                systemImage: state.readingWidth == width
                                    ? "checkmark"
                                    : width.symbol
                            )
                        }
                    }
                } label: {
                    Label("Reading width", systemImage: state.readingWidth.symbol)
                }

                Toggle("Paper canvas", isOn: $state.usesPaperCanvas)
                Toggle("Reload changes automatically", isOn: $state.liveReloadEnabled)

                Divider()

                Button("Actual Size") {
                    state.zoom = 1
                }
                Button("Zoom In") {
                    state.zoomIn()
                }
                Button("Zoom Out") {
                    state.zoomOut()
                }
            } label: {
                Label("Reading appearance", systemImage: "textformat.size")
            }
            .help("Reading appearance")

            // Focus belongs beside reading appearance: both controls change
            // the reading environment, while reload/share/outline act on the
            // current document. The bar is stripped as soon as focus begins.
            Button {
                state.enterFocusMode()
            } label: {
                Label("Focus", systemImage: "rectangle.center.inset.filled")
            }
            .disabled(!state.canEnterFocusMode)
            .help("Focus mode — just the page (⇧⌘F)")

            Button {
                state.reloadCurrent()
            } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }
            .disabled(state.currentDocument?.url == nil)
            .help("Reload from disk")

            Menu {
                Button {
                    state.exportPDF()
                } label: {
                    Label("Export as PDF…", systemImage: "doc.richtext")
                }
                .disabled(state.displayMode == .source)

                if let url = state.currentDocument?.url {
                    Divider()
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.path, forType: .string)
                    } label: {
                        Label("Copy Path", systemImage: "doc.on.doc")
                    }
                }
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .disabled(state.currentDocument == nil)

            Button {
                state.isInspectorVisible.toggle()
            } label: {
                Label("Outline", systemImage: "sidebar.right")
            }
            .disabled(state.currentDocument == nil)
            .help(state.isInspectorVisible ? "Hide outline" : "Show outline")
        }
        .controlGroupStyle(.navigation)
    }
}

private struct CustomStyleEditor: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var preset: CustomReadingPreset

    init(initialPreset: CustomReadingPreset) {
        _preset = State(initialValue: initialPreset)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Custom Reading Style")
                        .font(.title2.weight(.semibold))
                    Text("Save typography and colors as a named preset.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Form {
                TextField("Preset name", text: $preset.name)

                Picker("Body font", selection: $preset.bodyFont) {
                    ForEach(ReadingFont.allCases) { font in
                        Text(font.title).tag(font)
                    }
                }
                Picker("Heading font", selection: $preset.headingFont) {
                    ForEach(ReadingFont.allCases) { font in
                        Text(font.title).tag(font)
                    }
                }

                LabeledContent("Text size") {
                    HStack {
                        Slider(value: $preset.bodySize, in: 13...22, step: 0.5)
                            .frame(width: 190)
                        Text("\(preset.bodySize, specifier: "%.1f") pt")
                            .monospacedDigit()
                            .frame(width: 55, alignment: .trailing)
                    }
                }
                LabeledContent("Line height") {
                    HStack {
                        Slider(value: $preset.lineHeight, in: 1.25...2.0, step: 0.02)
                            .frame(width: 190)
                        Text("\(preset.lineHeight, specifier: "%.2f")")
                            .monospacedDigit()
                            .frame(width: 55, alignment: .trailing)
                    }
                }

                HexColorPicker("Accent", hex: $preset.accentHex)
                HexColorPicker("Light page", hex: $preset.lightPageHex)
                HexColorPicker("Light text", hex: $preset.lightInkHex)
                HexColorPicker("Dark page", hex: $preset.darkPageHex)
                HexColorPicker("Dark text", hex: $preset.darkInkHex)
            }
            .formStyle(.grouped)

            HStack {
                if state.customReadingPresets.contains(where: { $0.id == preset.id }) {
                    Button("Delete", role: .destructive) {
                        state.deleteCustomPreset(preset)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") {
                    state.editingCustomPreset = nil
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Save") {
                    state.saveCustomPreset(preset)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 540)
    }
}

private struct HexColorPicker: View {
    let title: String
    @Binding var hex: String

    init(_ title: String, hex: Binding<String>) {
        self.title = title
        _hex = hex
    }

    var body: some View {
        ColorPicker(title, selection: colorBinding, supportsOpacity: false)
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { Color(nsColor: NSColor(previewMDHex: hex) ?? .controlAccentColor) },
            set: { color in
                if let value = NSColor(color).usingColorSpace(.sRGB)?.previewMDHex {
                    hex = value
                }
            }
        )
    }
}

private extension NSColor {
    convenience init?(previewMDHex: String) {
        let value = previewMDHex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard value.count == 6, let number = Int(value, radix: 16) else { return nil }
        let red = CGFloat((number >> 16) & 0xff) / 255
        let green = CGFloat((number >> 8) & 0xff) / 255
        let blue = CGFloat(number & 0xff) / 255
        self.init(
            srgbRed: red,
            green: green,
            blue: blue,
            alpha: 1
        )
    }

    var previewMDHex: String {
        let color = usingColorSpace(.sRGB) ?? self
        return String(
            format: "#%02X%02X%02X",
            Int((color.redComponent * 255).rounded()),
            Int((color.greenComponent * 255).rounded()),
            Int((color.blueComponent * 255).rounded())
        )
    }
}

private struct SidebarView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            SidebarModePicker(selection: $state.sidebarMode)
                .frame(width: 176, height: 32)
                .padding(.top, 9)
                .padding(.bottom, 7)

            Divider()

            Group {
                switch state.sidebarMode {
                case .recent:
                    RecentDocumentsSidebar()
                case .tree:
                    FolderBrowserSidebar()
                case .files:
                    FlatFilesSidebar()
                case .search:
                    FolderSearchSidebar()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack(spacing: 12) {
                Button {
                    state.presentOpenPanel()
                } label: {
                    Label("File", systemImage: "doc.badge.plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .help("Open Markdown (⌘O)")

                Button {
                    state.presentFolderOpenPanel()
                } label: {
                    Label("Folder", systemImage: "folder.badge.plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .help("Open Folder (⇧⌘O)")
            }
            .buttonStyle(.plain)
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .foregroundStyle(.secondary)
        }
    }
}

/// AppKit exposes per-segment help tags, which produce the standard delayed
/// macOS tooltip bubble. SwiftUI's segmented picker only exposes one tooltip
/// for the entire control, so this small bridge keeps every icon discoverable.
private struct SidebarModePicker: NSViewRepresentable {
    @Binding var selection: SidebarMode

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.segmentCount = SidebarMode.allCases.count
        control.trackingMode = .selectOne
        control.segmentStyle = .rounded
        control.controlSize = .large
        control.target = context.coordinator
        control.action = #selector(Coordinator.selectionChanged(_:))
        control.setAccessibilityLabel("Sidebar mode")

        for mode in SidebarMode.allCases {
            let segment = mode.rawValue
            control.setImage(
                NSImage(systemSymbolName: mode.symbol, accessibilityDescription: mode.title),
                forSegment: segment
            )
            control.setImageScaling(.scaleProportionallyDown, forSegment: segment)
            control.setWidth(42, forSegment: segment)
            control.setToolTip(mode.title, forSegment: segment)
        }
        control.selectedSegment = selection.rawValue
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        if control.selectedSegment != selection.rawValue {
            control.selectedSegment = selection.rawValue
        }
    }

    final class Coordinator: NSObject {
        var parent: SidebarModePicker

        init(parent: SidebarModePicker) {
            self.parent = parent
        }

        @MainActor @objc func selectionChanged(_ sender: NSSegmentedControl) {
            guard let mode = SidebarMode(rawValue: sender.selectedSegment) else { return }
            parent.selection = mode
        }
    }
}

private struct RecentDocumentsSidebar: View {
    @EnvironmentObject private var state: AppState

    private var pinned: [RecentDocument] {
        state.recentDocuments.filter(\.isPinned)
    }

    private var recent: [RecentDocument] {
        state.recentDocuments.filter { !$0.isPinned }
    }

    var body: some View {
        if state.recentDocuments.isEmpty {
            SidebarPlaceholder(
                title: "No Recent Documents",
                description: "Files you open will appear here.",
                symbol: "clock.arrow.circlepath"
            )
        } else {
            List {
                if !pinned.isEmpty {
                    Section("Pinned") {
                        ForEach(pinned) { item in
                            RecentRow(item: item)
                        }
                    }
                }

                if !recent.isEmpty {
                    Section("Recent") {
                        ForEach(recent) { item in
                            RecentRow(item: item)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
    }
}

private struct FolderBrowserSidebar: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        if let folderURL = state.workspaceFolderURL {
            List {
                Section {
                    if state.workspaceFolderItems.isEmpty {
                        if state.isWorkspaceFolderLoading {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Scanning for Markdown…")
                            }
                            .foregroundStyle(.secondary)
                        } else {
                            VStack(spacing: 6) {
                                Label(
                                    "No Markdown Files",
                                    systemImage: "doc.text.magnifyingglass"
                                )
                                .font(.callout.weight(.medium))
                                Text("This folder has no supported documents.")
                                    .font(.caption)
                                    .multilineTextAlignment(.center)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                        }
                    } else {
                        OutlineGroup(
                            state.workspaceFolderItems,
                            children: \.children
                        ) { item in
                            FolderTreeRow(item: item)
                        }
                    }
                } header: {
                    FolderSectionHeader(folderURL: folderURL)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        } else {
            SidebarPlaceholder(
                title: "No Folder Open",
                description: "Open a folder to browse its Markdown files.",
                symbol: "folder"
            ) {
                state.presentFolderOpenPanel()
            }
        }
    }
}

private struct FlatFilesSidebar: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        if let folderURL = state.workspaceFolderURL {
            List {
                Section {
                    if state.workspaceFolderItems.isEmpty {
                        if state.isWorkspaceFolderLoading {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Scanning for Markdown…")
                            }
                            .foregroundStyle(.secondary)
                        } else {
                            ContentUnavailableView(
                                "No Markdown Files",
                                systemImage: "doc.text.magnifyingglass",
                                description: Text("No supported documents were found.")
                            )
                        }
                    } else {
                        ForEach(state.workspaceFiles) { item in
                            WorkspaceFileRow(item: item, rootURL: folderURL)
                        }
                    }
                } header: {
                    FlatFilesHeader(folderURL: folderURL)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        } else {
            SidebarPlaceholder(
                title: "No Folder Open",
                description: "Open a folder to browse all of its Markdown files.",
                symbol: "doc.text"
            ) {
                state.presentFolderOpenPanel()
            }
        }
    }
}

private struct FolderSearchSidebar: View {
    @EnvironmentObject private var state: AppState
    @FocusState private var isSearchFocused: Bool

    private var queryBinding: Binding<String> {
        Binding(
            get: { state.workspaceSearchQuery },
            set: { state.setWorkspaceSearchQuery($0) }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField

            Divider()

            if state.workspaceFolderURL == nil {
                SidebarPlaceholder(
                    title: "No Folder to Search",
                    description: "Open a folder, then search across all of its documents.",
                    symbol: "doc.text.magnifyingglass"
                ) {
                    state.presentFolderOpenPanel()
                }
            } else if state.workspaceSearchQuery
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty {
                SidebarPlaceholder(
                    title: "Search File Contents",
                    description: "Type a phrase or several words. Partial words also match.",
                    symbol: "text.magnifyingglass"
                )
            } else if state.workspaceSearchResults.isEmpty {
                if state.isWorkspaceSearching {
                    VStack(spacing: 9) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Searching folder…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    SidebarPlaceholder(
                        title: "No Matches",
                        description: "Try a shorter fragment or fewer words.",
                        symbol: "magnifyingglass"
                    )
                }
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 7) {
                        Text(resultSummary)
                        Spacer()
                        if state.isWorkspaceSearching {
                            ProgressView()
                                .controlSize(.mini)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)

                    List(state.workspaceSearchResults) { result in
                        FolderSearchResultRow(result: result)
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                    .opacity(state.isWorkspaceSearching ? 0.68 : 1)
                }
            }
        }
        .task {
            isSearchFocused = true
        }
        .onExitCommand {
            if state.workspaceSearchQuery.isEmpty {
                state.sidebarMode = state.workspaceFolderURL == nil ? .recent : .tree
            } else {
                state.setWorkspaceSearchQuery("")
            }
        }
    }

    private var searchField: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField("Search contents", text: queryBinding)
                    .textFieldStyle(.plain)
                    .focused($isSearchFocused)
                    .onSubmit {
                        state.setWorkspaceSearchQuery(
                            state.workspaceSearchQuery,
                            immediately: true
                        )
                    }

                if state.isWorkspaceSearching {
                    ProgressView()
                        .controlSize(.mini)
                } else if !state.workspaceSearchQuery.isEmpty {
                    Button {
                        state.setWorkspaceSearchQuery("")
                        isSearchFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear Search")
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(
                        Color(nsColor: .separatorColor).opacity(0.55),
                        lineWidth: 0.75
                    )
            }

            Text("All words · use \"quotes\" for an exact phrase")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 2)
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .help("Search all files in the open folder. Use quotes for an exact phrase.")
    }

    private var resultSummary: String {
        let count = state.workspaceSearchResults.count
        return count == 1 ? "1 matching file" : "\(count) matching files"
    }
}

private struct FolderSearchResultRow: View {
    @EnvironmentObject private var state: AppState
    let result: FolderSearchResult

    var body: some View {
        Button {
            state.openWorkspaceSearchResult(result)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text")
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    Text(result.title)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    Text(result.matchCount.formatted())
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                        .help(matchCountHelp)
                }

                Text(result.relativePath)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)

                Text(result.snippet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .background(
                isSelected ? Color.accentColor.opacity(0.13) : Color.clear,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .help(result.relativePath)
        .contextMenu {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([result.url])
            }
        }
    }

    private var isSelected: Bool {
        state.sidebarSelection == result.url.standardizedFileURL.path
    }

    private var matchCountHelp: String {
        result.matchCount == 1 ? "1 match" : "\(result.matchCount) matches"
    }
}

private struct SidebarPlaceholder: View {
    let title: String
    let description: String
    let symbol: String
    let action: (() -> Void)?

    init(
        title: String,
        description: String,
        symbol: String,
        action: (() -> Void)? = nil
    ) {
        self.title = title
        self.description = description
        self.symbol = symbol
        self.action = action
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.callout.weight(.medium))
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let action {
                Button("Open Folder…", action: action)
                    .controlSize(.small)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FolderSectionHeader: View {
    @EnvironmentObject private var state: AppState
    let folderURL: URL

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.secondary)
            Text(folderURL.lastPathComponent)
                .fontWeight(.semibold)
                .lineLimit(1)
                .help(folderURL.path(percentEncoded: false))

            Spacer(minLength: 4)

            if state.isWorkspaceFolderLoading {
                ProgressView()
                    .controlSize(.mini)
            }

            Button {
                state.refreshWorkspaceFolder()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Refresh Folder")

            Button {
                state.closeWorkspaceFolder()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("Close Folder")
        }
        .textCase(nil)
    }
}

private struct FlatFilesHeader: View {
    @EnvironmentObject private var state: AppState
    let folderURL: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            FolderSectionHeader(folderURL: folderURL)
            HStack(spacing: 5) {
                Picker("Sort files", selection: $state.workspaceFileSort) {
                    ForEach(WorkspaceFileSort.allCases) { sort in
                        Text(sort.title).tag(sort)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.mini)

                Button {
                    state.workspaceSortAscending.toggle()
                } label: {
                    Image(
                        systemName: state.workspaceSortAscending
                            ? "arrow.up"
                            : "arrow.down"
                    )
                }
                .buttonStyle(.plain)
                .help(state.workspaceSortAscending ? "Ascending" : "Descending")
            }
        }
        .textCase(nil)
    }
}

private struct WorkspaceFileRow: View {
    @EnvironmentObject private var state: AppState
    let item: FolderTreeItem
    let rootURL: URL

    var body: some View {
        Button {
            state.open(url: item.url)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "doc.text")
                    .font(.system(size: 13))
                    .frame(width: 16)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.caption2)
                        .lineLimit(1)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .background(
                isSelected ? Color.accentColor.opacity(0.13) : Color.clear,
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .help(item.url.path(percentEncoded: false))
        .contextMenu {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
        }
    }

    private var detail: String {
        if state.workspaceFileSort == .modified, let date = item.modificationDate {
            return date.formatted(date: .abbreviated, time: .shortened)
        }
        let root = rootURL.standardizedFileURL.path
        let parent = item.url.deletingLastPathComponent().standardizedFileURL.path
        guard parent.hasPrefix(root) else { return parent }
        let relative = parent.dropFirst(root.count).trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        )
        return relative.isEmpty ? rootURL.lastPathComponent : relative
    }

    private var isSelected: Bool {
        state.sidebarSelection == item.url.standardizedFileURL.path
    }
}

private struct FolderTreeRow: View {
    @EnvironmentObject private var state: AppState
    let item: FolderTreeItem

    var body: some View {
        Group {
            if item.isDirectory {
                rowLabel
            } else {
                Button {
                    state.open(url: item.url)
                } label: {
                    rowLabel
                }
                .buttonStyle(.plain)
            }
        }
        .contextMenu {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
        }
    }

    private var rowLabel: some View {
        HStack(spacing: 7) {
            Image(systemName: item.isDirectory ? "folder" : "doc.text")
                .font(.system(size: 13))
                .frame(width: 16)
                .foregroundStyle(
                    item.isDirectory
                        ? Color.secondary
                        : (isSelected ? Color.accentColor : Color.secondary)
                )
            Text(item.title)
                .lineLimit(1)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .background(
            isSelected ? Color.accentColor.opacity(0.13) : Color.clear,
            in: RoundedRectangle(cornerRadius: 5, style: .continuous)
        )
        .help(item.url.path(percentEncoded: false))
    }

    private var isSelected: Bool {
        !item.isDirectory && state.sidebarSelection == item.url.standardizedFileURL.path
    }
}

private struct SidebarRow: View {
    let title: String
    let subtitle: String?
    let symbol: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 14))
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption2)
                            .lineLimit(1)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, subtitle == nil ? 5 : 4)
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .background(
                isSelected ? Color.accentColor.opacity(0.13) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct RecentRow: View {
    @EnvironmentObject private var state: AppState
    let item: RecentDocument

    var body: some View {
        SidebarRow(
            title: item.title,
            subtitle: item.url.deletingLastPathComponent().lastPathComponent,
            symbol: item.isPinned ? "pin.fill" : "doc.text",
            isSelected: state.sidebarSelection == item.path
        ) {
            state.open(url: item.url)
        }
        .contextMenu {
            Button(item.isPinned ? "Unpin" : "Pin") {
                state.togglePin(for: item)
            }
            Divider()
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
            Button("Remove from Recents", role: .destructive) {
                state.removeRecent(item)
            }
        }
    }
}

private struct DocumentTabBar: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(state.documents) { document in
                    TabButton(
                        document: document,
                        isSelected: state.selectedDocumentID == document.id,
                        select: { state.select(documentID: document.id) },
                        close: { state.closeTab(document.id) }
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

private struct TabButton: View {
    let document: MarkdownDocument
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 7) {
                Image(systemName: document.isSample ? "sparkles" : "doc.text")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)

                Text(document.title)
                    .font(.system(size: 12.5, weight: isSelected ? .medium : .regular))
                    .lineLimit(1)
                    .frame(maxWidth: 150)

                if document.isDirty {
                    Circle()
                        .fill(.secondary)
                        .frame(width: 6, height: 6)
                } else if isHovering || isSelected {
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .frame(width: 14, height: 14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 29)
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .background(
                isSelected ? Color(nsColor: .controlBackgroundColor) : Color.clear,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(.quaternary, lineWidth: 0.5)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Close Tab", action: close)
            if document.url != nil {
                Button("Show in Finder") {
                    if let url = document.url {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
            }
        }
    }
}

private struct DocumentWorkspace: View {
    @EnvironmentObject private var state: AppState
    @State private var sourceColumnWidth: CGFloat = 420
    @State private var splitDragStartWidth: CGFloat?
    let document: MarkdownDocument

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                let availableWidth = proxy.size.width
                let clampedSourceWidth = min(
                    max(320, sourceColumnWidth),
                    max(320, availableWidth - 420)
                )
                let isSplit = state.displayMode == .split
                let isSourceOnly = state.displayMode == .source
                let dividerWidth: CGFloat = isSplit ? 9 : 0
                let visibleSourceWidth = isSourceOnly
                    ? availableWidth
                    : (isSplit ? clampedSourceWidth : 0)
                let previewWidth = max(
                    0,
                    availableWidth - visibleSourceWidth - dividerWidth
                )

                HStack(spacing: 0) {
                    // Both editors stay in this stable order. Changing display
                    // mode only changes their frames, never their identity.
                    SourceEditor()
                        .frame(width: visibleSourceWidth)
                        .opacity(visibleSourceWidth > 0 ? 1 : 0)
                        .allowsHitTesting(visibleSourceWidth > 0)
                        .accessibilityHidden(visibleSourceWidth == 0)
                        .clipped()

                    SplitDivider()
                        .frame(width: dividerWidth)
                        .opacity(isSplit ? 1 : 0)
                        .allowsHitTesting(isSplit)
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    if splitDragStartWidth == nil {
                                        splitDragStartWidth = clampedSourceWidth
                                    }
                                    sourceColumnWidth = min(
                                        max(
                                            320,
                                            (splitDragStartWidth ?? clampedSourceWidth)
                                                + value.translation.width
                                        ),
                                        max(320, availableWidth - 420)
                                    )
                                }
                                .onEnded { _ in
                                    splitDragStartWidth = nil
                                }
                        )

                    PreviewPane(document: document)
                        .frame(width: previewWidth)
                        .opacity(isSourceOnly ? 0 : 1)
                        .allowsHitTesting(!isSourceOnly)
                        .accessibilityHidden(isSourceOnly)
                        .clipped()
                }
                .clipped()
            }
            // The stable split container otherwise clips PreviewPane back to
            // the content safe area. In focus mode it must share the toolbar's
            // region so the web page's fading top blur can cover that band.
            .ignoresSafeArea(
                state.isFocusMode ? .container : [],
                edges: .top
            )

            if !state.isFocusMode {
                StatusBar(document: document)
            }
        }
    }
}

private struct SplitDivider: View {
    @State private var isHovering = false

    var body: some View {
        ZStack {
            Color.clear
                .frame(width: 9)

            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
        }
        .frame(width: 9)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
        }
        .onDisappear {
            if isHovering {
                NSCursor.pop()
                isHovering = false
            }
        }
    }
}

private struct PreviewPane: View {
    @EnvironmentObject private var state: AppState
    @State private var isDropTargeted = false
    let document: MarkdownDocument

    var body: some View {
        ZStack(alignment: .bottom) {
            MarkdownWebView(
                documentID: document.id,
                markdown: document.content,
                revision: document.contentRevision,
                isEditable: !state.isFocusMode,
                documentURL: document.url,
                theme: state.theme,
                readingStyle: state.readingStyle,
                customReadingPreset: state.activeCustomReadingPreset,
                readingWidth: state.effectiveReadingWidth,
                readingWidthIsFluid: state.readingWidth == .fullWidth,
                usesPaperCanvas: state.usesPaperCanvas,
                zoom: state.zoom,
                searchText: state.searchText,
                outlineTarget: state.outlineTarget,
                topInset: state.isFocusMode ? FocusMetrics.toolbarHeight : 0,
                controller: state.rendererController,
                onContentChange: { documentID, markdown, historyBoundary in
                    state.updateContent(
                        markdown,
                        for: documentID,
                        origin: .richEditor,
                        startsNewUndoGroup: historyBoundary
                    )
                },
                onDropFiles: { urls in
                    urls
                        .filter(MarkdownFileSupport.accepts)
                        .forEach(state.open)
                },
                onDropTargeted: { targeted in
                    withAnimation(.easeOut(duration: 0.16)) {
                        isDropTargeted = targeted
                    }
                }
            )
            .background(Color(nsColor: .textBackgroundColor))
            // In focus mode the page runs up behind the toolbar's material, the
            // way a document does in Mail or Safari. The matching top inset is
            // handed to the renderer above, so the text still starts below the
            // bar rather than under it.
            .ignoresSafeArea(state.isFocusMode ? .container : [], edges: .top)
            .overlay(alignment: .top) {
                if state.isFocusMode {
                    // The page now reaches the top of the window, and the web
                    // view swallows drags, so the strip beside the toolbar
                    // buttons would not move the window. This gives it back.
                    WindowDragArea()
                        .frame(height: FocusMetrics.toolbarHeight)
                        .ignoresSafeArea(edges: .top)
                }
            }

            ReadingWidthRuler()
                .padding(.bottom, 14)

            if isDropTargeted {
                DropOverlay()
                    .transition(.opacity)
            }
        }
    }
}

private struct ReadingWidthRuler: View {
    @EnvironmentObject private var state: AppState
    @State private var isHovering = false

    private var widthBinding: Binding<Double> {
        Binding(
            get: { Double(state.effectiveReadingWidth) },
            set: { state.setCustomReadingWidth($0) }
        )
    }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) {
                    state.readingWidth = .comfortable
                }
            } label: {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 11.5, weight: .medium))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Reset to comfortable reading width")

            Button {
                withAnimation(.easeOut(duration: 0.18)) {
                    state.readingWidth = .fullWidth
                }
            } label: {
                Image(systemName: "arrow.left.and.right.square")
                    .font(.system(size: 11.5, weight: .medium))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .foregroundStyle(
                state.readingWidth == .fullWidth ? Color.accentColor : .secondary
            )
            .help("Fit text to the available window width")

            Slider(value: widthBinding, in: 560...1600)
                .controlSize(.small)
                .frame(width: 176)
                .help("Drag to adjust document width")

            Text(
                state.readingWidth == .fullWidth
                    ? "Window"
                    : "\(state.effectiveReadingWidth) px"
            )
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 58, alignment: .trailing)

            Divider()
                .frame(height: 18)

            Menu {
                Picker("Reading width", selection: $state.readingWidth) {
                    ForEach(ReadingWidth.allCases) { width in
                        Label(
                            width == .custom
                                ? "Custom — \(Int(state.customReadingWidth)) px"
                                : width.title,
                            systemImage: width.symbol
                        )
                        .tag(width)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                ViewThatFits(in: .horizontal) {
                    Label(state.readingWidth.title, systemImage: state.readingWidth.symbol)
                    Image(systemName: state.readingWidth.symbol)
                }
                .font(.system(size: 11, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .frame(height: 24)
            .accessibilityLabel("Reading width presets")
            .accessibilityValue(
                state.readingWidth == .custom
                    ? "Custom, \(state.effectiveReadingWidth) pixels"
                    : state.readingWidth.title
            )
            .help("Choose a reading width preset")
        }
        .padding(.leading, 10)
        .padding(.trailing, 7)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.96))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 0.75)
        }
        .shadow(
            color: .black.opacity(isHovering ? 0.15 : 0.10),
            radius: isHovering ? 12 : 8,
            y: 3
        )
        .animation(.easeOut(duration: 0.14), value: isHovering)
        .onHover { isHovering = $0 }
    }
}

private struct SourceEditor: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ZStack {
            Color(nsColor: .textBackgroundColor)
            MarkdownSourceEditor(text: state.bindingForCurrentContent())
        }
    }
}

private struct StatusBar: View {
    @EnvironmentObject private var state: AppState
    let document: MarkdownDocument

    var body: some View {
        HStack(spacing: 13) {
            HStack(spacing: 5) {
                Circle()
                    .fill(document.isDirty ? Color.orange : Color.green)
                    .frame(width: 6, height: 6)
                Text(document.isDirty ? "Edited" : "Saved")
            }

            Text("\(document.wordCount.formatted()) words")
            Text("\(document.readingMinutes) min read")

            if document.hasExternalChanges {
                Label("Changed on disk — save or reload", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else if document.url != nil, state.liveReloadEnabled {
                Label("Live", systemImage: "bolt.fill")
            }

            Spacer()

            if !state.searchText.isEmpty {
                Label("Finding “\(state.searchText)”", systemImage: "magnifyingglass")
            }

            Text("\(Int(state.zoom * 100))%")
                .monospacedDigit()
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
    }
}

private struct OutlineInspector: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Document")
                        .font(.headline)
                    Text("Outline & insights")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if state.currentOutline.isEmpty {
                        ContentUnavailableView(
                            "No Headings",
                            systemImage: "list.bullet.indent",
                            description: Text("Add headings to navigate this document.")
                        )
                        .controlSize(.small)
                        .padding(.vertical, 20)
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("OUTLINE")
                                .inspectorLabel()

                            ForEach(state.currentOutline) { heading in
                                Button {
                                    state.outlineTarget = nil
                                    DispatchQueue.main.async {
                                        state.outlineTarget = heading.id
                                    }
                                } label: {
                                    Text(heading.title)
                                        .font(.system(size: heading.level == 1 ? 12.5 : 11.5, weight: heading.level <= 2 ? .medium : .regular))
                                        .lineLimit(2)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.leading, CGFloat(max(0, heading.level - 1)) * 11)
                                        .padding(.vertical, 5)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(heading.level == 1 ? .primary : .secondary)
                            }
                        }
                    }

                    if let document = state.currentDocument {
                        VStack(alignment: .leading, spacing: 9) {
                            Text("INSIGHTS")
                                .inspectorLabel()

                            InsightRow(label: "Words", value: document.wordCount.formatted())
                            InsightRow(label: "Characters", value: document.characterCount.formatted())
                            InsightRow(label: "Read time", value: "\(document.readingMinutes) min")
                            InsightRow(label: "Headings", value: state.currentOutline.count.formatted())
                        }

                        VStack(alignment: .leading, spacing: 9) {
                            Text("LOCATION")
                                .inspectorLabel()
                            Text(document.displayPath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(4)
                        }

                        FeatureSummary(markdown: document.content)
                    }
                }
                .padding(15)
            }
        }
    }
}

private struct InsightRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
        .font(.caption)
    }
}

private struct FeatureSummary: View {
    let markdown: String

    private var features: [(String, String)] {
        var result: [(String, String)] = []
        if markdown.contains("|") { result.append(("Tables", "tablecells")) }
        if markdown.contains("```mermaid") { result.append(("Diagrams", "point.3.connected.trianglepath.dotted")) }
        if markdown.contains("$$") || markdown.contains("\\[") { result.append(("Math", "sum")) }
        if markdown.contains("```") { result.append(("Code", "chevron.left.forwardslash.chevron.right")) }
        if markdown.contains("- [") { result.append(("Tasks", "checkmark.square")) }
        if markdown.contains("[^") { result.append(("Footnotes", "text.append")) }
        return result
    }

    var body: some View {
        if !features.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                Text("DETECTED")
                    .inspectorLabel()

                FlowLayout(spacing: 6) {
                    ForEach(features, id: \.0) { feature in
                        Label(feature.0, systemImage: feature.1)
                            .font(.system(size: 10.5, weight: .medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(.quaternary.opacity(0.6), in: Capsule())
                    }
                }
            }
        }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let width = proposal.width ?? 260
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }

        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

private extension View {
    func inspectorLabel() -> some View {
        self
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(.tertiary)
    }
}

private struct EmptyWorkspace: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color.accentColor.opacity(0.035)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(spacing: 22) {
                VStack(spacing: 12) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 72, height: 72)
                        .shadow(color: .black.opacity(0.14), radius: 12, y: 6)
                        .accessibilityLabel("PreviewMD")

                    Text("Ready for your next document")
                        .font(.system(size: 23, weight: .semibold, design: .rounded))

                    Text("Open a Markdown file or a folder containing your documents.")
                        .font(.system(size: 13.5))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 9) {
                    Button {
                        state.presentOpenPanel()
                    } label: {
                        Label("Open Markdown…", systemImage: "folder")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button {
                        state.presentFolderOpenPanel()
                    } label: {
                        Label("Open Folder…", systemImage: "folder.badge.plus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                    Button {
                        state.openWelcome()
                    } label: {
                        Label("View Showcase", systemImage: "sparkles")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }

                HStack(spacing: 7) {
                    Image(systemName: "arrow.down.doc")
                    Text("Drop a folder or Markdown files")
                    Text("•")
                    Text("⌘O to open")
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)

                if !state.recentDocuments.isEmpty {
                    VStack(spacing: 9) {
                        Text("RECENT")
                            .font(.system(size: 9.5, weight: .semibold))
                            .tracking(0.8)
                            .foregroundStyle(.tertiary)

                        HStack(spacing: 8) {
                            ForEach(Array(state.recentDocuments.prefix(3))) { recent in
                                Button {
                                    state.open(url: recent.url)
                                } label: {
                                    HStack(spacing: 7) {
                                        Image(systemName: "doc.text")
                                            .foregroundStyle(Color.accentColor)
                                        Text(recent.title)
                                            .lineLimit(1)
                                    }
                                    .font(.system(size: 11.5, weight: .medium))
                                    .padding(.horizontal, 11)
                                    .frame(height: 30)
                                    .background(.quaternary.opacity(0.55), in: Capsule())
                                }
                                .buttonStyle(.plain)
                                .frame(maxWidth: 190)
                                .help(recent.path)
                            }
                        }
                    }
                    .padding(.top, 5)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DropOverlay: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(
                    Color.accentColor,
                    style: StrokeStyle(lineWidth: 2, dash: [8, 7])
                )
                .padding(24)

            VStack(spacing: 12) {
                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 38, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                Text("Drop to open")
                    .font(.title3.weight(.semibold))
                Text("Open Markdown files as tabs or browse a folder")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .allowsHitTesting(false)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @State private var isDefaultMarkdownApplication = false
    @State private var isChangingDefaultApplication = false
    @State private var defaultApplicationError: String?

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Style", selection: $state.readingStyle) {
                    ForEach(ReadingStyle.allCases.filter {
                        $0 != .custom || !state.customReadingPresets.isEmpty
                    }) { style in
                        Label(style.title, systemImage: style.symbol).tag(style)
                    }
                }

                Text(state.readingStyle.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Theme", selection: $state.theme) {
                    ForEach(PreviewTheme.allCases) { theme in
                        Label(theme.title, systemImage: theme.symbol).tag(theme)
                    }
                }

                Picker("Reading width", selection: $state.readingWidth) {
                    ForEach(ReadingWidth.allCases) { width in
                        Label(
                            width == .custom
                                ? "Custom — \(Int(state.customReadingWidth)) px"
                                : width.title,
                            systemImage: width.symbol
                        )
                        .tag(width)
                    }
                }

                Toggle("Show document as a paper canvas", isOn: $state.usesPaperCanvas)
            }

            // Describes what the renderer can set, not which engines set it.
            // The engines are named only where their licenses require it —
            // see Acknowledgements.swift and the About window.
            Section("Rendering") {
                LabeledContent("Markdown", value: "GitHub Flavored")
                LabeledContent("Diagrams", value: "Flowcharts & charts")
                LabeledContent("Math", value: "Inline & display")
                LabeledContent("Code", value: "Syntax highlighted")
            }

            Section("Files") {
                LabeledContent("Open Markdown with") {
                    Text(isDefaultMarkdownApplication ? "PreviewMD" : "Another app")
                        .foregroundStyle(
                            isDefaultMarkdownApplication ? Color.secondary : Color.primary
                        )
                }

                Button(
                    isDefaultMarkdownApplication
                        ? "PreviewMD Is the Default"
                        : "Use PreviewMD as Default"
                ) {
                    makeDefaultMarkdownApplication()
                }
                .disabled(isDefaultMarkdownApplication || isChangingDefaultApplication)

                if let defaultApplicationError {
                    Text(defaultApplicationError)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if !isDefaultMarkdownApplication {
                    Text("This also changes the Open button in Finder Quick Look.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onChange(of: state.theme) { state.updatePreferences() }
        .onChange(of: state.readingStyle) { state.updatePreferences() }
        .onChange(of: state.readingWidth) { state.updatePreferences() }
        .onChange(of: state.customReadingWidth) { state.updatePreferences() }
        .onChange(of: state.usesPaperCanvas) { state.updatePreferences() }
        .onAppear {
            refreshDefaultMarkdownApplication()
        }
    }

    private func refreshDefaultMarkdownApplication() {
        isDefaultMarkdownApplication = MarkdownDefaultApplication.isPreviewMD
    }

    private func makeDefaultMarkdownApplication() {
        isChangingDefaultApplication = true
        defaultApplicationError = nil
        MarkdownDefaultApplication.makePreviewMD { error in
            DispatchQueue.main.async {
                isChangingDefaultApplication = false
                defaultApplicationError = error?.localizedDescription
                refreshDefaultMarkdownApplication()
            }
        }
    }
}
