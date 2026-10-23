import Foundation
import Testing
@testable import PersistedCore

struct LayoutEditingTests {
    private var desktops: DesktopSnapshot {
        .init(displays: [
            .init(displayID: "laptop", desktops: [
                .init(id: "one", ordinal: 0, uuidHint: "ONE", isActive: true),
                .init(id: "movie", ordinal: 1, kind: .fullscreen, uuidHint: "MOVIE"),
                .init(id: "two", ordinal: 2, uuidHint: "TWO"),
                .init(id: "three", ordinal: 3, uuidHint: "THREE")
            ]),
            .init(displayID: "office", desktops: [.init(id: "office-one", ordinal: 0, isActive: true)])
        ], separateDisplays: true)
    }

    private func layout() -> Layout {
        var window = CoreFixtures.saved()
        window.desktopAssignment = .desktop("one")
        window.matchingRule = .exactTitle("Notes")
        return Layout(name: "Work", topology: CoreFixtures.topology, windows: [window], desktopSnapshot: desktops)
    }

    @Test func relativeGeometryUsesNegativeGlobalMonitorOrigins() throws {
        var external = CoreFixtures.external
        external.frame = .init(x: -1600, y: 300, width: 1600, height: 1200)
        external.usableFrame = .init(x: -1600, y: 340, width: 1600, height: 1136)
        let topology = DisplayTopology(displays: [CoreFixtures.primary, external], lid: .open)
        var live = CoreFixtures.live(frame: .init(x: -1500, y: -500, width: 700, height: 500))
        live.desktopAssignment = .desktop("office-one")
        let saved = try #require(CoordinateMapper.save(live, in: topology, desktopSnapshot: desktops))
        let source = Layout(name: "Left monitor", topology: topology, windows: [saved], desktopSnapshot: desktops)
        var draft = LayoutEditDraft(layout: source)
        let usable = try #require(draft.displayUsableFrame(displayID: "office"))
        #expect(usable.x == -1600)
        #expect(usable.y == -576)
        try draft.setWindowFrame(windowID: saved.id, relativeFrame: .init(x: 50, y: 60, width: 500, height: 300))
        let edited = draft.revision.windows[0]
        #expect(edited.frame == .init(x: -1550, y: -516, width: 500, height: 300))
        #expect(edited.sourceUsableFrame == usable)
        #expect(edited.relativeFrame == .init(x: 50, y: 60, width: 500, height: 300))
        let expectedNormalized = Rect(x: 50.0 / 1600, y: 60.0 / 1136, width: 500.0 / 1600, height: 300.0 / 1136)
        #expect(edited.normalizedFrame == expectedNormalized)
        _ = try draft.validatedRevision()
    }

    @Test func editorBoundsAndMinimumSizeKeepWindowReachable() throws {
        let source = layout()
        let id = source.saved.windows[0].id
        var draft = LayoutEditDraft(layout: source)
        let usable = try #require(draft.displayUsableFrame(displayID: "laptop"))
        try draft.setWindowFrame(windowID: id, relativeFrame: .init(x: -80, y: -40, width: 1, height: 0.5))
        #expect(draft.revision.windows[0].relativeFrame == .init(x: 0, y: 0, width: 20, height: 20))
        try draft.setWindowFrame(windowID: id, relativeFrame: .init(x: 5000, y: 5000, width: 500, height: 300))
        #expect(draft.revision.windows[0].relativeFrame == .init(x: usable.width - 500, y: usable.height - 300, width: 500, height: 300))
        try draft.setWindowFrame(windowID: id, relativeFrame: .init(x: 50, y: 50, width: 8000, height: 8000))
        #expect(draft.revision.windows[0].frame == usable)
        #expect(draft.revision.windows[0].normalizedFrame == .init(x: 0, y: 0, width: 1, height: 1))
        _ = try draft.validatedRevision()
    }

    @Test func nonfiniteNonpositiveAndExtremeGeometryFailsWithoutChangingDraft() {
        let source = layout()
        let invalid = [
            Rect(x: .nan, y: 0, width: 300, height: 200),
            Rect(x: 0, y: 0, width: .infinity, height: 200),
            Rect(x: 0, y: 0, width: 0, height: 200),
            Rect(x: 0, y: 0, width: 300, height: -5),
            Rect(x: 1_000_000, y: 0, width: 300, height: 200)
        ]
        for rectangle in invalid {
            var draft = LayoutEditDraft(layout: source)
            let original = draft
            #expect(throws: LayoutEditError.invalidFrame) {
                try draft.setWindowFrame(windowID: source.saved.windows[0].id, relativeFrame: rectangle)
            }
            #expect(draft == original)
        }
    }

    @Test func displayMoveReprojectsProportionsAndPreservesWindowMetadata() throws {
        let source = layout()
        let saved = source.saved.windows[0]
        var draft = LayoutEditDraft(layout: source)
        try draft.moveWindow(windowID: saved.id, toDisplayID: "office", desktopID: "office-one")
        let moved = draft.revision.windows[0]
        let usable = try #require(draft.displayUsableFrame(displayID: "office"))
        #expect(moved.displayID == "office")
        #expect(moved.desktopAssignment == .desktop("office-one"))
        #expect(moved.normalizedFrame.approximatelyEquals(saved.normalizedFrame, tolerance: 0.000001))
        #expect(moved.frame.approximatelyEquals(.init(x: usable.x + saved.normalizedFrame.x * usable.width,
            y: usable.y + saved.normalizedFrame.y * usable.height,
            width: saved.normalizedFrame.width * usable.width, height: saved.normalizedFrame.height * usable.height), tolerance: 0.000001))
        #expect(moved.id == saved.id)
        #expect(moved.identity == saved.identity)
        #expect(moved.matchingRule == saved.matchingRule)
        #expect(moved.capabilities == saved.capabilities)
        _ = try draft.validatedRevision()
    }

    @Test func displayMoveHonorsPreserveSizeAndNilMeansUnknownDesktop() throws {
        var source = layout()
        source.options.preserveWindowSize = true
        let saved = source.saved.windows[0]
        var draft = LayoutEditDraft(layout: source)
        try draft.moveWindow(windowID: saved.id, toDisplayID: "office", desktopID: nil)
        let moved = draft.revision.windows[0]
        #expect(moved.frame.width == saved.frame.width)
        #expect(moved.frame.height == saved.frame.height)
        #expect(moved.desktopAssignment == nil)
        #expect(moved.displayID == "office")
        _ = try draft.validatedRevision()
    }

    @Test func incompatibleDesktopAssignmentsAndMissingTargetsAreAtomic() throws {
        let source = layout()
        var draft = LayoutEditDraft(layout: source)
        let original = draft
        let id = source.saved.windows[0].id
        #expect(throws: LayoutEditError.wrongDesktopDisplay) {
            try draft.assignDesktop(windowID: id, assignment: .desktop("office-one"))
        }
        #expect(throws: LayoutEditError.wrongDesktopDisplay) {
            try draft.moveWindow(windowID: id, toDisplayID: "office", desktopID: "one")
        }
        #expect(throws: LayoutEditError.missingDisplay) { try draft.moveWindow(windowID: id, toDisplayID: "missing", desktopID: nil) }
        #expect(throws: LayoutEditError.missingDesktop) { try draft.assignDesktop(windowID: id, assignment: .desktop("missing")) }
        #expect(throws: LayoutEditError.missingWindow) { try draft.assignDesktop(windowID: UUID(), assignment: nil) }
        #expect(draft == original)
        try draft.assignDesktop(windowID: id, assignment: .desktop("two"))
        #expect(draft.revision.windows[0].frame == source.saved.windows[0].frame)
        try draft.assignDesktop(windowID: id, assignment: .allDesktops)
        #expect(draft.revision.windows[0].desktopAssignment == .allDesktops)
        try draft.assignDesktop(windowID: id, assignment: nil)
        #expect(draft.revision.windows[0].desktopAssignment == nil)
        _ = try draft.validatedRevision()
    }

    @Test func sharedSpacesAllowAssignmentsAndAdditionsFromAnyPhysicalDisplay() throws {
        var source = layout()
        source.saved.desktopSnapshot = .init(displays: [desktops.displays[0]], separateDisplays: false)
        var draft = LayoutEditDraft(layout: source)
        let id = source.saved.windows[0].id
        try draft.moveWindow(windowID: id, toDisplayID: "office", desktopID: "two")
        #expect(draft.revision.windows[0].displayID == "office")
        #expect(draft.revision.windows[0].desktopAssignment == .desktop("two"))
        try draft.assignDesktop(windowID: id, assignment: .desktop("one"))
        let added = try draft.addDesktop(displayID: "office")
        #expect(draft.revision.desktopSnapshot?.displays.count == 1)
        #expect(draft.revision.desktopSnapshot?.displays[0].displayID == "laptop")
        #expect(draft.revision.desktopSnapshot?.displayID(for: added) == "laptop")
        _ = try draft.validatedRevision()
    }

    @Test func ordinaryDesktopReorderPreservesFullscreenSlotsAndMemberships() throws {
        let source = layout()
        var draft = LayoutEditDraft(layout: source)
        try draft.moveDesktop(id: "three", offset: -2)
        let recorded = try #require(draft.revision.desktopSnapshot?.displays[0].desktops)
        #expect(recorded.map(\.id) == ["three", "movie", "one", "two"])
        #expect(recorded.map(\.ordinal) == [0, 1, 2, 3])
        #expect(recorded[1] == desktops.displays[0].desktops[1])
        #expect(recorded.first(where: { $0.id == "one" })?.isActive == true)
        #expect(draft.revision.windows == source.saved.windows)
        _ = try draft.validatedRevision()
    }

    @Test func unsupportedOrOutOfRangeDesktopMovesDoNotMutateDraft() {
        var draft = LayoutEditDraft(layout: layout())
        let original = draft
        #expect(throws: LayoutEditError.desktopMoveOutOfBounds) { try draft.moveDesktop(id: "one", offset: -1) }
        #expect(throws: LayoutEditError.desktopMoveOutOfBounds) { try draft.moveDesktop(id: "three", offset: Int.max) }
        #expect(throws: LayoutEditError.desktopMoveOutOfBounds) { try draft.moveDesktop(id: "three", offset: Int.min) }
        #expect(throws: LayoutEditError.fullscreenDesktop) { try draft.moveDesktop(id: "movie", offset: 1) }
        #expect(draft == original)
    }

    @Test func addingAndRemovingEmptyDesktopMaintainsOrderAndActiveReplacement() throws {
        var draft = LayoutEditDraft(layout: layout())
        let added = try draft.addDesktop(displayID: "laptop")
        let newDesktop = try #require(draft.revision.desktopSnapshot?.desktop(id: added))
        #expect(newDesktop.ordinal == 4)
        #expect(newDesktop.kind == .ordinary)
        #expect(newDesktop.uuidHint == nil)
        #expect(!newDesktop.isActive)
        try draft.setActiveDesktop(id: added)
        try draft.removeDesktop(id: added)
        let current = try #require(draft.revision.desktopSnapshot)
        #expect(current.desktop(id: added) == nil)
        #expect(current.displays[0].desktops.map(\.ordinal) == [0, 1, 2, 3])
        #expect(current.displays[0].desktops.filter(\.isActive).map(\.id) == ["three"])
        #expect(current.displays[1].desktops.filter(\.isActive).map(\.id) == ["office-one"])
        _ = try draft.validatedRevision()
    }

    @Test func occupiedFullscreenAndLastOrdinaryDesktopCannotBeRemoved() {
        var draft = LayoutEditDraft(layout: layout())
        let original = draft
        #expect(throws: LayoutEditError.desktopNotEmpty) { try draft.removeDesktop(id: "one") }
        #expect(throws: LayoutEditError.lastOrdinaryDesktop) { try draft.removeDesktop(id: "office-one") }
        #expect(throws: LayoutEditError.fullscreenDesktop) { try draft.removeDesktop(id: "movie") }
        #expect(draft == original)
    }

    @Test func desktopLimitPreventsUnsupportedSavedCount() throws {
        var draft = LayoutEditDraft(layout: layout())
        for _ in 0..<13 { _ = try draft.addDesktop(displayID: "laptop") }
        #expect(draft.revision.desktopSnapshot?.displays[0].ordinaryDesktops.count == 16)
        let original = draft
        #expect(throws: LayoutEditError.desktopLimit) { _ = try draft.addDesktop(displayID: "laptop") }
        #expect(draft == original)
        _ = try draft.validatedRevision()
    }

    @Test func legacyLayoutCanEditGeometryAndBootstrapDesktopInventory() throws {
        let source = CoreFixtures.layout()
        var draft = LayoutEditDraft(layout: source)
        let id = source.saved.windows[0].id
        #expect(throws: LayoutEditError.missingDesktopSnapshot) { try draft.assignDesktop(windowID: id, assignment: .allDesktops) }
        try draft.setWindowFrame(windowID: id, relativeFrame: .init(x: 40, y: 50, width: 500, height: 300))
        try draft.moveWindow(windowID: id, toDisplayID: "office", desktopID: nil)
        #expect(draft.revision.desktopSnapshot == nil)
        let added = try draft.addDesktop(displayID: "office")
        let snapshot = try #require(draft.revision.desktopSnapshot)
        #expect(snapshot.separateDisplays)
        #expect(snapshot.displays.map(\.displayID) == ["laptop", "office"])
        #expect(snapshot.displays.map { $0.ordinaryDesktops.count } == [1, 2])
        #expect(snapshot.displayID(for: added) == "office")
        #expect(draft.revision.windows[0].desktopAssignment == nil)
        #expect(source.saved.desktopSnapshot == nil)
        _ = try draft.validatedRevision()
    }

    @Test func activeDesktopChangesOnlyItsOwnDisplay() throws {
        var draft = LayoutEditDraft(layout: layout())
        try draft.setActiveDesktop(id: "two")
        #expect(draft.revision.desktopSnapshot?.displays[0].desktops.filter(\.isActive).map(\.id) == ["two"])
        #expect(draft.revision.desktopSnapshot?.displays[1].desktops.filter(\.isActive).map(\.id) == ["office-one"])
        _ = try draft.validatedRevision()
    }

    @Test func effectiveRevisionAndSourceLayoutRemainImmutableUntilCommit() throws {
        var source = layout()
        var remembered = source.saved
        remembered.id = UUID()
        source.remembered = remembered
        let original = source
        var draft = LayoutEditDraft(layout: source)
        #expect(draft.layoutID == source.id)
        #expect(draft.sourceRevisionID == remembered.id)
        #expect(draft.sourceRevision == remembered)
        #expect(!draft.hasChanges)
        try draft.setWindowFrame(windowID: remembered.windows[0].id, relativeFrame: .init(x: 60, y: 70, width: 500, height: 400))
        #expect(draft.hasChanges)
        let committed = try draft.validatedRevision()
        #expect(committed.id != remembered.id)
        #expect(committed.windows == draft.revision.windows)
        #expect(draft.revision.id == remembered.id)
        #expect(draft.sourceRevision == remembered)
        #expect(source == original)
    }

    @Test func validationDoesNotDiscardInvalidNoneditorMetadata() {
        var source = layout()
        source.iconName = ""
        let draft = LayoutEditDraft(layout: source)
        #expect(throws: (any Error).self) { _ = try draft.validatedRevision() }
    }
}
