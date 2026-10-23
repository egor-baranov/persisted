import SwiftUI
import AppKit
import PersistedCore

extension DisplayTopology {
    var setupSummary: String {
        let count = displays.filter { !$0.isBuiltIn }.count
        let external = count == 1 ? "1 external display" : "\(count) external displays"
        let lidText: String
        switch lid {
        case .open: lidText = "Lid open"
        case .closed: lidText = "Lid closed"
        case .unknown: lidText = "Lid state unknown"
        case .notApplicable: lidText = "Desktop Mac"
        }
        return "\(external) · \(lidText)"
    }
    var builtInSummary: String? {
        guard let display = displays.first(where: { $0.isBuiltIn }) else { return nil }
        return display.isActive ? "Built-in display active" : "Built-in display inactive"
    }
}

extension WindowOutcomeKind {
    var label: String {
        switch self {
        case .restored: "Restored"
        case .alreadyPositioned: "Already positioned"
        case .adjustedToConstraints: "Adjusted to app limits"
        case .missingApplication: "Application unavailable"
        case .missingWindow: "Window unavailable"
        case .ambiguous: "Choose a window"
        case .unsupported: "Cannot move this window"
        case .timedOut: "Application did not respond"
        case .cancelled: "Apply cancelled"
        }
    }
}

struct DesktopCaptureSummaryView: View {
    let snapshot: DesktopSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let snapshot {
                Label("\(snapshot.desktopCount) \(snapshot.desktopCount == 1 ? "desktop" : "desktops") captured", systemImage: "rectangle.3.group")
                Text("Includes desktop order across your setup and the selected windows’ desktop assignments.")
                    .foregroundStyle(.secondary)
                if snapshot.totalSpaceCount > snapshot.desktopCount {
                    Text("Full-screen and Split View spaces will be preserved.").foregroundStyle(.secondary)
                }
            } else {
                Label("Desktop capture unavailable", systemImage: "exclamationmark.triangle")
                Text("This capture contains window positions only.").foregroundStyle(.secondary)
            }
        }.font(.caption).frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DesktopRestoreStatusView: View {
    let summary: String?
    let issues: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let summary {
                Label(summary, systemImage: issues.isEmpty ? "rectangle.3.group" : "exclamationmark.triangle")
                    .foregroundStyle(issues.isEmpty ? Color.secondary : Color.orange)
            }
            ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                Label(issue, systemImage: "exclamationmark.circle").foregroundStyle(.orange)
            }
        }.font(.caption).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
private func activateWindow(_ id: String, openWindow: OpenWindowAction) {
    NSApplication.shared.activate(ignoringOtherApps: true)
    openWindow(id: id)
}

struct AppIcon: View {
    let bundleID: String
    var size: CGFloat = 20
    var body: some View {
        Group {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
            } else {
                Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct ErrorPresentation: ViewModifier {
    @Bindable var model: AppModel
    func body(content: Content) -> some View {
        content.alert("Persisted needs your attention", isPresented: Binding(
            get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

struct MenuPopover: View {
    @Bindable var model: AppModel
    var body: some View { PersistedMenuPanel(model: model) }
}

private struct ApplyLayoutButton: View {
    enum Style { case menu, primary }
    let model: AppModel
    let layout: PersistedCore.Layout
    var style: Style = .primary
    @State private var showMapping = false
    var body: some View {
        Group {
            if style == .menu {
                Button(action: apply) {
                    HStack(spacing: 10) {
                        Image(systemName: model.selectedLayoutID == layout.id ? "checkmark.circle.fill" : "rectangle.3.group")
                            .foregroundStyle(model.selectedLayoutID == layout.id ? Color.accentColor : Color.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(layout.name).foregroundStyle(.primary)
                            Text(model.canApplyDirectly(layout) ? "\(layout.saved.windows.count) windows" : "Choose display mapping")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.tertiary)
                    }.padding(9).contentShape(Rectangle())
                }.buttonStyle(.plain)
            } else {
                Button(action: apply) {
                    Label("Apply layout", systemImage: "arrow.up.right")
                }.buttonStyle(.borderedProminent)
            }
        }
        .disabled(model.busy || !model.permissionGranted)
        .accessibilityLabel("Apply \(layout.name)\(model.selectedLayoutID == layout.id ? ", selected layout" : "")")
        .sheet(isPresented: $showMapping) { DisplayMappingSheet(model: model, layout: layout) }
    }
    private func apply() {
        if model.canApplyDirectly(layout) {
            Task { await model.apply(layout) }
        } else { showMapping = true }
    }
}

struct SaveLayoutView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var generatedName = ""
    @State private var newLayoutName = ""
    @State private var selected = Set<UUID>()
    @State private var updating: UUID?
    private var applications: [String] {
        Array(Set((model.capture?.windows ?? []).map { $0.identity.bundleID })).sorted {
            appName($0).localizedStandardCompare(appName($1)) == .orderedAscending
        }
    }
    private func appName(_ id: String) -> String { model.capture?.windows.first { $0.identity.bundleID == id }?.identity.appName ?? id }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Save your arrangement").font(.title2.weight(.semibold))
                    Text(model.topology.setupSummary).foregroundStyle(.secondary)
                }
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
            }
            if model.capture != nil {
                DesktopCaptureSummaryView(snapshot: model.capture?.desktopSnapshot)
            }
            Form {
                TextField("Layout name", text: $name, prompt: Text(model.suggestedLayoutName))
                Picker("Save to", selection: $updating) {
                    Text("New layout").tag(Optional<UUID>.none)
                    ForEach(model.library.layouts.filter { model.isCompatible($0) }) { layout in
                        Text("Update \(layout.name)").tag(Optional(layout.id))
                    }
                }
            }
            .onChange(of: updating) { previous, value in
                if previous == nil { newLayoutName = name }
                if let value, let layout = model.library.layouts.first(where: { $0.id == value }) { name = layout.name }
                else { name = newLayoutName; suggestName() }
            }
            HStack {
                Text("Include applications and windows").font(.headline)
                Spacer()
                Button("Refresh") { Task { await model.prepareCapture() } }.disabled(model.busy)
            }
            List {
                ForEach(applications, id: \.self) { bundleID in
                    let windows = (model.capture?.windows ?? []).filter { $0.identity.bundleID == bundleID }
                    Section {
                        ForEach(windows) { window in
                            Toggle(isOn: Binding(get: { selected.contains(window.id) }, set: { enabled in
                                if enabled { selected.insert(window.id) } else { selected.remove(window.id) }
                            })) {
                                HStack {
                                    Text(window.identity.title.isEmpty ? "Untitled window" : window.identity.title).lineLimit(1)
                                    Spacer()
                                    if window.fullscreen { Text("Fullscreen").font(.caption).foregroundStyle(.secondary) }
                                    else if window.minimized { Text("Minimized").font(.caption).foregroundStyle(.secondary) }
                                    else if !window.capabilities.canMove { Text("Cannot move").font(.caption).foregroundStyle(.secondary) }
                                }
                            }.toggleStyle(.checkbox).padding(.leading, 28)
                        }
                    } header: {
                        Toggle(isOn: Binding(get: { windows.allSatisfy { selected.contains($0.id) } }, set: { enabled in
                            for window in windows { if enabled { selected.insert(window.id) } else { selected.remove(window.id) } }
                        })) {
                            HStack { AppIcon(bundleID: bundleID); Text(appName(bundleID)).font(.headline) }
                        }.toggleStyle(.checkbox)
                    }
                }
                if applications.isEmpty {
                    ContentUnavailableView("No windows captured", systemImage: "macwindow", description: Text(model.permissionGranted ? "Open application windows, then refresh." : "Enable Accessibility to capture your windows."))
                }
            }.listStyle(.inset(alternatesRowBackgrounds: true))
            if let capture = model.capture, !capture.issues.isEmpty {
                Label("Some applications could not be read. A partial capture will not replace an existing layout.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
                Text(capture.issues.map(\.message).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            HStack {
                Text("\(selected.count) windows selected").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(updating == nil ? "Save layout" : "Update layout") {
                    Task {
                        await model.saveCapture(name: name.trimmingCharacters(in: .whitespacesAndNewlines), selected: selected, updating: updating)
                        if model.errorMessage == nil { dismiss() }
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selected.isEmpty || model.busy || !model.permissionGranted)
            }
        }.padding(24).frame(minWidth: 580, minHeight: 500)
            .onChange(of: model.capture?.windows.map(\.id)) { _, _ in
                selected = Set(model.capture?.windows.map(\.id) ?? [])
                suggestName()
            }
            .onAppear {
                selected = Set(model.capture?.windows.map(\.id) ?? [])
                suggestName()
            }
            .onDisappear {
                name = ""; generatedName = ""; newLayoutName = ""; updating = nil
            }
            .modifier(ErrorPresentation(model: model))
    }
    private func suggestName() {
        guard updating == nil else { return }
        let next = model.suggestedLayoutName
        if name.isEmpty || name == generatedName { name = next }
        generatedName = next
    }
}

struct ManageLayoutsView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var selection: UUID?
    @State private var importing = false
    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("This setup") {
                    ForEach(model.library.layouts.filter { model.isCompatible($0) }) { layout in sidebarRow(layout) }
                }
                Section("Other setups") {
                    ForEach(model.library.layouts.filter { !model.isCompatible($0) }) { layout in sidebarRow(layout) }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 280)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button {
                        activateWindow("save", openWindow: openWindow)
                        Task { await model.prepareCapture() }
                    } label: { Label("Save current", systemImage: "plus") }
                    Spacer()
                    Menu {
                        Button("Import layouts…") {
                            Task { await model.importLayouts(); importing = model.importPreview != nil }
                        }
                        Button("Export layouts…") { model.exportLayouts() }.disabled(model.library.layouts.isEmpty)
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Import and export layouts")
                }.padding(12).background(.bar)
            }
        } detail: {
            if let layout = model.library.layouts.first(where: { $0.id == selection }) {
                LayoutDetailView(model: model, layout: layout).id(layout.id)
            } else {
                ContentUnavailableView {
                    Label("A place for every window", systemImage: "rectangle.3.group")
                } description: {
                    Text("Save layouts for your desk, laptop, and everywhere you work.")
                } actions: {
                    Button("Save current layout…") {
                        activateWindow("save", openWindow: openWindow)
                        Task { await model.prepareCapture() }
                    }.buttonStyle(.borderedProminent).disabled(!model.permissionGranted)
                }
            }
        }
        .frame(minWidth: 780, minHeight: 560)
        .onAppear { if selection == nil { selection = model.selectedLayoutID ?? model.library.layouts.first?.id } }
        .sheet(isPresented: $importing) { ImportPreviewSheet(model: model) }
        .modifier(ErrorPresentation(model: model))
    }
    private func sidebarRow(_ layout: PersistedCore.Layout) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.3.group").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(layout.name)
                Text("\(layout.saved.windows.count) windows · \(layout.topology.surfaces.count) displays").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.library.preferredLayouts.values.contains(layout.id) {
                Image(systemName: "star.fill").font(.caption).foregroundStyle(.secondary).accessibilityLabel("Preferred restore-only layout")
            }
        }.padding(.vertical, 4).tag(layout.id)
    }
}

private struct LayoutDetailView: View {
    let model: AppModel
    let layout: PersistedCore.Layout
    @State private var editing = false
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmingDelete = false
    @State private var matchingWindow: SavedWindow?
    @State private var assignmentWindow: SavedWindow?
    @State private var mapping = false
    private var unresolved: [WindowOutcome] { model.selectedLayoutID == layout.id ? model.outcomes.filter { !$0.kind.succeeded } : [] }
    var body: some View {
        if editing {
            LayoutEditorHost(model: model, layout: layout) { editing = false }.id(layout.id)
        } else {
            details
        }
    }
    private var details: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(layout.name).font(.largeTitle.weight(.semibold))
                        Text(layout.topology.setupSummary).foregroundStyle(.secondary)
                        Text("Saved \(layout.saved.date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    ApplyLayoutButton(model: model, layout: layout)
                    Menu {
                        Button("Rename…") { newName = layout.name; renaming = true }
                        Button("Duplicate") { model.duplicateLayout(layout.id) }
                        Button("Update with current windows") { Task { await model.updateLayout(layout) } }
                            .disabled(!model.isCompatible(layout) || !model.permissionGranted || model.busy)
                        Divider()
                        Button("Delete layout…", role: .destructive) { confirmingDelete = true }
                    } label: { Image(systemName: "ellipsis.circle").font(.title3) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("Layout actions")
                }
                if let limitation = model.desktopRestorationNotice(for: layout) {
                    DesktopCapabilityNotice(message: limitation)
                }
                if layout.importedNeedsMapping {
                    Label("Imported layout · Choose its display mapping before applying or making it automatic.", systemImage: "square.and.arrow.down")
                        .font(.callout).foregroundStyle(.secondary)
                }
                MonitorPreview(topology: layout.topology, windows: layout.effectiveWindows, aliases: model.library.displayAliases)
                    .frame(height: 210).padding(14).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                Button { editing = true } label: { Label("Edit arrangement", systemImage: "pencil.and.outline") }
                    .disabled(model.busy)
                if layout.editedAwaitingApply { EditedLayoutNotice() }
                GroupBox("Auto mode") {
                    LayoutAutoModeControls(model: model, layout: layout).padding(10)
                }
                GroupBox("Other behavior") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(model.library.preferredLayouts.values.contains(layout.id) ? "Restore-only preset for this setup" : "Choose the restore-only preset for this setup")
                                Text(model.library.settings.autoModeEnabled ? "Auto mode controls saving and restoring while it is on." : "Restore-only switching applies this preset when the setup changes.").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Make preferred") { model.setPreferred(layout.id) }
                                .disabled(model.library.settings.autoModeEnabled || layout.importedNeedsMapping || model.library.preferredLayouts.values.contains(layout.id))
                        }
                        Divider()
                        optionToggle("Remember adjustments outside Auto mode", keyPath: \.rememberAdjustments)
                            .disabled(model.library.settings.autoModeEnabled)
                        Text("Remember position changes for these windows while this setup is stable. Window membership changes only when you update the layout.")
                            .font(.caption).foregroundStyle(.secondary)
                        if layout.remembered != nil {
                            Button("Discard remembered adjustments") { model.discardRemembered(layout.id) }
                        }
                        optionToggle("Launch missing applications", keyPath: \.launchMissingApplications)
                        Text("Opening an app may not recreate its documents, tabs, or windows.").font(.caption).foregroundStyle(.secondary)
                        optionToggle("Preserve window size when adapting to another work area", keyPath: \.preserveWindowSize)
                        Toggle("Match this setup regardless of lid state", isOn: Binding(get: { layout.options.lidPolicy == .ignore }, set: { value in
                            var options = layout.options; options.lidPolicy = value ? .ignore : .exact; model.setOptions(layout.id, options: options)
                        }))
                    }.padding(10)
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(layout.topology.surfaces) { display in
                            HStack {
                                Image(systemName: display.isBuiltIn ? "laptopcomputer" : "display").frame(width: 24)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(model.library.displayAliases[display.id] ?? display.name)
                                    Text("\(Int(display.frame.width)) × \(Int(display.frame.height)) points\(display.identityIsAmbiguous ? " · Mapping required" : "")")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                        Divider()
                        Button("Review display mapping…") { mapping = true }
                    }.padding(10)
                } label: { Text("Saved displays") }
                GroupBox("Desktops & apps") {
                    VStack(alignment: .leading, spacing: 12) {
                        if layout.effectiveDesktopSnapshot != nil {
                            optionToggle("Restore desktops", keyPath: \.restoreDesktops)
                                .disabled(!model.desktopRestorationAvailable && !layout.options.restoreDesktops)
                                .help("Experimental desktop restoration creates missing desktops and restores saved window assignments. Extra desktops and full-screen spaces are preserved; Mission Control may appear.")
                        }
                        LayoutWorkspaceView(model: model, layout: layout,
                            matchWindow: { matchingWindow = $0 }, assignWindow: { assignmentWindow = $0 })
                            .id(layout.id)
                    }.padding(10)
                }
                if model.selectedLayoutID == layout.id, model.desktopSummary != nil || !model.desktopIssues.isEmpty {
                    GroupBox("Desktop restore") {
                        VStack(alignment: .leading, spacing: 12) {
                            DesktopRestoreStatusView(summary: model.desktopSummary, issues: model.desktopIssues)
                            if !model.desktopIssues.isEmpty && unresolved.isEmpty {
                                Button("Retry restoration") { Task { await model.retryUnresolved() } }
                                    .disabled(model.busy || !model.permissionGranted)
                            }
                        }.padding(10)
                    }
                }
                if !unresolved.isEmpty { unresolvedSection }
                if !layout.history.isEmpty {
                    Menu("Restore a previous saved revision…") {
                        ForEach(layout.history.sorted { $0.date > $1.date }) { revision in
                            Button("\(revision.date.formatted(date: .abbreviated, time: .shortened)) · \(revision.windows.count) windows") {
                                model.restoreRevision(layoutID: layout.id, revisionID: revision.id)
                            }
                        }
                    }
                    Text("Restoring a revision changes the saved layout. Apply it when you are ready to move windows.").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(28)
        }
        .alert("Rename layout", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { model.renameLayout(layout.id, name: newName) }
                .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .confirmationDialog("Delete “\(layout.name)”?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete layout", role: .destructive) { model.deleteLayout(layout.id) }
        } message: { Text("The saved layout and its remembered adjustments will be removed.") }
        .sheet(item: $matchingWindow) { MatchingPreferenceSheet(model: model, layoutID: layout.id, window: $0) }
        .sheet(item: $assignmentWindow) { AssignWindowSheet(model: model, layoutID: layout.id, savedWindow: $0) }
        .sheet(isPresented: $mapping) { DisplayMappingSheet(model: model, layout: layout) }
    }
    private func optionToggle(_ label: String, keyPath: WritableKeyPath<LayoutOptions, Bool>) -> some View {
        Toggle(label, isOn: Binding(get: { layout.options[keyPath: keyPath] }, set: { value in
            var options = layout.options; options[keyPath: keyPath] = value; model.setOptions(layout.id, options: options)
        })).disabled(model.busy)
    }
    private var unresolvedSection: some View {
        GroupBox("Windows needing attention") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(unresolved) { outcome in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(outcome.appName) · \(outcome.kind.label)").font(.headline)
                            Text(outcome.explanation).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let savedWindow = layout.saved.windows.first(where: { $0.id == outcome.id }), [.ambiguous, .missingWindow].contains(outcome.kind) {
                            Button("Assign window…") { assignmentWindow = savedWindow }
                        }
                    }
                }
                Button(model.desktopIssues.isEmpty ? "Retry unavailable windows" : "Retry restoration") {
                    Task { await model.retryUnresolved() }
                }.disabled(model.busy || !model.permissionGranted)
            }.padding(10)
        }
    }
}

struct MonitorPreview: View {
    let topology: DisplayTopology
    let windows: [SavedWindow]
    var aliases: [String: String] = [:]
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        GeometryReader { geometry in
            let surfaces = topology.surfaces
            let frames = surfaces.map { CoordinateMapper.appKitToAX($0.frame, primaryFrame: topology.primaryFrame) }
            let minX = frames.map(\.minX).min() ?? 0
            let minY = frames.map(\.minY).min() ?? 0
            let width = max(1, (frames.map(\.maxX).max() ?? 1) - minX)
            let height = max(1, (frames.map(\.maxY).max() ?? 1) - minY)
            let scale = max(0.001, min((geometry.size.width - 12) / width, (geometry.size.height - 26) / height))
            let offsetX = (geometry.size.width - width * scale) / 2
            let offsetY = (geometry.size.height - height * scale) / 2
            ZStack(alignment: .topLeading) {
                ForEach(surfaces) { display in
                    let frame = CoordinateMapper.appKitToAX(display.frame, primaryFrame: topology.primaryFrame)
                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color(nsColor: .windowBackgroundColor))
                        ForEach(windows.filter { $0.displayID == display.id }) { window in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.accentColor.opacity(contrast == .increased ? 0.35 : 0.14))
                                .overlay(alignment: .topLeading) {
                                    if window.frame.width * scale > 32 && window.frame.height * scale > 25 {
                                        AppIcon(bundleID: window.identity.bundleID, size: min(18, window.frame.height * scale / 3)).padding(4)
                                    }
                                }
                                .overlay { RoundedRectangle(cornerRadius: 3).stroke(Color.accentColor.opacity(0.7), lineWidth: contrast == .increased ? 1.5 : 0.75) }
                                .frame(width: max(2, window.frame.width * scale), height: max(2, window.frame.height * scale))
                                .offset(x: (window.frame.x - frame.x) * scale, y: (window.frame.y - frame.y) * scale)
                        }
                    }
                    .frame(width: frame.width * scale, height: frame.height * scale)
                    .clipped()
                    .overlay { RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(contrast == .increased ? 0.8 : 0.35), lineWidth: display.isPrimary ? 2 : 1) }
                    .overlay(alignment: .bottom) {
                        Text(aliases[display.id] ?? display.name).font(.system(size: 10, weight: .medium)).lineLimit(1)
                            .padding(.horizontal, 5).padding(.vertical, 3)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 3)).padding(4)
                    }
                    .offset(x: offsetX + (frame.x - minX) * scale, y: offsetY + (frame.y - minY) * scale)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(aliases[display.id] ?? display.name), \(windows.filter { $0.displayID == display.id }.count) windows\(display.isPrimary ? ", primary display" : "")")
                }
                if surfaces.isEmpty {
                    ContentUnavailableView("No usable displays", systemImage: "display.trianglebadge.exclamationmark")
                }
            }
        }
        .accessibilityLabel("Saved display arrangement")
    }
}

struct DisplayMappingSheet: View {
    let model: AppModel
    let layout: PersistedCore.Layout
    var windowScope: Set<UUID>? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var choices: [String: String] = [:]
    @State private var saveAsNew = false
    @State private var makePreferred = false
    private let skipChoice = "__skip_display__"
    private var sourceDisplays: [DisplayRecord] {
        guard let windowScope else { return layout.topology.surfaces }
        let ids = Set(layout.effectiveWindows.filter { windowScope.contains($0.id) }.map(\.displayID))
        return layout.topology.surfaces.filter { ids.contains($0.id) }
    }
    private var complete: Bool {
        let targets = Set(model.topology.surfaces.map(\.id))
        return !targets.isEmpty && sourceDisplays.allSatisfy {
            guard let choice = choices[$0.id] else { return false }
            return choice == skipChoice || targets.contains(choice)
        } && choices.values.contains { targets.contains($0) }
    }
    private var projected: [SavedWindow] {
        layout.effectiveWindows.compactMap { window in
            guard windowScope?.contains(window.id) ?? true else { return nil }
            guard let targetID = choices[window.displayID], let target = model.topology.surfaces.first(where: { $0.id == targetID }) else { return nil }
            var result = window
            result.displayID = targetID
            result.frame = CoordinateMapper.targetFrame(for: window, on: target, in: model.topology, preserveSize: layout.options.preserveWindowSize)
            return result
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Choose where your windows go").font(.title2.weight(.semibold))
            Text("Clear display matches are selected automatically. Choose a destination for any remaining display, or skip its windows, before applying “\(layout.name)”.")
                .foregroundStyle(.secondary)
            MonitorPreview(topology: model.topology, windows: projected, aliases: model.library.displayAliases)
                .frame(height: 180).padding(12).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 14) {
                GridRow {
                    Text("Saved display").font(.caption).foregroundStyle(.secondary)
                    Text("Use this display").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(sourceDisplays) { source in
                    GridRow {
                        Label(model.library.displayAliases[source.id] ?? source.name, systemImage: source.isBuiltIn ? "laptopcomputer" : "display")
                        Picker("Destination for \(source.name)", selection: Binding(get: { choices[source.id] ?? "" }, set: { choices[source.id] = $0 })) {
                            Text("Choose display…").tag("")
                            ForEach(model.topology.surfaces) { target in
                                Text("\(model.library.displayAliases[target.id] ?? target.name) · \(Int(target.frame.x)), \(Int(target.frame.y))\(target.isPrimary ? " (primary)" : "")").tag(target.id)
                            }
                            Divider()
                            Text("Skip these windows").tag(skipChoice)
                        }.labelsHidden().frame(minWidth: 230)
                    }
                }
            }
            Divider()
            if windowScope == nil {
                Toggle("Save as a new layout for this setup", isOn: $saveAsNew)
                Toggle("Use as the preferred automatic layout for this setup", isOn: $makePreferred)
                    .disabled(!saveAsNew && !layout.importedNeedsMapping)
                    .onChange(of: saveAsNew) { _, enabled in if !enabled && !layout.importedNeedsMapping { makePreferred = false } }
            } else {
                Text("Only windows from the selected saved display will be applied.").font(.callout)
            }
            Text(saveAsNew ? "A new layout will keep this display mapping." : "The saved arrangement is preserved. Remember adjustments stays suspended for temporary mappings.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply mapped layout") {
                    let assignments = choices.filter { $0.value != skipChoice && !$0.value.isEmpty }
                    let skipped = Set(choices.filter { $0.value == skipChoice }.map(\.key))
                    Task {
                        await model.applyMapped(layout, assignments: assignments, skipped: skipped, saveAsNew: saveAsNew, makePreferred: makePreferred, windowScope: windowScope)
                        if model.errorMessage == nil { dismiss() }
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(!complete || model.busy || !model.permissionGranted)
            }
        }.padding(26).frame(width: 640)
            .onAppear {
                detectDisplays()
            }
            .onChange(of: model.topology.setupKey) { _, _ in detectDisplays() }
            .modifier(ErrorPresentation(model: model))
    }
    private func detectDisplays() {
        choices = SetupMatcher.suggestedMapping(for: layout, to: model.topology)
        if let existing = model.library.displayMappings.first(where: { $0.layoutID == layout.id && $0.targetSetupKey == model.topology.setupKey }),
           SetupMatcher.mapping(for: layout, to: model.topology, approved: existing) != nil {
            choices = existing.assignments
            for sourceID in existing.skipped { choices[sourceID] = skipChoice }
        }
        let sourceIDs = Set(sourceDisplays.map(\.id))
        choices = choices.filter { sourceIDs.contains($0.key) }
    }
}

struct MatchingPreferenceSheet: View {
    let model: AppModel
    let layoutID: UUID
    let window: SavedWindow
    @Environment(\.dismiss) private var dismiss
    @State private var mode = "automatic"
    @State private var title = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Match this window").font(.title2.weight(.semibold))
            HStack { AppIcon(bundleID: window.identity.bundleID); Text(window.identity.appName).font(.headline) }
            Text(window.identity.title.isEmpty ? "Untitled window" : window.identity.title).foregroundStyle(.secondary).lineLimit(3)
            Picker("Matching preference", selection: $mode) {
                Text("Automatic").tag("automatic")
                Text("Exact title").tag("exact")
                Text("Title contains").tag("contains")
            }
            if mode != "automatic" { TextField("Window title", text: $title).textFieldStyle(.roundedBorder) }
            Text("If multiple windows meet this preference, Persisted leaves them untouched and asks you to assign one.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save preference") {
                    let rule: MatchingRule = mode == "exact" ? .exactTitle(title) : mode == "contains" ? .titleContains(title) : .automatic
                    model.setMatchingRule(layoutID: layoutID, windowID: window.id, rule: rule)
                    dismiss()
                }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(mode != "automatic" && title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(26).frame(width: 480)
            .onAppear {
                switch window.matchingRule {
                case .automatic: mode = "automatic"; title = window.identity.title
                case .exactTitle(let text): mode = "exact"; title = text
                case .titleContains(let text): mode = "contains"; title = text
                }
            }
    }
}

struct AssignWindowSheet: View {
    let model: AppModel
    let layoutID: UUID
    let savedWindow: SavedWindow
    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [LiveWindow] = []
    @State private var selected: UUID?
    @State private var loading = true
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Assign a live window").font(.title2.weight(.semibold))
            Text("Choose the \(savedWindow.identity.appName) window to restore for “\(savedWindow.identity.title.isEmpty ? "Untitled window" : savedWindow.identity.title)”.")
                .foregroundStyle(.secondary)
            if loading { ProgressView("Finding windows…").frame(maxWidth: .infinity, minHeight: 100) }
            else if candidates.isEmpty {
                ContentUnavailableView("No windows available", systemImage: "macwindow", description: Text("Open the application and its window, then refresh."))
            } else {
                List(candidates, selection: $selected) { window in
                    HStack {
                        AppIcon(bundleID: window.identity.bundleID)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(window.identity.title.isEmpty ? "Untitled window" : window.identity.title)
                            Text("\(Int(window.frame.width)) × \(Int(window.frame.height)) points · position \(Int(window.frame.x)), \(Int(window.frame.y))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 5).tag(window.id)
                }.frame(height: 240)
            }
            Text("This assignment is valid only for the current application instance. Other saved windows will not reuse this window.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Refresh") { Task { await refresh() } }.disabled(loading)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Assign and retry") {
                    guard let selected else { return }
                    Task {
                        await model.assignAndRetry(layoutID: layoutID, windowID: savedWindow.id, liveWindowID: selected)
                        if model.errorMessage == nil { dismiss() }
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(selected == nil || model.busy)
            }
        }.padding(26).frame(width: 560)
            .task { await refresh() }
            .modifier(ErrorPresentation(model: model))
    }
    private func refresh() async {
        loading = true
        candidates = await model.assignmentCandidates(for: savedWindow)
        selected = nil
        loading = false
    }
}

struct ImportPreviewSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selected = Set<UUID>()
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Review imported layouts").font(.title2.weight(.semibold))
            Text("Imported layouts stay inactive until you choose a display mapping. Automatic behavior is your choice when you apply them.")
                .foregroundStyle(.secondary)
            List(model.importPreview ?? []) { layout in
                Toggle(isOn: Binding(get: { selected.contains(layout.id) }, set: { enabled in
                    if enabled { selected.insert(layout.id) } else { selected.remove(layout.id) }
                })) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(layout.name).font(.headline)
                        Text("\(layout.saved.windows.count) windows · \(layout.topology.setupSummary)").font(.caption).foregroundStyle(.secondary)
                        MonitorPreview(topology: layout.topology, windows: layout.saved.windows).frame(height: 100)
                    }.padding(.vertical, 8)
                }.toggleStyle(.checkbox)
            }.frame(minHeight: 200, maxHeight: 400)
            HStack {
                Spacer()
                Button("Cancel") { model.importPreview = nil; dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import \(selected.count) layouts") {
                    Task {
                        await model.commitImport((model.importPreview ?? []).filter { selected.contains($0.id) })
                        if model.errorMessage == nil { dismiss() }
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(selected.isEmpty)
            }
        }.padding(26).frame(width: 620)
            .onAppear { selected = Set(model.importPreview?.map(\.id) ?? []) }
            .modifier(ErrorPresentation(model: model))
    }
}

struct PersistedSettingsView: View {
    @Bindable var model: AppModel
    var body: some View {
        TabView {
            Form {
                Section("Behavior") {
                    AutoModeSettingsControls(model: model)
                    Toggle("Restore-only switching", isOn: Binding(get: { model.library.settings.automaticSwitching }, set: { model.setAutomatic($0) }))
                        .disabled(model.library.settings.autoModeEnabled)
                    Text(model.library.settings.autoModeEnabled ? "Paused while Auto mode is on. Its setting is kept for when Auto mode is off." : "Apply the preferred saved layout when your display setup changes, without automatically saving new configurations.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Launch Persisted at login", isOn: Binding(get: { model.loginEnabled }, set: { model.setLoginEnabled($0) }))
                    Text(model.loginStatus).font(.caption).foregroundStyle(.secondary)
                }
                Section("Accessibility") {
                    Label(model.permissionGranted ? "Accessibility enabled" : "Accessibility permission required", systemImage: model.permissionGranted ? "checkmark.shield" : "lock")
                    Text("Persisted uses window titles and placement to match your windows. It does not need Screen Recording, Full Disk Access, or Input Monitoring.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Enable Accessibility") { model.requestPermission() }.disabled(model.permissionGranted)
                        Button("Open System Settings…") { model.openAccessibilitySettings() }
                    }
                    Text("In System Settings → Privacy & Security → Accessibility, enable Persisted. Return to Persisted to recheck access.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Window restoration") {
                    Text("Experimental desktop restoration can create missing desktops and return included windows to their saved desktops. Extra desktops, native fullscreen, Split View, minimized windows, and all-desktop assignments are preserved. Documents and tabs are not recreated.")
                        .foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).tabItem { Label("General", systemImage: "gearshape") }

            Form {
                Section("Current setup") {
                    Text(model.topology.setupSummary)
                    if let builtIn = model.topology.builtInSummary { Text(builtIn).foregroundStyle(.secondary) }
                    ForEach(model.topology.displays) { display in
                        DisplayAliasRow(model: model, display: display)
                    }
                }
                Section {
                    Text("Display labels help you recognize monitors. Ambiguous displays still require explicit mapping before automatic restoration.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).tabItem { Label("Displays", systemImage: "display.2") }

            VStack(alignment: .leading, spacing: 12) {
                Text("Excluded applications and windows").font(.title3.weight(.semibold))
                Text("Exclusions apply to capture, remembered adjustments, restoration, and undo. Add exclusions from a saved layout’s window options.")
                    .font(.caption).foregroundStyle(.secondary)
                List {
                    ForEach(model.library.exclusions) { exclusion in
                        HStack {
                            AppIcon(bundleID: exclusion.bundleID)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(exclusion.bundleID)
                                Text(exclusion.title ?? "All application windows").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Remove") { model.removeExclusion(exclusion.id) }
                        }.padding(.vertical, 5)
                    }
                    if model.library.exclusions.isEmpty {
                        ContentUnavailableView("No exclusions", systemImage: "checkmark.circle", description: Text("Eligible application windows can be included in your layouts."))
                    }
                }
            }.padding(22).tabItem { Label("Exclusions", systemImage: "line.3.horizontal.decrease.circle") }

            VStack(alignment: .leading, spacing: 12) {
                Text("Stable recovery snapshots").font(.title3.weight(.semibold))
                Text("Saved layouts, remembered adjustments, and pre-apply undo are stored separately. Recover a stable snapshot as a new saved layout.")
                    .font(.caption).foregroundStyle(.secondary)
                List {
                    ForEach(model.library.recovery.sorted { $0.date > $1.date }) { snapshot in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(snapshot.date.formatted(date: .abbreviated, time: .shortened)).font(.headline)
                                Text("\(snapshot.windows.count) windows · \(snapshot.topology.setupSummary)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Recover layout") { Task { await model.recoverSnapshot(snapshot.id) } }
                        }.padding(.vertical, 6)
                    }
                    if model.library.recovery.isEmpty {
                        ContentUnavailableView("No recovery snapshots yet", systemImage: "clock.arrow.circlepath", description: Text("Snapshots are retained when a layout and display setup are stable."))
                    }
                }
            }.padding(22).tabItem { Label("Recovery", systemImage: "clock.arrow.circlepath") }
        }.padding(12).frame(minWidth: 600, minHeight: 530)
            .modifier(ErrorPresentation(model: model))
    }
}

private struct DisplayAliasRow: View {
    let model: AppModel
    let display: DisplayRecord
    @State private var alias = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Image(systemName: display.isBuiltIn ? "laptopcomputer" : "display").frame(width: 24)
                TextField(display.name, text: $alias, prompt: Text(display.name))
                    .accessibilityLabel("Display label for \(display.name)")
                Button("Save label") { model.setDisplayAlias(display.id, name: alias) }
            }
            Text("\(display.name) · \(display.isActive ? "Active" : "Inactive")\(display.mirrorSourceID == nil ? "" : " · Mirrored")\(display.identityIsAmbiguous ? " · Identity ambiguous" : "")")
                .font(.caption).foregroundStyle(.secondary)
        }.onAppear { alias = model.library.displayAliases[display.id] ?? "" }
    }
}

struct OnboardingView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 16) {
                Image(systemName: "rectangle.3.group").font(.system(size: 38, weight: .light))
                    .frame(width: 64, height: 64).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 15))
                VStack(alignment: .leading, spacing: 6) {
                    Text("Your windows, remembered.").font(.title.weight(.semibold))
                    Text("Welcome to Persisted").foregroundStyle(.secondary)
                }
            }
            Text("Save the arrangement you like for each desk or display setup. Persisted can bring it back when you reconnect, or whenever you choose.")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 16) {
                onboardingStep("1", title: "Allow window placement", description: "Accessibility lets Persisted inspect, move, and resize application windows.")
                HStack {
                    if model.permissionGranted {
                        Label("Accessibility enabled", systemImage: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                    } else {
                        Button("Enable Accessibility") { model.requestPermission() }.buttonStyle(.borderedProminent)
                        Button("Open System Settings…") { model.openAccessibilitySettings() }
                    }
                }.padding(.leading, 38)
                if !model.permissionGranted {
                    Text("Enable Persisted in Privacy & Security → Accessibility, then return here.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.leading, 38)
                }
                Divider()
                onboardingStep("2", title: "Your current setup", description: model.topology.setupSummary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), alignment: .leading)], alignment: .leading, spacing: 8) {
                    ForEach(model.topology.surfaces) { display in
                        Label(display.name, systemImage: display.isBuiltIn ? "laptopcomputer" : "display").font(.caption).fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(.leading, 38)
                Divider()
                onboardingStep("3", title: "Make it yours", description: "Arrange your windows and save your first layout.")
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Enable automatic switching after my first save", isOn: Binding(get: { model.library.settings.enableAutomaticAfterFirstSave }, set: { model.setOnboardingAutomatic($0) }))
                    Toggle("Launch Persisted at login", isOn: Binding(get: { model.loginEnabled }, set: { model.setLoginEnabled($0) }))
                    Text("Remember adjustments and launching missing apps start off. You can enable them for individual layouts.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(.leading, 38)
            }
            HStack {
                Button("Set up later") { model.completeOnboarding(); dismiss() }
                Spacer()
                Button("Save my first layout…") {
                    model.completeOnboarding()
                    activateWindow("save", openWindow: openWindow)
                    Task { await model.prepareCapture() }
                    dismiss()
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!model.permissionGranted)
            }
            Text("Your layouts stay on this Mac. Window titles and document paths may be included in exported layouts.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(30).frame(width: 580)
            .modifier(ErrorPresentation(model: model))
    }
    private func onboardingStep(_ number: String, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number).font(.callout.weight(.semibold)).frame(width: 26, height: 26)
                .background(.quaternary, in: Circle()).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline)
                Text(description).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
