import SwiftUI
import PersistedCore

/// Edits a saved arrangement only. The caller owns persistence and editor lifetime.
struct LayoutEditorView: View {
    let model: AppModel
    let layout: PersistedCore.Layout
    let save: (LayoutEditDraft) -> Bool
    let cancel: () -> Void
    @State private var draft: LayoutEditDraft
    @State private var displayID: String
    @State private var desktopSelection: EditorDesktopSelection
    @State private var windowID: UUID?
    @State private var error: String?
    @State private var geometryError: String?
    @State private var invalidGeometry = false
    @State private var geometryResetID = UUID()

    init(model: AppModel, layout: PersistedCore.Layout, save: @escaping (LayoutEditDraft) -> Bool,
         cancel: @escaping () -> Void) {
        self.model = model; self.layout = layout; self.save = save; self.cancel = cancel
        _draft = State(initialValue: LayoutEditDraft(layout: layout))
        let window = layout.effectiveWindows.first
        _displayID = State(initialValue: window?.displayID ?? layout.topology.surfaces.first?.id ?? "")
        _desktopSelection = State(initialValue: EditorDesktopSelection(window?.desktopAssignment))
        _windowID = State(initialValue: window?.id)
    }

    private var displays: [DisplayRecord] { draft.topology.surfaces }
    private var selectedWindow: SavedWindow? { draft.revision.windows.first { $0.id == windowID } }
    private var selectedDesktop: SavedDesktop? {
        guard case .desktop(let id) = desktopSelection else { return nil }
        return desktops.first { $0.id == id }
    }
    private var desktopGroup: DesktopDisplay? { group(for: displayID) }
    private var desktops: [SavedDesktop] { (desktopGroup?.desktops ?? []).sorted { $0.ordinal < $1.ordinal } }
    private var shownWindows: [SavedWindow] {
        draft.revision.windows.filter { window in
            guard window.displayID == displayID else { return false }
            if desktopSelection.matches(window.desktopAssignment) { return true }
            return selectedDesktop?.kind == .ordinary && window.desktopAssignment == .allDesktops
        }
    }
    private var ordinaryDesktops: [SavedDesktop] { desktops.filter { $0.kind == .ordinary } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    displayPicker
                    desktopControls
                    preview
                    windowList
                    if let window = selectedWindow { inspector(window) }
                    if let issue = geometryError ?? error {
                        Label(issue, systemImage: "exclamationmark.circle")
                            .font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(16)
            }.scrollIndicators(.visible)
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { normalizeSelection() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: cancel) { Image(systemName: "chevron.left").frame(width: 24, height: 28) }
                .buttonStyle(.plain).help("Cancel editing").accessibilityLabel("Cancel editing")
            VStack(alignment: .leading, spacing: 2) {
                Text("Edit layout").font(.headline)
                Text(layout.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
        }.padding(.horizontal, 14).padding(.vertical, 11)
    }
    private var footer: some View {
        HStack(spacing: 12) {
            Text("Save now. Restore the layout when you’re ready to move windows.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Save changes") {
                do {
                    _ = try draft.validatedRevision()
                    if !save(draft) { error = model.errorMessage ?? "The layout could not be saved. Your draft is still here." }
                } catch { self.error = error.localizedDescription }
            }
            .buttonStyle(.borderedProminent).keyboardShortcut("s", modifiers: .command)
            .disabled(!draft.hasChanges || invalidGeometry || model.busy).fixedSize()
        }.padding(14)
    }
    private var displayPicker: some View {
        Picker("Display", selection: Binding(get: { displayID }, set: { value in
            displayID = value; desktopSelection = .unassigned; windowID = nil; resetGeometryFields()
            normalizeSelection()
        })) {
            ForEach(displays) { display in
                Label(displayName(display.id), systemImage: display.isBuiltIn ? "laptopcomputer" : "display").tag(display.id)
            }
        }.pickerStyle(.menu)
    }
    private var desktopControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(desktopGroup != nil && draft.revision.desktopSnapshot?.separateDisplays == false ? "Shared desktops" : "Desktops")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Button { mutate { value in
                    let id = try value.addDesktop(displayID: displayID)
                    desktopSelection = .desktop(id); windowID = nil
                } } label: { Label("Add", systemImage: "plus") }.buttonStyle(.borderless)
                    .disabled(model.busy || displays.isEmpty)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 93, maximum: 150), spacing: 7)], spacing: 7) {
                ForEach(desktops) { desktop in
                    desktopTile(.desktop(desktop.id), title: desktopTitle(desktop), active: desktop.isActive,
                        icon: desktop.kind == .fullscreen ? "arrow.up.left.and.arrow.down.right" : "rectangle")
                }
                if draft.revision.windows.contains(where: { $0.displayID == displayID && $0.desktopAssignment == .allDesktops }) {
                    desktopTile(.allDesktops, title: "All desktops", active: false, icon: "rectangle.stack")
                }
                if desktops.isEmpty || draft.revision.windows.contains(where: { $0.displayID == displayID && $0.desktopAssignment == nil }) {
                    desktopTile(.unassigned, title: "Not assigned", active: false, icon: "rectangle.dashed")
                }
            }
            if let desktop = selectedDesktop {
                desktopActions(desktop)
            } else if desktopGroup == nil {
                Text("Desktop assignments were not recorded. Add a desktop to start arranging them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func desktopTile(_ selection: EditorDesktopSelection, title: String, active: Bool, icon: String) -> some View {
        Button {
            desktopSelection = selection; windowID = nil; resetGeometryFields(); normalizeSelection()
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Image(systemName: icon)
                    if active { Circle().fill(Color.accentColor).frame(width: 5, height: 5) }
                    Spacer(minLength: 0)
                }.foregroundStyle(.secondary)
                Text(title).font(.caption).lineLimit(2)
            }.frame(maxWidth: .infinity, minHeight: 39, alignment: .leading).padding(8)
                .background(selection == desktopSelection ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
                .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(selection == desktopSelection ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: selection == desktopSelection ? 1.3 : 0.5) }
        }.buttonStyle(.plain).accessibilityLabel(title + (active ? ", active when restored" : ""))
            .accessibilityAddTraits(selection == desktopSelection ? .isSelected : [])
    }
    private func desktopActions(_ desktop: SavedDesktop) -> some View {
        HStack(spacing: 10) {
            if desktop.kind == .ordinary {
                Button { mutate { try $0.moveDesktop(id: desktop.id, offset: -1) } } label: { Image(systemName: "arrow.left") }
                    .disabled(ordinaryDesktops.first?.id == desktop.id).help("Move desktop earlier").accessibilityLabel("Move desktop earlier")
                Button { mutate { try $0.moveDesktop(id: desktop.id, offset: 1) } } label: { Image(systemName: "arrow.right") }
                    .disabled(ordinaryDesktops.last?.id == desktop.id).help("Move desktop later").accessibilityLabel("Move desktop later")
                Button(desktop.isActive ? "Active on restore" : "Make active") { mutate { try $0.setActiveDesktop(id: desktop.id) } }
                    .disabled(desktop.isActive)
                Spacer(minLength: 0)
                Button { mutate { try $0.removeDesktop(id: desktop.id) }; normalizeSelection() } label: { Image(systemName: "minus.circle") }
                    .disabled(ordinaryDesktops.count <= 1 || draft.revision.windows.contains { $0.desktopAssignment == .desktop(desktop.id) })
                    .help("Remove this desktop if no windows are assigned only to it").accessibilityLabel("Remove empty desktop")
            } else {
                Text("Native full-screen Spaces are preserved.").font(.caption).foregroundStyle(.secondary)
            }
        }.buttonStyle(.borderless).font(.caption).disabled(model.busy)
    }
    @ViewBuilder private var preview: some View {
        if let usable = draft.displayUsableFrame(displayID: displayID) {
            VStack(alignment: .leading, spacing: 6) {
                EditorWindowCanvas(windows: shownWindows, usable: usable, selectedID: windowID,
                    select: selectWindow, change: { id, frame in setFrame(id, frame) })
                    .frame(height: 210).disabled(model.busy)
                Text("Drag a window to move it. Drag its lower-right handle to resize.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
    private var windowList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Windows").font(.subheadline.weight(.medium))
            if shownWindows.isEmpty {
                Text("No saved windows on this desktop. Select a window on another desktop to move it here.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(shownWindows) { window in
                Button { selectWindow(window.id) } label: {
                    HStack(spacing: 8) {
                        AppIcon(bundleID: window.identity.bundleID, size: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(window.identity.appName).font(.callout)
                            Text(window.identity.title.isEmpty ? "Untitled window" : window.identity.title)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            if window.desktopAssignment == .allDesktops {
                                Text("All desktops").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                        if window.id == windowID { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                    }.padding(7).contentShape(Rectangle())
                        .background(window.id == windowID ? Color.accentColor.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 6))
                }.buttonStyle(.plain)
            }
        }
    }
    private func inspector(_ window: SavedWindow) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text("Window placement").font(.subheadline.weight(.medium))
            Picker("Display", selection: Binding(get: { window.displayID }, set: { target in
                guard target != window.displayID else { return }
                let targetDesktop = group(for: target)?.ordinaryDesktops.first(where: \.isActive)?.id
                    ?? group(for: target)?.ordinaryDesktops.first?.id
                mutate { value in
                    var candidate = value
                    try candidate.moveWindow(windowID: window.id, toDisplayID: target, desktopID: targetDesktop)
                    if window.desktopAssignment == .allDesktops {
                        try candidate.assignDesktop(windowID: window.id, assignment: .allDesktops)
                    }
                    value = candidate
                }
                followWindow(window.id)
            })) {
                ForEach(displays) { display in
                    Label(displayName(display.id), systemImage: display.isBuiltIn ? "laptopcomputer" : "display").tag(display.id)
                }
            }
            Picker("Desktop", selection: Binding(get: { EditorDesktopSelection(window.desktopAssignment) }, set: { target in
                mutate { try $0.assignDesktop(windowID: window.id, assignment: target.assignment) }
                followWindow(window.id)
            })) {
                ForEach(desktops) { desktop in
                    Text(desktopTitle(desktop)).tag(EditorDesktopSelection.desktop(desktop.id))
                        .disabled(desktop.kind == .fullscreen && window.desktopAssignment != .desktop(desktop.id))
                }
                if draft.revision.desktopSnapshot != nil { Text("All desktops").tag(EditorDesktopSelection.allDesktops) }
                Text("Not assigned").tag(EditorDesktopSelection.unassigned)
            }
            EditorGeometryFields(window: window, resetID: geometryResetID, invalid: $invalidGeometry,
                change: { setFrame(window.id, $0) }, report: { geometryError = $0 })
                .id(window.id)
            HStack {
                Text("Points from the display’s top-left work area.").font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Menu("Arrange") {
                    ForEach(EditorPlacement.allCases, id: \.self) { placement in
                        Button(placement.rawValue) {
                            guard let usable = draft.displayUsableFrame(displayID: window.displayID) else { return }
                            setFrame(window.id, placement.frame(in: usable, current: window.relativeFrame))
                            resetGeometryFields()
                        }
                    }
                }.fixedSize()
            }
        }.pickerStyle(.menu).disabled(model.busy)
    }

    private func group(for id: String) -> DesktopDisplay? {
        guard let snapshot = draft.revision.desktopSnapshot else { return nil }
        return snapshot.separateDisplays ? snapshot.displays.first { $0.displayID == id } : snapshot.displays.first
    }
    private func displayName(_ id: String) -> String {
        model.library.displayAliases[id] ?? draft.topology.displays.first { $0.id == id }?.name ?? "Saved display"
    }
    private func desktopTitle(_ desktop: SavedDesktop) -> String {
        let peers = desktops.filter { $0.kind == desktop.kind }
        return (desktop.kind == .ordinary ? "Desktop " : "Full-screen ") + String((peers.firstIndex { $0.id == desktop.id } ?? 0) + 1)
    }
    private func normalizeSelection() {
        if case .desktop(let id) = desktopSelection, !desktops.contains(where: { $0.id == id }) {
            desktopSelection = desktops.first.map { .desktop($0.id) } ?? .unassigned
        }
        if desktopSelection == .unassigned, shownWindows.isEmpty, let first = desktops.first {
            desktopSelection = .desktop(first.id)
        }
        if !shownWindows.contains(where: { $0.id == windowID }) { windowID = shownWindows.first?.id }
    }
    private func followWindow(_ id: UUID) {
        guard let window = draft.revision.windows.first(where: { $0.id == id }) else { return }
        displayID = window.displayID; desktopSelection = EditorDesktopSelection(window.desktopAssignment); windowID = id
        resetGeometryFields()
    }
    private func selectWindow(_ id: UUID) { windowID = id; resetGeometryFields() }
    private func resetGeometryFields() { invalidGeometry = false; geometryError = nil; geometryResetID = UUID() }
    private func setFrame(_ id: UUID, _ frame: Rect) { mutate { try $0.setWindowFrame(windowID: id, relativeFrame: frame) } }
    private func mutate(_ change: (inout LayoutEditDraft) throws -> Void) {
        do { try change(&draft); error = nil }
        catch { self.error = error.localizedDescription }
    }
}

private enum EditorDesktopSelection: Hashable {
    case desktop(String), allDesktops, unassigned
    init(_ assignment: DesktopAssignment?) {
        switch assignment {
        case .desktop(let id): self = .desktop(id)
        case .allDesktops: self = .allDesktops
        case nil: self = .unassigned
        }
    }
    var assignment: DesktopAssignment? {
        switch self {
        case .desktop(let id): .desktop(id)
        case .allDesktops: .allDesktops
        case .unassigned: nil
        }
    }
    func matches(_ value: DesktopAssignment?) -> Bool { assignment == value }
}

private struct EditorWindowCanvas: View {
    static let coordinateSpaceName = "saved-layout-editor-canvas"
    let windows: [SavedWindow]
    let usable: Rect
    let selectedID: UUID?
    let select: (UUID) -> Void
    let change: (UUID, Rect) -> Void
    var body: some View {
        GeometryReader { geometry in
            let scale = min(Double(geometry.size.width) / max(1, usable.width), Double(geometry.size.height) / max(1, usable.height))
            ZStack(alignment: .topLeading) {
                Color(nsColor: .controlBackgroundColor)
                ForEach(windows) { window in
                    EditorCanvasWindow(window: window, usable: usable, scale: scale, selected: window.id == selectedID,
                        select: { select(window.id) }, change: { change(window.id, $0) })
                        .zIndex(window.id == selectedID ? 1 : 0)
                }
            }
            .frame(width: CGFloat(usable.width * scale), height: CGFloat(usable.height * scale))
            .clipped()
            .overlay { Rectangle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.7) }
            .coordinateSpace(name: Self.coordinateSpaceName)
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }.accessibilityLabel("Saved window arrangement preview")
    }
}

private struct EditorCanvasWindow: View {
    let window: SavedWindow
    let usable: Rect
    let scale: Double
    let selected: Bool
    let select: () -> Void
    let change: (Rect) -> Void
    @State private var moveStart: Rect?
    @State private var resizeStart: Rect?
    private var previewWidth: CGFloat { CGFloat(max(8, window.relativeFrame.width * scale)) }
    private var previewHeight: CGFloat { CGFloat(max(8, window.relativeFrame.height * scale)) }
    private var previewX: CGFloat { CGFloat(window.relativeFrame.x * scale) }
    private var previewY: CGFloat { CGFloat(window.relativeFrame.y * scale) }
    private var spokenLabel: String { window.identity.appName + ", " + window.identity.title }
    var body: some View {
        positionedArtwork
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spokenLabel)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { select() }
            .help("\(window.identity.appName) · \(window.identity.title)")
    }
    private var positionedArtwork: some View {
        interactiveArtwork
            .frame(width: previewWidth, height: previewHeight)
            .offset(x: previewX, y: previewY)
    }
    private var interactiveArtwork: some View {
        artwork
            .contentShape(Rectangle())
            .onTapGesture(perform: select)
            .gesture(moveGesture)
            .overlay(alignment: .bottomTrailing) { if selected { resizeHandle } }
    }
    private var artwork: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(selected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.075))
            .overlay { border }
            .overlay(alignment: .topLeading) { windowLabel }
    }
    private var border: some View {
        RoundedRectangle(cornerRadius: 3)
            .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.35), lineWidth: selected ? 1.5 : 0.7)
    }
    private var windowLabel: some View {
        HStack(spacing: 4) {
            AppIcon(bundleID: window.identity.bundleID, size: 13)
            if window.relativeFrame.width * scale > 85 { Text(window.identity.appName).font(.system(size: 9)).lineLimit(1) }
        }.padding(4).allowsHitTesting(false)
    }
    private var resizeHandle: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 9, weight: .semibold))
            .frame(width: 18, height: 18).foregroundStyle(Color.accentColor)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 3))
            .contentShape(Rectangle()).highPriorityGesture(resizeGesture)
            .accessibilityLabel("Resize \(window.identity.appName) window")
    }
    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(EditorWindowCanvas.coordinateSpaceName))
            .onChanged { value in
                if moveStart == nil { moveStart = window.relativeFrame; select() }
                guard let start = moveStart, scale > 0 else { return }
                var frame = start
                frame.x = min(max(0, start.x + Double(value.translation.width) / scale), max(0, usable.width - start.width))
                frame.y = min(max(0, start.y + Double(value.translation.height) / scale), max(0, usable.height - start.height))
                change(frame)
            }.onEnded { _ in moveStart = nil }
    }
    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(EditorWindowCanvas.coordinateSpaceName))
            .onChanged { value in
                if resizeStart == nil { resizeStart = window.relativeFrame; select() }
                guard let start = resizeStart, scale > 0 else { return }
                var frame = start
                frame.width = max(20, min(usable.width - start.x, start.width + Double(value.translation.width) / scale))
                frame.height = max(20, min(usable.height - start.y, start.height + Double(value.translation.height) / scale))
                change(frame)
            }.onEnded { _ in resizeStart = nil }
    }
}

private struct EditorGeometryFields: View {
    let window: SavedWindow
    let resetID: UUID
    @Binding var invalid: Bool
    let change: (Rect) -> Void
    let report: (String?) -> Void
    @State private var values: [String] = []
    @FocusState private var focused: Int?
    private let names = ["X", "Y", "Width", "Height"]
    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<4, id: \.self) { index in field(index) }
        }
        .onAppear { values = formatted; invalid = false }
        .onChange(of: window.relativeFrame) { _, _ in if focused == nil { values = formatted } }
        .onChange(of: focused) { _, _ in if !invalid { values = formatted } }
        .onChange(of: resetID) { _, _ in focused = nil; values = formatted; invalid = false; report(nil) }
    }
    private func field(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(names[index]).font(.caption).foregroundStyle(.secondary)
            TextField(names[index], text: fieldBinding(index))
                .textFieldStyle(.roundedBorder).focused($focused, equals: index)
                .accessibilityLabel("Window \(names[index]) in points")
                .onSubmit { commit(); focused = nil }
        }
    }
    private func fieldBinding(_ index: Int) -> Binding<String> {
        Binding(get: { values.indices.contains(index) ? values[index] : formatted[index] }, set: { value in
            if values.count != 4 { values = formatted }
            values[index] = value
            commit()
        })
    }
    private var formatted: [String] {
        [window.relativeFrame.x, window.relativeFrame.y, window.relativeFrame.width, window.relativeFrame.height].map {
            $0.formatted(.number.locale(Locale(identifier: "en_US_POSIX")).grouping(.never).precision(.fractionLength(0...1)))
        }
    }
    private func commit() {
        let numbers = values.map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard numbers.count == 4, numbers.allSatisfy({ $0?.isFinite == true }),
              let x = numbers[0], let y = numbers[1], let width = numbers[2], let height = numbers[3], width > 0, height > 0 else {
            invalid = true; report("Enter numbers for position and a positive width and height."); return
        }
        let frame = Rect(x: x, y: y, width: width, height: height)
        guard frame.isValid else {
            invalid = true; report("Enter window coordinates and dimensions below 1,000,000 points."); return
        }
        invalid = false
        report(nil)
        change(frame)
    }
}

private enum EditorPlacement: String, CaseIterable {
    case left = "Left half", right = "Right half", top = "Top half", bottom = "Bottom half"
    case topLeft = "Top-left quarter", topRight = "Top-right quarter", bottomLeft = "Bottom-left quarter", bottomRight = "Bottom-right quarter"
    case fill = "Fill work area", center = "Center"
    func frame(in usable: Rect, current: Rect) -> Rect {
        let halfWidth = usable.width / 2, halfHeight = usable.height / 2
        switch self {
        case .left: return Rect(width: halfWidth, height: usable.height)
        case .right: return Rect(x: halfWidth, width: halfWidth, height: usable.height)
        case .top: return Rect(width: usable.width, height: halfHeight)
        case .bottom: return Rect(y: halfHeight, width: usable.width, height: halfHeight)
        case .topLeft: return Rect(width: halfWidth, height: halfHeight)
        case .topRight: return Rect(x: halfWidth, width: halfWidth, height: halfHeight)
        case .bottomLeft: return Rect(y: halfHeight, width: halfWidth, height: halfHeight)
        case .bottomRight: return Rect(x: halfWidth, y: halfHeight, width: halfWidth, height: halfHeight)
        case .fill: return Rect(width: usable.width, height: usable.height)
        case .center:
            let width = min(current.width, usable.width), height = min(current.height, usable.height)
            return Rect(x: (usable.width - width) / 2, y: (usable.height - height) / 2, width: width, height: height)
        }
    }
}
