import Foundation
import Testing
@testable import PersistedCore

@MainActor private final class FakeDisplays: TopologyProviding {
    var value: DisplayTopology
    init(_ value: DisplayTopology) { self.value = value }
    func snapshot() -> DisplayTopology { value }
}
@MainActor private final class FakePermission: PermissionChecking {
    var isTrusted = true
}
@MainActor private final class FakeLauncher: ApplicationLaunching {
    var launched: Set<String> = []
    var onLaunch: (() async -> Void)?
    func launch(bundleIDs: Set<String>) async -> [CaptureIssue] {
        launched.formUnion(bundleIDs)
        await onLaunch?()
        return []
    }
}
private actor FakeStore: LibraryStoring {
    var value: Library
    var saves: [Library] = []
    init(_ library: Library) { value = library }
    func load() -> Library { value }
    func save(_ library: Library) { value = library; saves.append(library) }
}
private actor FakeWindows: WindowAccessing {
    var value: WindowCapture
    var writes: [PlannedPlacement] = []
    var failures: [String: WindowOutcomeKind] = [:]
    var mutatingFailures: Set<String> = []
    var onCapture: (@Sendable () async -> Void)?
    var beforeWrite: (@Sendable () async -> Void)?
    var afterWrite: (@Sendable () async -> Void)?
    var desktopCalls: [String] = []
    var preparedSnapshots: [DesktopSnapshot] = []
    var movedAssignments: [DesktopAssignment] = []
    var failDesktopMove = false
    var desktopCapability = DesktopRestorationCapability.available
    func desktopRestorationCapability() async -> DesktopRestorationCapability { desktopCapability }
    func setDesktopCapability(_ value: DesktopRestorationCapability) { desktopCapability = value }
    var afterDesktopMove: (@Sendable () async -> Void)?
    func setDesktopMoveFailure() { failDesktopMove = true }
    func desktopMoveHook(_ hook: (@Sendable () async -> Void)?) { afterDesktopMove = hook }
    func prepareDesktops(_ snapshot: DesktopSnapshot, mapping: [String: String], generation: UInt64,
                         gate: MutationGate, automatic: Bool) async -> DesktopPreparation {
        desktopCalls.append("prepare"); preparedSnapshots.append(snapshot)
        let targets = DesktopRestorePlanner.plan(snapshot: snapshot, displayMapping: mapping).targets
        return .init(destinations: Dictionary(uniqueKeysWithValues: targets.keys.sorted().enumerated().map { ($0.element, UInt64($0.offset + 1)) }))
    }
    func moveToDesktop(_ live: LiveWindow, assignment: DesktopAssignment, destinations: [String: UInt64],
                       generation: UInt64, gate: MutationGate, automatic: Bool) async -> DesktopMoveResult {
        desktopCalls.append("move"); movedAssignments.append(assignment)
        guard !failDesktopMove else { return .init(succeeded: false, message: "Test desktop move unavailable.") }
        if let index = value.windows.firstIndex(where: { $0.id == live.id }) { value.windows[index].desktopAssignment = assignment }
        await afterDesktopMove?()
        return .init(succeeded: true, didMutate: true)
    }
    func restoreActiveDesktops(_ snapshot: DesktopSnapshot, destinations: [String: UInt64],
                               generation: UInt64, gate: MutationGate, automatic: Bool) async -> [String] {
        desktopCalls.append("activate"); return []
    }
    func verifyDesktop(_ live: LiveWindow, assignment: DesktopAssignment, destinations: [String: UInt64],
                       generation: UInt64, gate: MutationGate) async -> DesktopMoveResult {
        .init(succeeded: value.windows.first { $0.id == live.id }?.desktopAssignment == assignment,
              message: "Final desktop verification failed.")
    }
    init(_ windows: [LiveWindow]) { value = WindowCapture(windows: windows, runningBundleIDs: Set(windows.map { $0.identity.bundleID })) }
    func setCapture(_ capture: WindowCapture) { value = capture }
    func setFailure(_ bundle: String, _ kind: WindowOutcomeKind, didMutate: Bool = false) {
        failures[bundle] = kind
        if didMutate { mutatingFailures.insert(bundle) } else { mutatingFailures.remove(bundle) }
    }
    func captureHook(_ hook: (@Sendable () async -> Void)?) { onCapture = hook }
    func writeHook(_ hook: (@Sendable () async -> Void)?) { beforeWrite = hook }
    func afterWriteHook(_ hook: (@Sendable () async -> Void)?) { afterWrite = hook }
    func capture(exclusions: [WindowExclusion]) async -> WindowCapture {
        await onCapture?()
        var result = value
        result.windows.removeAll { window in exclusions.contains { $0.excludes(window.identity) } }
        return result
    }
    func place(_ placement: PlannedPlacement, generation: UInt64, gate: MutationGate, automatic: Bool) async -> WindowOutcome {
        desktopCalls.append("geometry")
        await beforeWrite?()
        guard gate.isValid(generation) else {
            return .init(id: placement.savedWindow.id, appName: placement.savedWindow.identity.appName, kind: .cancelled)
        }
        let kind = failures[placement.liveWindow.identity.bundleID] ?? .restored
        let didMutate = (kind.succeeded && kind != .alreadyPositioned)
            || mutatingFailures.contains(placement.liveWindow.identity.bundleID)
        var actualFrame: Rect?
        if didMutate {
            writes.append(placement)
            if let index = value.windows.firstIndex(where: { $0.id == placement.liveWindow.id }) {
                if kind.succeeded { value.windows[index].frame = placement.targetFrame }
                else { value.windows[index].frame.x = placement.targetFrame.x }
                actualFrame = value.windows[index].frame
            }
            await afterWrite?()
        }
        return .init(id: placement.savedWindow.id, appName: placement.savedWindow.identity.appName,
                     kind: kind, actualFrame: actualFrame, didMutate: didMutate)
    }
}
private struct FastClock: RestoreClock {
    func sleep(for: Duration) async throws { await Task.yield(); try Task.checkCancellation() }
    func now() -> Date { Date(timeIntervalSince1970: 2_000_000_000) }
}

/// A controlled clock makes event-order and cancellation tests independent of wall time.
private final class ControlledClock: RestoreClock, @unchecked Sendable {
    private let lock = NSLock()
    private var waits: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var date = Date(timeIntervalSince1970: 2_000_000_000)
    var pending: Int { lock.withLock { waits.count } }
    func now() -> Date { lock.withLock { date } }
    func sleep(for: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.lock()
                if Task.isCancelled { lock.unlock(); continuation.resume(throwing: CancellationError()) }
                else { waits[id] = continuation; lock.unlock() }
            }
        } onCancel: {
            let continuation = self.lock.withLock { self.waits.removeValue(forKey: id) }
            continuation?.resume(throwing: CancellationError())
        }
    }
    func advance() {
        let pending = lock.withLock {
            date.addTimeInterval(10)
            let result = Array(waits.values); waits = [:]; return result
        }
        pending.forEach { $0.resume() }
    }
}

@MainActor private final class Rig {
    let displays: FakeDisplays
    let permission = FakePermission()
    let windows: FakeWindows
    let launcher = FakeLauncher()
    let store: FakeStore
    let coordinator: RestoreCoordinator
    init(library: Library, topology: DisplayTopology = CoreFixtures.topology,
         windows: [LiveWindow] = [CoreFixtures.live()], clock: any RestoreClock = FastClock()) {
        let displays = FakeDisplays(topology)
        let access = FakeWindows(windows)
        let store = FakeStore(library)
        self.displays = displays; self.windows = access; self.store = store
        var timing = CoordinatorTiming()
        timing.writeSuppression = 0
        coordinator = RestoreCoordinator(displays: displays, accessibility: access, permission: permission,
                                         launcher: launcher, repository: store, clock: clock, timing: timing)
    }
    func start() async { await coordinator.start(); await coordinator.waitForSettling() }
}

@Suite(.serialized) @MainActor struct CoordinatorTests {
    private func autoLibrary(_ layouts: [Layout] = []) -> Library {
        var data = Library()
        data.settings.autoModeEnabled = true
        data.layouts = layouts
        for layout in layouts { data.autoLayoutIDs[layout.topology.setupKey] = layout.id }
        return data
    }
    @Test func autoModeDefaultsOffAndDoesNotCreateLayouts() async {
        let rig = Rig(library: Library())
        await rig.start()
        await rig.coordinator.captureStableRecovery()
        #expect(!rig.coordinator.library.settings.autoModeEnabled)
        #expect(rig.coordinator.library.layouts.isEmpty)
        #expect(await rig.windows.writes.isEmpty)
        rig.coordinator.stop()
    }
    @Test func oversizedLibraryUpdateIsRejectedBeforeChangingMemoryOrQueuingSave() async throws {
        let layout = CoreFixtures.layout()
        let rig = Rig(library: library(automatic: false, layouts: [layout]))
        defer { rig.coordinator.stop() }
        await rig.start()
        rig.coordinator.stop()
        await rig.coordinator.flushPersistence()
        let before = try LayoutRepository.encode(rig.coordinator.library)
        let savedCount = await rig.store.saves.count
        let accepted = rig.coordinator.updateLibrary { library in
            library.layouts[0].saved.windows[0].identity.title = String(repeating: "a", count: LayoutRepository.maximumLibraryBytes)
        }
        await rig.coordinator.flushPersistence()
        #expect(!accepted)
        #expect(try LayoutRepository.encode(rig.coordinator.library) == before)
        #expect(rig.coordinator.errorMessage != nil)
        #expect(await rig.store.saves.count == savedCount)
    }
    @Test func autoModeCreatesNamedPresetAndLearnsWithoutChangingSavedBaseline() async {
        let rig = Rig(library: autoLibrary())
        await rig.start()
        await rig.coordinator.captureStableRecovery()
        let created = rig.coordinator.library.layouts.first!
        #expect(created.name == "One display and laptop")
        #expect(rig.coordinator.library.autoLayoutIDs[CoreFixtures.topology.setupKey] == created.id)
        var moved = CoreFixtures.live(); moved.frame.x += 120
        let added = CoreFixtures.live(2, title: "Another window", frame: Rect(x: 400, y: 100, width: 500, height: 300))
        await rig.windows.setCapture(.init(windows: [moved, added]))
        await rig.coordinator.captureStableRecovery()
        let learned = rig.coordinator.library.layouts.first!
        #expect(learned.saved == created.saved)
        #expect(learned.effectiveWindows.count == 2)
        #expect(learned.effectiveWindows.first { $0.id == created.saved.windows[0].id }?.frame == moved.frame)
        #expect(learned.history.contains(created.saved))
        #expect(await rig.windows.writes.isEmpty)
        rig.coordinator.stop()
    }
    @Test func autoModeRestoresKnownSetupBeforeLearningCollapsedWindows() async {
        let dock = CoreFixtures.layout()
        let rig = Rig(library: autoLibrary([dock]))
        await rig.start()
        let laptop = DisplayTopology(displays: [CoreFixtures.primary], lid: .open)
        rig.displays.value = laptop
        var laptopWindow = CoreFixtures.live(); laptopWindow.frame.x = 260
        await rig.windows.setCapture(.init(windows: [laptopWindow]))
        rig.coordinator.handle(.displayChanged)
        await rig.coordinator.waitForSettling()
        await rig.coordinator.captureStableRecovery()
        #expect(rig.coordinator.library.layouts.count == 2)
        let laptopID = rig.coordinator.library.autoLayoutIDs[laptop.setupKey]!
        #expect(rig.coordinator.library.layouts.first { $0.id == laptopID }?.name == "Laptop only")
        var collapsed = laptopWindow; collapsed.frame.x = 30
        rig.displays.value = CoreFixtures.topology
        await rig.windows.setCapture(.init(windows: [collapsed]))
        rig.coordinator.handle(.displayChanged)
        await rig.coordinator.waitForSettling()
        #expect(await rig.windows.value.windows.first?.frame == dock.saved.windows[0].frame)
        await rig.coordinator.captureStableRecovery()
        #expect(rig.coordinator.library.layouts.first { $0.id == dock.id }?.effectiveWindows[0].frame == dock.saved.windows[0].frame)
        #expect(rig.coordinator.library.layouts.first { $0.id == laptopID }?.effectiveWindows[0].frame == laptopWindow.frame)
        rig.coordinator.stop()
    }
    @Test func disabledAutoPresetIsNotRestoredLearnedOrReplaced() async {
        var layout = CoreFixtures.layout(); layout.options.autoModeEnabled = false
        let rig = Rig(library: autoLibrary([layout]))
        await rig.start(); await rig.coordinator.captureStableRecovery()
        rig.coordinator.pollAutoMode()
        await rig.coordinator.captureStableRecovery()
        #expect(rig.coordinator.library.layouts.count == 1)
        #expect(rig.coordinator.library.layouts[0].remembered == nil)
        #expect(await rig.windows.writes.isEmpty)
        #expect(rig.coordinator.requestApply(layoutID: layout.id))
        await rig.coordinator.waitForRestoration()
        #expect(await rig.windows.writes.count == 1)
        rig.coordinator.stop()
    }
    @Test func frozenAutoPresetRestoresButDoesNotLearn() async {
        var layout = CoreFixtures.layout(); layout.options.autoSaveEnabled = false
        let rig = Rig(library: autoLibrary([layout]))
        await rig.start()
        #expect(await rig.windows.writes.count == 1)
        var moved = CoreFixtures.live(); moved.frame.x += 300
        await rig.windows.setCapture(.init(windows: [moved]))
        await rig.coordinator.captureStableRecovery()
        #expect(rig.coordinator.library.layouts[0].remembered == nil)
        rig.coordinator.stop()
    }
    @Test func failedAutoRestoreCannotBeLearnedAsNewConfiguration() async {
        let layout = CoreFixtures.layout()
        let rig = Rig(library: autoLibrary([layout]))
        await rig.windows.setFailure("example.editor", .unsupported)
        await rig.start()
        var moved = CoreFixtures.live(); moved.frame.x += 300
        await rig.windows.setCapture(.init(windows: [moved]))
        await rig.coordinator.captureStableRecovery()
        #expect(rig.coordinator.library.layouts[0].remembered == nil)
        #expect(rig.coordinator.library.layouts[0].saved == layout.saved)
        rig.coordinator.stop()
    }
    @Test func disablingAutoDuringCapturePreventsPresetCreation() async {
        let rig = Rig(library: autoLibrary())
        await rig.windows.captureHook { @MainActor in rig.coordinator.setAutoMode(false) }
        await rig.start(); await rig.coordinator.captureStableRecovery()
        #expect(!rig.coordinator.library.settings.autoModeEnabled)
        #expect(rig.coordinator.library.layouts.isEmpty)
        rig.coordinator.stop()
    }
    @Test func disablingAutoDuringRestorePreventsFurtherWindowWrites() async {
        let layout = CoreFixtures.layout()
        let rig = Rig(library: autoLibrary([layout]))
        await rig.windows.writeHook { @MainActor in rig.coordinator.setAutoMode(false) }
        await rig.start()
        #expect(await rig.windows.writes.isEmpty)
        #expect(rig.coordinator.library.layouts[0].remembered == nil)
        #expect(rig.coordinator.state == .idle)
        rig.coordinator.stop()
    }
    @Test func partialOrDeniedAutoCaptureCannotCreatePreset() async {
        for denied in [false, true] {
            let rig = Rig(library: autoLibrary())
            rig.permission.isTrusted = !denied
            await rig.windows.setCapture(.init(windows: [CoreFixtures.live()], issues: [.init(bundleID: "example.editor", message: "Timed out")]))
            await rig.start(); await rig.coordinator.captureStableRecovery()
            #expect(rig.coordinator.library.layouts.isEmpty)
            rig.coordinator.stop()
        }
    }
    @Test func autoConfigurationChangeDuringCaptureInvalidatesLearning() async {
        let layout = CoreFixtures.layout()
        let rig = Rig(library: autoLibrary([layout]))
        await rig.start()
        var moved = CoreFixtures.live(); moved.frame.x += 300
        await rig.windows.captureHook { @MainActor in
            rig.coordinator.updateLibrary { $0.layouts[0].options.autoSaveEnabled = false }
        }
        await rig.windows.setCapture(.init(windows: [moved]))
        await rig.coordinator.captureStableRecovery()
        #expect(rig.coordinator.library.layouts[0].remembered == nil)
        rig.coordinator.stop()
    }
    @Test func changingAutoPresetUsesExplicitChoiceForCurrentSetup() async {
        let first = CoreFixtures.layout()
        var otherWindow = CoreFixtures.live(); otherWindow.frame.x = 360
        let second = CoreFixtures.layout(windows: [CoreFixtures.saved(otherWindow)])
        var data = autoLibrary([first]); data.layouts.append(second)
        let rig = Rig(library: data)
        await rig.start()
        rig.coordinator.setAutoLayout(layoutID: second.id)
        await rig.coordinator.waitForSettling()
        #expect(rig.coordinator.library.autoLayoutIDs[CoreFixtures.topology.setupKey] == second.id)
        #expect(await rig.windows.value.windows.first?.frame == otherWindow.frame)
        rig.coordinator.stop()
    }
    @Test func enablingAutoDuringManualApplyReusesExistingPreset() async {
        let layout = CoreFixtures.layout()
        let rig = Rig(library: library(automatic: false, layouts: [layout]))
        await rig.start()
        await rig.windows.writeHook { @MainActor in rig.coordinator.setAutoMode(true) }
        #expect(rig.coordinator.requestApply(layoutID: layout.id))
        await rig.coordinator.waitForRestoration()
        await rig.coordinator.captureStableRecovery()
        #expect(rig.coordinator.library.autoLayoutIDs[CoreFixtures.topology.setupKey] == layout.id)
        #expect(rig.coordinator.library.layouts.count == 1)
        rig.coordinator.stop()
    }
    @Test func equalTitledWindowsKeepCaptureReferencesWhileAutoLearning() async {
        let first = CoreFixtures.live()
        let second = CoreFixtures.live(2, frame: Rect(x: 500, y: 100, width: 500, height: 300))
        let rig = Rig(library: autoLibrary(), windows: [first, second])
        await rig.start(); await rig.coordinator.captureStableRecovery()
        let ids = rig.coordinator.library.layouts[0].effectiveWindows.map(\.id)
        var movedFirst = first; movedFirst.frame.x = 200
        var movedSecond = second; movedSecond.frame.x = 800
        await rig.windows.setCapture(.init(windows: [movedSecond, movedFirst]))
        await rig.coordinator.captureStableRecovery()
        let windows = rig.coordinator.library.layouts[0].effectiveWindows
        #expect(windows.count == 2)
        #expect(windows.first { $0.id == ids[0] }?.frame == movedFirst.frame)
        #expect(windows.first { $0.id == ids[1] }?.frame == movedSecond.frame)
        rig.coordinator.stop()
    }
    @Test func closedApplicationDoesNotPreventLearningAvailableWindows() async {
        let live = CoreFixtures.live()
        let closed = CoreFixtures.saved(CoreFixtures.live(2, bundle: "example.closed"))
        let layout = CoreFixtures.layout(windows: [CoreFixtures.saved(live), closed])
        let rig = Rig(library: autoLibrary([layout]), windows: [live])
        await rig.start()
        #expect(rig.coordinator.outcomes.contains { $0.kind == .missingApplication })
        var moved = live; moved.frame.x = 340
        await rig.windows.setCapture(.init(windows: [moved]))
        await rig.coordinator.captureStableRecovery()
        let windows = rig.coordinator.library.layouts[0].effectiveWindows
        #expect(windows.count == 2)
        #expect(windows.first { $0.id == closed.id } == closed)
        #expect(windows.first { $0.id == layout.saved.windows[0].id }?.frame == moved.frame)
        rig.coordinator.stop()
    }
    private func desktops(_ prefix: String = "saved") -> DesktopSnapshot {
        .init(displays: [
            .init(displayID: "laptop", desktops: [.init(id: prefix + "1", ordinal: 0), .init(id: prefix + "2", ordinal: 1, isActive: true)]),
            .init(displayID: "office", desktops: [.init(id: prefix + "3", ordinal: 0, isActive: true)])
        ], separateDisplays: true)
    }
    @Test func unavailableDesktopCapabilitySkipsAllDesktopMutationsAndKeepsGeometryUndo() async {
        var live = CoreFixtures.live(frame: .init(x: 200, y: 200, width: 400, height: 300))
        live.desktopAssignment = .desktop("before1")
        var saved = CoreFixtures.saved()
        saved.desktopAssignment = .desktop("saved2")
        let layout = Layout(name: "Spaces", topology: CoreFixtures.topology, windows: [saved], desktopSnapshot: desktops())
        let rig = Rig(library: library(automatic: false, layouts: [layout]), windows: [live])
        defer { rig.coordinator.stop() }
        let limitation = "Desktop placement is unavailable in this test."
        await rig.windows.setDesktopCapability(.unavailable(limitation))
        await rig.windows.setCapture(.init(windows: [live], desktopSnapshot: desktops("before")))
        await rig.start()
        #expect(rig.coordinator.requestApply(layoutID: layout.id))
        await rig.coordinator.waitForRestoration()
        #expect(await rig.windows.desktopCalls == ["geometry"])
        #expect(await rig.windows.value.windows.first?.frame == saved.frame)
        #expect(await rig.windows.value.windows.first?.desktopAssignment == live.desktopAssignment)
        #expect(rig.coordinator.desktopIssues.contains(limitation))
        #expect(rig.coordinator.desktopSummary == "Desktop restoration unavailable")
        #expect(rig.coordinator.outcomes.first?.kind == .unsupported)
        #expect(rig.coordinator.canUndo)
        await rig.coordinator.undo()
        #expect(await rig.windows.desktopCalls == ["geometry", "geometry"])
        #expect(await rig.windows.value.windows.first?.frame == live.frame)
        #expect(await rig.windows.value.windows.first?.desktopAssignment == live.desktopAssignment)
    }
    @Test func undoPreflightsDesktopCapabilityAgain() async {
        var live = CoreFixtures.live()
        live.desktopAssignment = .desktop("before1")
        var saved = CoreFixtures.saved(live)
        saved.desktopAssignment = .desktop("saved2")
        let layout = Layout(name: "Spaces", topology: CoreFixtures.topology, windows: [saved], desktopSnapshot: desktops())
        let rig = Rig(library: library(automatic: false, layouts: [layout]), windows: [live])
        defer { rig.coordinator.stop() }
        await rig.windows.setCapture(.init(windows: [live], desktopSnapshot: desktops("before")))
        await rig.start()
        #expect(rig.coordinator.requestApply(layoutID: layout.id))
        await rig.coordinator.waitForRestoration()
        await rig.windows.setDesktopCapability(.unavailable("Desktop placement became unavailable."))
        await rig.coordinator.undo()
        #expect(await rig.windows.desktopCalls == ["prepare", "move", "geometry", "activate", "geometry"])
        #expect(await rig.windows.value.windows.first?.desktopAssignment == .desktop("saved2"))
        #expect(rig.coordinator.desktopSummary == "Desktop restoration unavailable")
        #expect(!rig.coordinator.desktopIssues.isEmpty)
    }
    @Test func unsupportedDesktopApplyKeepsOfflineEditsProtectedFromAutoLearning() async {
        var saved = CoreFixtures.saved()
        saved.desktopAssignment = .desktop("saved2")
        var layout = Layout(name: "Edited desktops", topology: CoreFixtures.topology,
                            windows: [saved], desktopSnapshot: desktops())
        layout.editedAwaitingApply = true
        var live = CoreFixtures.live()
        live.desktopAssignment = .desktop("before1")
        let rig = Rig(library: autoLibrary([layout]), windows: [live])
        defer { rig.coordinator.stop() }
        await rig.windows.setDesktopCapability(.unavailable("Desktop placement is unavailable."))
        await rig.windows.setCapture(.init(windows: [live], desktopSnapshot: desktops("before")))
        await rig.start()
        #expect(await rig.windows.desktopCalls == ["geometry"])
        #expect(rig.coordinator.library.layouts[0].editedAwaitingApply)
        await rig.coordinator.captureStableRecovery()
        #expect(rig.coordinator.library.layouts[0].saved == layout.saved)
        #expect(rig.coordinator.library.layouts[0].remembered == nil)
        #expect(rig.coordinator.library.layouts[0].effectiveWindows[0].desktopAssignment == .desktop("saved2"))
    }
    @Test func desktopMembershipPrecedesGeometryAndUndoUsesOriginalSnapshot() async {
        var live = CoreFixtures.live()
        live.desktopAssignment = .desktop("before1")
        var saved = CoreFixtures.saved(live)
        saved.desktopAssignment = .desktop("saved2")
        let layout = Layout(name: "Spaces", topology: CoreFixtures.topology, windows: [saved], desktopSnapshot: desktops())
        let rig = Rig(library: library(automatic: false, layouts: [layout]), windows: [live])
        await rig.windows.setCapture(.init(windows: [live], desktopSnapshot: desktops("before")))
        await rig.start()
        #expect(rig.coordinator.requestApply(layoutID: layout.id))
        await rig.coordinator.waitForRestoration()
        #expect(await rig.windows.desktopCalls == ["prepare", "move", "geometry", "activate"])
        #expect(rig.coordinator.desktopIssues.isEmpty)
        #expect(rig.coordinator.canUndo)
        await rig.coordinator.undo()
        #expect(await rig.windows.movedAssignments == [.desktop("saved2"), .desktop("before1")])
        #expect(await rig.windows.preparedSnapshots.last == desktops("before"))
        rig.coordinator.stop()
    }
    @Test func desktopFailureDoesNotPretendGeometrySuccessRestoredEverything() async {
        var saved = CoreFixtures.saved()
        saved.desktopAssignment = .desktop("saved2")
        var layout = Layout(name: "Spaces", topology: CoreFixtures.topology, windows: [saved], desktopSnapshot: desktops())
        layout.options.rememberAdjustments = true
        let rig = Rig(library: library(automatic: false, layouts: [layout]))
        await rig.windows.setDesktopMoveFailure()
        var current = CoreFixtures.live()
        current.desktopAssignment = .desktop("before1")
        await rig.windows.setCapture(.init(windows: [current], desktopSnapshot: desktops("before")))
        await rig.start()
        #expect(rig.coordinator.requestApply(layoutID: layout.id))
        await rig.coordinator.waitForRestoration()
        #expect(await rig.windows.writes.count == 1)
        #expect(rig.coordinator.outcomes.first?.kind == .unsupported)
        #expect(rig.coordinator.outcomes.first?.explanation.contains("Window position restored") == true)
        #expect(!rig.coordinator.desktopIssues.isEmpty)
        await rig.coordinator.captureStableRecovery()
        #expect(rig.coordinator.library.layouts[0].remembered == nil)
        rig.coordinator.stop()
    }
    @Test func disabledDesktopOptionKeepsGeometryOnly() async {
        var saved = CoreFixtures.saved()
        saved.desktopAssignment = .desktop("saved2")
        var layout = Layout(name: "Spaces", topology: CoreFixtures.topology, windows: [saved], desktopSnapshot: desktops())
        layout.options.restoreDesktops = false
        let rig = Rig(library: library(automatic: false, layouts: [layout]))
        await rig.windows.setDesktopCapability(.unavailable("Desktop placement is unavailable."))
        await rig.start()
        #expect(rig.coordinator.requestApply(layoutID: layout.id))
        await rig.coordinator.waitForRestoration()
        #expect(await rig.windows.desktopCalls == ["geometry"])
        #expect(rig.coordinator.desktopSummary == nil)
        #expect(rig.coordinator.outcomes.allSatisfy { $0.kind.succeeded })
        rig.coordinator.stop()
    }
    @Test func unavailableInitialDesktopSnapshotPreventsDesktopMutations() async {
        var saved = CoreFixtures.saved()
        saved.desktopAssignment = .desktop("saved2")
        let layout = Layout(name: "Spaces", topology: CoreFixtures.topology, windows: [saved], desktopSnapshot: desktops())
        let rig = Rig(library: library(automatic: false, layouts: [layout]))
        await rig.start()
        #expect(rig.coordinator.requestApply(layoutID: layout.id))
        await rig.coordinator.waitForRestoration()
        #expect(await rig.windows.desktopCalls == ["geometry"])
        #expect(!rig.coordinator.desktopIssues.isEmpty)
        #expect(rig.coordinator.outcomes.first?.kind == .unsupported)
        rig.coordinator.stop()
    }
    @Test func geometryCannotSilentlyMoveWindowAwayFromItsRestoredDesktop() async {
        var live = CoreFixtures.live()
        live.desktopAssignment = .desktop("before1")
        var saved = CoreFixtures.saved(live)
        saved.desktopAssignment = .desktop("saved2")
        let layout = Layout(name: "Spaces", topology: CoreFixtures.topology, windows: [saved], desktopSnapshot: desktops())
        let rig = Rig(library: library(automatic: false, layouts: [layout]), windows: [live])
        await rig.windows.setCapture(.init(windows: [live], desktopSnapshot: desktops("before")))
        await rig.start()
        let displaced = live
        await rig.windows.afterWriteHook {
            await rig.windows.setCapture(.init(windows: [displaced]))
        }
        #expect(rig.coordinator.requestApply(layoutID: layout.id))
        await rig.coordinator.waitForRestoration()
        #expect(rig.coordinator.outcomes.first?.kind == .unsupported)
        #expect(rig.coordinator.desktopIssues.contains { $0.contains("Final desktop verification failed") })
        rig.coordinator.stop()
    }
    @Test func interruptedDesktopMoveRetainsMembershipUndoBeforeGeometry() async {
        var live = CoreFixtures.live()
        live.desktopAssignment = .desktop("before1")
        var saved = CoreFixtures.saved(live)
        saved.desktopAssignment = .desktop("saved2")
        let layout = Layout(name: "Spaces", topology: CoreFixtures.topology, windows: [saved], desktopSnapshot: desktops())
        let rig = Rig(library: library(automatic: false, layouts: [layout]), windows: [live])
        await rig.windows.setCapture(.init(windows: [live], desktopSnapshot: desktops("before")))
        await rig.start()
        await rig.windows.desktopMoveHook { @MainActor in
            rig.permission.isTrusted = false
            rig.coordinator.handle(.permissionChanged)
        }
        #expect(rig.coordinator.requestApply(layoutID: layout.id))
        await rig.coordinator.waitForRestoration()
        #expect(rig.coordinator.canUndo)
        #expect(await rig.windows.writes.isEmpty)
        await rig.windows.desktopMoveHook(nil)
        rig.permission.isTrusted = true
        await rig.coordinator.undo()
        #expect(await rig.windows.movedAssignments == [.desktop("saved2"), .desktop("before1")])
        rig.coordinator.stop()
    }
    @Test func scopedDesktopApplyLeavesOtherMonitorAlone() async {
        var live = [CoreFixtures.live(), CoreFixtures.live(2, title: "External", frame: .init(x: 1500, y: 50, width: 600, height: 400))]
        live[0].desktopAssignment = .desktop("before1")
        live[1].desktopAssignment = .desktop("before3")
        var saved = live.map { CoreFixtures.saved($0) }
        saved[0].desktopAssignment = .desktop("saved2")
        saved[1].desktopAssignment = .desktop("saved3")
        let layout = Layout(name: "Spaces", topology: CoreFixtures.topology, windows: saved, desktopSnapshot: desktops())
        let rig = Rig(library: library(automatic: false, layouts: [layout]), windows: live)
        await rig.windows.setCapture(.init(windows: live, desktopSnapshot: desktops("before")))
        await rig.start()
        #expect(rig.coordinator.requestApply(layoutID: layout.id, windowScope: [saved[0].id]))
        await rig.coordinator.waitForRestoration()
        #expect(await rig.windows.preparedSnapshots.first?.displays.map(\.displayID) == ["laptop"])
        #expect(await rig.windows.movedAssignments == [.desktop("saved2")])
        #expect(await rig.windows.writes.map { $0.liveWindow.id } == [live[0].id])
        rig.coordinator.stop()
    }
    @Test func rememberedRevisionUsesItsOwnDesktopSnapshot() async {
        var saved = CoreFixtures.saved()
        saved.desktopAssignment = .desktop("saved2")
        var layout = Layout(name: "Spaces", topology: CoreFixtures.topology, windows: [saved], desktopSnapshot: desktops())
        saved.desktopAssignment = .desktop("remembered1")
        layout.remembered = .init(windows: [saved], desktopSnapshot: desktops("remembered"))
        let rig = Rig(library: library(automatic: false, layouts: [layout]))
        var current = CoreFixtures.live()
        current.desktopAssignment = .desktop("before1")
        await rig.windows.setCapture(.init(windows: [current], desktopSnapshot: desktops("before")))
        await rig.start()
        #expect(rig.coordinator.requestApply(layoutID: layout.id))
        await rig.coordinator.waitForRestoration()
        #expect(await rig.windows.preparedSnapshots.first == desktops("remembered"))
        #expect(await rig.windows.movedAssignments == [.desktop("remembered1")])
        rig.coordinator.stop()
    }
    @Test func recoverySnapshotRetainsDesktopMembership() async {
        var live = CoreFixtures.live()
        live.desktopAssignment = .desktop("before1")
        let rig = Rig(library: library(automatic: false), windows: [live])
        await rig.windows.setCapture(.init(windows: [live], desktopSnapshot: desktops("before")))
        await rig.start()
        await rig.coordinator.captureStableRecovery()
        #expect(rig.coordinator.lastStableSnapshot?.desktopSnapshot == desktops("before"))
        #expect(rig.coordinator.lastStableSnapshot?.windows.first?.desktopAssignment == .desktop("before1"))
        rig.coordinator.stop()
    }
    private func library(automatic: Bool = true, layouts: [Layout]? = nil) -> Library {
        var library = Library()
        library.layouts = layouts ?? [CoreFixtures.layout()]
        for layout in library.layouts { library.preferredLayouts[layout.topology.setupKey] = layout.id }
        library.settings.automaticSwitching = automatic
        return library
    }
    @Test func recognizedLaptopDockAndReturnSelectTheirPreferences() async {
        let dock = CoreFixtures.layout()
        let laptopTopology = DisplayTopology(displays: [CoreFixtures.primary], lid: .open)
        let laptop = CoreFixtures.layout(windows: [CoreFixtures.saved(topology: laptopTopology)], topology: laptopTopology)
        let rig = Rig(library: library(layouts: [dock, laptop]))
        await rig.start()
        #expect(rig.coordinator.selectedLayoutID == dock.id)
        rig.displays.value = laptopTopology
        rig.coordinator.handle(.displayChanged)
        await rig.coordinator.waitForSettling()
        #expect(rig.coordinator.selectedLayoutID == laptop.id)
        rig.displays.value = dock.topology
        rig.coordinator.handle(.displayChanged)
        await rig.coordinator.waitForSettling()
        #expect(rig.coordinator.selectedLayoutID == dock.id)
        rig.coordinator.stop()
    }
    @Test func duplicateNotificationsDoNotRestoreAgain() async {
        let rig = Rig(library: library())
        await rig.start()
        let count = await rig.windows.writes.count
        for _ in 0..<10 { rig.coordinator.handle(.displayChanged) }
        await rig.coordinator.waitForSettling()
        #expect(await rig.windows.writes.count == count)
        rig.coordinator.stop()
    }
    @Test func manualChoiceSurvivesGeometryChangeWithoutChangingPreference() async {
        let first = CoreFixtures.layout(), second = CoreFixtures.layout()
        var data = library(layouts: [first, second])
        data.preferredLayouts[first.topology.setupKey] = first.id
        let rig = Rig(library: data)
        await rig.start()
        rig.coordinator.requestApply(layoutID: second.id)
        await rig.coordinator.waitForRestoration()
        rig.displays.value.displays[0].usableFrame.width -= 100
        rig.coordinator.handle(.displayChanged)
        await rig.coordinator.waitForSettling()
        #expect(rig.coordinator.selectedLayoutID == second.id)
        #expect(rig.coordinator.library.preferredLayouts[first.topology.setupKey] == first.id)
        rig.coordinator.stop()
    }
    @Test func unknownSetupDoesNotMoveWindows() async {
        var unrelated = CoreFixtures.topology
        unrelated.displays[1].uuid = "HOME"
        let rig = Rig(library: library(), topology: unrelated)
        await rig.start()
        #expect(await rig.windows.writes.isEmpty)
        #expect(rig.coordinator.status == "No layout saved for this setup")
        rig.coordinator.stop()
    }
    @Test func sleepRequiresWakeAndUsableStableDisplays() async {
        let rig = Rig(library: library())
        await rig.start()
        let before = await rig.windows.writes.count
        rig.coordinator.handle(.sleep)
        rig.displays.value = .init()
        rig.coordinator.handle(.displayChanged)
        #expect(rig.coordinator.state == .suspended)
        rig.coordinator.handle(.wake)
        await rig.coordinator.waitForSettling()
        #expect(rig.coordinator.state == .waiting)
        #expect(await rig.windows.writes.count == before)
        rig.displays.value = CoreFixtures.topology
        rig.coordinator.handle(.displayChanged)
        await rig.coordinator.waitForSettling()
        #expect(rig.coordinator.state == .idle)
        rig.coordinator.stop()
    }
    @Test func permissionRevocationStopsRemainingWritesAndPreservesSavedRevision() async {
        let live = [CoreFixtures.live(1), CoreFixtures.live(2, title: "Second")]
        let layout = CoreFixtures.layout(windows: live.map { CoreFixtures.saved($0) })
        let rig = Rig(library: library(automatic: false, layouts: [layout]), windows: live)
        await rig.start()
        await rig.windows.writeHook { @MainActor in
            rig.permission.isTrusted = false
            rig.coordinator.handle(.permissionChanged)
        }
        rig.coordinator.requestApply(layoutID: layout.id)
        await rig.coordinator.waitForRestoration()
        #expect(rig.coordinator.state == .permissionRequired)
        #expect(await rig.windows.writes.isEmpty)
        #expect(rig.coordinator.library.layouts[0].saved == layout.saved)
        rig.coordinator.stop()
    }
    @Test func hungApplicationDoesNotPreventAnotherFromRestoring() async {
        let live = [CoreFixtures.live(1, bundle: "hung"), CoreFixtures.live(2, bundle: "healthy")]
        let layout = CoreFixtures.layout(windows: live.map { CoreFixtures.saved($0) })
        let rig = Rig(library: library(automatic: false, layouts: [layout]), windows: live)
        await rig.start(); await rig.windows.setFailure("hung", .timedOut)
        rig.coordinator.requestApply(layoutID: layout.id)
        await rig.coordinator.waitForRestoration()
        #expect(rig.coordinator.outcomes.contains { $0.kind == .timedOut })
        #expect(await rig.windows.writes.map { $0.liveWindow.identity.bundleID } == ["healthy"])
        rig.coordinator.stop()
    }
    @Test func undoReturnsSurvivingChangedWindowsOnly() async {
        let original = CoreFixtures.live(frame: Rect(x: 330, y: 200, width: 500, height: 400))
        let layout = CoreFixtures.layout()
        let rig = Rig(library: library(automatic: false, layouts: [layout]), windows: [original])
        await rig.start()
        rig.coordinator.requestApply(layoutID: layout.id)
        await rig.coordinator.waitForRestoration()
        #expect(rig.coordinator.canUndo)
        await rig.coordinator.undo()
        #expect(await rig.windows.writes.last?.targetFrame == original.frame)
        #expect(!rig.coordinator.canUndo)
        rig.coordinator.stop()
    }
    @Test func timeoutAfterPartialMutationStillPreservesUndoWithoutRetrying() async {
        let original = CoreFixtures.live(frame: Rect(x: 330, y: 200, width: 500, height: 400))
        let layout = CoreFixtures.layout()
        let rig = Rig(library: library(automatic: false, layouts: [layout]), windows: [original])
        await rig.start()
        await rig.windows.setFailure("example.editor", .timedOut, didMutate: true)
        rig.coordinator.requestApply(layoutID: layout.id)
        await rig.coordinator.waitForRestoration()
        #expect(rig.coordinator.outcomes.first?.kind == .timedOut)
        #expect(rig.coordinator.outcomes.first?.didMutate == true)
        #expect(rig.coordinator.canUndo)
        #expect(await rig.windows.writes.count == 1)
        #expect(await rig.windows.value.windows.first?.frame != original.frame)
        await rig.windows.setFailure("example.editor", .restored)
        await rig.coordinator.undo()
        #expect(await rig.windows.writes.count == 2)
        #expect(await rig.windows.writes.last?.targetFrame == original.frame)
        #expect(await rig.windows.value.windows.first?.frame == original.frame)
        #expect(!rig.coordinator.canUndo)
        rig.coordinator.stop()
    }
    @Test(arguments: [WindowOutcomeKind.restored, .timedOut])
    func permissionLossAfterMutationPreservesUndoFromInterruptedSession(kind: WindowOutcomeKind) async {
        let original = CoreFixtures.live(frame: Rect(x: 330, y: 200, width: 500, height: 400))
        let layout = CoreFixtures.layout()
        let rig = Rig(library: library(automatic: false, layouts: [layout]), windows: [original])
        await rig.start()
        await rig.windows.setFailure("example.editor", kind, didMutate: true)
        await rig.windows.afterWriteHook { @MainActor in
            rig.permission.isTrusted = false
            rig.coordinator.handle(.permissionChanged)
        }
        rig.coordinator.requestApply(layoutID: layout.id)
        await rig.coordinator.waitForRestoration()
        #expect(rig.coordinator.state == .permissionRequired)
        #expect(rig.coordinator.canUndo)
        #expect(await rig.windows.writes.count == 1)
        #expect(await rig.windows.value.windows.first?.frame != original.frame)

        await rig.windows.afterWriteHook(nil)
        await rig.windows.setFailure("example.editor", .restored)
        rig.permission.isTrusted = true
        await rig.coordinator.undo()
        #expect(await rig.windows.writes.count == 2)
        #expect(await rig.windows.value.windows.first?.frame == original.frame)
        #expect(!rig.coordinator.canUndo)
        #expect(rig.coordinator.state == .idle)
        rig.coordinator.stop()
    }
    @Test func undoRefusesDifferentGeometry() async {
        let rig = Rig(library: library())
        await rig.start()
        let count = await rig.windows.writes.count
        rig.displays.value.displays[0].frame.width -= 50
        await rig.coordinator.undo()
        #expect(await rig.windows.writes.count == count)
        #expect(rig.coordinator.errorMessage != nil)
        rig.coordinator.stop()
    }
    @Test func launchedLateWindowIsMatchedWithinBoundedSession() async {
        var layout = CoreFixtures.layout(); layout.options.launchMissingApplications = true
        let rig = Rig(library: library(automatic: false, layouts: [layout]), windows: [])
        rig.launcher.onLaunch = { await rig.windows.setCapture(.init(windows: [CoreFixtures.live()])) }
        await rig.start()
        rig.coordinator.requestApply(layoutID: layout.id)
        await rig.coordinator.waitForRestoration()
        #expect(rig.launcher.launched == ["example.editor"])
        #expect(rig.coordinator.outcomes.first?.kind == .restored)
        rig.coordinator.stop()
    }
    @Test func missingApplicationWithLaunchingOffStaysUnavailable() async {
        let rig = Rig(library: library(), windows: [])
        await rig.start()
        #expect(rig.launcher.launched.isEmpty)
        #expect(rig.coordinator.outcomes.first?.kind == .missingApplication)
        rig.coordinator.stop()
    }
    @Test func disconnectDuringCaptureCannotReplaceSavedOrRememberedGeometry() async {
        var layout = CoreFixtures.layout(); layout.options.rememberAdjustments = true
        let rig = Rig(library: library(automatic: false, layouts: [layout]))
        await rig.start()
        rig.coordinator.selectSavedLayout(layout.id)
        await rig.windows.captureHook { @MainActor in
            rig.displays.value = DisplayTopology(displays: [CoreFixtures.primary], lid: .open)
            rig.coordinator.handle(.displayChanged)
        }
        await rig.coordinator.captureStableRecovery()
        #expect(rig.coordinator.library.layouts[0].saved == layout.saved)
        #expect(rig.coordinator.library.layouts[0].remembered == nil)
        rig.coordinator.stop()
    }
    @Test func partialCaptureNeverLearnsOrReplacesExplicitLayout() async {
        var layout = CoreFixtures.layout(); layout.options.rememberAdjustments = true
        let rig = Rig(library: library(automatic: false, layouts: [layout]))
        await rig.start(); rig.coordinator.selectSavedLayout(layout.id)
        await rig.windows.setCapture(.init(windows: [CoreFixtures.live(frame: Rect(x: 0, y: 0, width: 200, height: 200))], issues: [.init(bundleID: "other", message: "Timed out")]))
        await rig.coordinator.captureStableRecovery()
        #expect(rig.coordinator.library.layouts[0].saved == layout.saved)
        #expect(rig.coordinator.library.layouts[0].remembered == nil)
        rig.coordinator.stop()
    }
    @Test func swappedDisplayMappingCannotLearnCurrentIDsBackIntoOriginalLayout() async {
        var layout = CoreFixtures.layout()
        layout.options.rememberAdjustments = true
        let rig = Rig(library: library(automatic: false, layouts: [layout]))
        await rig.start()
        let mapping = DisplayMapping(layoutID: layout.id, targetSetupKey: layout.topology.setupKey,
                                     assignments: ["laptop": "office", "office": "laptop"])
        rig.coordinator.confirmMapping(mapping)
        rig.coordinator.requestApply(layoutID: layout.id, mapping: mapping.assignments)
        await rig.coordinator.waitForRestoration()
        var moved = await rig.windows.value.windows[0]
        moved.frame.x += 40
        await rig.windows.setCapture(WindowCapture(windows: [moved]))
        await rig.coordinator.captureStableRecovery()
        #expect(rig.coordinator.library.layouts[0].remembered == nil)
        #expect(rig.coordinator.library.layouts[0].saved == layout.saved)
        rig.coordinator.stop()
    }
    @Test func controlledClockCancelsQueuedAutomaticWorkImmediately() async {
        let clock = ControlledClock()
        let rig = Rig(library: library(), clock: clock)
        await rig.coordinator.start()
        for _ in 0..<100 where clock.pending == 0 { await Task.yield() }
        #expect(clock.pending == 1)
        rig.coordinator.setAutomatic(false)
        clock.advance()
        for _ in 0..<100 { await Task.yield() }
        #expect(await rig.windows.writes.isEmpty)
        #expect(!rig.coordinator.library.settings.automaticSwitching)
        rig.coordinator.stop()
        clock.advance()
    }
    @Test func disablingAutomaticDuringGeometryRestoreCancelsDespiteEarlierManualSelection() async {
        let layout = CoreFixtures.layout()
        let rig = Rig(library: library(layouts: [layout]))
        await rig.start()
        rig.coordinator.requestApply(layoutID: layout.id)
        await rig.coordinator.waitForRestoration()
        let countBeforeAutomatic = await rig.windows.writes.count
        await rig.windows.writeHook { @MainActor in
            let generation = rig.coordinator.gate.current
            #expect(rig.coordinator.state == .restoring)
            rig.coordinator.setAutomatic(false)
            #expect(!rig.coordinator.gate.isValid(generation))
        }
        rig.displays.value.displays[0].usableFrame.width -= 100
        rig.coordinator.handle(.displayChanged)
        await rig.coordinator.waitForSettling()
        #expect(!rig.coordinator.library.settings.automaticSwitching)
        #expect(rig.coordinator.state == .idle)
        #expect(await rig.windows.writes.count == countBeforeAutomatic)
        rig.coordinator.stop()
    }
    @Test func captureDenialOverridesStalePermissionCheck() async {
        let rig = Rig(library: library(automatic: false))
        await rig.start()
        await rig.windows.setCapture(WindowCapture(permissionGranted: false))
        rig.coordinator.requestApply(layoutID: rig.coordinator.library.layouts[0].id)
        await rig.coordinator.waitForRestoration()
        #expect(rig.permission.isTrusted)
        #expect(!rig.coordinator.permissionGranted)
        #expect(rig.coordinator.state == .permissionRequired)
        #expect(await rig.windows.writes.isEmpty)
        rig.coordinator.stop()
    }
    @Test func repeatedDeniedPermissionNotificationDoesNotPreventInitialTopologyDiscovery() async {
        let rig = Rig(library: library(automatic: false))
        rig.permission.isTrusted = false
        await rig.coordinator.start()
        rig.coordinator.handle(.permissionChanged)
        await rig.coordinator.waitForSettling()
        #expect(rig.coordinator.topology == CoreFixtures.topology)
        #expect(rig.coordinator.state == .permissionRequired)
        #expect(!rig.coordinator.permissionGranted)
        #expect(await rig.windows.writes.isEmpty)
        rig.coordinator.stop()
    }
    @Test func permissionRecheckImmediatelyReflectsGrantAndUnblocksCapture() async {
        let rig = Rig(library: library(automatic: false))
        rig.permission.isTrusted = false
        await rig.start()
        #expect(!rig.coordinator.permissionGranted)
        #expect(rig.coordinator.state == .permissionRequired)

        rig.permission.isTrusted = true
        rig.coordinator.handle(.permissionChanged)
        // The onboarding controls must update before display stabilization finishes.
        #expect(rig.coordinator.permissionGranted)
        await rig.coordinator.waitForSettling()
        #expect(rig.coordinator.state == .idle)
        #expect(await rig.coordinator.captureCurrent() != nil)
        #expect(await rig.windows.writes.isEmpty)
        rig.coordinator.stop()
    }
    @Test func repeatedGrantedPermissionRechecksDoNotRepeatAutomaticRestore() async {
        let rig = Rig(library: library())
        rig.permission.isTrusted = false
        await rig.start()
        #expect(await rig.windows.writes.isEmpty)

        rig.permission.isTrusted = true
        rig.coordinator.handle(.permissionChanged)
        await rig.coordinator.waitForSettling()
        let writes = await rig.windows.writes.count
        #expect(writes > 0)
        let generation = rig.coordinator.gate.current
        for _ in 0..<10 { rig.coordinator.handle(.permissionChanged) }
        await rig.coordinator.waitForSettling()
        #expect(rig.coordinator.permissionGranted)
        #expect(rig.coordinator.state == .idle)
        #expect(rig.coordinator.gate.current == generation)
        #expect(await rig.windows.writes.count == writes)
        rig.coordinator.stop()
    }
    @Test func lateWindowCaptureDenialAlsoExitsRestoring() async {
        var layout = CoreFixtures.layout()
        layout.options.launchMissingApplications = true
        let rig = Rig(library: library(automatic: false, layouts: [layout]), windows: [])
        rig.launcher.onLaunch = { await rig.windows.setCapture(WindowCapture(permissionGranted: false)) }
        await rig.start()
        rig.coordinator.requestApply(layoutID: layout.id)
        await rig.coordinator.waitForRestoration()
        #expect(rig.permission.isTrusted)
        #expect(!rig.coordinator.permissionGranted)
        #expect(rig.coordinator.state == .permissionRequired)
        #expect(await rig.windows.writes.isEmpty)
        rig.coordinator.stop()
    }
    @Test func manualCommandWinsWhileAutomaticWorkIsQueued() async {
        let clock = ControlledClock()
        let first = CoreFixtures.layout(), second = CoreFixtures.layout()
        let rig = Rig(library: library(layouts: [first, second]), clock: clock)
        await rig.coordinator.start()
        rig.coordinator.requestApply(layoutID: first.id)
        for _ in 0..<8 {
            for _ in 0..<100 { await Task.yield() }
            clock.advance()
        }
        #expect(rig.coordinator.selectedLayoutID == first.id)
        rig.coordinator.stop(); clock.advance()
    }
    @Test func staleGenerationIsRejectedBeforeMutation() async {
        let rig = Rig(library: library(automatic: false))
        await rig.start()
        let gate = rig.coordinator.gate
        await rig.windows.writeHook { gate.invalidate() }
        rig.coordinator.requestApply(layoutID: rig.coordinator.library.layouts[0].id)
        await rig.coordinator.waitForRestoration()
        #expect(await rig.windows.writes.isEmpty)
        rig.coordinator.stop()
    }
    @Test func activeUserMovementIsReportedWithoutRetrying() async {
        let rig = Rig(library: library(automatic: false))
        await rig.start(); await rig.windows.setFailure("example.editor", .cancelled)
        rig.coordinator.requestApply(layoutID: rig.coordinator.library.layouts[0].id)
        await rig.coordinator.waitForRestoration()
        #expect(await rig.windows.writes.isEmpty)
        #expect(rig.coordinator.outcomes.first?.kind == .cancelled)
        rig.coordinator.stop()
    }
    @Test(arguments: [false, true]) func layoutExclusionsPreventLaunchingAndMovingApplications(excludedIsRunning: Bool) async {
        let included = CoreFixtures.live(1, bundle: "included.app")
        let excluded = CoreFixtures.live(2, title: "Excluded", bundle: "excluded.app")
        var layout = CoreFixtures.layout(windows: [included, excluded].map { CoreFixtures.saved($0) })
        layout.options.launchMissingApplications = true
        layout.excludedBundleIDs = ["excluded.app"]
        let rig = Rig(library: library(automatic: false, layouts: [layout]), windows: excludedIsRunning ? [included, excluded] : [included])
        await rig.start()
        rig.coordinator.requestApply(layoutID: layout.id)
        await rig.coordinator.waitForRestoration()
        #expect(rig.launcher.launched.isEmpty)
        #expect(await rig.windows.writes.map { $0.liveWindow.identity.bundleID } == ["included.app"])
        #expect(rig.coordinator.outcomes.map(\.id) == [layout.saved.windows[0].id])
        #expect(rig.coordinator.library.layouts[0].saved == layout.saved)
        rig.coordinator.stop()
    }
    @Test(arguments: [false, true]) func singleDisplayApplyLeavesOtherDisplaysAndApplicationsAlone(otherAppIsRunning: Bool) async {
        let laptop = CoreFixtures.live(1, bundle: "laptop.app")
        let external = CoreFixtures.live(2, title: "External", bundle: "external.app", frame: Rect(x: 1600, y: 100, width: 700, height: 500))
        var layout = CoreFixtures.layout(windows: [laptop, external].map { CoreFixtures.saved($0) })
        layout.options.launchMissingApplications = true
        layout.options.rememberAdjustments = true
        layout.remembered = .init(windows: layout.saved.windows)
        let scope = Set(layout.effectiveWindows.filter { $0.displayID == "laptop" }.map(\.id))
        let rig = Rig(library: library(automatic: false, layouts: [layout]), windows: otherAppIsRunning ? [laptop, external] : [laptop])
        await rig.start()
        rig.coordinator.requestApply(layoutID: layout.id, windowScope: scope)
        await rig.coordinator.waitForRestoration()
        #expect(rig.launcher.launched.isEmpty)
        #expect(await rig.windows.writes.map { $0.liveWindow.identity.bundleID } == ["laptop.app"])
        #expect(rig.coordinator.library.layouts[0].saved == layout.saved)
        #expect(rig.coordinator.library.layouts[0].remembered == layout.remembered)
        #expect(rig.coordinator.outcomes.map(\.id) == Array(scope))
        rig.coordinator.stop()
    }
    @Test func scopedRequestQueuedDuringSettlingKeepsItsWindowScope() async {
        let first = CoreFixtures.live(1, bundle: "included.app")
        let second = CoreFixtures.live(2, title: "External", bundle: "other.app", frame: Rect(x: 1600, y: 100, width: 700, height: 500))
        let layout = CoreFixtures.layout(windows: [first, second].map { CoreFixtures.saved($0) })
        let rig = Rig(library: library(automatic: false, layouts: [layout]), windows: [first, second])
        await rig.coordinator.start()
        #expect(rig.coordinator.state == .settling)
        rig.coordinator.requestApply(layoutID: layout.id, windowScope: [layout.saved.windows[0].id])
        await rig.coordinator.waitForSettling()
        #expect(rig.coordinator.state == .idle)
        #expect(await rig.windows.writes.map { $0.liveWindow.identity.bundleID } == ["included.app"])
        #expect(rig.coordinator.outcomes.map(\.id) == [layout.saved.windows[0].id])
        rig.coordinator.stop()
    }
    @Test func interruptedScopedApplyKeepsItsScopeAfterDisplaySettling() async {
        let first = CoreFixtures.live(1, bundle: "included.app")
        let second = CoreFixtures.live(2, title: "External", bundle: "other.app", frame: Rect(x: 1600, y: 100, width: 700, height: 500))
        let layout = CoreFixtures.layout(windows: [first, second].map { CoreFixtures.saved($0) })
        let rig = Rig(library: library(automatic: false, layouts: [layout]), windows: [first, second])
        await rig.start()
        await rig.windows.writeHook { @MainActor in
            await rig.windows.writeHook(nil)
            rig.displays.value.displays[0].usableFrame.width -= 100
            rig.coordinator.handle(.displayChanged)
        }
        rig.coordinator.requestApply(layoutID: layout.id, windowScope: [layout.saved.windows[0].id])
        await rig.coordinator.waitForRestoration()
        await rig.coordinator.waitForSettling()
        #expect(rig.coordinator.state == .idle)
        #expect(await rig.windows.writes.map { $0.liveWindow.identity.bundleID } == ["included.app"])
        #expect(rig.coordinator.outcomes.map(\.id) == [layout.saved.windows[0].id])
        rig.coordinator.stop()
    }
    @Test func retryOfScopedApplyDoesNotLaunchOtherDisplayApplications() async {
        let first = CoreFixtures.live(1, bundle: "included.app")
        let second = CoreFixtures.live(2, title: "External", bundle: "other.app", frame: Rect(x: 1600, y: 100, width: 700, height: 500))
        var layout = CoreFixtures.layout(windows: [first, second].map { CoreFixtures.saved($0) })
        layout.options.launchMissingApplications = true
        let rig = Rig(library: library(automatic: false, layouts: [layout]), windows: [first])
        await rig.start()
        await rig.windows.setFailure("included.app", .timedOut)
        rig.coordinator.requestApply(layoutID: layout.id, windowScope: [layout.saved.windows[0].id])
        await rig.coordinator.waitForRestoration()
        #expect(rig.coordinator.outcomes.first?.kind == .timedOut)
        #expect(rig.launcher.launched.isEmpty)
        await rig.windows.setFailure("included.app", .restored)
        rig.coordinator.retryUnresolved()
        await rig.coordinator.waitForRestoration()
        #expect(rig.launcher.launched.isEmpty)
        #expect(await rig.windows.writes.map { $0.liveWindow.identity.bundleID } == ["included.app"])
        rig.coordinator.stop()
    }
    @Test(arguments: [false, true]) func scopedReviewMappingIsRetainedOnlyUntilReconfiguration(reconfigured: Bool) async {
        let first = CoreFixtures.live(1, bundle: "included.app")
        let second = CoreFixtures.live(2, title: "External", bundle: "other.app", frame: Rect(x: 1600, y: 100, width: 700, height: 500))
        var layout = CoreFixtures.layout(windows: [first, second].map { CoreFixtures.saved($0) })
        layout.importedNeedsMapping = true
        var data = library(automatic: false, layouts: [layout])
        data.preferredLayouts = [:]
        let rig = Rig(library: data, windows: [first, second])
        await rig.start()
        await rig.windows.setFailure("included.app", .timedOut)
        rig.coordinator.requestApply(layoutID: layout.id, mapping: ["laptop": "office"], windowScope: [layout.saved.windows[0].id])
        await rig.coordinator.waitForRestoration()
        #expect(rig.coordinator.outcomes.first?.kind == .timedOut)
        #expect(rig.coordinator.library.displayMappings.isEmpty)
        await rig.windows.setFailure("included.app", .restored)
        if reconfigured {
            rig.coordinator.handle(.displayChanged)
            await rig.coordinator.waitForSettling()
        }
        rig.coordinator.retryUnresolved()
        await rig.coordinator.waitForRestoration()
        #expect(await rig.windows.writes.count == (reconfigured ? 0 : 1))
        if !reconfigured {
            let expected = CoordinateMapper.targetFrame(for: layout.saved.windows[0], on: CoreFixtures.external,
                in: CoreFixtures.topology, preserveSize: false)
            #expect(await rig.windows.writes.first?.targetFrame == expected)
            #expect(await rig.windows.writes.first?.liveWindow.identity.bundleID == "included.app")
        }
        #expect(rig.coordinator.library.layouts[0].importedNeedsMapping)
        rig.coordinator.stop()
    }
    @Test func changingLayoutExclusionsCancelsBeforeNextMutation() async {
        let first = CoreFixtures.live(1, bundle: "first.app")
        let second = CoreFixtures.live(2, title: "Second", bundle: "second.app")
        let layout = CoreFixtures.layout(windows: [first, second].map { CoreFixtures.saved($0) })
        let rig = Rig(library: library(automatic: false, layouts: [layout]), windows: [first, second])
        await rig.start()
        await rig.windows.writeHook { @MainActor in
            rig.coordinator.updateLibrary { $0.layouts[0].excludedBundleIDs = ["first.app", "second.app"] }
        }
        rig.coordinator.requestApply(layoutID: layout.id)
        await rig.coordinator.waitForRestoration()
        #expect(await rig.windows.writes.isEmpty)
        #expect(rig.coordinator.state == .idle)
        #expect(rig.coordinator.library.layouts[0].excludedBundleIDs == ["first.app", "second.app"])
        #expect(rig.coordinator.library.layouts[0].saved == layout.saved)
        rig.coordinator.stop()
    }
    @Test func changingLayoutExclusionsDuringSettlingStillCompletesDiscovery() async {
        let layout = CoreFixtures.layout()
        let rig = Rig(library: library(automatic: false, layouts: [layout]))
        await rig.coordinator.start()
        #expect(rig.coordinator.state == .settling)
        rig.coordinator.updateLibrary { $0.layouts[0].excludedBundleIDs = ["example.editor"] }
        await rig.coordinator.waitForSettling()
        #expect(rig.coordinator.state == .idle)
        #expect(rig.coordinator.topology == CoreFixtures.topology)
        #expect(await rig.windows.writes.isEmpty)
        rig.coordinator.stop()
    }
    @Test func missingApplicationExcludedInSettingsIsNotLaunched() async {
        var layout = CoreFixtures.layout()
        layout.options.launchMissingApplications = true
        var data = library(automatic: false, layouts: [layout])
        data.exclusions = [.init(bundleID: "example.editor")]
        let rig = Rig(library: data, windows: [])
        await rig.start()
        rig.coordinator.requestApply(layoutID: layout.id)
        await rig.coordinator.waitForRestoration()
        #expect(rig.launcher.launched.isEmpty)
        #expect(await rig.windows.writes.isEmpty)
        #expect(rig.coordinator.outcomes.first?.kind == .unsupported)
        rig.coordinator.stop()
    }
    @Test func undoUsesOriginalLayoutsCurrentExclusionsAfterSelectionChanges() async {
        let included = CoreFixtures.live(1, bundle: "included.app")
        let excluded = CoreFixtures.live(2, title: "Excluded", bundle: "excluded.app")
        let layout = CoreFixtures.layout(windows: [included, excluded].map { CoreFixtures.saved($0) })
        let anotherLayout = CoreFixtures.layout()
        var movedIncluded = included; movedIncluded.frame.x += 100
        var movedExcluded = excluded; movedExcluded.frame.x += 200
        let rig = Rig(library: library(automatic: false, layouts: [layout, anotherLayout]), windows: [movedIncluded, movedExcluded])
        await rig.start()
        rig.coordinator.requestApply(layoutID: layout.id)
        await rig.coordinator.waitForRestoration()
        #expect(await rig.windows.writes.count == 2)
        #expect(rig.coordinator.canUndo)
        rig.coordinator.updateLibrary { $0.layouts[0].excludedBundleIDs = ["excluded.app"] }
        rig.coordinator.selectSavedLayout(anotherLayout.id)
        await rig.coordinator.undo()
        #expect(await rig.windows.writes.count == 3)
        #expect(await rig.windows.writes.last?.liveWindow.identity.bundleID == "included.app")
        #expect(await rig.windows.writes.last?.targetFrame == movedIncluded.frame)
        #expect(await rig.windows.value.windows.first(where: { $0.id == excluded.id })?.frame == excluded.frame)
        #expect(!rig.coordinator.canUndo)
        rig.coordinator.stop()
    }
    @Test func excludingApplicationWhileUndoIsInFlightStopsItsWrite() async {
        let layout = CoreFixtures.layout()
        let moved = CoreFixtures.live(frame: Rect(x: 300, y: 200, width: 700, height: 500))
        let rig = Rig(library: library(automatic: false, layouts: [layout]), windows: [moved])
        await rig.start()
        rig.coordinator.requestApply(layoutID: layout.id)
        await rig.coordinator.waitForRestoration()
        #expect(await rig.windows.writes.count == 1)
        await rig.windows.writeHook { @MainActor in
            rig.coordinator.updateLibrary { $0.layouts[0].excludedBundleIDs = ["example.editor"] }
        }
        await rig.coordinator.undo()
        #expect(await rig.windows.writes.count == 1)
        #expect(rig.coordinator.state == .idle)
        rig.coordinator.stop()
    }
    @Test func applyReportsAcceptanceWhenRestorationStarts() async {
        let layout = CoreFixtures.layout()
        let rig = Rig(library: library(automatic: false, layouts: [layout]))
        await rig.start()
        #expect(rig.coordinator.requestApply(layoutID: layout.id))
        #expect(rig.coordinator.state == .restoring)
        await rig.coordinator.waitForRestoration()
        #expect(await rig.windows.writes.count == 1)
        rig.coordinator.stop()
    }
    @Test func applyReportsAcceptanceForExplicitRequestQueuedDuringSettling() async {
        let layout = CoreFixtures.layout()
        let rig = Rig(library: library(automatic: false, layouts: [layout]))
        await rig.coordinator.start()
        #expect(rig.coordinator.state == .settling)
        #expect(rig.coordinator.requestApply(layoutID: layout.id))
        await rig.coordinator.waitForSettling()
        #expect(await rig.windows.writes.count == 1)
        rig.coordinator.stop()
    }
    @Test func manualLaptopLayoutUsesBuiltInDisplayWithExternalConnected() async {
        let laptop = DisplayTopology(displays: [CoreFixtures.primary], lid: .open)
        var layout = CoreFixtures.layout(windows: [CoreFixtures.saved(topology: laptop)], topology: laptop)
        layout.options.rememberAdjustments = true
        let original = layout.saved
        let moved = CoreFixtures.live(frame: Rect(x: 400, y: 240, width: 700, height: 500))
        let rig = Rig(library: library(layouts: [layout]), windows: [moved])
        await rig.start()
        #expect(await rig.windows.writes.isEmpty)
        #expect(!rig.coordinator.isCompatible(layout))
        #expect(rig.coordinator.manualMapping(for: layout) == ["laptop": "laptop"])
        #expect(!rig.coordinator.requestApply(layoutID: layout.id, automatic: true))
        #expect(rig.coordinator.requestApply(layoutID: layout.id))
        await rig.coordinator.waitForRestoration()
        #expect(await rig.windows.writes.count == 1)
        #expect(await rig.windows.writes.first?.targetFrame == original.windows[0].frame)
        #expect(rig.coordinator.library.layouts[0].saved == original)
        #expect(rig.coordinator.library.layouts[0].remembered == nil)
        #expect(rig.coordinator.library.displayMappings.isEmpty)
        #expect(rig.coordinator.library.preferredLayouts[CoreFixtures.topology.setupKey] == nil)
        rig.coordinator.stop()
    }
    @Test func manualDisplayDetectionResolvesAfterSettling() async {
        let laptop = DisplayTopology(displays: [CoreFixtures.primary], lid: .open)
        let layout = CoreFixtures.layout(windows: [CoreFixtures.saved(topology: laptop)], topology: laptop)
        let rig = Rig(library: library(automatic: false, layouts: [layout]))
        await rig.coordinator.start()
        #expect(rig.coordinator.requestApply(layoutID: layout.id))
        await rig.coordinator.waitForSettling()
        #expect(await rig.windows.writes.count == 1)
        rig.coordinator.stop()
    }
    @Test func selectedBuiltInDisplayDoesNotNeedUnrelatedMonitorMapping() async {
        var savedTopology = CoreFixtures.topology
        savedTopology.displays[1].identityIsAmbiguous = true
        var second = savedTopology.displays[1]
        second.id = "second"; second.uuid = "SECOND"
        second.frame.x = 3360; second.usableFrame.x = 3360
        savedTopology.displays.append(second)
        let laptopWindow = CoreFixtures.live()
        let externalWindow = CoreFixtures.live(2, title: "External", bundle: "external.app",
            frame: Rect(x: 1500, y: 100, width: 700, height: 500))
        let layout = CoreFixtures.layout(windows: [laptopWindow, externalWindow].map {
            CoreFixtures.saved($0, topology: savedTopology)
        }, topology: savedTopology)
        let rig = Rig(library: library(automatic: false, layouts: [layout]), windows: [laptopWindow, externalWindow])
        await rig.start()
        let scope: Set<UUID> = [layout.saved.windows[0].id]
        #expect(rig.coordinator.manualMapping(for: layout) == nil)
        #expect(rig.coordinator.manualMapping(for: layout, windowScope: scope) == ["laptop": "laptop"])
        #expect(rig.coordinator.requestApply(layoutID: layout.id, windowScope: scope))
        await rig.coordinator.waitForRestoration()
        #expect(await rig.windows.writes.map { $0.liveWindow.id } == [laptopWindow.id])
        #expect(await rig.windows.value.windows.first { $0.id == externalWindow.id }?.frame == externalWindow.frame)
        #expect(rig.coordinator.outcomes.count == 1)
        rig.coordinator.stop()
    }
    @Test func explicitMappingTakesPrecedenceOverDetectedBuiltIn() async {
        let laptop = DisplayTopology(displays: [CoreFixtures.primary], lid: .open)
        let layout = CoreFixtures.layout(windows: [CoreFixtures.saved(topology: laptop)], topology: laptop)
        let rig = Rig(library: library(automatic: false, layouts: [layout]))
        await rig.start()
        rig.coordinator.confirmMapping(DisplayMapping(layoutID: layout.id,
            targetSetupKey: CoreFixtures.topology.setupKey, assignments: ["laptop": "office"]))
        #expect(rig.coordinator.manualMapping(for: layout) == ["laptop": "office"])
        #expect(rig.coordinator.requestApply(layoutID: layout.id))
        await rig.coordinator.waitForRestoration()
        let expected = CoordinateMapper.targetFrame(for: layout.saved.windows[0], on: CoreFixtures.external,
            in: CoreFixtures.topology, preserveSize: false)
        #expect(await rig.windows.writes.first?.targetFrame == expected)
        rig.coordinator.stop()
    }
    @Test func importedLayoutStillNeedsReviewBeforeManualApply() async {
        var layout = CoreFixtures.layout()
        layout.importedNeedsMapping = true
        var data = library(automatic: false, layouts: [layout])
        data.preferredLayouts = [:]
        let rig = Rig(library: data)
        await rig.start()
        #expect(rig.coordinator.manualMapping(for: layout) == nil)
        #expect(!rig.coordinator.requestApply(layoutID: layout.id))
        #expect(await rig.windows.writes.isEmpty)
        rig.coordinator.stop()
    }
    @Test(arguments: ["stalePermission", "suspended", "missingLayout", "mappingRequired", "invalidMapping", "noDisplays", "automaticDisabled"])
    func applyReportsRejectionWithoutConsumingRequest(reason: String) async {
        let layout = CoreFixtures.layout()
        var topology = CoreFixtures.topology
        if reason == "mappingRequired" {
            topology.displays[1].uuid = "OTHER-DESK"
            var another = topology.displays[1]
            another.id = "another"; another.uuid = "ANOTHER-DESK"
            topology.displays.append(another)
        }
        let rig = Rig(library: library(automatic: false, layouts: [layout]), topology: topology)
        await rig.start()
        var requestedID = layout.id
        var mapping: [String: String]?
        switch reason {
        case "stalePermission":
            #expect(rig.coordinator.permissionGranted)
            rig.permission.isTrusted = false
        case "suspended": rig.coordinator.handle(.sleep)
        case "missingLayout": requestedID = UUID()
        case "invalidMapping": mapping = ["laptop": "disconnected"]
        case "noDisplays": rig.displays.value = DisplayTopology()
        default: break
        }
        #expect(!rig.coordinator.requestApply(layoutID: requestedID, mapping: mapping, automatic: reason == "automaticDisabled"))
        #expect(await rig.windows.writes.isEmpty)
        if reason == "stalePermission" { #expect(!rig.coordinator.permissionGranted) }
        rig.coordinator.stop()
    }

    private func movedEditDraft(_ layout: Layout, x: Double = 260) throws -> LayoutEditDraft {
        var draft = LayoutEditDraft(layout: layout)
        try draft.setWindowFrame(windowID: layout.effectiveWindows[0].id,
                                 relativeFrame: Rect(x: x, y: 150, width: 640, height: 420))
        return draft
    }

    @Test func savedLayoutCanBeEditedOfflineWithoutAccessibilityPermission() async throws {
        let layout = CoreFixtures.layout()
        let laptop = DisplayTopology(displays: [CoreFixtures.primary], lid: .open)
        let rig = Rig(library: library(automatic: false, layouts: [layout]), topology: laptop)
        defer { rig.coordinator.stop() }
        rig.permission.isTrusted = false
        await rig.start()
        let session = UUID()
        #expect(rig.coordinator.beginLayoutEditing(layoutID: layout.id, sessionID: session))
        let draft = try movedEditDraft(layout)
        #expect(rig.coordinator.commitLayoutEdit(draft))
        rig.coordinator.endLayoutEditing(sessionID: session)
        let saved = try #require(rig.coordinator.library.layouts.first)
        #expect(saved.saved.windows[0].frame == draft.revision.windows[0].frame)
        #expect(saved.topology == layout.topology)
        #expect(saved.editedAwaitingApply)
        #expect(await rig.windows.writes.isEmpty)
        #expect(await rig.windows.desktopCalls.isEmpty)
    }

    @Test func savingOfflineEditsPausesAutoLearningUntilSuccessfulFullApply() async throws {
        let original = CoreFixtures.layout()
        let rig = Rig(library: autoLibrary([original]))
        defer { rig.coordinator.stop() }
        await rig.start()
        let source = try #require(rig.coordinator.library.layouts.first)
        let initialWrites = await rig.windows.writes.count
        let session = UUID()
        #expect(rig.coordinator.beginLayoutEditing(layoutID: source.id, sessionID: session))
        #expect(!rig.coordinator.requestApply(layoutID: source.id))
        #expect(!rig.coordinator.requestApply(layoutID: source.id, automatic: true))
        let draft = try movedEditDraft(source)
        var live = CoreFixtures.live(); live.frame.x = 430
        await rig.windows.setCapture(.init(windows: [live]))
        await rig.coordinator.captureStableRecovery()
        #expect(rig.coordinator.commitLayoutEdit(draft))
        rig.coordinator.endLayoutEditing(sessionID: session)
        await rig.coordinator.captureStableRecovery()
        rig.coordinator.pollAutoMode()
        await Task.yield()
        await rig.coordinator.captureStableRecovery()
        let pending = try #require(rig.coordinator.library.layouts.first)
        #expect(pending.editedAwaitingApply)
        #expect(pending.saved.windows[0].frame == draft.revision.windows[0].frame)
        #expect(pending.remembered == nil)
        #expect(await rig.windows.writes.count == initialWrites)
        #expect(await rig.windows.value.windows[0].frame == live.frame)

        #expect(rig.coordinator.requestApply(layoutID: source.id))
        await rig.coordinator.waitForRestoration()
        #expect(!rig.coordinator.library.layouts[0].editedAwaitingApply)
        #expect(await rig.windows.value.windows[0].frame == pending.saved.windows[0].frame)
        var adjusted = live
        adjusted.frame = pending.saved.windows[0].frame
        adjusted.frame.x += 70
        await rig.windows.setCapture(.init(windows: [adjusted]))
        await rig.coordinator.captureStableRecovery()
        #expect(rig.coordinator.library.layouts[0].saved == pending.saved)
        #expect(rig.coordinator.library.layouts[0].remembered?.windows[0].frame == adjusted.frame)
        #expect(rig.coordinator.library.layouts[0].options.autoSaveEnabled)
    }

    @Test func cancellingSavedLayoutEditingLeavesLibraryAndLiveWindowsUnchanged() async throws {
        let layout = CoreFixtures.layout()
        let rig = Rig(library: library(automatic: false, layouts: [layout]))
        defer { rig.coordinator.stop() }
        await rig.start()
        let before = rig.coordinator.library.layouts
        let session = UUID()
        #expect(rig.coordinator.beginLayoutEditing(layoutID: layout.id, sessionID: session))
        let draft = try movedEditDraft(layout)
        #expect(draft.hasChanges)
        rig.coordinator.endLayoutEditing(sessionID: session)
        #expect(rig.coordinator.library.layouts == before)
        #expect(await rig.windows.writes.isEmpty)
        #expect(await rig.windows.value.windows[0].frame == CoreFixtures.live().frame)
    }

    @Test(arguments: [false, true])
    func savedLayoutEditRejectsAStaleSourceEvenWhenRevisionIDWasReused(reuseRevisionID: Bool) async throws {
        let layout = CoreFixtures.layout()
        let rig = Rig(library: library(automatic: false, layouts: [layout]))
        defer { rig.coordinator.stop() }
        await rig.start()
        let session = UUID()
        #expect(rig.coordinator.beginLayoutEditing(layoutID: layout.id, sessionID: session))
        let stale = try movedEditDraft(layout, x: 260)
        var replacement = try movedEditDraft(layout, x: 500).validatedRevision()
        if reuseRevisionID { replacement.id = layout.saved.id }
        rig.coordinator.updateLibrary { $0.layouts[0].saved = replacement }
        #expect(!rig.coordinator.commitLayoutEdit(stale))
        #expect(rig.coordinator.library.layouts[0].saved == replacement)
        #expect(!rig.coordinator.library.layouts[0].editedAwaitingApply)
        #expect(await rig.windows.writes.isEmpty)
        rig.coordinator.endLayoutEditing(sessionID: session)
    }

    @Test func savedLayoutEditPromotesEffectiveRevisionAndPreservesBothHistoriesAndCurrentMetadata() async throws {
        var layout = CoreFixtures.layout()
        let previousSaved = layout.saved
        layout.remembered = try movedEditDraft(layout, x: 360).validatedRevision()
        let previousRemembered = try #require(layout.remembered)
        let existingHistory = LayoutRevision(windows: layout.saved.windows)
        layout.history = [existingHistory]
        let rig = Rig(library: library(automatic: false, layouts: [layout]))
        defer { rig.coordinator.stop() }
        await rig.start()
        let session = UUID()
        #expect(rig.coordinator.beginLayoutEditing(layoutID: layout.id, sessionID: session))
        let draft = try movedEditDraft(layout, x: 450)
        #expect(draft.sourceRevision == previousRemembered)
        rig.coordinator.updateLibrary {
            $0.layouts[0].name = "Renamed while editing"
            $0.layouts[0].options.preserveWindowSize = true
        }
        #expect(rig.coordinator.commitLayoutEdit(draft))
        let committed = rig.coordinator.library.layouts[0]
        #expect(committed.saved.id != previousSaved.id)
        #expect(committed.saved.id != previousRemembered.id)
        #expect(committed.saved.windows == draft.revision.windows)
        #expect(committed.remembered == nil)
        #expect(committed.history.contains(existingHistory))
        #expect(committed.history.contains(previousSaved))
        #expect(committed.history.contains(previousRemembered))
        #expect(Set(committed.history.map(\.id)).count == committed.history.count)
        #expect(committed.name == "Renamed while editing")
        #expect(committed.options.preserveWindowSize)
        #expect(committed.editedAwaitingApply)
        #expect(await rig.windows.writes.isEmpty)
        rig.coordinator.endLayoutEditing(sessionID: session)
    }

    @Test(arguments: [WindowOutcomeKind.unsupported, .missingApplication])
    func incompleteApplyCannotClearOfflineEditProtection(failure: WindowOutcomeKind) async throws {
        let layout = CoreFixtures.layout()
        let rig = Rig(library: library(automatic: false, layouts: [layout]))
        defer { rig.coordinator.stop() }
        await rig.start()
        let session = UUID()
        #expect(rig.coordinator.beginLayoutEditing(layoutID: layout.id, sessionID: session))
        #expect(rig.coordinator.commitLayoutEdit(try movedEditDraft(layout)))
        rig.coordinator.endLayoutEditing(sessionID: session)
        await rig.windows.setFailure("example.editor", failure)
        #expect(rig.coordinator.requestApply(layoutID: layout.id))
        await rig.coordinator.waitForRestoration()
        #expect(rig.coordinator.outcomes.first?.kind == failure)
        #expect(rig.coordinator.library.layouts[0].editedAwaitingApply)
        #expect(rig.coordinator.library.layouts[0].remembered == nil)
    }

    @Test(arguments: ["scope", "retry"])
    func partialApplyCannotClearOfflineEditProtection(mode: String) async throws {
        let layout = CoreFixtures.layout()
        let rig = Rig(library: library(automatic: false, layouts: [layout]))
        defer { rig.coordinator.stop() }
        await rig.start()
        let session = UUID()
        #expect(rig.coordinator.beginLayoutEditing(layoutID: layout.id, sessionID: session))
        #expect(rig.coordinator.commitLayoutEdit(try movedEditDraft(layout)))
        rig.coordinator.endLayoutEditing(sessionID: session)
        let ids: Set<UUID> = [layout.saved.windows[0].id]
        #expect(rig.coordinator.requestApply(layoutID: layout.id, retryOnly: mode == "retry" ? ids : nil,
                                             windowScope: mode == "scope" ? ids : nil))
        await rig.coordinator.waitForRestoration()
        #expect(rig.coordinator.outcomes.allSatisfy { $0.kind.succeeded })
        #expect(rig.coordinator.library.layouts[0].editedAwaitingApply)
    }

    @Test func endingOneEditorCannotReleaseAnotherEditorsPause() async {
        let layout = CoreFixtures.layout()
        let rig = Rig(library: library(automatic: false, layouts: [layout]))
        defer { rig.coordinator.stop() }
        await rig.start()
        let first = UUID(), second = UUID()
        #expect(rig.coordinator.beginLayoutEditing(layoutID: layout.id, sessionID: first))
        #expect(rig.coordinator.beginLayoutEditing(layoutID: layout.id, sessionID: second))
        rig.coordinator.endLayoutEditing(sessionID: UUID())
        rig.coordinator.endLayoutEditing(sessionID: first)
        #expect(!rig.coordinator.requestApply(layoutID: layout.id))
        #expect(await rig.windows.writes.isEmpty)
        rig.coordinator.endLayoutEditing(sessionID: second)
        #expect(rig.coordinator.requestApply(layoutID: layout.id))
        await rig.coordinator.waitForRestoration()
        #expect(await rig.windows.writes.count == 1)
    }

    @Test func restartingAutoModeAppliesPendingEditedRevisionBeforeLearningLiveGeometry() async throws {
        var edited = CoreFixtures.layout()
        edited.saved = try movedEditDraft(edited, x: 400).validatedRevision()
        edited.editedAwaitingApply = true
        var live = CoreFixtures.live(); live.frame.x = 30
        let rig = Rig(library: autoLibrary([edited]), windows: [live])
        defer { rig.coordinator.stop() }
        await rig.start()
        #expect(await rig.windows.writes.count == 1)
        #expect(await rig.windows.value.windows[0].frame == edited.saved.windows[0].frame)
        #expect(rig.coordinator.library.layouts[0].saved == edited.saved)
        #expect(!rig.coordinator.library.layouts[0].editedAwaitingApply)
        #expect(rig.coordinator.library.layouts[0].remembered == nil)
    }

    @Test func savingOfflineEditsPreservesDeferredRestoreForNewDisplaySetup() async throws {
        let dock = CoreFixtures.layout()
        let laptopTopology = DisplayTopology(displays: [CoreFixtures.primary], lid: .open)
        var laptopWindow = CoreFixtures.live()
        laptopWindow.frame.x = 420
        let laptop = CoreFixtures.layout(windows: [CoreFixtures.saved(laptopWindow, topology: laptopTopology)],
                                         topology: laptopTopology)
        let rig = Rig(library: autoLibrary([dock, laptop]))
        defer { rig.coordinator.stop() }
        await rig.start()
        let source = try #require(rig.coordinator.library.layouts.first { $0.id == dock.id })
        let session = UUID()
        #expect(rig.coordinator.beginLayoutEditing(layoutID: dock.id, sessionID: session))
        let draft = try movedEditDraft(source)
        let initialWrites = await rig.windows.writes.count

        var collapsed = laptopWindow
        collapsed.frame.x = 30
        rig.displays.value = laptopTopology
        await rig.windows.setCapture(.init(windows: [collapsed]))
        rig.coordinator.handle(.displayChanged)
        await rig.coordinator.waitForSettling()
        #expect(rig.coordinator.topology == laptopTopology)
        #expect(await rig.windows.writes.count == initialWrites)

        #expect(rig.coordinator.commitLayoutEdit(draft))
        rig.coordinator.endLayoutEditing(sessionID: session)
        await rig.coordinator.waitForSettling()
        #expect(await rig.windows.writes.count == initialWrites + 1)
        #expect(await rig.windows.value.windows.first?.frame == laptop.saved.windows[0].frame)
        #expect(rig.coordinator.selectedLayoutID == laptop.id)
        #expect(rig.coordinator.library.layouts.first { $0.id == dock.id }?.editedAwaitingApply == true)
    }

    @Test func geometryOnlyApplyCannotReleasePendingDesktopEditProtection() async {
        var saved = CoreFixtures.saved()
        saved.desktopAssignment = .desktop("saved2")
        var layout = Layout(name: "Edited desktops", topology: CoreFixtures.topology,
                            windows: [saved], desktopSnapshot: desktops())
        layout.options.restoreDesktops = false
        layout.editedAwaitingApply = true
        var live = CoreFixtures.live()
        live.desktopAssignment = .desktop("before1")
        let rig = Rig(library: autoLibrary([layout]), windows: [live])
        defer { rig.coordinator.stop() }
        await rig.windows.setCapture(.init(windows: [live], desktopSnapshot: desktops("before")))
        await rig.start()
        #expect(rig.coordinator.outcomes.allSatisfy { $0.kind.succeeded })
        #expect(await rig.windows.desktopCalls == ["geometry"])
        #expect(rig.coordinator.library.layouts[0].editedAwaitingApply)
        await rig.coordinator.captureStableRecovery()
        #expect(rig.coordinator.library.layouts[0].saved == layout.saved)
        #expect(rig.coordinator.library.layouts[0].remembered == nil)
        #expect(rig.coordinator.library.layouts[0].effectiveWindows[0].desktopAssignment == .desktop("saved2"))
    }

    @Test func editingUnrelatedPresetDoesNotStopCurrentAutoPresetLearning() async throws {
        let active = CoreFixtures.layout()
        let other = CoreFixtures.layout()
        var data = autoLibrary([active, other])
        data.autoLayoutIDs[CoreFixtures.topology.setupKey] = active.id
        let rig = Rig(library: data)
        defer { rig.coordinator.stop() }
        await rig.start()
        let source = try #require(rig.coordinator.library.layouts.first { $0.id == other.id })
        let initialWrites = await rig.windows.writes.count
        let session = UUID()
        #expect(rig.coordinator.beginLayoutEditing(layoutID: other.id, sessionID: session))
        #expect(rig.coordinator.commitLayoutEdit(try movedEditDraft(source, x: 500)))
        rig.coordinator.endLayoutEditing(sessionID: session)

        var adjusted = CoreFixtures.live()
        adjusted.frame.x += 80
        await rig.windows.setCapture(.init(windows: [adjusted]))
        await rig.coordinator.captureStableRecovery()
        let learned = try #require(rig.coordinator.library.layouts.first { $0.id == active.id })
        let edited = try #require(rig.coordinator.library.layouts.first { $0.id == other.id })
        #expect(learned.saved == active.saved)
        #expect(learned.remembered?.windows[0].frame == adjusted.frame)
        #expect(edited.editedAwaitingApply)
        #expect(edited.remembered == nil)
        #expect(rig.coordinator.library.autoLayoutIDs[CoreFixtures.topology.setupKey] == active.id)
        #expect(await rig.windows.writes.count == initialWrites)
    }
}
