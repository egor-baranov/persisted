import Foundation
import Testing
@testable import PersistedCore

struct AutoLearningPolicyTests {
    private func snapshot(prefix: String = "", hints: Bool = true) -> DesktopSnapshot {
        .init(displays: [
            .init(displayID: "laptop", desktops: [
                .init(id: "\(prefix)one", ordinal: 0, uuidHint: hints ? "UUID-ONE" : nil, isActive: true),
                .init(id: "\(prefix)two", ordinal: 1, uuidHint: hints ? "UUID-TWO" : nil)
            ]),
            .init(displayID: "office", desktops: [.init(id: "\(prefix)office", ordinal: 0, uuidHint: hints ? "UUID-OFFICE" : nil, isActive: true)])
        ], separateDisplays: true)
    }

    private func live(_ number: Int = 1, title: String = "Notes", bundle: String = "example.editor",
                      desktop: String? = "one", x: Double = 100) -> LiveWindow {
        var value = CoreFixtures.live(number, title: title, bundle: bundle,
                                      frame: .init(x: x, y: 100, width: 700, height: 500))
        value.desktopAssignment = desktop.map(DesktopAssignment.desktop)
        return value
    }

    private func layout(windows: [LiveWindow]? = nil, desktops: DesktopSnapshot? = nil) -> Layout {
        let desktops = desktops ?? snapshot()
        let windows = (windows ?? [live()]).map {
            CoordinateMapper.save($0, in: CoreFixtures.topology, desktopSnapshot: desktops)!
        }
        return Layout(name: "Auto", topology: CoreFixtures.topology, windows: windows, desktopSnapshot: desktops)
    }

    private func capture(_ windows: [LiveWindow]? = nil, desktops: DesktopSnapshot? = nil) -> WindowCapture {
        .init(windows: windows ?? [live()], desktopSnapshot: desktops ?? snapshot())
    }

    @Test func autoDefaultsAndOlderLibraryMigrationStayOffGlobally() throws {
        #expect(!AppSettings().autoModeEnabled)
        #expect(LayoutOptions().autoModeEnabled)
        #expect(LayoutOptions().autoSaveEnabled)
        #expect(LayoutOptions().excludedDesktopIDs.isEmpty)
        #expect(Library().autoLayoutIDs.isEmpty)
        var library = Library()
        library.layouts = [CoreFixtures.layout()]
        library.settings.automaticSwitching = true
        var object = try #require(JSONSerialization.jsonObject(with: LayoutRepository.encode(library)) as? [String: Any])
        object.removeValue(forKey: "autoLayoutIDs")
        var settings = try #require(object["settings"] as? [String: Any])
        settings.removeValue(forKey: "autoModeEnabled")
        object["settings"] = settings
        var layouts = try #require(object["layouts"] as? [[String: Any]])
        layouts[0].removeValue(forKey: "editedAwaitingApply")
        var options = try #require(layouts[0]["options"] as? [String: Any])
        for key in ["autoModeEnabled", "autoSaveEnabled", "excludedDesktopIDs"] { options.removeValue(forKey: key) }
        layouts[0]["options"] = options
        object["layouts"] = layouts
        let decoded = try LayoutRepository.decode(JSONSerialization.data(withJSONObject: object))
        #expect(!decoded.settings.autoModeEnabled)
        #expect(decoded.settings.automaticSwitching)
        #expect(decoded.layouts[0].options.autoModeEnabled)
        #expect(decoded.layouts[0].options.autoSaveEnabled)
        #expect(decoded.layouts[0].options.excludedDesktopIDs.isEmpty)
        #expect(!decoded.layouts[0].editedAwaitingApply)
        #expect(decoded.autoLayoutIDs.isEmpty)
    }

    @Test func autoConfigurationRoundTrips() throws {
        var library = Library()
        var saved = layout()
        saved.options.autoModeEnabled = false
        saved.options.autoSaveEnabled = false
        saved.options.excludedDesktopIDs = ["two"]
        library.layouts = [saved]
        library.settings.autoModeEnabled = true
        library.autoLayoutIDs = [saved.topology.setupKey: saved.id]
        let decoded = try LayoutRepository.decode(LayoutRepository.encode(library))
        #expect(decoded.settings.autoModeEnabled)
        #expect(!decoded.layouts[0].options.autoModeEnabled)
        #expect(!decoded.layouts[0].options.autoSaveEnabled)
        #expect(decoded.layouts[0].options.excludedDesktopIDs == ["two"])
        #expect(decoded.autoLayoutIDs == library.autoLayoutIDs)
    }

    @Test func offlineEditProtectionSurvivesRestartWithoutChangingAutoSavePreference() throws {
        var original = layout()
        original.saved.date = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(!original.editedAwaitingApply)
        original.editedAwaitingApply = true
        var library = Library()
        library.layouts = [original]
        let restored = try LayoutRepository.decode(LayoutRepository.encode(library)).layouts[0]
        #expect(restored.editedAwaitingApply)
        #expect(restored.options.autoModeEnabled)
        #expect(restored.options.autoSaveEnabled)
        let observed = capture([live(x: 420)])
        #expect(AutoLearningPolicy.updatedRevision(layout: restored, capture: observed, topology: CoreFixtures.topology) == nil)
        #expect(restored.saved == original.saved)
        var applied = restored
        applied.editedAwaitingApply = false
        #expect(AutoLearningPolicy.updatedRevision(layout: applied, capture: observed, topology: CoreFixtures.topology) != nil)
    }

    @Test func learnsNewWindowsAndGeometryWhileKeepingSavedIDsAndRules() throws {
        var saved = layout()
        saved.saved.windows[0].matchingRule = .exactTitle("Notes")
        let moved = live(x: 240)
        let added = live(2, title: "New document", bundle: "example.new", desktop: "two", x: 450)
        let revision = try #require(AutoLearningPolicy.updatedRevision(layout: saved, capture: capture([moved, added]), topology: CoreFixtures.topology))
        #expect(revision.windows.count == 2)
        #expect(revision.windows[0].id == saved.saved.windows[0].id)
        #expect(revision.windows[0].matchingRule == .exactTitle("Notes"))
        #expect(revision.windows[0].frame == moved.frame)
        #expect(revision.windows[1].identity.bundleID == "example.new")
        #expect(revision.windows[1].id == added.id)
        #expect(revision.windows[1].desktopAssignment == .desktop("two"))
        saved.remembered = revision
        #expect(AutoLearningPolicy.updatedRevision(layout: saved, capture: capture([added, moved]), topology: CoreFixtures.topology) == nil)
    }

    @Test func learnsCrossDisplayAndDesktopMovement() throws {
        let saved = layout()
        let moved = live(desktop: "office", x: 1750)
        let revision = try #require(AutoLearningPolicy.updatedRevision(layout: saved, capture: capture([moved]), topology: CoreFixtures.topology))
        #expect(revision.windows[0].displayID == "office")
        #expect(revision.windows[0].desktopAssignment == .desktop("office"))
        #expect(revision.windows[0].id == saved.saved.windows[0].id)
    }

    @Test func newCaptureIDsOrderTitlesAndActiveDesktopAloneDoNotChurn() {
        let saved = layout(windows: [live(), live(2, title: "Other", desktop: "two")])
        var desktops = snapshot(prefix: "fresh-")
        desktops.displays[0].desktops[0].isActive = false
        desktops.displays[0].desktops[1].isActive = true
        desktops.displays[0].desktops.reverse()
        desktops.displays.reverse()
        let first = live(10, title: "A different browser tab", desktop: "fresh-one")
        let second = live(11, title: "Other", desktop: "fresh-two")
        let references = [saved.saved.windows[0].id: first.id, saved.saved.windows[1].id: second.id]
        #expect(AutoLearningPolicy.updatedRevision(layout: saved, capture: capture([second, first], desktops: desktops),
                                                   topology: CoreFixtures.topology, references: references) == nil)
    }

    @Test func ordinalFallbackKeepsDesktopExclusionsStableWithoutUUIDHints() throws {
        var saved = layout(desktops: snapshot(hints: false))
        saved.options.excludedDesktopIDs = ["two"]
        let fresh = snapshot(prefix: "fresh-", hints: false)
        let moved = live(desktop: "fresh-one", x: 230)
        let excludedNew = live(2, title: "Ignore", desktop: "fresh-two")
        let revision = try #require(AutoLearningPolicy.updatedRevision(layout: saved, capture: capture([moved, excludedNew], desktops: fresh), topology: CoreFixtures.topology))
        #expect(revision.windows.count == 1)
        #expect(revision.windows[0].desktopAssignment == .desktop("one"))
        #expect(revision.desktopSnapshot?.desktopIDs == snapshot().desktopIDs)
        #expect(saved.options.excludedDesktopIDs == ["two"])
    }

    @Test func restoredReorderRebindsNativeHintsBeforeLearningExcludedDesktopGroups() throws {
        let excluded = live(1, title: "Excluded group", desktop: "one")
        let included = live(2, title: "Included group", desktop: "two", x: 300)
        var saved = layout(windows: [excluded, included])
        saved.options.excludedDesktopIDs = ["one"]
        var draft = LayoutEditDraft(layout: saved)
        try draft.moveDesktop(id: "two", offset: -1)
        saved.saved = try draft.validatedRevision()
        let edited = try #require(saved.saved.desktopSnapshot)
        let rebound = try #require(AutoLearningPolicy.rebindingDesktopHints(edited,
            afterRestore: snapshot(), topology: CoreFixtures.topology))
        #expect(rebound.displays[0].desktops.map(\.id) == ["two", "one"])
        #expect(rebound.desktop(id: "two")?.uuidHint == "UUID-ONE")
        #expect(rebound.desktop(id: "one")?.uuidHint == "UUID-TWO")
        #expect(rebound.desktop(id: "one")?.isActive == true)
        #expect(rebound.desktop(id: "two")?.isActive == false)
        #expect(saved.options.excludedDesktopIDs == ["one"])
        saved.saved.desktopSnapshot = rebound

        // Applying the edit moves the included group to native Space one. The
        // excluded group's live window stays untouched, even though it shares it.
        var restoredIncluded = included
        restoredIncluded.desktopAssignment = .desktop("one")
        #expect(AutoLearningPolicy.updatedRevision(layout: saved,
            capture: capture([excluded, restoredIncluded]), topology: CoreFixtures.topology) == nil)
        restoredIncluded.frame.x += 80
        let learned = try #require(AutoLearningPolicy.updatedRevision(layout: saved,
            capture: capture([excluded, restoredIncluded]), topology: CoreFixtures.topology))
        #expect(learned.windows[0] == saved.saved.windows[0])
        #expect(learned.windows[1].desktopAssignment == .desktop("two"))
        #expect(learned.windows[1].frame == restoredIncluded.frame)
        #expect(learned.desktopSnapshot?.displays[0].desktops.map(\.id) == ["two", "one"])

        // The hint binding survives persistence and a new native capture session.
        var library = Library(); library.layouts = [saved]
        let reopened = try LayoutRepository.decode(LayoutRepository.encode(library)).layouts[0]
        var freshIncluded = included
        freshIncluded.desktopAssignment = .desktop("fresh-one")
        var freshExcluded = excluded
        freshExcluded.desktopAssignment = .desktop("fresh-one")
        #expect(AutoLearningPolicy.updatedRevision(layout: reopened,
            capture: capture([freshExcluded, freshIncluded], desktops: snapshot(prefix: "fresh-")),
            topology: CoreFixtures.topology) == nil)
    }

    @Test func restoredReorderWithoutHintsCannotStealExcludedLogicalDesktopIDs() throws {
        var saved = layout(desktops: snapshot(hints: false))
        saved.options.excludedDesktopIDs = ["one"]
        var draft = LayoutEditDraft(layout: saved)
        try draft.moveDesktop(id: "two", offset: -1)
        saved.saved = try draft.validatedRevision()
        saved.editedAwaitingApply = true
        let edited = try #require(saved.saved.desktopSnapshot)
        #expect(AutoLearningPolicy.rebindingDesktopHints(edited,
            afterRestore: snapshot(hints: false), topology: CoreFixtures.topology) == nil)
        #expect(saved.options.excludedDesktopIDs == ["one"])
        #expect(AutoLearningPolicy.updatedRevision(layout: saved,
            capture: capture([live(x: 450)], desktops: snapshot(hints: false)), topology: CoreFixtures.topology) == nil)
    }

    @Test func safeOrdinalFallbackStillWorksWhenCaptureIDsAndHintsAreUnavailable() throws {
        var draft = LayoutEditDraft(layout: layout(desktops: snapshot(hints: false)))
        try draft.moveDesktop(id: "two", offset: -1)
        let edited = try #require(draft.revision.desktopSnapshot)
        let captured = snapshot(prefix: "new-session-", hints: false)
        let rebound = try #require(AutoLearningPolicy.rebindingDesktopHints(edited,
            afterRestore: captured, topology: CoreFixtures.topology))
        #expect(rebound == edited)
    }

    @Test(arguments: ["count", "display", "mode", "duplicateHint", "invalidOrder"])
    func restoredDesktopHintBindingRejectsIncompleteOrChangedInventory(change: String) {
        let saved = snapshot()
        var captured = snapshot()
        switch change {
        case "count": captured.displays[0].desktops.removeLast()
        case "display": captured.displays.removeLast()
        case "mode": captured.separateDisplays = false
        case "duplicateHint": captured.displays[0].desktops[1].uuidHint = "uuid-one"
        default: captured.displays[0].desktops[1].ordinal = 0
        }
        #expect(AutoLearningPolicy.rebindingDesktopHints(saved,
            afterRestore: captured, topology: CoreFixtures.topology) == nil)
    }

    @Test func restoredHintBindingPreservesFullscreenIdentityAndSlots() throws {
        var recorded = snapshot()
        recorded.displays[0].desktops[1].ordinal = 2
        recorded.displays[0].desktops.insert(.init(id: "movie", ordinal: 1, kind: .fullscreen,
                                                  uuidHint: "UUID-MOVIE"), at: 1)
        var draft = LayoutEditDraft(layout: layout(desktops: recorded))
        try draft.moveDesktop(id: "two", offset: -1)
        let edited = try #require(draft.revision.desktopSnapshot)
        let rebound = try #require(AutoLearningPolicy.rebindingDesktopHints(edited,
            afterRestore: recorded, topology: CoreFixtures.topology))
        #expect(rebound.desktop(id: "movie") == edited.desktop(id: "movie"))
        #expect(rebound.displays[0].desktops.map(\.id) == ["two", "movie", "one"])
        var changed = recorded
        changed.displays[0].desktops[1].uuidHint = "UNRELATED-MOVIE"
        #expect(AutoLearningPolicy.rebindingDesktopHints(edited,
            afterRestore: changed, topology: CoreFixtures.topology) == nil)
    }

    @Test func learnsDesktopCreationAndUUIDBasedReordering() throws {
        let saved = layout()
        var created = snapshot(prefix: "fresh-")
        created.displays[0].desktops.append(.init(id: "fresh-three", ordinal: 2, uuidHint: "UUID-THREE"))
        let revision = try #require(AutoLearningPolicy.updatedRevision(layout: saved,
            capture: capture([live(desktop: "fresh-one")], desktops: created), topology: CoreFixtures.topology))
        #expect(revision.desktopSnapshot?.desktopCount == 4)
        #expect(revision.desktopSnapshot?.desktopIDs == ["one", "two", "office", "fresh-three"])

        var reordered = snapshot(prefix: "fresh-")
        reordered.displays[0].desktops[0].ordinal = 1
        reordered.displays[0].desktops[1].ordinal = 0
        let order = try #require(AutoLearningPolicy.updatedRevision(layout: saved,
            capture: capture([live(desktop: "fresh-one")], desktops: reordered), topology: CoreFixtures.topology))
        #expect(order.desktopSnapshot?.displays[0].desktops.map(\.id) == ["two", "one"])
        #expect(order.windows[0].desktopAssignment == .desktop("one"))
    }

    @Test func removedUnreferencedDesktopCanDisappearButClosedAppAssignmentsRemain() throws {
        var reduced = snapshot()
        reduced.displays[0].desktops.removeLast()
        let saved = layout()
        let revision = try #require(AutoLearningPolicy.updatedRevision(layout: saved, capture: capture(desktops: reduced), topology: CoreFixtures.topology))
        #expect(revision.desktopSnapshot?.desktopIDs == ["one", "office"])

        let closedApp = live(2, title: "Closed app", bundle: "example.closed", desktop: "two")
        let withClosedApp = layout(windows: [live(), closedApp])
        #expect(AutoLearningPolicy.updatedRevision(layout: withClosedApp, capture: capture(desktops: reduced), topology: CoreFixtures.topology) == nil)
        let newWindow = live(3, title: "New", bundle: "example.new")
        let preserved = try #require(AutoLearningPolicy.updatedRevision(layout: withClosedApp,
            capture: capture([live(), newWindow], desktops: reduced), topology: CoreFixtures.topology))
        #expect(preserved.windows[1] == withClosedApp.saved.windows[1])
        #expect(preserved.desktopSnapshot?.desktopIDs.contains("two") == true)
        #expect(preserved.desktopSnapshot?.displays[0].desktops.map(\.ordinal) == [0, 1])
    }

    @Test func excludedApplicationsAndDesktopsKeepTheirSavedWindowsUntouched() throws {
        let appWindow = live(1, bundle: "example.excluded")
        let desktopWindow = live(2, title: "Excluded desktop", desktop: "two")
        var saved = layout(windows: [appWindow, desktopWindow])
        saved.excludedBundleIDs = ["example.excluded"]
        saved.options.excludedDesktopIDs = ["two"]
        let fresh = snapshot(prefix: "fresh-")
        let observations = [
            live(1, bundle: "example.excluded", desktop: "fresh-one", x: 330),
            live(2, title: "Excluded desktop", desktop: "fresh-one", x: 350),
            live(3, title: "New excluded app", bundle: "example.excluded", desktop: "fresh-one"),
            live(4, title: "New excluded desktop", desktop: "fresh-two"),
            live(5, title: "Included", bundle: "example.included", desktop: "fresh-one")
        ]
        let revision = try #require(AutoLearningPolicy.updatedRevision(layout: saved, capture: capture(observations, desktops: fresh), topology: CoreFixtures.topology))
        #expect(revision.windows.count == 3)
        #expect(Array(revision.windows.prefix(2)) == saved.saved.windows)
        #expect(revision.windows.last?.identity.bundleID == "example.included")
    }

    @Test func globalWindowExclusionAndUnknownMembershipArePreserved() throws {
        let saved = layout(windows: [live(), live(2, title: "Private")])
        let observations = [live(desktop: nil, x: 250), live(2, title: "Private", x: 350), live(3, title: "New", bundle: "example.new")]
        let revision = try #require(AutoLearningPolicy.updatedRevision(layout: saved, capture: capture(observations), topology: CoreFixtures.topology,
            exclusions: [.init(bundleID: "example.editor", title: "Private")]))
        #expect(Array(revision.windows.prefix(2)) == saved.saved.windows)
        #expect(revision.windows.count == 3)
    }

    @Test func incompleteDeniedAmbiguousOrSnapshotLossCapturesCannotSave() {
        let saved = layout()
        var partial = capture([live(x: 250)])
        partial.issues = [.init(bundleID: "example.other", message: "Timed out")]
        var denied = capture([live(x: 250)])
        denied.permissionGranted = false
        let missingSnapshot = WindowCapture(windows: [live(x: 250)])
        let ambiguous = capture([live(x: 250), live(2, x: 350)])
        let duplicateTokens = capture([live(x: 250), live(x: 350)])
        for observed in [partial, denied, missingSnapshot, ambiguous, duplicateTokens] {
            #expect(AutoLearningPolicy.updatedRevision(layout: saved, capture: observed, topology: CoreFixtures.topology) == nil)
        }
    }

    @Test func disabledOrDifferentPhysicalSetupCannotSaveEvenWithIgnoreLidPolicy() {
        let observation = capture([live(x: 250)])
        for option in 0...2 {
            var saved = layout()
            if option == 0 { saved.options.autoModeEnabled = false }
            if option == 1 { saved.options.autoSaveEnabled = false }
            if option == 2 { saved.importedNeedsMapping = true }
            #expect(AutoLearningPolicy.updatedRevision(layout: saved, capture: observation, topology: CoreFixtures.topology) == nil)
        }
        var saved = layout()
        saved.options.lidPolicy = .ignore
        var different = CoreFixtures.topology
        different.lid = .closed
        #expect(AutoLearningPolicy.updatedRevision(layout: saved, capture: observation, topology: different) == nil)
    }

    @Test func legacyGeometryOnlyLayoutCanLearnWithoutDesktopMetadata() throws {
        let original = live(desktop: nil)
        let saved = CoreFixtures.layout(windows: [CoordinateMapper.save(original, in: CoreFixtures.topology)!])
        let observed = WindowCapture(windows: [live(desktop: nil, x: 280), live(2, title: "New", desktop: nil)])
        let revision = try #require(AutoLearningPolicy.updatedRevision(layout: saved, capture: observed, topology: CoreFixtures.topology))
        #expect(revision.desktopSnapshot == nil)
        #expect(revision.windows.count == 2)
        #expect(revision.windows[0].id == saved.saved.windows[0].id)
    }

    @Test func renamedUnmatchedWindowDoesNotAccumulateDuplicates() {
        let saved = layout()
        for title in ["A different tab", "Another tab", "Third tab"] {
            let observed = live(10, title: title)
            #expect(AutoLearningPolicy.updatedRevision(layout: saved, capture: capture([observed]), topology: CoreFixtures.topology) == nil)
        }
    }

    @Test func additionalWindowIsLearnedWhenExistingApplicationWindowMatches() throws {
        let saved = layout()
        let added = live(2, title: "Another window", desktop: "two")
        let revision = try #require(AutoLearningPolicy.updatedRevision(layout: saved, capture: capture([live(), added]), topology: CoreFixtures.topology))
        #expect(revision.windows.count == 2)
        #expect(revision.windows[0].id == saved.saved.windows[0].id)
        #expect(revision.windows[1].id == added.id)
    }

    @Test func distinctDocumentCanBeAddedWhileOlderDocumentIsClosed() throws {
        var original = live(title: "First document")
        original.identity.documentID = "/documents/first.txt"
        let saved = layout(windows: [original])
        var added = live(2, title: "Second document")
        added.identity.documentID = "/documents/second.txt"
        let revision = try #require(AutoLearningPolicy.updatedRevision(layout: saved, capture: capture([added]), topology: CoreFixtures.topology))
        #expect(revision.windows.count == 2)
        #expect(revision.windows[0] == saved.saved.windows[0])
        #expect(revision.windows[1].id == added.id)
    }

    @Test func newlyLearnedOpaqueIDsCannotCollideWithExistingSavedIDs() {
        var saved = layout()
        let added = live(2, title: "Another app", bundle: "example.new")
        saved.saved.windows[0].id = added.id
        #expect(AutoLearningPolicy.updatedRevision(layout: saved, capture: capture([live(), added]), topology: CoreFixtures.topology) == nil)
    }
}
