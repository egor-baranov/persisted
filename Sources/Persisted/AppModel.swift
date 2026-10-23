import AppKit
import Observation
import PersistedCore
import PersistedPlatform
import UniformTypeIdentifiers

struct DisplayMappingRequest: Identifiable {
    let id = UUID()
    let layout: Layout
    var windowScope: Set<UUID>? = nil
}

@MainActor @Observable final class AppModel {
    let coordinator: RestoreCoordinator
    private let displayService: DisplayTopologyService
    private let accessibility: AccessibilityService
    private let permissionService: PermissionService
    private let loginService: LoginItemService
    private let repository: LayoutRepository
    private let hotkeyService = GlobalHotkeyService()
    private var automationTimer: Timer?
    private var registeredHotkeys: [UUID: LayoutHotkey]?
    private var firedSchedules = Set<ScheduleOccurrence>()
    @ObservationIgnored var presentPanel: (@MainActor () -> Void)?
    var quickSwitcherRequest = UUID()
    var hotkeyErrors: [UUID: String] = [:]
    var quickSwitcherError: String?
    private var capturedTopology: DisplayTopology?
    private var startupComplete = false
    /// The website renderer uses an isolated, inert coordinator and never starts system services.
    private let isWebsitePreview: Bool
    var capture: WindowCapture?
    var pendingMapping: DisplayMappingRequest?
    var importPreview: [Layout]?
    var loginStatus = "Off"
    var loginEnabled = false
    private(set) var desktopRestorationCapability: DesktopRestorationCapability?
    var desktopRestorationAvailable: Bool { desktopRestorationCapability?.isAvailable == true }
    func desktopRestorationNotice(for layout: Layout) -> String? {
        guard layout.options.restoreDesktops, layout.effectiveDesktopSnapshot != nil else { return nil }
        return desktopRestorationCapability?.limitation
    }
    var library: Library { coordinator.library }
    var topology: DisplayTopology { coordinator.topology }
    var suggestedLayoutName: String {
        LayoutCatalog.suggestedName(for: capturedTopology ?? topology, existingNames: library.layouts.map(\.name))
    }
    var selectedLayoutID: UUID? { coordinator.selectedLayoutID }
    var status: String { coordinator.status }
    var busy: Bool { coordinator.busy }
    var permissionGranted: Bool { coordinator.permissionGranted }
    var outcomes: [WindowOutcome] { coordinator.outcomes }
    var desktopIssues: [String] { coordinator.desktopIssues }
    var desktopSummary: String? { coordinator.desktopSummary }
    var canUndo: Bool { coordinator.canUndo }
    var isIntegrationCheck: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--integration-check") || arguments.contains("--desktop-diagnostics")
    }
    var errorMessage: String? {
        get { coordinator.errorMessage }
        set { if let newValue { coordinator.reportError(newValue) } else { coordinator.clearError() } }
    }

    init() {
        self.isWebsitePreview = false
        let displays = DisplayTopologyService()
        let ax = AccessibilityService()
        let permission = PermissionService()
        let repo = LayoutRepository()
        self.displayService = displays; self.accessibility = ax
        self.permissionService = permission; self.repository = repo; self.loginService = LoginItemService()
        self.coordinator = RestoreCoordinator(displays: displays, accessibility: ax, permission: permission,
                                              launcher: ApplicationLauncher(), repository: repo)
    }
    init(websitePreview coordinator: RestoreCoordinator) {
        self.isWebsitePreview = true
        self.startupComplete = true
        self.desktopRestorationCapability = .available
        self.displayService = DisplayTopologyService()
        self.accessibility = AccessibilityService()
        self.permissionService = PermissionService()
        self.repository = LayoutRepository(directory: FileManager.default.temporaryDirectory.appendingPathComponent("Persisted-website-unused"))
        self.loginService = LoginItemService()
        self.coordinator = coordinator
    }
    func startup() async {
        guard !startupComplete else { return }
        startupComplete = true
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--desktop-diagnostics"), arguments.indices.contains(index + 1) {
            let report = await accessibility.desktopDiagnostics()
            do {
                let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: URL(fileURLWithPath: arguments[index + 1]), options: .atomic)
                exit(EXIT_SUCCESS)
            } catch { exit(EXIT_FAILURE) }
        }
        if let index = arguments.firstIndex(of: "--integration-check"), arguments.indices.contains(index + 1) {
            await NativeIntegrationCheck.run(accessibility: accessibility, topologyService: displayService,
                                              output: URL(fileURLWithPath: arguments[index + 1]))
            await accessibility.stopObserving()
            // This explicit command-line mode never loads the library or installs
            // app observers. Exit after the fixture cleanup and report are complete;
            // SwiftUI may not instantiate its status-label task in a headless launch.
            exit(EXIT_SUCCESS)
        }
        desktopRestorationCapability = await accessibility.desktopRestorationCapability()
        await coordinator.start()
        displayService.start { [weak self] event in
            guard let self else { return }
            let mapped: RestoreEvent
            switch event {
            case .displayChanged: mapped = .displayChanged
            case .lidChanged: mapped = .lidChanged
            case .sleep: mapped = .sleep
            case .wake: mapped = .wake
            case .screenSleep: mapped = .screenSleep
            case .screenWake: mapped = .screenWake
            case .sessionInactive: mapped = .sessionInactive
            case .sessionActive: mapped = .sessionActive
            case .applicationsChanged: mapped = .applicationsChanged
            case .windowsChanged: mapped = .windowsChanged
            case .permissionChanged: mapped = .permissionChanged
            }
            coordinator.handle(mapped)
            if case .permissionChanged = event { refreshLogin() }
        }
        await accessibility.startObserving { [weak self] in
            Task { @MainActor [weak self] in self?.coordinator.handle(.windowsChanged) }
        }
        refreshLogin()
        hotkeyService.registrationDidChange = { [weak self] errors, switcherError in
            self?.hotkeyErrors = errors
            self?.quickSwitcherError = switcherError
        }
        refreshHotkeys()
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tickAutomations() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        automationTimer = timer
        if let notice = await repository.recoveryNotice { errorMessage = notice }
    }
    func shutdown() async {
        automationTimer?.invalidate(); automationTimer = nil
        hotkeyService.stop()
        displayService.stop(); coordinator.stop()
        await accessibility.stopObserving()
        await coordinator.flushPersistence()
    }
    func isCompatible(_ layout: Layout) -> Bool { coordinator.isCompatible(layout) }
    func canApplyDirectly(_ layout: Layout) -> Bool { coordinator.manualMapping(for: layout) != nil }
    func apply(_ layout: Layout) async {
        guard canApplyDirectly(layout) else { pendingMapping = .init(layout: layout); return }
        coordinator.requestApply(layoutID: layout.id)
        await coordinator.waitForRestoration()
    }
    func prepareCapture() async {
        capture = nil; capturedTopology = nil
        guard let (topology, result) = await coordinator.captureCurrent() else { return }
        capturedTopology = topology; capture = result
    }
    func saveCapture(name: String, selected: Set<UUID>, updating: UUID?) async {
        let cleanedName = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        guard !cleanedName.isEmpty, let capture, let capturedTopology, !selected.isEmpty else {
            errorMessage = "Name the layout and select at least one window."; return
        }
        guard coordinator.state == .idle, capturedTopology.isEquivalent(to: displayService.snapshot()),
              capturedTopology.isEquivalent(to: topology) else {
            errorMessage = "The display setup changed. Capture the windows again before saving."; return
        }
        if updating != nil && !capture.isComplete {
            errorMessage = "Some applications could not be read. The existing layout was preserved; retry after they respond."; return
        }
        let chosen = capture.windows.filter { selected.contains($0.id) }
        let windows = chosen.compactMap { CoordinateMapper.save($0, in: capturedTopology, desktopSnapshot: capture.desktopSnapshot) }
        guard windows.count == chosen.count, !windows.isEmpty else { errorMessage = "The captured geometry is unavailable. Try capturing again."; return }
        let first = library.layouts.isEmpty
        var savedID = UUID()
        var referenceWindows = windows
        if let updating, let previous = library.layouts.first(where: { $0.id == updating }) {
            guard previous.effectiveDesktopSnapshot == nil || capture.desktopSnapshot != nil else {
                errorMessage = "Desktops could not be captured. The existing layout was preserved; retry after Mission Control has settled."; return
            }
            guard previous.effectiveDesktopSnapshot == nil || chosen.allSatisfy({ $0.desktopAssignment != nil }) else {
                errorMessage = "Some window desktop assignments could not be read. The existing layout was preserved; capture again before updating."; return
            }
            guard coordinator.isCompatible(previous) else {
                errorMessage = "Save a new layout for this display setup instead of replacing the original."; return
            }
            savedID = updating
            // Keep stable saved-window IDs for confidently recognized entries.
            let matches = WindowMatcher.match(saved: previous.effectiveWindows, live: chosen)
            referenceWindows = zip(windows, chosen).map { saved, live in
                var result = saved
                if let oldID = matches.matches.first(where: { $0.value.id == live.id })?.key {
                    result.id = oldID
                    result.matchingRule = previous.effectiveWindows.first(where: { $0.id == oldID })?.matchingRule ?? .automatic
                }
                return result
            }
            let desktopExclusions = remappedDesktopExclusions(previous, snapshot: capture.desktopSnapshot)
            let accepted = coordinator.updateLibrary { library in
                guard let index = library.layouts.firstIndex(where: { $0.id == updating }) else { return }
                library.layouts[index].history.append(previous.saved)
                library.layouts[index].history = Array(library.layouts[index].history.suffix(10))
                library.layouts[index].name = cleanedName
                library.layouts[index].topology = capturedTopology
                if previous.topology.setupKey != capturedTopology.setupKey {
                    let wasAutoPreset = library.autoLayoutIDs.values.contains(updating)
                    library.autoLayoutIDs = library.autoLayoutIDs.filter { $0.value != updating }
                    if wasAutoPreset && library.autoLayoutIDs[capturedTopology.setupKey] == nil {
                        library.autoLayoutIDs[capturedTopology.setupKey] = updating
                    }
                }
                library.layouts[index].options.excludedDesktopIDs = desktopExclusions
                library.layouts[index].saved = .init(windows: referenceWindows, desktopSnapshot: capture.desktopSnapshot)
                library.layouts[index].remembered = nil
                library.layouts[index].editedAwaitingApply = false
            }
            guard accepted else { return }
        } else {
            let layout = Layout(id: savedID, name: cleanedName, topology: capturedTopology, windows: windows,
                                desktopSnapshot: capture.desktopSnapshot)
            let accepted = coordinator.updateLibrary { library in
                library.layouts.append(layout)
                if library.preferredLayouts[capturedTopology.setupKey] == nil {
                    library.preferredLayouts[capturedTopology.setupKey] = layout.id
                }
                if first { library.settings.automaticSwitching = library.settings.enableAutomaticAfterFirstSave }
            }
            guard accepted else { return }
        }
        let references = Dictionary(uniqueKeysWithValues: zip(referenceWindows, chosen).map { ($0.0.id, $0.1.id) })
        // A fresh explicit capture identifies the current session's surfaces. Weak
        // identities must be confirmed again after any reconnection or app restart.
        if capturedTopology.hasAmbiguousIdentity {
            coordinator.confirmMapping(.init(layoutID: savedID, targetSetupKey: capturedTopology.setupKey,
                assignments: Dictionary(uniqueKeysWithValues: capturedTopology.surfaces.map { ($0.id, $0.id) })))
        }
        coordinator.selectSavedLayout(savedID, references: references)
        self.capture = nil; self.capturedTopology = nil
        await coordinator.flushPersistence()
    }
    private func remappedDesktopExclusions(_ layout: Layout, snapshot: DesktopSnapshot?) -> Set<String> {
        var result = layout.options.excludedDesktopIDs
        guard !result.isEmpty, let previous = layout.effectiveDesktopSnapshot, let snapshot else { return result }
        let currentDesktops = snapshot.displays.flatMap(\.desktops)
        for display in previous.displays {
            for desktop in display.desktops where desktop.kind == .ordinary && layout.options.excludedDesktopIDs.contains(desktop.id) {
                let identityMatches = desktop.uuidHint.flatMap { hint in
                    hint.isEmpty ? nil : currentDesktops.filter {
                        $0.kind == desktop.kind && $0.uuidHint?.caseInsensitiveCompare(hint) == .orderedSame
                    }
                } ?? []
                let replacement = identityMatches.count == 1 ? identityMatches.first
                    : snapshot.displays.first { $0.displayID == display.displayID }?.desktops.first {
                        $0.kind == desktop.kind && $0.ordinal == desktop.ordinal
                    }
                if let replacement { result.insert(replacement.id) }
            }
        }
        // Keep old logical IDs too, so restoring a previous revision retains its exclusions.
        return result
    }
    func updateLayout(_ layout: Layout) async {
        await prepareCapture()
        guard let capture else { return }
        await saveCapture(name: layout.name, selected: Set(capture.windows.map(\.id)), updating: layout.id)
    }
    func undo() async { await coordinator.undo() }
    func setAutomatic(_ enabled: Bool) { coordinator.setAutomatic(enabled) }
    func setAutoMode(_ enabled: Bool) { coordinator.setAutoMode(enabled) }
    func setAutoLayout(_ id: UUID) { coordinator.setAutoLayout(layoutID: id) }
    func beginLayoutEditing(layoutID: UUID, sessionID: UUID) -> Bool {
        coordinator.beginLayoutEditing(layoutID: layoutID, sessionID: sessionID)
    }
    func endLayoutEditing(sessionID: UUID) { coordinator.endLayoutEditing(sessionID: sessionID) }
    func saveLayoutEdits(_ draft: LayoutEditDraft) -> Bool { coordinator.commitLayoutEdit(draft) }
    func renameLayout(_ id: UUID, name: String) {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        guard !trimmed.isEmpty else { return }
        edit(id) { $0.name = trimmed }
    }
    func duplicateLayout(_ id: UUID) {
        guard var copy = library.layouts.first(where: { $0.id == id }) else { return }
        copy.id = UUID(); copy.name = String((copy.name + " copy").prefix(200))
        copy.history = []; copy.hotkey = nil
        coordinator.updateLibrary { $0.layouts.append(copy) }
    }
    func deleteLayout(_ id: UUID) {
        coordinator.updateLibrary { library in
            library.layouts.removeAll { $0.id == id }
            library.preferredLayouts = library.preferredLayouts.filter { $0.value != id }
            library.autoLayoutIDs = library.autoLayoutIDs.filter { $0.value != id }
            library.displayMappings.removeAll { $0.layoutID == id }
            library.schedules.removeAll { $0.layoutID == id }
        }
        refreshHotkeys()
    }
    func setPreferred(_ id: UUID) {
        guard let layout = library.layouts.first(where: { $0.id == id }), !layout.importedNeedsMapping else { return }
        coordinator.updateLibrary { $0.preferredLayouts[layout.topology.setupKey] = id }
    }
    func setOptions(_ id: UUID, options: LayoutOptions) { edit(id) { $0.options = options } }
    func discardRemembered(_ id: UUID) {
        edit(id) {
            guard let remembered = $0.remembered else { return }
            $0.history.removeAll { $0.id == remembered.id }
            $0.history.append(remembered)
            $0.history = Array($0.history.suffix(10))
            $0.remembered = nil
            $0.editedAwaitingApply = true
        }
    }
    func restoreRevision(layoutID: UUID, revisionID: UUID) {
        guard let layout = library.layouts.first(where: { $0.id == layoutID }), let revision = layout.history.first(where: { $0.id == revisionID }) else { return }
        edit(layoutID) { value in
            let current = value.saved
            value.saved = revision; value.remembered = nil
            value.history.removeAll { $0.id == revisionID }
            value.history.append(current)
            if let remembered = layout.remembered, remembered.id != current.id, remembered.id != revision.id {
                value.history.removeAll { $0.id == remembered.id }
                value.history.append(remembered)
            }
            value.history = Array(value.history.suffix(10))
            value.editedAwaitingApply = true
        }
    }
    func setMatchingRule(layoutID: UUID, windowID: UUID, rule: MatchingRule) {
        edit(layoutID) { layout in
            if let index = layout.saved.windows.firstIndex(where: { $0.id == windowID }) { layout.saved.windows[index].matchingRule = rule }
            if let index = layout.remembered?.windows.firstIndex(where: { $0.id == windowID }) { layout.remembered?.windows[index].matchingRule = rule }
        }
    }
    func excludeWindow(_ window: SavedWindow, wholeApplication: Bool) {
        coordinator.updateLibrary { library in
            let exclusion = WindowExclusion(bundleID: window.identity.bundleID, title: wholeApplication ? nil : window.identity.title)
            if !library.exclusions.contains(where: { $0.bundleID == exclusion.bundleID && $0.title == exclusion.title }) { library.exclusions.append(exclusion) }
        }
    }
    func removeExclusion(_ id: UUID) { coordinator.updateLibrary { $0.exclusions.removeAll { $0.id == id } } }
    func setDisplayAlias(_ id: String, name: String) {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        coordinator.updateLibrary {
            if trimmed.isEmpty { $0.displayAliases.removeValue(forKey: id) }
            else { $0.displayAliases[id] = trimmed }
        }
    }
    private func edit(_ id: UUID, _ transform: (inout Layout) -> Void) {
        coordinator.updateLibrary { library in
            guard let index = library.layouts.firstIndex(where: { $0.id == id }) else { return }
            transform(&library.layouts[index])
        }
    }
    func importLayouts() async {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false; panel.message = "Preview layouts before importing them."
        guard await panel.begin() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            importPreview = try LayoutRepository.importPreview(data)
        } catch { errorMessage = error.localizedDescription }
    }
    func commitImport(_ layouts: [Layout]) async {
        guard let preview = importPreview else { return }
        let allowed = Set(preview.map(\.id))
        let chosen = layouts.filter { allowed.contains($0.id) && $0.importedNeedsMapping }
        guard coordinator.updateLibrary({ $0.layouts.append(contentsOf: chosen) }) else { return }
        importPreview = nil
        await coordinator.flushPersistence()
    }
    func exportLayouts() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "Persisted layouts.json"
        panel.message = "The export contains window titles and document paths. Keep it private."
        panel.begin { [weak self] response in
            Task { @MainActor [weak self] in
                guard response == .OK, let self, let url = panel.url else { return }
                do { try LayoutRepository.encode(library).write(to: url, options: .atomic) }
                catch { errorMessage = error.localizedDescription }
            }
        }
    }
    func recoverSnapshot(_ id: UUID) async {
        guard let snapshot = library.recovery.first(where: { $0.id == id }) else { return }
        let layout = Layout(name: "Recovered \(snapshot.date.formatted(date: .abbreviated, time: .shortened))", topology: snapshot.topology,
                            windows: snapshot.windows, desktopSnapshot: snapshot.desktopSnapshot)
        coordinator.updateLibrary { $0.layouts.append(layout) }
        await coordinator.flushPersistence()
    }
    func applyMapped(_ layout: Layout, assignments: [String: String], skipped: Set<String>, saveAsNew: Bool, makePreferred: Bool,
                     windowScope: Set<UUID>? = nil) async {
        let source = windowScope.map { scope in
            Set(layout.effectiveWindows.filter { scope.contains($0.id) }.map(\.displayID))
        } ?? Set(layout.topology.surfaces.map(\.id))
        guard Set(assignments.keys).union(skipped) == source,
              Set(assignments.keys).isDisjoint(with: skipped),
              !assignments.isEmpty,
              assignments.values.allSatisfy({ id in topology.surfaces.contains { $0.id == id } }) else {
            errorMessage = "Map every saved display or choose Skip, and include at least one display."; return
        }
        let targetKey = topology.setupKey
        if windowScope == nil {
            let mapping = DisplayMapping(layoutID: layout.id, targetSetupKey: targetKey, assignments: assignments, skipped: skipped)
            coordinator.confirmMapping(mapping)
            if layout.importedNeedsMapping { edit(layout.id) { $0.importedNeedsMapping = false } }
            if makePreferred { coordinator.updateLibrary { $0.preferredLayouts[targetKey] = layout.id } }
        }
        coordinator.requestApply(layoutID: layout.id, mapping: assignments, windowScope: windowScope)
        await coordinator.waitForRestoration()
        if windowScope == nil, saveAsNew, !outcomes.isEmpty, outcomes.allSatisfy({ $0.kind.succeeded }), desktopIssues.isEmpty, topology.setupKey == targetKey,
           let (current, captured) = await coordinator.captureCurrent(), captured.isComplete {
            let matches = WindowMatcher.match(saved: layout.effectiveWindows, live: captured.windows)
            let windows = layout.effectiveWindows.compactMap { saved in matches.matches[saved.id].flatMap {
                CoordinateMapper.save($0, in: current, desktopSnapshot: captured.desktopSnapshot)
            } }
            if !windows.isEmpty {
                let copy = Layout(name: String((layout.name + " – current setup").prefix(200)), topology: current, windows: windows,
                                  desktopSnapshot: captured.desktopSnapshot)
                coordinator.updateLibrary {
                    $0.layouts.append(copy)
                    if makePreferred { $0.preferredLayouts[targetKey] = copy.id }
                }
                coordinator.selectSavedLayout(copy.id)
            }
        }
        pendingMapping = nil
    }
    func assignmentCandidates(for window: SavedWindow) async -> [LiveWindow] {
        let captured = await accessibility.capture(exclusions: library.exclusions)
        return captured.windows.filter { $0.identity.bundleID == window.identity.bundleID && $0.identity.role == window.identity.role && $0.identity.subrole == window.identity.subrole }
    }
    func assignAndRetry(layoutID: UUID, windowID: UUID, liveWindowID: UUID) async {
        coordinator.assignReference(savedID: windowID, liveID: liveWindowID)
        coordinator.requestApply(layoutID: layoutID, retryOnly: [windowID])
        await coordinator.waitForRestoration()
    }
    func retryUnresolved() async { coordinator.retryUnresolved(); await coordinator.waitForRestoration() }
    func requestPermission() { permissionService.request(); coordinator.handle(.permissionChanged) }
    func openAccessibilitySettings() { permissionService.openSettings() }
    func setLoginEnabled(_ enabled: Bool) {
        Task {
            do { try await loginService.setEnabled(enabled) }
            catch { errorMessage = "Launch at login could not be changed: \(error.localizedDescription)" }
            refreshLogin()
            if loginService.requiresApproval { loginService.openSettings() }
        }
    }
    private func refreshLogin() { loginStatus = loginService.statusDescription; loginEnabled = loginService.isEnabled }
    func completeOnboarding() { coordinator.updateLibrary { $0.settings.onboardingCompleted = true } }
    func setOnboardingAutomatic(_ enabled: Bool) { coordinator.updateLibrary { $0.settings.enableAutomaticAfterFirstSave = enabled } }

    func moveLayout(id: UUID, offset: Int) {
        coordinator.updateLibrary { library in
            guard let source = library.layouts.firstIndex(where: { $0.id == id }) else { return }
            let destination = max(0, min(library.layouts.count - 1, source + offset))
            guard source != destination else { return }
            library.layouts.insert(library.layouts.remove(at: source), at: destination)
        }
    }
    func setIcon(id: UUID, name: String) { edit(id) { $0.iconName = name } }
    func setHotkey(id: UUID, hotkey: LayoutHotkey?) {
        edit(id) { $0.hotkey = hotkey }
        refreshHotkeys()
    }
    func setLayoutApplicationEnabled(layoutID: UUID, bundleID: String, enabled: Bool) {
        edit(layoutID) { layout in
            if enabled { layout.excludedBundleIDs.remove(bundleID) }
            else { layout.excludedBundleIDs.insert(bundleID) }
        }
    }
    func setLayoutDesktopEnabled(layoutID: UUID, desktopID: String, enabled: Bool) {
        guard let layout = library.layouts.first(where: { $0.id == layoutID }),
              layout.effectiveDesktopSnapshot?.displays.contains(where: { display in
                  display.desktops.contains { $0.id == desktopID && $0.kind == .ordinary }
              }) == true else { return }
        edit(layoutID) { layout in
            if enabled { layout.options.excludedDesktopIDs.remove(desktopID) }
            else { layout.options.excludedDesktopIDs.insert(desktopID) }
        }
    }
    func setProfileName(setupKey: String, name: String) {
        let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        coordinator.updateLibrary { library in
            if clean.isEmpty { library.displayProfileNames.removeValue(forKey: setupKey) }
            else { library.displayProfileNames[setupKey] = clean }
        }
    }
    func upsertSchedule(_ schedule: LayoutSchedule) {
        coordinator.updateLibrary { library in
            if let index = library.schedules.firstIndex(where: { $0.id == schedule.id }) {
                library.schedules[index] = schedule
            } else { library.schedules.append(schedule) }
        }
    }
    func deleteSchedule(_ id: UUID) { coordinator.updateLibrary { $0.schedules.removeAll { $0.id == id } } }
    func applySingleDisplay(_ layout: Layout, displayID: String) async {
        let ids = Set(layout.effectiveWindows.filter { $0.displayID == displayID }.map(\.id))
        guard !ids.isEmpty else { return }
        guard coordinator.manualMapping(for: layout, windowScope: ids) != nil else {
            pendingMapping = .init(layout: layout, windowScope: ids)
            return
        }
        coordinator.requestApply(layoutID: layout.id, windowScope: ids)
        await coordinator.waitForRestoration()
    }
    func showQuickSwitcher() {
        quickSwitcherRequest = UUID()
        presentPanel?()
    }
    func recheckHotkeys() { refreshHotkeys(force: true) }
    private func refreshHotkeys(force: Bool = false) {
        guard !isWebsitePreview else { return }
        let keys = Dictionary(uniqueKeysWithValues: library.layouts.compactMap { layout in
            layout.hotkey.map { (layout.id, $0) }
        })
        guard force || registeredHotkeys != keys else { return }
        registeredHotkeys = keys
        hotkeyErrors = hotkeyService.register(layouts: library.layouts, onLayout: { [weak self] id in
            guard let self, let layout = library.layouts.first(where: { $0.id == id }) else { return }
            if !permissionGranted || !canApplyDirectly(layout) {
                pendingMapping = permissionGranted ? .init(layout: layout) : nil
                presentPanel?()
            } else { Task { await self.apply(layout) } }
        }, onQuickSwitcher: { [weak self] in self?.showQuickSwitcher() })
        quickSwitcherError = hotkeyService.quickSwitcherError
    }
    private func tickAutomations() {
        refreshHotkeys()
        coordinator.pollAutoMode()
        let now = Date()
        firedSchedules = firedSchedules.filter { now.timeIntervalSince($0.startDate) < 172_800 }
        guard coordinator.state == .idle, permissionGranted,
              let occurrence = ScheduleMatcher.activeOccurrence(schedules: library.schedules, at: now),
              !firedSchedules.contains(occurrence),
              let layout = library.layouts.first(where: { $0.id == occurrence.layoutID }),
              !layout.importedNeedsMapping, isCompatible(layout) else { return }
        if coordinator.requestApply(layoutID: layout.id) { firedSchedules.insert(occurrence) }
    }
}
