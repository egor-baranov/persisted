import AppKit
import SwiftUI
import PersistedCore

/// The menu bar is the primary workspace: every layout and everyday action lives here.
struct PersistedMenuPanel: View {
    @Bindable var model: AppModel
    @State private var page: Page = .layouts
    @State private var query = ""
    @State private var highlightedLayoutID: UUID?
    @State private var pendingDeletion: MenuDeletion?
    @FocusState private var searchFocused: Bool

    private enum Page: Equatable {
        case layouts, save(UUID?), detail(UUID), editor(UUID), settings, schedule, profiles
    }
    init(model: AppModel, showingLayoutID: UUID? = nil) {
        self.model = model
        _page = State(initialValue: showingLayoutID.map { .detail($0) } ?? .layouts)
    }
    private var isEditing: Bool { if case .editor = page { true } else { false } }
    private var layouts: [PersistedCore.Layout] { LayoutCatalog.filteredLayouts(model.library.layouts, query: query) }
    private var failedOutcomes: [WindowOutcome] { model.outcomes.filter { !$0.kind.succeeded } }
    private var pageTitle: String {
        switch page {
        case .layouts: "Persisted"
        case .save(let id): id == nil ? "Save current layout" : "Update layout"
        case .detail: "Layout details"
        case .editor: "Edit layout"
        case .settings: "Settings"
        case .schedule: "Schedule"
        case .profiles: "Display profiles"
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            if page != .layouts && !isEditing {
                navigationHeader
                Divider()
            }
            pageContent
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            if !isEditing {
                Divider()
                footer
            }
        }
        .frame(width: 446, height: panelHeight)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(.accentColor)
        .disabled(pendingDeletion != nil)
        .accessibilityHidden(pendingDeletion != nil)
        .overlay {
            if let deletion = pendingDeletion {
                // Keep confirmation in the MenuBarExtra's host. A native dialog
                // can take focus from that transient window and dismiss it.
                ZStack {
                    Color.black.opacity(0.12)
                        .contentShape(Rectangle())
                        .onTapGesture { }
                        .accessibilityHidden(true)
                    MenuDeleteConfirmation(deletion: deletion, cancel: { pendingDeletion = nil }, confirm: confirmDeletion)
                        .padding(24)
                }
            }
        }
        .modifier(ErrorPresentation(model: model))
        .sheet(item: $model.pendingMapping) { DisplayMappingSheet(model: model, layout: $0.layout, windowScope: $0.windowScope) }
        .sheet(isPresented: Binding(get: { model.importPreview != nil }, set: { if !$0 { model.importPreview = nil } })) {
            ImportPreviewSheet(model: model)
        }
        .onAppear { searchFocused = true; model.recheckHotkeys() }
        .onDisappear { pendingDeletion = nil }
        .onChange(of: model.quickSwitcherRequest) { _, _ in
            guard !isEditing else { return }
            pendingDeletion = nil; page = .layouts; query = ""; highlightedLayoutID = layouts.first?.id; searchFocused = true
        }
        .onChange(of: query) { _, _ in highlightedLayoutID = layouts.first?.id }
        .background {
            Button("Search layouts") { page = .layouts; searchFocused = true }
                .keyboardShortcut("f", modifiers: .command).hidden()
                .disabled(pendingDeletion != nil || isEditing)
        }
        .task { await model.startup() }
    }
    @ViewBuilder private var pageContent: some View {
        switch page {
        case .layouts: catalog
        case .save(let id): MenuSavePage(model: model, updating: id) { page = .layouts }
        case .detail(let id):
            if let layout = model.library.layouts.first(where: { $0.id == id }) {
                MenuLayoutDetail(model: model, layout: layout, editArrangement: { page = .editor(id) }, update: { beginCapture(layout.id) }, delete: {
                    pendingDeletion = .layout(layout.id, layout.name)
                })
            } else { ContentUnavailableView("Layout removed", systemImage: "rectangle.3.group") }
        case .editor(let id):
            if let layout = model.library.layouts.first(where: { $0.id == id }) {
                LayoutEditorHost(model: model, layout: layout) { page = .detail(id) }.id(id)
            } else {
                ContentUnavailableView {
                    Label("Layout removed", systemImage: "rectangle.3.group")
                } actions: { Button("Back to layouts") { page = .layouts } }
            }
        case .settings: MenuSettingsPage(model: model)
        case .schedule: MenuSchedulePage(model: model, delete: { schedule in
            pendingDeletion = .schedule(schedule.id, schedule.name)
        })
        case .profiles: MenuProfilesPage(model: model)
        }
    }
    private var panelHeight: CGFloat {
        let contentHeight = min(800, max(640, CGFloat(min(model.library.layouts.count, 6)) * 82 + 300))
        let availableHeight = (NSScreen.main?.visibleFrame.height ?? 848) - 48
        return min(contentHeight, availableHeight)
    }
    private var navigationHeader: some View {
        HStack(spacing: 10) {
            Button { page = .layouts } label: { Image(systemName: "chevron.left").font(.body.weight(.semibold)).frame(width: 24, height: 26) }
                .buttonStyle(.plain).help("Back to saved layouts").accessibilityLabel("Back to saved layouts")
            Text(pageTitle).font(.system(size: 19, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 8)
        }.padding(.horizontal, 18).frame(height: 52)
    }
    private var catalog: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find a layout or app", text: $query).textFieldStyle(.plain).focused($searchFocused)
                    .accessibilityLabel("Search all saved layouts")
                    .onSubmit { applyHighlightedLayout() }
                    .onKeyPress(.downArrow) { moveHighlight(1); return .handled }
                    .onKeyPress(.upArrow) { moveHighlight(-1); return .handled }
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                        .buttonStyle(.plain).accessibilityLabel("Clear search")
                } else { Text("⌘F").font(.caption).foregroundStyle(.tertiary) }
            }.padding(.horizontal, 10).padding(.vertical, 8)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 16).padding(.top, 13)
            HStack {
                Text(query.isEmpty ? "Saved layouts" : "Search results").font(.subheadline)
                Spacer()
                Text(query.isEmpty ? "\(model.library.layouts.count)" : "\(layouts.count) of \(model.library.layouts.count)").monospacedDigit().font(.caption)
            }.foregroundStyle(.secondary).padding(.horizontal, 19).padding(.top, 15).padding(.bottom, 8)
            if !model.permissionGranted {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "lock.open").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Allow window placement").font(.callout.weight(.medium))
                        Button("Enable Accessibility…") { model.requestPermission(); model.openAccessibilitySettings() }.buttonStyle(.link)
                    }
                    Spacer(minLength: 0)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 9)).padding(.horizontal, 16).padding(.bottom, 6)
            }
            if let limitation = model.desktopRestorationCapability?.limitation,
               layouts.contains(where: { $0.options.restoreDesktops && $0.effectiveDesktopSnapshot != nil }) {
                DesktopCapabilityNotice(message: limitation)
                    .padding(.horizontal, 19).padding(.vertical, 8)
            }
            ScrollViewReader { proxy in
                ScrollView {
                LazyVStack(spacing: 7) {
                    ForEach(Array(layouts.enumerated()), id: \.element.id) { index, layout in
                        MenuLayoutCard(model: model, layout: layout, shortcutIndex: query.isEmpty ? index : nil, keyboardSelected: highlightedLayoutID == layout.id) { page = .detail(layout.id) }
                            .id(layout.id)
                    }
                    if layouts.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: query.isEmpty ? "rectangle.3.group" : "magnifyingglass").font(.system(size: 30, weight: .light)).foregroundStyle(.tertiary)
                            Text(query.isEmpty ? "A place for every window" : "No matching layouts").font(.headline)
                            Text(query.isEmpty ? "Arrange your windows, then save your first layout below." : "Try another layout or application name.")
                                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }.frame(maxWidth: .infinity).padding(.horizontal, 30).padding(.vertical, 60)
                    }
                }.padding(.horizontal, 13).padding(.bottom, 14)
                }.scrollIndicators(.visible).frame(maxHeight: .infinity)
                .onChange(of: highlightedLayoutID) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .center) }
                }
            }
            if model.busy || !model.outcomes.isEmpty || model.canUndo {
                HStack(spacing: 8) {
                    if model.busy { ProgressView().controlSize(.mini) }
                    else {
                        Image(systemName: failedOutcomes.isEmpty ? "checkmark.circle" : "exclamationmark.circle")
                            .foregroundStyle(failedOutcomes.isEmpty ? Color.secondary : Color.orange)
                    }
                    Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .help(failedOutcomes.map { "\($0.appName): \($0.explanation)" }.joined(separator: "\n"))
                    Spacer(minLength: 4)
                    if !failedOutcomes.isEmpty, let id = model.selectedLayoutID {
                        Button("Details") { page = .detail(id) }.buttonStyle(.link).font(.caption)
                            .help("See which windows could not be restored and why")
                    }
                    if model.canUndo {
                        Button("Undo") { Task { await model.undo() } }.buttonStyle(.link)
                            .keyboardShortcut("z", modifiers: .command).disabled(model.busy || !model.permissionGranted)
                    }
                }.padding(.horizontal, 18).padding(.vertical, 9)
            }
            if model.desktopSummary != nil || !model.desktopIssues.isEmpty {
                if model.desktopIssues.isEmpty {
                    DesktopRestoreStatusView(summary: model.desktopSummary, issues: [])
                        .padding(.horizontal, 18).padding(.bottom, 9)
                } else {
                    ScrollView {
                        DesktopRestoreStatusView(summary: model.desktopSummary, issues: model.desktopIssues)
                            .padding(.horizontal, 18).padding(.bottom, 9)
                    }.frame(maxHeight: 100)
                }
            }
            Divider()
            HStack(spacing: 12) {
                Button { beginCapture(nil) } label: { Label("Save current layout", systemImage: "plus").font(.system(size: 12, weight: .medium)) }
                    .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut("s", modifiers: .command)
                    .disabled(model.busy || !model.permissionGranted)
                Spacer(minLength: 0)
                Button { model.exportLayouts() } label: { Label("Export", systemImage: "square.and.arrow.up").font(.system(size: 11)) }
                    .disabled(model.library.layouts.isEmpty)
                Button { Task { await model.importLayouts() } } label: { Label("Import", systemImage: "square.and.arrow.down").font(.system(size: 11)) }
            }.buttonStyle(.borderless).padding(.horizontal, 16).padding(.vertical, 12)
        }
    }
    private var footer: some View {
        HStack(spacing: 10) {
            Button { page = page == .settings ? .layouts : .settings } label: { Label("Settings", systemImage: "gearshape") }
                .keyboardShortcut(",", modifiers: .command)
            Button { page = page == .schedule ? .layouts : .schedule } label: { Label("Schedule", systemImage: "clock") }
            Toggle("Auto", isOn: Binding(get: { model.library.settings.autoModeEnabled }, set: { model.setAutoMode($0) }))
                .toggleStyle(.switch).controlSize(.mini).fixedSize()
                .accessibilityLabel("Auto mode")
                .help("Automatically remember and restore configurations for each display setup")
            Spacer(minLength: 0)
            Button { page = page == .profiles ? .layouts : .profiles } label: {
                DisplaySetupLabel(topology: model.topology, name: model.library.displayProfileNames[model.topology.setupKey])
                    .frame(maxWidth: 110, alignment: .trailing)
            }.help(DisplaySetupLabel(topology: model.topology, name: model.library.displayProfileNames[model.topology.setupKey]).helpText
                + "\nName this display setup and choose its automatic layout")
            Button("Quit") { NSApplication.shared.terminate(nil) }.help("Quit Persisted")
        }.font(.system(size: 11)).foregroundStyle(.secondary).buttonStyle(.plain)
            .padding(.horizontal, 18).frame(height: 39)
    }
    private func moveHighlight(_ offset: Int) {
        guard !layouts.isEmpty else { return }
        let next: Int
        if let current = layouts.firstIndex(where: { $0.id == highlightedLayoutID }) {
            next = min(layouts.count - 1, max(0, current + offset))
        } else { next = offset > 0 ? 0 : layouts.count - 1 }
        highlightedLayoutID = layouts[next].id
    }
    private func applyHighlightedLayout() {
        guard !model.busy, model.permissionGranted,
              let layout = layouts.first(where: { $0.id == highlightedLayoutID }) ?? layouts.first else { return }
        Task { await model.apply(layout) }
    }
    private func beginCapture(_ updating: UUID?) {
        page = .save(updating)
    }
    private func confirmDeletion() {
        guard let deletion = pendingDeletion else { return }
        switch deletion {
        case .layout(let id, _):
            model.deleteLayout(id)
            guard !model.library.layouts.contains(where: { $0.id == id }) else { return }
            page = .layouts
        case .schedule(let id, _):
            model.deleteSchedule(id)
            guard !model.library.schedules.contains(where: { $0.id == id }) else { return }
        }
        pendingDeletion = nil
    }
}

private enum MenuDeletion {
    case layout(UUID, String)
    case schedule(UUID, String)

    var name: String {
        switch self {
        case .layout(_, let name), .schedule(_, let name): name
        }
    }
    var actionTitle: String {
        switch self {
        case .layout: "Delete layout"
        case .schedule: "Delete schedule"
        }
    }
    var message: String {
        switch self {
        case .layout: "This removes the saved layout, its remembered adjustments, and any schedules using it."
        case .schedule: "This removes the schedule. The saved layout is kept."
        }
    }
}

private struct MenuDeleteConfirmation: View {
    let deletion: MenuDeletion
    let cancel: () -> Void
    let confirm: () -> Void
    @FocusState private var cancelFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Delete “\(deletion.name)”?").font(.headline).lineLimit(3)
            Text(deletion.message).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Spacer(minLength: 0)
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                    .focused($cancelFocused)
                Button(deletion.actionTitle, role: .destructive, action: confirm)
                    .accessibilityLabel("\(deletion.actionTitle) \(deletion.name)")
            }.controlSize(.large).padding(.top, 4)
        }
        .padding(20)
        .frame(maxWidth: 350)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.separator, lineWidth: 0.5) }
        .shadow(color: .black.opacity(0.15), radius: 16, y: 6)
        .accessibilityElement(children: .contain)
        .onAppear { cancelFocused = true }
    }
}

private struct MenuLayoutCard: View {
    let model: AppModel
    let layout: PersistedCore.Layout
    let shortcutIndex: Int?
    let keyboardSelected: Bool
    var details: () -> Void
    @State private var hovered = false
    private var active: Bool {
        model.selectedLayoutID == layout.id && !model.busy && model.desktopIssues.isEmpty && !model.outcomes.contains { !$0.kind.succeeded }
    }
    private var windows: [SavedWindow] {
        layout.effectiveWindows.filter { window in
            guard !layout.excludedBundleIDs.contains(window.identity.bundleID) else { return false }
            if case .desktop(let id) = window.desktopAssignment { return !layout.options.excludedDesktopIDs.contains(id) }
            return true
        }
    }
    private var appCount: Int { Set(windows.map { $0.identity.bundleID }).count }
    private var summary: String {
        let counts = "\(windows.count) \(windows.count == 1 ? "window" : "windows") · \(appCount) \(appCount == 1 ? "app" : "apps")"
        guard let snapshot = layout.effectiveDesktopSnapshot else { return counts }
        return counts + " · \(snapshot.desktopCount) \(snapshot.desktopCount == 1 ? "desktop" : "desktops")"
    }
    var body: some View {
        HStack(spacing: 12) {
            Button(action: details) { LayoutMiniature(layout: layout).frame(width: 54, height: 54) }
                .buttonStyle(.plain).accessibilityLabel("Details for \(layout.name)")
            Button(action: details) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 6) {
                        Image(systemName: layout.iconName).font(.system(size: 13)).foregroundStyle(.secondary)
                        Text(layout.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
                    }
                    HStack(spacing: 5) {
                        Text(summary).font(.system(size: 11)).minimumScaleFactor(0.85)
                        DisplaySetupLabel(topology: layout.topology).font(.system(size: 10)).fixedSize()
                    }.foregroundStyle(.secondary).lineLimit(1)
                    if !model.canApplyDirectly(layout) {
                        Text("Choose displays on apply").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            VStack(spacing: 5) {
                applyButton
                if let hotkey = layout.hotkey, model.hotkeyErrors[layout.id] == nil {
                    Text(hotkey.displayString).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                } else if let shortcutIndex, shortcutIndex < 9 {
                    Text("⌘\(shortcutIndex + 1)").font(.system(size: 9, weight: .medium)).foregroundStyle(.tertiary)
                }
            }.frame(width: 61)
            Button(action: details) { Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(.tertiary).frame(width: 16, height: 38) }
                .buttonStyle(.plain).accessibilityLabel("Edit \(layout.name)")
        }.padding(.leading, 10).padding(.trailing, 6).padding(.vertical, 10)
            .background(keyboardSelected ? Color.accentColor.opacity(0.11) : active ? Color.accentColor.opacity(0.075) : hovered ? Color.primary.opacity(0.045) : Color.primary.opacity(0.018), in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(keyboardSelected ? Color.accentColor.opacity(0.4) : active ? Color.accentColor.opacity(0.14) : Color.clear, lineWidth: 1) }
            .onHover { hovered = $0 }
    }
    @ViewBuilder private var applyButton: some View {
        let button = Button { Task { await model.apply(layout) } } label: {
            Text(active ? "Active" : "Apply").font(.system(size: 12, weight: .semibold)).frame(width: 58, height: 30)
                .foregroundStyle(active ? Color.green : Color.accentColor)
                .background(active ? Color.green.opacity(0.15) : Color.accentColor.opacity(0.11), in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).disabled(model.busy || !model.permissionGranted)
            .accessibilityLabel(active ? "Reapply active layout \(layout.name)" : "Apply \(layout.name)")
        if let shortcutIndex, shortcutIndex < 9 {
            button.keyboardShortcut(KeyEquivalent(Character(String(shortcutIndex + 1))), modifiers: .command)
        } else { button }
    }
}

/// Multicolour geometry gives each layout a recognizable silhouette without reading window titles.
struct LayoutMiniature: View {
    let layout: PersistedCore.Layout
    private let colors: [Color] = [.indigo, .cyan, .green, .orange, .pink, .purple, .mint]
    var body: some View {
        Canvas { context, size in
            let surfaces = layout.topology.surfaces
            let frames = surfaces.map { CoordinateMapper.appKitToAX($0.frame, primaryFrame: layout.topology.primaryFrame) }
            let left = frames.map(\.minX).min() ?? 0, top = frames.map(\.minY).min() ?? 0
            let width = max(1, (frames.map(\.maxX).max() ?? 1) - left)
            let height = max(1, (frames.map(\.maxY).max() ?? 1) - top)
            let scale = min((size.width - 8) / width, (size.height - 12) / height)
            let origin = CGPoint(x: (size.width - width * scale) / 2, y: (size.height - height * scale) / 2)
            func projected(_ rect: Rect) -> CGRect {
                CGRect(x: origin.x + (rect.x - left) * scale, y: origin.y + (rect.y - top) * scale, width: max(1, rect.width * scale), height: max(1, rect.height * scale))
            }
            for frame in frames {
                let path = Path(roundedRect: projected(frame), cornerRadius: 2)
                context.fill(path, with: .color(.primary.opacity(0.09)))
                context.stroke(path, with: .color(.primary.opacity(0.14)), lineWidth: 0.5)
            }
            let apps = Array(Set(layout.effectiveWindows.map { $0.identity.bundleID })).sorted()
            for window in layout.effectiveWindows where !layout.excludedBundleIDs.contains(window.identity.bundleID) {
                let rect = projected(window.frame)
                let color = colors[(apps.firstIndex(of: window.identity.bundleID) ?? 0) % colors.count]
                let path = Path(roundedRect: rect, cornerRadius: min(1.2, rect.height / 5))
                context.fill(path, with: .color(color.opacity(0.55)))
                context.stroke(path, with: .color(color.opacity(0.9)), lineWidth: 0.6)
            }
        }
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10)).accessibilityHidden(true)
    }
}

private struct MenuSavePage: View {
    let model: AppModel
    let updating: UUID?
    let completion: () -> Void
    @State private var name = ""
    @State private var generatedName = ""
    @State private var selected = Set<UUID>()
    @State private var displayFilter = ""
    @State private var saving = false
    @State private var loading = true
    private var windows: [LiveWindow] {
        (model.capture?.windows ?? []).filter {
            displayFilter.isEmpty || CoordinateMapper.save($0, in: model.topology, desktopSnapshot: model.capture?.desktopSnapshot)?.displayID == displayFilter
        }
    }
    private var applications: [String] { Array(Set(windows.map { $0.identity.bundleID })).sorted { appName($0).localizedStandardCompare(appName($1)) == .orderedAscending } }
    private func appName(_ id: String) -> String { windows.first { $0.identity.bundleID == id }?.identity.appName ?? id }
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Layout name", text: $name).textFieldStyle(.roundedBorder).controlSize(.large)
                Picker("Windows from", selection: $displayFilter) {
                    Text("All displays").tag("")
                    ForEach(model.topology.surfaces) { display in Text(model.library.displayAliases[display.id] ?? display.name).tag(display.id) }
                }
                if !loading, let capture = model.capture {
                    DesktopCaptureSummaryView(snapshot: capture.desktopSnapshot)
                }
                HStack {
                    Text("\(selected.count) windows selected").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("All") { selected = Set(windows.map(\.id)) }
                    Button("None") { selected = [] }
                    Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }.help("Capture current windows again")
                }.font(.caption).buttonStyle(.borderless)
            }.padding(18)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if loading {
                        ProgressView("Reading current windows…").frame(maxWidth: .infinity).padding(.vertical, 70)
                    } else if windows.isEmpty {
                        ContentUnavailableView("No windows found", systemImage: "macwindow", description: Text("Open an application window or choose another display, then refresh."))
                    }
                    ForEach(applications, id: \.self) { bundleID in
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle(isOn: appSelection(bundleID)) {
                                HStack(spacing: 8) { AppIcon(bundleID: bundleID, size: 21); Text(appName(bundleID)).font(.callout.weight(.semibold)) }
                            }.toggleStyle(.checkbox)
                            ForEach(windows.filter { $0.identity.bundleID == bundleID }) { window in
                                Toggle(isOn: windowSelection(window.id)) {
                                    Text(window.identity.title.isEmpty ? "Untitled window" : window.identity.title).font(.caption).lineLimit(2)
                                }.toggleStyle(.checkbox).padding(.leading, 27)
                            }
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
                    }
                    ForEach(model.capture?.issues ?? []) { issue in
                        Label(issue.message, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(16)
            }.scrollIndicators(.visible)
            Divider()
            HStack {
                Button("Cancel", action: completion).keyboardShortcut(.cancelAction)
                Spacer()
                Button(updating == nil ? "Save layout" : "Update layout") {
                    saving = true
                    Task {
                        await model.saveCapture(name: name, selected: selected, updating: updating)
                        saving = false
                        if model.capture == nil { completion() }
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(saving || loading || model.capture == nil || selected.isEmpty || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding(16)
        }
        .onAppear {
            if let layout = model.library.layouts.first(where: { $0.id == updating }) { name = layout.name }
            else { suggestName() }
        }
        .task { await refresh() }
        .onChange(of: model.capture?.windows.map(\.id)) { _, _ in resetSelection() }
        .onChange(of: displayFilter) { _, _ in resetSelection() }
    }
    private func refresh() async {
        loading = true
        await model.prepareCapture()
        suggestName()
        resetSelection()
        loading = false
    }
    private func resetSelection() { selected = Set(windows.map(\.id)) }
    private func suggestName() {
        guard updating == nil else { return }
        let next = model.suggestedLayoutName
        if name.isEmpty || name == generatedName { name = next }
        generatedName = next
    }
    private func windowSelection(_ id: UUID) -> Binding<Bool> {
        Binding(get: { selected.contains(id) }, set: { if $0 { selected.insert(id) } else { selected.remove(id) } })
    }
    private func appSelection(_ id: String) -> Binding<Bool> {
        let ids = Set(windows.filter { $0.identity.bundleID == id }.map(\.id))
        return Binding(get: { ids.isSubset(of: selected) }, set: { if $0 { selected.formUnion(ids) } else { selected.subtract(ids) } })
    }
}

private struct MenuLayoutDetail: View {
    let model: AppModel
    let layout: PersistedCore.Layout
    let editArrangement: () -> Void
    let update: () -> Void
    let delete: () -> Void
    @State private var name = ""
    @State private var matchingWindow: SavedWindow?
    @State private var assignmentWindow: SavedWindow?
    private let icons = ["rectangle.3.group", "chevron.left.forwardslash.chevron.right", "doc.text", "video", "laptopcomputer", "display.2", "paintbrush", "music.note", "gamecontroller", "briefcase", "book", "house"]
    private var apps: [String] { Array(Set(layout.effectiveWindows.map { $0.identity.bundleID })).sorted() }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    LayoutMiniature(layout: layout).frame(width: 78, height: 67)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(layout.name).font(.title3.weight(.semibold))
                        Text("\(layout.effectiveWindows.count) windows · \(apps.count) apps · \(layout.topology.surfaces.count) displays").font(.caption).foregroundStyle(.secondary)
                        Text("Saved \(layout.saved.date.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                HStack {
                    Button { Task { await model.apply(layout) } } label: { Label("Apply layout", systemImage: "play.fill") }.buttonStyle(.borderedProminent)
                        .disabled(model.busy || !model.permissionGranted)
                    Menu("Apply saved display") {
                        ForEach(layout.topology.surfaces) { display in
                            Button(model.library.displayAliases[display.id] ?? display.name) { Task { await model.applySingleDisplay(layout, displayID: display.id) } }
                        }
                    }.disabled(model.busy || !model.permissionGranted)
                }
                Button(action: editArrangement) { Label("Edit arrangement", systemImage: "pencil.and.outline") }
                    .disabled(model.busy)
                if let limitation = model.desktopRestorationNotice(for: layout) {
                    DesktopCapabilityNotice(message: limitation)
                }
                if layout.editedAwaitingApply { EditedLayoutNotice() }
                if model.busy {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(model.status).font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                if !model.canApplyDirectly(layout) {
                    Label("Some saved displays need a destination. Clear matches are selected automatically.", systemImage: "display.trianglebadge.exclamationmark")
                        .font(.caption).foregroundStyle(.secondary)
                }
                MenuSection("Desktops & apps") {
                    if layout.effectiveDesktopSnapshot != nil {
                        option("Restore desktops", keyPath: \.restoreDesktops)
                            .disabled(!model.desktopRestorationAvailable && !layout.options.restoreDesktops)
                            .help("Experimental desktop restoration creates missing desktops and restores saved window assignments. Extra desktops and full-screen spaces are preserved; Mission Control may appear.")
                        Text("Select a desktop to see its apps.").font(.caption).foregroundStyle(.secondary)
                    }
                    LayoutWorkspaceView(model: model, layout: layout,
                        matchWindow: { matchingWindow = $0 }, assignWindow: { assignmentWindow = $0 })
                        .id(layout.id)
                }
                MenuSection("Auto mode") {
                    LayoutAutoModeControls(model: model, layout: layout)
                }
                MenuSection("Personalize") {
                    HStack {
                        Menu {
                            ForEach(icons, id: \.self) { icon in
                                Button { model.setIcon(id: layout.id, name: icon) } label: { Label(iconLabel(icon), systemImage: icon) }
                            }
                        } label: { Image(systemName: layout.iconName).frame(width: 26) }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 34).accessibilityLabel("Choose layout icon")
                        TextField("Layout name", text: $name).textFieldStyle(.roundedBorder).onSubmit { model.renameLayout(layout.id, name: name) }
                        Button("Rename") { model.renameLayout(layout.id, name: name) }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name == layout.name)
                    }
                    Divider()
                    HStack { Text("Global shortcut"); Spacer(); HotkeyRecorderView(hotkey: layout.hotkey) { model.setHotkey(id: layout.id, hotkey: $0) } }
                    if let error = model.hotkeyErrors[layout.id] { Text(error).font(.caption).foregroundStyle(.orange) }
                    HStack {
                        Button { model.moveLayout(id: layout.id, offset: -1) } label: { Label("Move up", systemImage: "arrow.up") }
                            .disabled(model.library.layouts.first?.id == layout.id)
                        Button { model.moveLayout(id: layout.id, offset: 1) } label: { Label("Move down", systemImage: "arrow.down") }
                            .disabled(model.library.layouts.last?.id == layout.id)
                        Spacer()
                        Button("Duplicate") { model.duplicateLayout(layout.id) }
                    }.buttonStyle(.borderless).font(.caption)
                }
                MenuSection("Behavior") {
                    HStack {
                        Label(model.library.preferredLayouts.values.contains(layout.id) ? "Restore-only preset for this setup" : "Restore-only preset", systemImage: "star")
                        Spacer()
                        Button("Set") { model.setPreferred(layout.id) }
                            .disabled(model.library.settings.autoModeEnabled || layout.importedNeedsMapping || model.library.preferredLayouts[layout.topology.setupKey] == layout.id)
                    }.font(.callout)
                    if model.library.settings.autoModeEnabled {
                        Text("Auto mode controls saving and restoring while it is on.").font(.caption).foregroundStyle(.secondary)
                    }
                    option("Remember adjustments outside Auto mode", keyPath: \.rememberAdjustments)
                        .disabled(model.library.settings.autoModeEnabled)
                    option("Launch missing applications", keyPath: \.launchMissingApplications)
                    option("Preserve window size", keyPath: \.preserveWindowSize)
                    Toggle("Match regardless of lid state", isOn: Binding(get: { layout.options.lidPolicy == .ignore }, set: { enabled in
                        var options = layout.options; options.lidPolicy = enabled ? .ignore : .exact; model.setOptions(layout.id, options: options)
                    }))
                    if layout.remembered != nil { Button("Discard remembered adjustments") { model.discardRemembered(layout.id) }.font(.caption) }
                    Button("Review display mapping…") { model.pendingMapping = .init(layout: layout) }.font(.caption)
                }
                if model.selectedLayoutID == layout.id, !model.outcomes.isEmpty || model.desktopSummary != nil || !model.desktopIssues.isEmpty {
                    MenuSection("Last apply") {
                        DesktopRestoreStatusView(summary: model.desktopSummary, issues: model.desktopIssues)
                        ForEach(model.outcomes) { outcome in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: outcome.kind.succeeded ? "checkmark.circle.fill" : "exclamationmark.circle").foregroundStyle(outcome.kind.succeeded ? Color.green : Color.orange)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(outcome.appName) · \(outcome.kind.label)").font(.caption.weight(.medium))
                                    if !outcome.kind.succeeded { Text(outcome.explanation).font(.caption2).foregroundStyle(.secondary) }
                                }
                            }
                        }
                        if model.outcomes.contains(where: { !$0.kind.succeeded }) || !model.desktopIssues.isEmpty {
                            Button(model.desktopIssues.isEmpty ? "Retry unavailable windows" : "Retry restoration") {
                                Task { await model.retryUnresolved() }
                            }.disabled(model.busy || !model.permissionGranted)
                        }
                    }
                }
                MenuSection("Saved arrangement") {
                    Button(action: update) { Label("Update with current windows…", systemImage: "arrow.triangle.2.circlepath") }
                        .disabled(model.busy || !model.permissionGranted || !model.isCompatible(layout))
                    if !layout.history.isEmpty {
                        Menu("Restore a previous revision") {
                            ForEach(layout.history.sorted { $0.date > $1.date }) { revision in
                                Button("\(revision.date.formatted(date: .abbreviated, time: .shortened)) · \(revision.windows.count) windows") {
                                    model.restoreRevision(layoutID: layout.id, revisionID: revision.id)
                                }
                            }
                        }
                    }
                    Button("Delete layout…", role: .destructive, action: delete)
                }
            }.padding(18)
        }.scrollIndicators(.visible)
            .onAppear { name = layout.name }
            .sheet(item: $matchingWindow) { MatchingPreferenceSheet(model: model, layoutID: layout.id, window: $0) }
            .sheet(item: $assignmentWindow) { AssignWindowSheet(model: model, layoutID: layout.id, savedWindow: $0) }
    }
    private func option(_ title: String, keyPath: WritableKeyPath<LayoutOptions, Bool>) -> some View {
        Toggle(title, isOn: Binding(get: { layout.options[keyPath: keyPath] }, set: { value in
            var options = layout.options; options[keyPath: keyPath] = value; model.setOptions(layout.id, options: options)
        })).disabled(model.busy)
    }
    private func iconLabel(_ icon: String) -> String {
        let names = ["Windows", "Coding", "Writing", "Calls", "Laptop", "Displays", "Design", "Music", "Gaming", "Work", "Reading", "Home"]
        return names[icons.firstIndex(of: icon) ?? 0]
    }
}

private struct MenuSettingsPage: View {
    let model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 17) {
                MenuSection("General") {
                    AutoModeSettingsControls(model: model)
                    Divider()
                    Toggle("Restore-only switching", isOn: Binding(get: { model.library.settings.automaticSwitching }, set: { model.setAutomatic($0) }))
                        .toggleStyle(.switch).controlSize(.small)
                        .disabled(model.library.settings.autoModeEnabled)
                    Text(model.library.settings.autoModeEnabled ? "Paused while Auto mode is on. Its setting is kept for when Auto mode is off." : "Apply the preferred saved layout when your display setup changes, without automatically saving new configurations.")
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    Toggle("Launch Persisted at login", isOn: Binding(get: { model.loginEnabled }, set: { model.setLoginEnabled($0) }))
                        .toggleStyle(.switch).controlSize(.small)
                    Text(model.loginStatus).font(.caption).foregroundStyle(.secondary)
                }
                MenuSection("Keyboard") {
                    HStack { Text("Quick layout switcher"); Spacer(); Text("⇧⌘L").foregroundStyle(.secondary) }
                    Text("Search and switch without reaching for the menu bar. Set a global shortcut for any layout in its details.").font(.caption).foregroundStyle(.secondary)
                    if let error = model.quickSwitcherError { Text(error).font(.caption).foregroundStyle(.orange) }
                    HStack { Text("Apply first nine layouts"); Spacer(); Text("⌘1–9").foregroundStyle(.secondary) }
                    HStack { Text("Search layouts"); Spacer(); Text("⌘F").foregroundStyle(.secondary) }
                    Text("Command shortcuts work while this panel is open.").font(.caption).foregroundStyle(.tertiary)
                }
                MenuSection("Accessibility") {
                    Label(model.permissionGranted ? "Window placement enabled" : "Permission needed", systemImage: model.permissionGranted ? "checkmark.shield" : "lock")
                        .foregroundStyle(model.permissionGranted ? Color.green : Color.orange)
                    Text("Allow Persisted to read, move, and resize application windows.").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Enable") { model.requestPermission() }.disabled(model.permissionGranted)
                        Button("System Settings…") { model.openAccessibilitySettings() }
                    }
                }
                MenuSection("Exclusions") {
                    if model.library.exclusions.isEmpty { Text("No excluded apps or windows.").font(.caption).foregroundStyle(.secondary) }
                    ForEach(model.library.exclusions) { exclusion in
                        HStack(spacing: 8) {
                            AppIcon(bundleID: exclusion.bundleID, size: 22)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(exclusion.bundleID).font(.caption).lineLimit(1)
                                Text(exclusion.title ?? "All application windows").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            Button { model.removeExclusion(exclusion.id) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless).help("Remove exclusion")
                        }
                    }
                }
                MenuSection("Recovery") {
                    if model.library.recovery.isEmpty { Text("Stable snapshots will appear here as you use your layouts.").font(.caption).foregroundStyle(.secondary) }
                    ForEach(model.library.recovery.sorted { $0.date > $1.date }.prefix(10)) { snapshot in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(snapshot.date.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                                Text("\(snapshot.windows.count) windows").font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Recover") { Task { await model.recoverSnapshot(snapshot.id) } }.font(.caption)
                        }
                    }
                }
            }.padding(18)
        }.scrollIndicators(.visible)
    }
}

private struct MenuProfilesPage: View {
    let model: AppModel
    private var setups: [DisplayTopology] {
        var values = [model.topology]
        for layout in model.library.layouts where !values.contains(where: { $0.setupKey == layout.topology.setupKey }) { values.append(layout.topology) }
        return values
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 17) {
                Text("Give each workspace a name and choose the layout to apply when it connects.").font(.callout).foregroundStyle(.secondary)
                ForEach(setups, id: \.setupKey) { topology in
                    MenuProfileEditor(model: model, topology: topology)
                }
                MenuSection("Current displays") {
                    ForEach(model.topology.displays) { display in
                        MenuDisplayAliasEditor(model: model, display: display)
                        if display.id != model.topology.displays.last?.id { Divider() }
                    }
                }
            }.padding(18)
        }.scrollIndicators(.visible)
    }
}

private struct MenuProfileEditor: View {
    let model: AppModel
    let topology: DisplayTopology
    @State private var name = ""
    private var layouts: [PersistedCore.Layout] { model.library.layouts.filter { $0.topology.setupKey == topology.setupKey && !$0.importedNeedsMapping } }
    var body: some View {
        MenuSection(topology.setupKey == model.topology.setupKey ? "Current setup" : "Saved setup") {
            HStack {
                DisplaySetupLabel(topology: topology).font(.callout).foregroundStyle(.secondary).fixedSize()
                TextField("Workspace name, e.g. Desk", text: $name).textFieldStyle(.roundedBorder).onSubmit { saveName() }
                Button("Save", action: saveName)
            }
            Text(topology.setupSummary).font(.caption).foregroundStyle(.secondary)
            if !layouts.isEmpty {
                Picker("Auto preset", selection: Binding(get: { model.library.autoLayoutIDs[topology.setupKey] }, set: { id in if let id { model.setAutoLayout(id) } })) {
                    Text("Choose a layout").tag(Optional<UUID>.none)
                    ForEach(layouts) { layout in
                        Text(layout.name + (layout.options.autoModeEnabled ? "" : " (excluded from Auto)"))
                            .tag(Optional(layout.id)).disabled(!layout.options.autoModeEnabled)
                    }
                }.disabled(model.busy)
                Picker("Restore-only preset", selection: Binding(get: { model.library.preferredLayouts[topology.setupKey] }, set: { id in if let id { model.setPreferred(id) } })) {
                    Text("Choose a layout").tag(Optional<UUID>.none)
                    ForEach(layouts) { Text($0.name).tag(Optional($0.id)) }
                }.disabled(model.library.settings.autoModeEnabled || model.busy)
            }
            if topology.hasAmbiguousIdentity { Text("This setup needs a confirmed display mapping before it can switch automatically.").font(.caption).foregroundStyle(.secondary) }
        }.onAppear { name = model.library.displayProfileNames[topology.setupKey] ?? "" }
    }
    private func saveName() { model.setProfileName(setupKey: topology.setupKey, name: name) }
}

private struct MenuDisplayAliasEditor: View {
    let model: AppModel
    let display: DisplayRecord
    @State private var name = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: display.isBuiltIn ? "laptopcomputer" : "display").foregroundStyle(.secondary).frame(width: 22)
                TextField(display.name, text: $name).textFieldStyle(.roundedBorder).onSubmit { model.setDisplayAlias(display.id, name: name) }
                Button("Save") { model.setDisplayAlias(display.id, name: name) }
            }
            Text("\(Int(display.frame.width)) × \(Int(display.frame.height)) points\(display.isPrimary ? " · Main display" : "")").font(.caption2).foregroundStyle(.secondary).padding(.leading, 30)
        }.onAppear { name = model.library.displayAliases[display.id] ?? "" }
    }
}

private struct MenuSection<Content: View>: View {
    let title: String
    let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.subheadline).foregroundStyle(.secondary).padding(.leading, 2)
            VStack(alignment: .leading, spacing: 12) { content }
                .frame(maxWidth: .infinity, alignment: .leading).padding(13)
                .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 10))
        }.font(.callout)
    }
}
