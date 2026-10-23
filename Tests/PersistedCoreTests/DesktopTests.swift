import Foundation
import Testing
@testable import PersistedCore

struct DesktopTests {
    private func snapshot(prefix: String = "") -> DesktopSnapshot {
        DesktopSnapshot(displays: [
            DesktopDisplay(displayID: "laptop", desktops: [
                SavedDesktop(id: "\(prefix)laptop-1", ordinal: 0, uuidHint: "local-laptop-1", isActive: true),
                SavedDesktop(id: "\(prefix)laptop-2", ordinal: 1, uuidHint: "local-laptop-2")
            ]),
            DesktopDisplay(displayID: "office", desktops: [
                SavedDesktop(id: "\(prefix)office-1", ordinal: 0, uuidHint: "local-office-1", isActive: true)
            ])
        ], separateDisplays: true)
    }

    private func fixture() -> Library {
        var window = CoreFixtures.saved()
        window.desktopAssignment = .desktop("laptop-2")
        let layout = Layout(name: "Work", topology: CoreFixtures.topology, windows: [window], desktopSnapshot: snapshot())
        var library = Library()
        library.layouts = [layout]
        return library
    }

    @Test func oldLibraryMigratesWithoutInventingDesktopMembership() throws {
        var original = Library()
        original.layouts = [CoreFixtures.layout()]
        let encoded = try LayoutRepository.encode(original)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["schemaVersion"] = 1
        var layouts = try #require(object["layouts"] as? [[String: Any]])
        var options = try #require(layouts[0]["options"] as? [String: Any])
        options.removeValue(forKey: "restoreDesktops")
        layouts[0]["options"] = options
        object["layouts"] = layouts

        let migrated = try LayoutRepository.decode(JSONSerialization.data(withJSONObject: object))
        #expect(migrated.schemaVersion == 2)
        #expect(migrated.layouts[0].id == original.layouts[0].id)
        #expect(migrated.layouts[0].effectiveWindows == original.layouts[0].effectiveWindows)
        #expect(migrated.layouts[0].effectiveDesktopSnapshot == nil)
        #expect(migrated.layouts[0].options.restoreDesktops)
        let rewritten = try #require(JSONSerialization.jsonObject(with: LayoutRepository.encode(migrated)) as? [String: Any])
        #expect(rewritten["schemaVersion"] as? Int == 2)
    }

    @Test func encoderAlwaysWritesCurrentFormat() throws {
        var legacy = Library()
        legacy.schemaVersion = 1
        legacy.layouts = [CoreFixtures.layout()]
        let object = try #require(JSONSerialization.jsonObject(with: LayoutRepository.encode(legacy)) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 2)
    }

    @Test func eachRevisionAndRecoveryRetainTheirOwnDesktopSnapshot() throws {
        var library = fixture()
        let saved = library.layouts[0].saved
        var rememberedWindow = saved.windows[0]
        rememberedWindow.desktopAssignment = .desktop("remembered-laptop-1")
        let remembered = LayoutRevision(windows: [rememberedWindow], desktopSnapshot: snapshot(prefix: "remembered-"))
        var historicalWindow = saved.windows[0]
        historicalWindow.desktopAssignment = .desktop("history-laptop-2")
        let history = LayoutRevision(windows: [historicalWindow], desktopSnapshot: snapshot(prefix: "history-"))
        library.layouts[0].remembered = remembered
        library.layouts[0].history = [history]
        library.layouts[0].options.restoreDesktops = false
        library.recovery = [RecoverySnapshot(topology: CoreFixtures.topology, windows: saved.windows, desktopSnapshot: saved.desktopSnapshot)]

        let decoded = try LayoutRepository.decode(LayoutRepository.encode(library))
        #expect(decoded.layouts[0].saved.desktopSnapshot == saved.desktopSnapshot)
        #expect(decoded.layouts[0].remembered?.desktopSnapshot == remembered.desktopSnapshot)
        #expect(decoded.layouts[0].history[0].desktopSnapshot == history.desktopSnapshot)
        #expect(decoded.layouts[0].effectiveDesktopSnapshot == remembered.desktopSnapshot)
        #expect(decoded.layouts[0].effectiveWindows[0].desktopAssignment == .desktop("remembered-laptop-1"))
        #expect(decoded.recovery[0].desktopSnapshot == saved.desktopSnapshot)
        #expect(decoded.recovery[0].windows[0].desktopAssignment == saved.windows[0].desktopAssignment)
        #expect(!decoded.layouts[0].options.restoreDesktops)
    }

    @Test func unknownRememberedSnapshotDoesNotFallBackToSavedAssignments() {
        var layout = fixture().layouts[0]
        layout.remembered = LayoutRevision(windows: [CoreFixtures.saved()])
        #expect(layout.saved.desktopSnapshot != nil)
        #expect(layout.effectiveDesktopSnapshot == nil)
        layout.remembered = nil
        #expect(layout.effectiveDesktopSnapshot == layout.saved.desktopSnapshot)
    }

    @Test func coordinateCapturePreservesKnownMembership() throws {
        var live = CoreFixtures.live()
        #expect(CoordinateMapper.save(live, in: CoreFixtures.topology)?.desktopAssignment == nil)
        live.desktopAssignment = .desktop("laptop-2")
        #expect(CoordinateMapper.save(live, in: CoreFixtures.topology)?.desktopAssignment == .desktop("laptop-2"))
        live.desktopAssignment = .allDesktops
        #expect(CoordinateMapper.save(live, in: CoreFixtures.topology)?.desktopAssignment == .allDesktops)
        var library = fixture()
        library.layouts[0].saved.windows[0].desktopAssignment = .allDesktops
        let decoded = try LayoutRepository.decode(LayoutRepository.encode(library))
        #expect(decoded.layouts[0].saved.windows[0].desktopAssignment == .allDesktops)
    }

    @Test func spanningAndOffscreenWindowsUseTheirDesktopDisplayForSavedGeometry() throws {
        for frame in [Rect(x: 1300, y: 100, width: 1000, height: 500), Rect(x: 5000, y: 100, width: 700, height: 500)] {
            var live = CoreFixtures.live(frame: frame)
            live.desktopAssignment = .desktop("laptop-2")
            #expect(CoordinateMapper.sourceDisplay(for: frame, in: CoreFixtures.topology)?.id == "office")
            let saved = try #require(CoordinateMapper.save(live, in: CoreFixtures.topology, desktopSnapshot: snapshot()))
            #expect(saved.displayID == "laptop")
            #expect(saved.sourceUsableFrame == CoordinateMapper.usableAX(CoreFixtures.primary, in: CoreFixtures.topology))
            #expect(saved.frame == frame)
            var library = fixture()
            library.layouts[0].saved.windows = [saved]
            try LayoutRepository.validate(library)
        }
    }

    @Test func sharedDesktopMembershipDoesNotOverridePhysicalGeometryOwner() throws {
        let shared = DesktopSnapshot(displays: [snapshot().displays[0]], separateDisplays: false)
        var live = CoreFixtures.live(frame: Rect(x: 1700, y: 100, width: 700, height: 500))
        live.desktopAssignment = .desktop("laptop-1")
        #expect(CoordinateMapper.save(live, in: CoreFixtures.topology, desktopSnapshot: shared)?.displayID == "office")
        live.desktopAssignment = .desktop("unknown")
        #expect(CoordinateMapper.save(live, in: CoreFixtures.topology, desktopSnapshot: shared) == nil)
    }

    @Test func malformedDesktopInventoriesAreRejected() {
        let mutations: [(inout DesktopSnapshot) -> Void] = [
            { $0.displays = [] },
            { $0.displays[0].displayID = "unavailable" },
            { $0.displays.append($0.displays[0]) },
            { $0.displays[0].desktops = [] },
            { $0.displays[0].desktops[0].ordinal = -1 },
            { $0.displays[0].desktops[1].ordinal = 0 },
            { $0.displays[0].desktops[1].ordinal = 2 },
            { $0.displays[0].desktops[1].id = $0.displays[0].desktops[0].id },
            { $0.displays[1].desktops[0].id = $0.displays[0].desktops[0].id },
            { $0.displays[0].desktops[1].isActive = true },
            { $0.displays[0].desktops[0].id = "invalid\nidentifier" },
            { $0.displays[0].desktops[0].uuidHint = "" },
            { $0.displays[1].desktops[0].kind = .fullscreen },
            { $0.separateDisplays = false },
            { $0.displays[0].desktops = (0..<129).map { SavedDesktop(id: "desktop-\($0)", ordinal: $0) } }
        ]
        for mutate in mutations {
            var library = fixture()
            var invalid = snapshot()
            mutate(&invalid)
            library.layouts[0].saved.desktopSnapshot = invalid
            #expect(throws: (any Error).self) { try LayoutRepository.validate(library) }
        }
    }

    @Test func missingAndCrossDisplayAssignmentsAreRejected() {
        for assignment in [DesktopAssignment.desktop("not-captured"), .desktop("office-1")] {
            var library = fixture()
            library.layouts[0].saved.windows[0].desktopAssignment = assignment
            #expect(throws: (any Error).self) { try LayoutRepository.validate(library) }
        }
        var missingSnapshot = fixture()
        missingSnapshot.layouts[0].saved.desktopSnapshot = nil
        #expect(throws: (any Error).self) { try LayoutRepository.validate(missingSnapshot) }
        missingSnapshot.layouts[0].saved.windows[0].desktopAssignment = .allDesktops
        #expect(throws: (any Error).self) { try LayoutRepository.validate(missingSnapshot) }
    }

    @Test func unknownMembershipAndUnknownActiveDesktopRemainValid() throws {
        var library = fixture()
        library.layouts[0].saved.windows[0].desktopAssignment = nil
        for index in library.layouts[0].saved.desktopSnapshot!.displays.indices {
            library.layouts[0].saved.desktopSnapshot!.displays[index].desktops[0].isActive = false
        }
        try LayoutRepository.validate(library)
    }

    @Test func sharedDesktopInventoryAcceptsWindowsOnOtherPhysicalDisplays() throws {
        var library = fixture()
        library.layouts[0].saved.desktopSnapshot = DesktopSnapshot(displays: [
            DesktopDisplay(displayID: "office", desktops: [SavedDesktop(id: "shared", ordinal: 0)])
        ], separateDisplays: false)
        library.layouts[0].saved.windows[0].desktopAssignment = .desktop("shared")
        try LayoutRepository.validate(library)
    }

    @Test func validationAlsoProtectsHistoricalAndRecoverySnapshots() {
        var library = fixture()
        var malformed = library.layouts[0].saved
        malformed.desktopSnapshot!.displays[0].desktops[0].ordinal = 999
        library.layouts[0].history = [malformed]
        #expect(throws: (any Error).self) { try LayoutRepository.validate(library) }
        library.layouts[0].history = []
        library.layouts[0].remembered = malformed
        #expect(throws: (any Error).self) { try LayoutRepository.validate(library) }
        library.layouts[0].remembered = nil
        library.recovery = [RecoverySnapshot(topology: CoreFixtures.topology, windows: malformed.windows, desktopSnapshot: malformed.desktopSnapshot)]
        #expect(throws: (any Error).self) { try LayoutRepository.validate(library) }
    }

    @Test func importedRevisionsLoseMachineHintsButKeepLogicalMembership() throws {
        var library = fixture()
        library.layouts[0].remembered = library.layouts[0].saved
        library.layouts[0].history = [library.layouts[0].saved]
        let imported = try #require(LayoutRepository.importPreview(LayoutRepository.encode(library)).first)
        #expect(imported.importedNeedsMapping)
        for revision in [imported.saved, imported.remembered!] + imported.history {
            let inventory = try #require(revision.desktopSnapshot)
            #expect(inventory.displays.flatMap(\.desktops).allSatisfy { $0.uuidHint == nil })
            #expect(revision.windows[0].desktopAssignment == .desktop("laptop-2"))
            #expect(inventory.desktopIDs.contains("laptop-2"))
        }
    }

    @Test func plannerUsesMissionControlOrderAndReportsFullscreenSpaces() {
        let desktops = DesktopSnapshot(displays: [DesktopDisplay(displayID: "laptop", desktops: [
            SavedDesktop(id: "second", ordinal: 2, isActive: true),
            SavedDesktop(id: "movie", ordinal: 1, kind: .fullscreen),
            SavedDesktop(id: "first", ordinal: 0)
        ])], separateDisplays: true)
        let plan = DesktopRestorePlanner.plan(snapshot: desktops, displayMapping: ["laptop": "new-monitor"])
        #expect(plan.targets["first"] == DesktopTarget(displayID: "new-monitor", ordinal: 0))
        #expect(plan.targets["second"] == DesktopTarget(displayID: "new-monitor", ordinal: 1))
        #expect(plan.targets["movie"] == nil)
        #expect(plan.requiredCounts == ["new-monitor": 2])
        #expect(plan.activeTargets == [DesktopTarget(displayID: "new-monitor", ordinal: 1)])
        #expect(plan.unsupportedDesktopIDs == ["movie"])
        #expect(desktops.desktopCount == 2)
        #expect(desktops.totalSpaceCount == 3)
    }

    @Test func consolidatingMonitorsPreservesSeparateDesktopSlots() {
        let plan = DesktopRestorePlanner.plan(snapshot: snapshot(), displayMapping: ["laptop": "only", "office": "only"])
        #expect(plan.requiredCounts == ["only": 3])
        #expect(plan.targets["laptop-1"] == DesktopTarget(displayID: "only", ordinal: 0))
        #expect(plan.targets["laptop-2"] == DesktopTarget(displayID: "only", ordinal: 1))
        #expect(plan.targets["office-1"] == DesktopTarget(displayID: "only", ordinal: 2))
        #expect(plan.activeTargets == [DesktopTarget(displayID: "only", ordinal: 0)])
        #expect(plan.mergedActiveDesktopIDs == ["office-1"])
    }

    @Test func scopedAndSkippedDisplaysDoNotCreateOtherDesktops() {
        let scoped = DesktopRestorePlanner.plan(snapshot: snapshot(), displayMapping: ["laptop": "left", "office": "right"],
                                                windowScopeDisplayIDs: ["office"])
        #expect(scoped.requiredCounts == ["right": 1])
        #expect(scoped.targets.keys.sorted() == ["office-1"])
        let skipped = DesktopRestorePlanner.plan(snapshot: snapshot(), displayMapping: ["laptop": "left"])
        #expect(skipped.requiredCounts == ["left": 2])
        #expect(skipped.targets["office-1"] == nil)
    }

    @Test func sharedSpacesCanRestoreForNoncanonicalScopedDisplay() {
        let shared = DesktopSnapshot(displays: [snapshot().displays[0]], separateDisplays: false)
        let plan = DesktopRestorePlanner.plan(snapshot: shared, displayMapping: ["office": "right"], windowScopeDisplayIDs: ["office"])
        #expect(plan.requiredCounts == ["right": 2])
        #expect(plan.targets["laptop-1"] == DesktopTarget(displayID: "right", ordinal: 0))
        let noScope = DesktopRestorePlanner.plan(snapshot: shared, displayMapping: ["office": "right"], windowScopeDisplayIDs: [])
        #expect(noScope.targets.isEmpty)
    }

    @Test func desktopChangesDoNotChangePhysicalSetupIdentity() {
        var layout = fixture().layouts[0]
        let originalKey = layout.topology.setupKey
        layout.saved.desktopSnapshot!.displays[0].desktops.append(SavedDesktop(id: "laptop-3", ordinal: 2))
        #expect(layout.topology.setupKey == originalKey)
    }
}
