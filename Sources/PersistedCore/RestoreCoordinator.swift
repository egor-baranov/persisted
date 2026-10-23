import Foundation
import Observation
import OSLog

@MainActor @Observable public final class RestoreCoordinator {
    public private(set) var library = Library()
    public private(set) var topology = DisplayTopology()
    public private(set) var state: CoordinatorState = .settling
    public private(set) var selectedLayoutID: UUID?
    public private(set) var outcomes: [WindowOutcome] = []
    public private(set) var desktopIssues: [String] = []
    public private(set) var desktopSummary: String?
    public private(set) var errorMessage: String?
    public private(set) var permissionGranted = false
    public private(set) var canUndo = false
    public private(set) var lastStableSnapshot: RecoverySnapshot?
    public private(set) var storageAvailable = true
    public var busy: Bool { state == .restoring || state == .settling }
    public var selectedLayout: Layout? { library.layouts.first { $0.id == selectedLayoutID } }
    public var status: String {
        switch state {
        case .settling, .waiting: return "Waiting for displays"
        case .restoring: return "Applying layout…"
        case .suspended: return "Paused"
        case .permissionRequired: return "Accessibility permission required"
        case .idle:
            if !desktopIssues.isEmpty { return "Desktop restoration needs attention" }
            if !outcomes.isEmpty {
                let restored = outcomes.filter { $0.kind.succeeded }.count
                let unavailable = outcomes.count - restored
                return unavailable == 0 ? "\(restored) restored" : "\(restored) restored · \(unavailable) unavailable"
            }
            if library.layouts.contains(where: { !$0.importedNeedsMapping && $0.topology.setupKey == topology.setupKey
                && ($0.topology.hasAmbiguousIdentity || topology.hasAmbiguousIdentity) && resolvedMapping(for: $0) == nil }) {
                return "Confirm display mapping"
            }
            if !library.layouts.contains(where: { isCompatible($0) }) {
                return "No layout saved for this setup"
            }
            if library.settings.autoModeEnabled {
                if let id = library.autoLayoutIDs[topology.setupKey], let layout = library.layouts.first(where: { $0.id == id }) {
                    if !layout.options.autoModeEnabled { return "Auto paused for this setup" }
                    if !layout.options.autoSaveEnabled { return "Auto restoring only" }
                }
                return "Auto remembering this setup"
            }
            return library.settings.automaticSwitching ? "Ready" : "Automatic switching paused"
        }
    }

    @ObservationIgnored private let displays: any TopologyProviding
    @ObservationIgnored private let accessibility: any WindowAccessing
    @ObservationIgnored private let permission: any PermissionChecking
    @ObservationIgnored private let launcher: any ApplicationLaunching
    @ObservationIgnored private let repository: any LibraryStoring
    @ObservationIgnored private let clock: any RestoreClock
    @ObservationIgnored private let timing: CoordinatorTiming
    @ObservationIgnored public let gate = MutationGate()
    @ObservationIgnored private let logger = Logger(subsystem: "app.persisted.Persisted", category: "Restore")
    @ObservationIgnored private var settleTask: Task<Void, Never>?
    @ObservationIgnored private var restoreTask: Task<Void, Never>?
    @ObservationIgnored private var learnTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var sleeping = false
    @ObservationIgnored private var screenSleeping = false
    @ObservationIgnored private var sessionInactive = false
    @ObservationIgnored private var pendingManual: (UUID, [String: String]?, Set<UUID>?)?
    @ObservationIgnored private var activeWindowScope: Set<UUID>?
    @ObservationIgnored private var activeDisplayMapping: (layoutID: UUID, topology: DisplayTopology, assignments: [String: String])?
    @ObservationIgnored private var lastSelectionSetup: String?
    @ObservationIgnored private var manualSelection = false
    @ObservationIgnored private var activeAutomatic = false
    @ObservationIgnored private var temporaryMapping = false
    @ObservationIgnored private var suppressionUntil = Date.distantPast
    @ObservationIgnored private var windowReferences: [UUID: UUID] = [:]
    @ObservationIgnored private var sessionApprovedMappings: [UUID: DisplayMapping] = [:]
    @ObservationIgnored private var undoPlacements: [PlannedPlacement] = []
    @ObservationIgnored private var undoTopology: DisplayTopology?
    @ObservationIgnored private var undoDesktopSnapshot: DesktopSnapshot?
    // Undo belongs to the apply that produced it, even if another layout is selected later.
    @ObservationIgnored private var undoLayoutID: UUID?
    @ObservationIgnored private var activeApplyGeneration: UInt64?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var lastRecoveryWrite = Date.distantPast
    @ObservationIgnored private var autoLearningReady = false
    @ObservationIgnored private var learningRequestID: UUID?
    @ObservationIgnored private var layoutEditorSessions: [UUID: UUID] = [:]
    @ObservationIgnored private var deferredEditorReconcile = false

    public init(displays: any TopologyProviding, accessibility: any WindowAccessing,
                permission: any PermissionChecking, launcher: any ApplicationLaunching,
                repository: any LibraryStoring, clock: any RestoreClock = SystemRestoreClock(),
                timing: CoordinatorTiming = CoordinatorTiming()) {
        self.displays = displays; self.accessibility = accessibility; self.permission = permission
        self.launcher = launcher; self.repository = repository; self.clock = clock; self.timing = timing
    }
    public func start() async {
        guard !started else { return }
        started = true
        do { library = try await repository.load() }
        catch { storageAvailable = false; errorMessage = error.localizedDescription }
        permissionGranted = permission.isTrusted
        scheduleStabilization(forceReconcile: true)
    }
    public func stop() {
        gate.invalidate(); settleTask?.cancel(); restoreTask?.cancel(); learnTask?.cancel()
        state = .suspended
    }
    public func clearError() { errorMessage = nil }
    public func reportError(_ message: String) { errorMessage = message }
    @discardableResult public func beginLayoutEditing(layoutID: UUID, sessionID: UUID) -> Bool {
        guard storageAvailable, state != .restoring,
              library.layouts.contains(where: { $0.id == layoutID }) else { return false }
        if layoutEditorSessions[sessionID] == layoutID { return true }
        layoutEditorSessions[sessionID] = layoutID
        learnTask?.cancel(); learningRequestID = nil
        // Settling owns its generation; let it discover displays and defer applying.
        if state != .settling { gate.invalidate() }
        return true
    }
    public func endLayoutEditing(sessionID: UUID) {
        guard layoutEditorSessions.removeValue(forKey: sessionID) != nil, layoutEditorSessions.isEmpty else { return }
        if deferredEditorReconcile {
            deferredEditorReconcile = false
            scheduleStabilization(forceReconcile: true)
        } else { scheduleLearning() }
    }
    @discardableResult public func commitLayoutEdit(_ draft: LayoutEditDraft) -> Bool {
        guard storageAvailable, layoutEditorSessions.values.contains(draft.layoutID), state != .restoring,
              let current = library.layouts.first(where: { $0.id == draft.layoutID }) else {
            errorMessage = "Reopen the layout editor before saving these changes."; return false
        }
        guard (current.remembered ?? current.saved) == draft.sourceRevision, current.topology == draft.topology else {
            errorMessage = "This layout changed while you were editing it. Reopen the editor to use its latest arrangement."; return false
        }
        guard draft.hasChanges else { return true }
        let revision: LayoutRevision
        do { revision = try draft.validatedRevision() }
        catch { errorMessage = error.localizedDescription; return false }
        // Offline edits replace the baseline, but preserve both prior revisions.
        updateLibrary { library in
            guard let index = library.layouts.firstIndex(where: { $0.id == draft.layoutID }) else { return }
            var history = current.history
            for old in [current.saved] + [current.remembered].compactMap({ $0 }) {
                history.removeAll { $0.id == old.id }; history.append(old)
            }
            library.layouts[index].history = Array(history.suffix(10))
            library.layouts[index].saved = revision
            library.layouts[index].remembered = nil
            library.layouts[index].editedAwaitingApply = true
        }
        guard library.layouts.first(where: { $0.id == draft.layoutID })?.saved.id == revision.id else { return false }
        // A saved edit waits for Apply on its own setup. A different setup that
        // connected while editing must still get its deferred automatic restore.
        let automaticID = library.settings.autoModeEnabled
            ? AutoModePolicy.layout(for: topology, library: library, selectedLayoutID: selectedLayoutID)?.id
            : (selectedLayoutID ?? library.preferredLayouts[topology.setupKey])
        if topology.setupKey == draft.topology.setupKey, automaticID == draft.layoutID { deferredEditorReconcile = false }
        return true
    }
    @discardableResult public func updateLibrary(_ change: (inout Library) -> Void) -> Bool {
        guard storageAvailable else { errorMessage = "Your library is protected after a load failure. Resolve the reported storage problem before saving."; return false }
        var candidate = library
        change(&candidate)
        // Accept only a library that can be persisted and loaded again. Structural
        // validation alone misses the serialized size limit (including history).
        do { _ = try LayoutRepository.encode(candidate) }
        catch { errorMessage = error.localizedDescription; return false }
        let changedLayoutExclusions = candidate.layouts.contains { next in
            library.layouts.first(where: { $0.id == next.id }).map {
                $0.excludedBundleIDs != next.excludedBundleIDs || $0.options != next.options
            } ?? false
        }
        let changedGlobalExclusions = candidate.exclusions != library.exclusions
        let changedArrangements = candidate.layouts.contains { next in
            library.layouts.first(where: { $0.id == next.id }).map {
                $0.saved != next.saved || ($0.editedAwaitingApply != next.editedAwaitingApply && next.editedAwaitingApply)
            } ?? false
        }
        let enabledCurrentAutoLayout = candidate.layouts.contains { next in
            next.id == candidate.autoLayoutIDs[topology.setupKey] && next.options.autoModeEnabled
                && library.layouts.first(where: { $0.id == next.id })?.options.autoModeEnabled == false
        }
        var restartSettling = false
        if changedLayoutExclusions || changedGlobalExclusions || changedArrangements || (selectedLayoutID != nil && !candidate.layouts.contains(where: { $0.id == selectedLayoutID })) {
            restartSettling = state == .settling
            gate.invalidate(); restoreTask?.cancel(); learnTask?.cancel()
            if state == .restoring { state = permission.isTrusted ? .idle : .permissionRequired }
        }
        library = candidate
        persist()
        if library.settings.autoModeEnabled && enabledCurrentAutoLayout { scheduleStabilization(forceReconcile: true) }
        else if restartSettling { scheduleStabilization() }
        else if changedLayoutExclusions || changedGlobalExclusions { scheduleLearning() }
        return true
    }
    private func persist() {
        // Await each previous write before issuing the next: actor arrival order must not depend on task scheduling.
        let previous = saveTask
        let value = library
        saveTask = Task { [weak self, repository] in
            await previous?.value
            do { try await repository.save(value) }
            catch { self?.errorMessage = "Could not save layouts: \(error.localizedDescription)" }
        }
    }
    public func flushPersistence() async { await saveTask?.value }
    public func setAutomatic(_ enabled: Bool) {
        updateLibrary { $0.settings.automaticSwitching = enabled }
        if library.settings.autoModeEnabled { return }
        if !enabled {
            // Manual work remains higher priority than this settings change.
            if activeAutomatic || (state != .restoring && pendingManual == nil) {
                gate.invalidate(); settleTask?.cancel(); restoreTask?.cancel(); learnTask?.cancel()
                if !isSuspended { state = permission.isTrusted ? .idle : .permissionRequired }
            }
        } else { scheduleStabilization(forceReconcile: true) }
    }
    /// Auto mode is opt-in and independent of the older restore-only preference.
    public func setAutoMode(_ enabled: Bool) {
        guard enabled != library.settings.autoModeEnabled else { return }
        updateLibrary { $0.settings.autoModeEnabled = enabled }
        guard library.settings.autoModeEnabled == enabled else { return }
        autoLearningReady = false
        if enabled {
            if state != .restoring || activeAutomatic { scheduleStabilization(forceReconcile: true) }
        } else {
            learnTask?.cancel()
            if activeAutomatic || (state != .restoring && pendingManual == nil) {
                gate.invalidate(); settleTask?.cancel(); restoreTask?.cancel()
                if !isSuspended { state = permission.isTrusted ? .idle : .permissionRequired }
            }
        }
    }
    public func setAutoLayout(layoutID: UUID) {
        guard let layout = library.layouts.first(where: { $0.id == layoutID }), !layout.importedNeedsMapping else { return }
        updateLibrary { $0.autoLayoutIDs[layout.topology.setupKey] = layoutID }
        if library.settings.autoModeEnabled, layout.topology.setupKey == topology.setupKey {
            autoLearningReady = false
            scheduleStabilization(forceReconcile: true)
        }
    }
    /// A low-frequency fallback catches Space edits for which macOS sends no AX event.
    public func pollAutoMode() {
        guard library.settings.autoModeEnabled, learningRequestID == nil else { return }
        scheduleLearning()
    }
    private var isSuspended: Bool { sleeping || screenSleeping || sessionInactive }
    public func handle(_ event: RestoreEvent) {
        switch event {
        case .sleep: sleeping = true; suspend()
        case .screenSleep: screenSleeping = true; suspend()
        case .sessionInactive: sessionInactive = true; suspend()
        case .wake: sleeping = false; scheduleStabilization(grace: timing.wakeGrace, forceReconcile: true)
        case .screenWake: screenSleeping = false; scheduleStabilization(grace: timing.wakeGrace, forceReconcile: true)
        case .sessionActive: sessionInactive = false; scheduleStabilization(grace: timing.wakeGrace, forceReconcile: true)
        case .displayChanged, .lidChanged:
            sessionApprovedMappings = [:]
            activeDisplayMapping = nil
            scheduleStabilization()
        case .permissionChanged:
            let granted = permission.isTrusted
            let changed = granted != permissionGranted
            permissionGranted = granted
            if !granted {
                // Topology discovery does not require AX permission. An activation
                // notification during onboarding must not cancel initial settling.
                if changed || state == .restoring {
                    let wasSettling = state == .settling
                    gate.invalidate(); restoreTask?.cancel(); learnTask?.cancel()
                    if wasSettling { scheduleStabilization() }
                    else { state = .permissionRequired }
                } else if state != .settling && state != .waiting && state != .suspended { state = .permissionRequired }
            }
            else if changed { scheduleStabilization(forceReconcile: true) }
        case .applicationsChanged, .windowsChanged:
            // Late windows are handled only by the bounded active restoration session.
            // Ordinary window movement schedules learning, never another restore.
            scheduleLearning()
        }
    }
    private func suspend() {
        gate.invalidate(); settleTask?.cancel(); restoreTask?.cancel(); learnTask?.cancel()
        pendingManual = nil; state = .suspended
        logger.info("Restoration suspended")
    }
    private func permissionDenied() {
        permissionGranted = false
        gate.invalidate(); restoreTask?.cancel(); learnTask?.cancel()
        state = .permissionRequired
    }
    private func scheduleStabilization(grace: Duration? = nil, forceReconcile: Bool = false) {
        if state == .restoring, !activeAutomatic, pendingManual == nil, let selectedLayoutID {
            pendingManual = (selectedLayoutID, nil, activeWindowScope)
        }
        let generation = gate.invalidate()
        autoLearningReady = false
        settleTask?.cancel(); restoreTask?.cancel(); learnTask?.cancel()
        if isSuspended { state = .suspended; return }
        state = .settling
        settleTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await clock.sleep(for: grace ?? timing.quietPeriod)
                var previous: DisplayTopology?
                for _ in 0..<timing.maxObservations {
                    guard gate.isValid(generation), !Task.isCancelled, !isSuspended else { return }
                    let observed = displays.snapshot()
                    if let previous, observed.isEquivalent(to: previous), !observed.surfaces.isEmpty {
                        stable(observed, forceReconcile: forceReconcile)
                        return
                    }
                    previous = observed
                    try await clock.sleep(for: timing.observationInterval)
                }
                guard gate.isValid(generation) else { return }
                state = .waiting
                logger.notice("Display stabilization reached its observation limit")
            } catch { /* Newer events own the state. */ }
        }
    }
    private func stable(_ observed: DisplayTopology, forceReconcile: Bool) {
        let identityChanged = topology.setupKey != observed.setupKey
        let geometryChanged = topology.geometryKey != observed.geometryKey
        topology = observed
        permissionGranted = permission.isTrusted
        state = permissionGranted ? .idle : .permissionRequired
        if identityChanged {
            selectedLayoutID = nil; manualSelection = false; temporaryMapping = false
            outcomes = []; desktopIssues = []; desktopSummary = nil; windowReferences = [:]
        }
        if !layoutEditorSessions.isEmpty {
            deferredEditorReconcile = deferredEditorReconcile || ((identityChanged || geometryChanged || forceReconcile)
                && (library.settings.autoModeEnabled || library.settings.automaticSwitching))
            return
        }
        if let pending = pendingManual {
            pendingManual = nil
            requestApply(layoutID: pending.0, mapping: pending.1, automatic: false, windowScope: pending.2)
            return
        }
        if library.settings.autoModeEnabled {
            guard permissionGranted else { return }
            if let layout = AutoModePolicy.layout(for: observed, library: library, selectedLayoutID: selectedLayoutID) {
                if library.autoLayoutIDs[observed.setupKey] != layout.id {
                    updateLibrary { $0.autoLayoutIDs[observed.setupKey] = layout.id }
                }
                // Keep the chosen preset even when opted out: don't create a replacement.
                guard layout.options.autoModeEnabled else { return }
                requestApply(layoutID: layout.id, automatic: true)
            } else if library.autoLayoutIDs[observed.setupKey] == nil, !observed.hasAmbiguousIdentity {
                autoLearningReady = true
                scheduleLearning()
            }
            return
        }
        guard permissionGranted, library.settings.automaticSwitching,
              identityChanged || geometryChanged || forceReconcile else { scheduleLearning(); return }
        if let selected = selectedLayout, SetupMatcher.compatible(selected, with: observed), lastSelectionSetup == observed.setupKey {
            requestApply(layoutID: selected.id, automatic: true)
        } else {
            let preferred = library.preferredLayouts[observed.setupKey]
                ?? library.layouts.first { layout in
                    library.preferredLayouts.values.contains(layout.id) && SetupMatcher.compatible(layout, with: observed)
                }?.id
            if let preferred { requestApply(layoutID: preferred, automatic: true) }
            else { scheduleLearning() }
        }
    }
    public func isCompatible(_ layout: Layout) -> Bool {
        guard !layout.importedNeedsMapping, resolvedMapping(for: layout) != nil else { return false }
        if SetupMatcher.compatible(layout, with: topology) { return true }
        // Ambiguous outputs can be used within the explicitly confirmed, unchanged
        // connection session. Reconfiguration always clears this approval.
        return layout.topology.setupKey == topology.setupKey && sessionApprovedMappings[layout.id] != nil
    }
    /// Explicit applies can reuse a recognizable display in a different setup.
    /// Keep this separate from automatic setup selection and adjustment learning.
    public func manualMapping(for layout: Layout, windowScope: Set<UUID>? = nil) -> [String: String]? {
        guard !layout.importedNeedsMapping else { return nil }
        if let approved = resolvedMapping(for: layout) { return approved }
        if let windowScope {
            let required = Set(layout.effectiveWindows.filter { windowScope.contains($0.id) }.map(\.displayID))
            guard !required.isEmpty else { return nil }
            let suggestions = SetupMatcher.suggestedMapping(for: layout, to: topology).filter { required.contains($0.key) }
            return Set(suggestions.keys) == required ? suggestions : nil
        }
        return SetupMatcher.manualMapping(for: layout, to: topology)
    }
    private func resolvedMapping(for layout: Layout) -> [String: String]? {
        let approved: DisplayMapping?
        if topology.hasAmbiguousIdentity || layout.topology.hasAmbiguousIdentity {
            // Indistinguishable outputs must be confirmed again after a reconfiguration or restart.
            approved = sessionApprovedMappings[layout.id]
        } else {
            approved = library.displayMappings.first { $0.layoutID == layout.id && $0.targetSetupKey == topology.setupKey }
        }
        return SetupMatcher.mapping(for: layout, to: topology, approved: approved)
    }
    public func confirmMapping(_ mapping: DisplayMapping) {
        sessionApprovedMappings[mapping.layoutID] = mapping
        updateLibrary { library in
            library.displayMappings.removeAll { $0.layoutID == mapping.layoutID && $0.targetSetupKey == mapping.targetSetupKey }
            library.displayMappings.append(mapping)
        }
    }
    public func selectSavedLayout(_ id: UUID, references: [UUID: UUID] = [:]) {
        selectedLayoutID = id; lastSelectionSetup = topology.setupKey
        manualSelection = true; temporaryMapping = false; outcomes = []; desktopIssues = []; desktopSummary = nil
        windowReferences = references
        activeDisplayMapping = nil
        if library.settings.autoModeEnabled, let layout = selectedLayout, isCompatible(layout), layout.topology.setupKey == topology.setupKey {
            updateLibrary { $0.autoLayoutIDs[topology.setupKey] = id }
            autoLearningReady = true
        }
        scheduleLearning()
    }
    public func assignReference(savedID: UUID, liveID: UUID) { windowReferences[savedID] = liveID }
    /// Returns true only when this exact request started or was explicitly queued for settling.
    @discardableResult public func requestApply(layoutID: UUID, mapping: [String: String]? = nil, automatic: Bool = false, retryOnly: Set<UUID>? = nil, windowScope: Set<UUID>? = nil) -> Bool {
        guard layoutEditorSessions.isEmpty else {
            if !automatic { errorMessage = "Finish editing the saved layout before applying an arrangement." }
            return false
        }
        guard let layout = library.layouts.first(where: { $0.id == layoutID }) else { return false }
        if automatic && (layout.importedNeedsMapping || (library.settings.autoModeEnabled
            ? !layout.options.autoModeEnabled : !library.settings.automaticSwitching)) { return false }
        if !automatic { manualSelection = true }
        guard !isSuspended else { errorMessage = "Wait until the Mac and its displays are awake."; return false }
        permissionGranted = permission.isTrusted
        guard permissionGranted else { gate.invalidate(); state = .permissionRequired; return false }
        let current = displays.snapshot()
        guard !current.surfaces.isEmpty else { scheduleStabilization(); return false }
        if !current.isEquivalent(to: topology) || state == .settling || state == .waiting {
            if !automatic { pendingManual = (layoutID, mapping, windowScope) }
            scheduleStabilization()
            return !automatic
        }
        guard let resolved = mapping ?? (automatic ? resolvedMapping(for: layout) : manualMapping(for: layout, windowScope: windowScope)) else {
            if !automatic { errorMessage = "Assign each saved display to a current display before applying this layout." }
            return false
        }
        guard resolved.values.allSatisfy({ id in topology.surfaces.contains { $0.id == id } }) else {
            errorMessage = "The selected displays are no longer available."; return false
        }
        let generation = gate.invalidate()
        settleTask?.cancel(); restoreTask?.cancel(); learnTask?.cancel()
        activeApplyGeneration = generation
        selectedLayoutID = layoutID; lastSelectionSetup = topology.setupKey
        activeWindowScope = windowScope
        activeDisplayMapping = (layoutID, topology, resolved)
        temporaryMapping = windowScope != nil || !isCompatible(layout) || resolved.contains(where: { $0.key != $0.value })
        autoLearningReady = false
        if library.settings.autoModeEnabled, !temporaryMapping, layout.topology.setupKey == topology.setupKey {
            updateLibrary { $0.autoLayoutIDs[topology.setupKey] = layoutID }
        }
        state = .restoring
        desktopIssues = []; desktopSummary = nil
        activeAutomatic = automatic
        logger.info("Restore requested; generation \(generation), automatic \(automatic)")
        restoreTask = Task { [weak self] in
            guard let self else { return }
            await execute(layout: layout, mapping: resolved, generation: generation, automatic: automatic, retryOnly: retryOnly, windowScope: windowScope)
        }
        return true
    }
    public func waitForRestoration() async { await restoreTask?.value }
    public func waitForSettling() async { await settleTask?.value; await restoreTask?.value }
    public func captureCurrent() async -> (DisplayTopology, WindowCapture)? {
        guard layoutEditorSessions.isEmpty else { errorMessage = "Finish editing the saved layout before capturing current windows."; return nil }
        guard permission.isTrusted else { permissionGranted = false; state = .permissionRequired; return nil }
        guard state == .idle, !isSuspended, !topology.surfaces.isEmpty else {
            errorMessage = "Wait for the displays to settle before saving."; return nil
        }
        let generation = gate.current
        let before = displays.snapshot()
        guard before.isEquivalent(to: topology) else { scheduleStabilization(); return nil }
        let capture = await accessibility.capture(exclusions: library.exclusions)
        guard gate.isValid(generation), before.isEquivalent(to: displays.snapshot()), state == .idle else {
            errorMessage = "The display setup changed during capture. Your saved layouts are unchanged."; return nil
        }
        guard capture.permissionGranted else { permissionDenied(); return nil }
        guard !capture.windows.isEmpty else { errorMessage = "No eligible windows were found. Open an ordinary application window and try again."; return nil }
        return (before, capture)
    }
    private func execute(layout: Layout, mapping: [String: String], generation: UInt64, automatic: Bool, retryOnly: Set<UUID>?, windowScope: Set<UUID>?) async {
        // Limit matching, application launching and writes to the requested windows.
        // Keep the stored layout intact so a one-display apply cannot erase membership.
        let originalLayout = layout
        var layout = AutoModePolicy.restorationLayout(layout)
        let excludedBundles = layout.excludedBundleIDs
        layout.saved.windows.removeAll { excludedBundles.contains($0.identity.bundleID) }
        if let windowScope {
            layout.saved.windows.removeAll { !windowScope.contains($0.id) }
            layout.remembered?.windows.removeAll { !windowScope.contains($0.id) }
        }
        layout.remembered?.windows.removeAll { excludedBundles.contains($0.identity.bundleID) }
        let targetTopology = topology
        var capture = await accessibility.capture(exclusions: library.exclusions)
        guard valid(generation, topology: targetTopology) else { return }
        guard capture.permissionGranted else { permissionDenied(); return }
        // The pre-apply capture is taken before launching or writing. Never substitute a post-disconnect capture.
        let before = Dictionary(uniqueKeysWithValues: capture.windows.map { ($0.id, $0) })
        var beforeDesktops = capture.desktopSnapshot
        // A desktop snapshot is paired with the same saved/remembered revision as
        // its windows. A display-scoped apply cannot create or switch other displays.
        var savedDesktops = layout.options.restoreDesktops ? layout.effectiveDesktopSnapshot : nil
        let requiredDisplays = Set(layout.effectiveWindows.map(\.displayID))
        let desktopMapping = windowScope == nil ? mapping : mapping.filter { requiredDisplays.contains($0.key) }
        if windowScope != nil, savedDesktops?.separateDisplays == true {
            savedDesktops?.displays.removeAll { !requiredDisplays.contains($0.displayID) }
            let affectedTargets = Set(desktopMapping.values)
            beforeDesktops?.displays.removeAll { !affectedTargets.contains($0.displayID) }
        }
        if layout.options.launchMissingApplications {
            let launchable = layout.effectiveWindows.filter { saved in
                (retryOnly?.contains(saved.id) ?? true)
                    && !library.exclusions.contains(where: { $0.excludes(saved.identity) })
            }
            let missing = Set(launchable.map { $0.identity.bundleID }).subtracting(capture.runningBundleIDs)
            if !missing.isEmpty {
                _ = await launcher.launch(bundleIDs: missing)
                guard valid(generation, topology: targetTopology) else { return }
            }
        }
        // Bounded late-window handling belongs only to this restore session. It also
        // covers already-running applications that create their windows after docking.
        for _ in 0..<timing.launchRetries {
            let matches = WindowMatcher.match(saved: layout.effectiveWindows, live: capture.windows, references: windowReferences)
            let pending = layout.effectiveWindows.contains { saved in
                matches.matches[saved.id] == nil && !matches.ambiguous.contains(saved.id)
                    && (retryOnly?.contains(saved.id) ?? true)
                    && !library.exclusions.contains(where: { $0.excludes(saved.identity) })
                    && !capture.issues.contains(where: { $0.bundleID == saved.identity.bundleID })
                    && (layout.options.launchMissingApplications || capture.runningBundleIDs.contains(saved.identity.bundleID))
            }
            guard pending else { break }
            do { try await clock.sleep(for: .milliseconds(600)) } catch { return }
            guard valid(generation, topology: targetTopology) else { return }
            capture = await accessibility.capture(exclusions: library.exclusions)
            guard capture.permissionGranted else { permissionDenied(); return }
        }
        guard valid(generation, topology: targetTopology) else { return }
        guard capture.permissionGranted else { permissionDenied(); return }
        var desktopPreparation = DesktopPreparation()
        let desktopCapability = savedDesktops != nil ? await accessibility.desktopRestorationCapability() : .available
        guard valid(generation, topology: targetTopology) else { return }
        let canRestoreDesktops = desktopCapability.isAvailable && beforeDesktops != nil
        let desktopLimitation = desktopCapability.limitation
            ?? (beforeDesktops == nil ? "Current desktops could not be captured reliably. Only window positions will be restored." : nil)
        if let savedDesktops {
            // Retain the original active desktops before the first asynchronous
            // creation, including if that operation is interrupted after a mutation.
            if canRestoreDesktops, let beforeDesktops, activeApplyGeneration == generation {
                undoPlacements = []; undoTopology = targetTopology; undoDesktopSnapshot = beforeDesktops
                undoLayoutID = layout.id; canUndo = true
            }
            if canRestoreDesktops {
                desktopPreparation = await accessibility.prepareDesktops(savedDesktops, mapping: desktopMapping,
                    generation: generation, gate: gate, automatic: automatic)
            } else {
                desktopPreparation.issues = [desktopLimitation ?? "Desktop restoration is unavailable."]
            }
            guard valid(generation, topology: targetTopology) else { return }
            desktopIssues = desktopPreparation.issues
            desktopSummary = canRestoreDesktops ? "Restoring \(savedDesktops.desktopCount) desktops" : "Desktop restoration unavailable"
        }
        var plan = RestorePlanner.plan(layout: layout, topology: targetTopology, capture: capture, generation: generation,
                                       mapping: mapping, references: windowReferences, exclusions: library.exclusions)
        if let retryOnly {
            plan.placements.removeAll { !retryOnly.contains($0.savedWindow.id) }
            plan.unresolved.removeAll { !retryOnly.contains($0.id) }
        }
        var results = plan.unresolved
        var undo: [PlannedPlacement] = []
        for placement in plan.placements {
            guard valid(generation, topology: targetTopology) else {
                results.append(.init(id: placement.savedWindow.id, appName: placement.savedWindow.identity.appName, kind: .cancelled, explanation: "The setup or restore request changed."))
                break
            }
            var desktopMove: DesktopMoveResult?
            if savedDesktops != nil {
                if !canRestoreDesktops {
                    desktopMove = .init(succeeded: false, message: desktopLimitation)
                } else if let original = before[placement.liveWindow.id], original.desktopAssignment == nil {
                    desktopMove = .init(succeeded: false, message: "The window’s original desktop is unknown; its membership was left unchanged.")
                } else if let assignment = placement.savedWindow.desktopAssignment {
                    desktopMove = await accessibility.moveToDesktop(placement.liveWindow, assignment: assignment,
                        destinations: desktopPreparation.destinations, generation: generation, gate: gate, automatic: automatic)
                } else {
                    desktopMove = .init(succeeded: false, message: "The saved desktop for this window is unknown. Update the layout to capture it.")
                }
            }
            // A Space move is itself a mutation. Keep it undoable even if permission
            // is revoked before geometry can be restored.
            if desktopMove?.didMutate == true, let original = before[placement.liveWindow.id], activeApplyGeneration == generation {
                var inverse = placement
                inverse.targetFrame = original.frame
                inverse.savedWindow.desktopAssignment = original.desktopAssignment
                undo.append(inverse)
                undoPlacements = undo; undoTopology = targetTopology; undoDesktopSnapshot = beforeDesktops
                undoLayoutID = layout.id; canUndo = true
            }
            guard valid(generation, topology: targetTopology) else { return }
            var result = await accessibility.place(placement, generation: generation, gate: gate, automatic: automatic)
            if desktopMove?.succeeded == true, let assignment = placement.savedWindow.desktopAssignment,
               gate.isValid(generation) {
                let verified = await accessibility.verifyDesktop(placement.liveWindow, assignment: assignment,
                    destinations: desktopPreparation.destinations, generation: generation, gate: gate)
                if !verified.succeeded {
                    desktopMove = .init(succeeded: false, didMutate: desktopMove?.didMutate ?? false, message: verified.message)
                }
            }
            if let desktopMove, !desktopMove.succeeded, gate.isValid(generation) {
                let message = desktopMove.message ?? "The window’s desktop could not be restored."
                desktopIssues.append("\(placement.savedWindow.identity.appName): \(message)")
                if result.kind.succeeded {
                    result.kind = .unsupported
                    result.explanation = "Window position restored. " + message
                } else {
                    result.explanation += " " + message
                }
            }
            result.didMutate = result.didMutate || (desktopMove?.didMutate ?? false)
            results.append(result)
            if result.kind.succeeded, gate.isValid(generation) {
                windowReferences[placement.savedWindow.id] = placement.liveWindow.id
            }
            if result.didMutate || (result.kind.succeeded && result.kind != .alreadyPositioned),
               let original = before[placement.liveWindow.id] {
                var current = placement.liveWindow
                current.frame = result.actualFrame ?? placement.targetFrame
                var inverseSaved = placement.savedWindow
                inverseSaved.desktopAssignment = original.desktopAssignment
                undo.removeAll { $0.liveWindow.id == current.id }
                undo.append(.init(savedWindow: inverseSaved, liveWindow: current, targetFrame: original.frame))
                // Keep recovery available if permission or topology invalidates this
                // session after a partial write. A newer apply exclusively owns its undo.
                if activeApplyGeneration == generation {
                    undoPlacements = undo; undoTopology = targetTopology
                    undoDesktopSnapshot = savedDesktops != nil && canRestoreDesktops ? beforeDesktops : nil
                    undoLayoutID = layout.id; canUndo = true
                }
            }
        }
        if let savedDesktops, valid(generation, topology: targetTopology) {
            if canRestoreDesktops {
                desktopIssues += await accessibility.restoreActiveDesktops(savedDesktops, destinations: desktopPreparation.destinations,
                    generation: generation, gate: gate, automatic: automatic)
            }
            desktopIssues = Array(Set(desktopIssues)).sorted()
            desktopSummary = !canRestoreDesktops ? "Desktop restoration unavailable"
                : desktopIssues.isEmpty ? "\(savedDesktops.desktopCount) desktops restored" : "Desktops partially restored"
        }
        guard gate.isValid(generation) else { return }
        var completedEditedLayout = originalLayout.editedAwaitingApply && permission.isTrusted
            && windowScope == nil && retryOnly == nil && !temporaryMapping
            && (originalLayout.effectiveDesktopSnapshot == nil || originalLayout.options.restoreDesktops)
            && targetTopology.setupKey == originalLayout.topology.setupKey
            && results.allSatisfy { $0.kind.succeeded } && desktopIssues.isEmpty
            && library.layouts.first(where: { $0.id == originalLayout.id })?.saved.id == originalLayout.saved.id
        var reboundDesktops: DesktopSnapshot?
        if completedEditedLayout, let savedSnapshot = originalLayout.effectiveDesktopSnapshot {
            // Logical desktop groups were applied into native ordinal slots. Rebind
            // UUID hints so Auto follows those groups rather than their old Spaces.
            let after = await accessibility.capture(exclusions: library.exclusions)
            guard valid(generation, topology: targetTopology) else { return }
            if after.isComplete, let captured = after.desktopSnapshot {
                reboundDesktops = AutoLearningPolicy.rebindingDesktopHints(savedSnapshot, afterRestore: captured, topology: targetTopology)
            }
            completedEditedLayout = reboundDesktops != nil
            if !completedEditedLayout {
                desktopIssues.append("Saved edits are protected because desktop identities could not be verified after restoration.")
            }
        }
        if let retryOnly { outcomes.removeAll { retryOnly.contains($0.id) }; outcomes.append(contentsOf: results) }
        else { outcomes = results }
        undoPlacements = undo; undoTopology = targetTopology
        undoDesktopSnapshot = savedDesktops != nil && canRestoreDesktops ? beforeDesktops : nil
        canUndo = !undo.isEmpty || undoDesktopSnapshot != nil
        undoLayoutID = canUndo ? layout.id : nil
        suppressionUntil = clock.now().addingTimeInterval(timing.writeSuppression)
        permissionGranted = permission.isTrusted
        state = permissionGranted ? .idle : .permissionRequired
        autoLearningReady = !temporaryMapping && results.allSatisfy { $0.kind.succeeded || $0.kind == .missingApplication } && desktopIssues.isEmpty
        if completedEditedLayout {
            updateLibrary { library in
                if let index = library.layouts.firstIndex(where: { $0.id == layout.id }) {
                    if let reboundDesktops { library.layouts[index].saved.desktopSnapshot = reboundDesktops }
                    library.layouts[index].editedAwaitingApply = false
                }
            }
        }
        logger.info("Restore finished; \(results.filter { $0.kind.succeeded }.count) succeeded, \(results.filter { !$0.kind.succeeded }.count) unresolved")
        scheduleLearning()
    }
    private func valid(_ generation: UInt64, topology expected: DisplayTopology) -> Bool {
        guard gate.isValid(generation), !Task.isCancelled, !isSuspended else { return false }
        guard permission.isTrusted else { handle(.permissionChanged); return false }
        guard expected.isEquivalent(to: displays.snapshot()) else { scheduleStabilization(); return false }
        return true
    }
    public func retryUnresolved() {
        guard let id = selectedLayoutID else { return }
        let ids = Set(outcomes.filter { !$0.kind.succeeded }.map(\.id))
        guard !ids.isEmpty || !desktopIssues.isEmpty else { return }
        let mapping: [String: String]?
        if let activeDisplayMapping, activeDisplayMapping.layoutID == id,
           activeDisplayMapping.topology.isEquivalent(to: topology), topology.isEquivalent(to: displays.snapshot()) {
            mapping = activeDisplayMapping.assignments
        } else { mapping = nil }
        requestApply(layoutID: id, mapping: mapping, retryOnly: ids.isEmpty ? nil : ids, windowScope: activeWindowScope)
    }
    public func undo() async {
        guard layoutEditorSessions.isEmpty else { errorMessage = "Finish editing the saved layout before undoing a restore."; return }
        guard let expected = undoTopology, canUndo else { return }
        guard expected.isEquivalent(to: displays.snapshot()), expected.isEquivalent(to: topology), !isSuspended else {
            errorMessage = "Undo is available only on the display arrangement where the layout was applied."; return
        }
        let generation = gate.invalidate()
        settleTask?.cancel(); restoreTask?.cancel(); learnTask?.cancel(); state = .restoring; activeAutomatic = false
        let undoOwner = library.layouts.first { $0.id == undoLayoutID }
        let ownerExclusions = undoOwner?.excludedBundleIDs ?? []
        let includedWindowIDs = undoOwner.map { Set(AutoModePolicy.restorationLayout($0).effectiveWindows.map(\.id)) }
        let capture = await accessibility.capture(exclusions: library.exclusions + ownerExclusions.map { WindowExclusion(bundleID: $0) })
        guard capture.permissionGranted else { permissionDenied(); return }
        guard valid(generation, topology: expected) else { return }
        desktopIssues = []; desktopSummary = nil
        var desktopPreparation = DesktopPreparation()
        let originalDesktops = undoDesktopSnapshot
        let desktopCapability = originalDesktops != nil ? await accessibility.desktopRestorationCapability() : .available
        guard valid(generation, topology: expected) else { return }
        let canRestoreDesktops = desktopCapability.isAvailable && capture.desktopSnapshot != nil
        let desktopLimitation = desktopCapability.limitation
            ?? (capture.desktopSnapshot == nil ? "Current desktops could not be captured reliably. Only window positions will be restored." : nil)
        if let originalDesktops {
            if canRestoreDesktops {
                let mapping = Dictionary(uniqueKeysWithValues: expected.surfaces.map { ($0.id, $0.id) })
                desktopPreparation = await accessibility.prepareDesktops(originalDesktops, mapping: mapping,
                    generation: generation, gate: gate, automatic: false)
            } else {
                desktopPreparation.issues = [desktopLimitation ?? "Desktop restoration is unavailable."]
            }
            guard valid(generation, topology: expected) else { return }
            desktopIssues = desktopPreparation.issues
        }
        var results: [WindowOutcome] = []
        for original in undoPlacements {
            guard valid(generation, topology: expected) else { return }
            guard includedWindowIDs?.contains(original.savedWindow.id) ?? true else { continue }
            guard let live = capture.windows.first(where: { $0.id == original.liveWindow.id && $0.instance == original.liveWindow.instance }),
                  !(library.layouts.first { $0.id == undoLayoutID }?.excludedBundleIDs.contains(live.identity.bundleID) ?? false),
                  !library.exclusions.contains(where: { $0.excludes(live.identity) }) else { continue }
            var placement = original; placement.liveWindow = live
            var desktopMove: DesktopMoveResult?
            if originalDesktops != nil, let assignment = original.savedWindow.desktopAssignment {
                if canRestoreDesktops {
                    desktopMove = await accessibility.moveToDesktop(live, assignment: assignment,
                        destinations: desktopPreparation.destinations, generation: generation, gate: gate, automatic: false)
                } else {
                    desktopMove = .init(succeeded: false, message: desktopLimitation)
                }
            }
            guard valid(generation, topology: expected) else { return }
            var result = await accessibility.place(placement, generation: generation, gate: gate, automatic: false)
            if desktopMove?.succeeded == true, let assignment = original.savedWindow.desktopAssignment,
               gate.isValid(generation) {
                let verified = await accessibility.verifyDesktop(live, assignment: assignment,
                    destinations: desktopPreparation.destinations, generation: generation, gate: gate)
                if !verified.succeeded { desktopMove = verified }
            }
            if let desktopMove, !desktopMove.succeeded {
                let message = desktopMove.message ?? "The original desktop could not be restored."
                desktopIssues.append("\(live.identity.appName): \(message)")
                if result.kind.succeeded { result.kind = .unsupported; result.explanation = message }
            }
            results.append(result)
        }
        if let originalDesktops, valid(generation, topology: expected) {
            if canRestoreDesktops {
                desktopIssues += await accessibility.restoreActiveDesktops(originalDesktops, destinations: desktopPreparation.destinations,
                    generation: generation, gate: gate, automatic: false)
            }
            desktopIssues = Array(Set(desktopIssues)).sorted()
            desktopSummary = !canRestoreDesktops ? "Desktop restoration unavailable"
                : desktopIssues.isEmpty ? "Original desktops restored" : "Desktops partially restored"
        }
        guard gate.isValid(generation) else { return }
        outcomes = results; canUndo = false; undoPlacements = []; undoLayoutID = nil; undoDesktopSnapshot = nil
        suppressionUntil = clock.now().addingTimeInterval(timing.writeSuppression)
        state = .idle
    }
    private func scheduleLearning() {
        learnTask?.cancel()
        learningRequestID = nil
        guard layoutEditorSessions.isEmpty, state == .idle, !isSuspended, permission.isTrusted else { return }
        let generation = gate.current
        let requestID = UUID()
        learningRequestID = requestID
        learnTask = Task { [weak self] in
            guard let self else { return }
            defer { if learningRequestID == requestID { learningRequestID = nil } }
            do {
                try await clock.sleep(for: timing.learningDebounce)
                if clock.now() < suppressionUntil {
                    try await clock.sleep(for: .seconds(suppressionUntil.timeIntervalSince(clock.now())))
                }
                await captureStableRecovery(generation: generation)
            } catch { }
        }
    }
    public func captureStableRecovery(generation: UInt64? = nil) async {
        let expectedGeneration = generation ?? gate.current
        guard layoutEditorSessions.isEmpty, !Task.isCancelled, state == .idle, !isSuspended, clock.now() >= suppressionUntil,
              gate.isValid(expectedGeneration), permission.isTrusted,
              !outcomes.contains(where: { !$0.kind.succeeded && !(library.settings.autoModeEnabled && $0.kind == .missingApplication) }), desktopIssues.isEmpty else { return }
        let before = topology
        guard before.isEquivalent(to: displays.snapshot()), !before.surfaces.isEmpty else { return }
        let capture = await accessibility.capture(exclusions: library.exclusions)
        let canLearnEmptyCapture = library.settings.autoModeEnabled && library.autoLayoutIDs[before.setupKey] != nil
            && capture.desktopSnapshot != nil
        guard layoutEditorSessions.isEmpty, !Task.isCancelled, capture.isComplete, (!capture.windows.isEmpty || canLearnEmptyCapture), gate.isValid(expectedGeneration), state == .idle,
              before.isEquivalent(to: displays.snapshot()), before.isEquivalent(to: topology) else { return }
        let windows = capture.windows.compactMap { CoordinateMapper.save($0, in: before, desktopSnapshot: capture.desktopSnapshot) }
        guard windows.count == capture.windows.count else { return }
        let snapshot = RecoverySnapshot(date: clock.now(), topology: before, windows: windows, desktopSnapshot: capture.desktopSnapshot)
        if !windows.isEmpty { lastStableSnapshot = snapshot }
        if !windows.isEmpty && clock.now().timeIntervalSince(lastRecoveryWrite) >= 30 {
            lastRecoveryWrite = clock.now()
            updateLibrary { $0.recovery.append(snapshot); $0.recovery = Array($0.recovery.suffix(12)) }
        }
        if library.settings.autoModeEnabled {
            rememberAutoConfiguration(capture: capture, topology: before)
            return
        }
        guard let selected = selectedLayout, selected.options.rememberAdjustments,
              !temporaryMapping, !selected.importedNeedsMapping,
              isCompatible(selected), resolvedMapping(for: selected) != nil else { return }
        guard let remembered = LearningPolicy.updatedWindows(layout: selected, capture: capture, topology: before,
            beganGeneration: expectedGeneration, endedGeneration: gate.current, stable: state == .idle,
            fullyRestored: !outcomes.contains(where: { !$0.kind.succeeded }), temporaryMapping: temporaryMapping,
            references: windowReferences, exclusions: library.exclusions + selected.excludedBundleIDs.map { WindowExclusion(bundleID: $0) },
            displayMappingConfirmed: sessionApprovedMappings[selected.id].map {
                $0.skipped.isEmpty && $0.assignments.allSatisfy { $0.key == $0.value }
            } ?? false) else { return }
        updateLibrary { library in
            guard let index = library.layouts.firstIndex(where: { $0.id == selected.id }) else { return }
            if let old = library.layouts[index].remembered { library.layouts[index].history.append(old) }
            library.layouts[index].history = Array(library.layouts[index].history.suffix(10))
            library.layouts[index].remembered = .init(date: clock.now(), windows: remembered,
                desktopSnapshot: selected.effectiveDesktopSnapshot)
        }
    }
    private func rememberAutoConfiguration(capture: WindowCapture, topology observed: DisplayTopology) {
        guard autoLearningReady, storageAvailable, !temporaryMapping, !observed.hasAmbiguousIdentity else { return }
        if library.autoLayoutIDs[observed.setupKey] == nil,
           let candidate = AutoModePolicy.layout(for: observed, library: library, selectedLayoutID: selectedLayoutID) {
            updateLibrary { $0.autoLayoutIDs[observed.setupKey] = candidate.id }
        }
        if let id = library.autoLayoutIDs[observed.setupKey] {
            guard let layout = library.layouts.first(where: { $0.id == id }),
                  layout.options.autoModeEnabled, layout.options.autoSaveEnabled,
                  isCompatible(layout), let revision = AutoLearningPolicy.updatedRevision(layout: layout,
                    capture: capture, topology: observed, references: windowReferences, exclusions: library.exclusions) else { return }
            let accepted = updateLibrary { library in
                guard let index = library.layouts.firstIndex(where: { $0.id == id }) else { return }
                let previous = library.layouts[index].remembered ?? library.layouts[index].saved
                library.layouts[index].history.append(previous)
                library.layouts[index].history = Array(library.layouts[index].history.suffix(10))
                var dated = revision; dated.date = clock.now()
                library.layouts[index].remembered = dated
            }
            guard accepted else { return }
            var references = windowReferences
            let priorIDs = Set(layout.effectiveWindows.map(\.id))
            let liveIDs = Set(capture.windows.map(\.id))
            for window in revision.windows where !priorIDs.contains(window.id) && liveIDs.contains(window.id) {
                references[window.id] = window.id
            }
            windowReferences = WindowMatcher.match(saved: revision.windows, live: capture.windows,
                references: references).matches.mapValues(\.id)
        } else {
            // First encounter with this physical setup. The stable capture is its baseline.
            let windows = capture.windows.compactMap { CoordinateMapper.save($0, in: observed, desktopSnapshot: capture.desktopSnapshot) }
            guard !windows.isEmpty, windows.count == capture.windows.count else { return }
            let layout = Layout(name: LayoutCatalog.suggestedName(for: observed, existingNames: library.layouts.map(\.name)),
                topology: observed, windows: windows, desktopSnapshot: capture.desktopSnapshot)
            updateLibrary { library in
                library.layouts.append(layout)
                library.autoLayoutIDs[observed.setupKey] = layout.id
            }
            guard library.layouts.contains(where: { $0.id == layout.id }) else { return }
            selectedLayoutID = layout.id; lastSelectionSetup = observed.setupKey
            // These pairs come from the same capture, so even equal-titled windows
            // have a definite session reference without heuristic matching.
            windowReferences = Dictionary(uniqueKeysWithValues: zip(windows, capture.windows).map { ($0.0.id, $0.1.id) })
        }
    }
}
