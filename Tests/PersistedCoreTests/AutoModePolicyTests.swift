import Foundation
import Testing
@testable import PersistedCore

struct AutoModePolicyTests {
    private func layout(_ number: Int, topology: DisplayTopology = CoreFixtures.topology) -> Layout {
        var layout = CoreFixtures.layout(topology: topology)
        layout.id = CoreFixtures.id(number)
        layout.name = "Layout \(number)"
        return layout
    }

    @Test func registeredDisabledLayoutPreventsFallbackToAnotherCandidate() throws {
        var registered = layout(1)
        registered.options.autoModeEnabled = false
        registered.options.autoSaveEnabled = false
        let preferred = layout(2), selected = layout(3)
        var library = Library()
        library.layouts = [preferred, selected, registered]
        library.autoLayoutIDs[CoreFixtures.topology.setupKey] = registered.id
        library.preferredLayouts[CoreFixtures.topology.setupKey] = preferred.id

        let result = try #require(AutoModePolicy.layout(for: CoreFixtures.topology, library: library, selectedLayoutID: selected.id))
        #expect(result.id == registered.id)
        #expect(!result.options.autoModeEnabled)
        #expect(!result.options.autoSaveEnabled)
    }

    @Test func preferredThenSelectedThenPersistedCatalogOrderDetermineSelection() {
        let first = layout(1), second = layout(2), third = layout(3)
        var library = Library()
        library.layouts = [third, first, second]
        library.preferredLayouts[CoreFixtures.topology.setupKey] = second.id
        #expect(AutoModePolicy.layout(for: CoreFixtures.topology, library: library, selectedLayoutID: first.id)?.id == second.id)
        library.preferredLayouts = [:]
        #expect(AutoModePolicy.layout(for: CoreFixtures.topology, library: library, selectedLayoutID: first.id)?.id == first.id)
        #expect(AutoModePolicy.layout(for: CoreFixtures.topology, library: library)?.id == third.id)
        library.layouts = [second, third, first]
        #expect(AutoModePolicy.layout(for: CoreFixtures.topology, library: library)?.id == second.id)
    }

    @Test func ignoreLidManualPolicyCannotMergeDistinctAutomaticConfigurations() {
        var preferred = layout(2)
        preferred.options.lidPolicy = .ignore
        let selected = layout(1)
        var library = Library()
        library.layouts = [selected, preferred]
        library.preferredLayouts[CoreFixtures.topology.setupKey] = preferred.id
        var current = CoreFixtures.topology
        current.lid = .closed
        #expect(SetupMatcher.compatible(preferred, with: current))
        #expect(AutoModePolicy.layout(for: current, library: library, selectedLayoutID: selected.id) == nil)
    }

    @Test func equalMonitorCountsAndNamesCannotSelectDifferentPhysicalDisplays() {
        let saved = layout(1)
        var current = CoreFixtures.topology
        current.displays[1].uuid = "OTHER-MONITOR"
        current.displays[1].id = "other-office"
        var library = Library()
        library.layouts = [saved]
        #expect(AutoModePolicy.layout(for: current, library: library) == nil)
        library.preferredLayouts[current.setupKey] = saved.id
        #expect(AutoModePolicy.layout(for: current, library: library) == nil)
    }

    @Test func samePhysicalSetupRemainsSelectableAfterResolutionAndArrangementChanges() {
        let saved = layout(1)
        var current = CoreFixtures.topology
        current.displays[1].frame = Rect(x: -2560, y: 180, width: 2560, height: 1440)
        current.displays[1].usableFrame = Rect(x: -2560, y: 180, width: 2560, height: 1416)
        var library = Library()
        library.layouts = [saved]
        #expect(current.setupKey == saved.topology.setupKey)
        #expect(current.geometryKey != saved.topology.geometryKey)
        #expect(AutoModePolicy.layout(for: current, library: library)?.id == saved.id)
    }

    @Test func importsAndAmbiguousDisplaysNeverBecomeAutomaticCandidates() {
        var imported = layout(1)
        imported.importedNeedsMapping = true
        var ambiguous = layout(2)
        ambiguous.topology.displays[1].identityIsAmbiguous = true
        var library = Library()
        library.layouts = [imported, ambiguous]
        #expect(AutoModePolicy.layout(for: CoreFixtures.topology, library: library) == nil)

        let ordinary = layout(3)
        library.layouts = [ordinary]
        var ambiguousCurrent = CoreFixtures.topology
        ambiguousCurrent.displays[1].identityIsAmbiguous = true
        #expect(AutoModePolicy.layout(for: ambiguousCurrent, library: library) == nil)
    }

    @Test func unsafeRegisteredLayoutDoesNotSilentlyFallBack() {
        var imported = layout(1)
        imported.importedNeedsMapping = true
        let fallback = layout(2)
        var library = Library()
        library.layouts = [fallback, imported]
        library.autoLayoutIDs[CoreFixtures.topology.setupKey] = imported.id
        #expect(AutoModePolicy.layout(for: CoreFixtures.topology, library: library) == nil)
    }

    @Test func staleRegistryReferenceCanUseAnExistingCompatibleLayout() {
        let candidate = layout(1)
        var library = Library()
        library.layouts = [candidate]
        library.autoLayoutIDs[CoreFixtures.topology.setupKey] = CoreFixtures.id(99)
        #expect(AutoModePolicy.layout(for: CoreFixtures.topology, library: library)?.id == candidate.id)
    }

    private func desktopLayout() -> Layout {
        let snapshot = DesktopSnapshot(displays: [DesktopDisplay(displayID: "laptop", desktops: [
            SavedDesktop(id: "one", ordinal: 0),
            SavedDesktop(id: "two", ordinal: 1, isActive: true),
            SavedDesktop(id: "three", ordinal: 2)
        ])], separateDisplays: true)
        let windows = ["one", "two", "three"].enumerated().map { index, desktop in
            var window = CoreFixtures.saved(CoreFixtures.live(index + 1, title: "Window \(index + 1)"))
            window.desktopAssignment = .desktop(desktop)
            return window
        }
        return Layout(name: "Desktops", topology: CoreFixtures.topology, windows: windows, desktopSnapshot: snapshot)
    }

    @Test func desktopExclusionsFilterBothRevisionsWithoutChangingStoredHistory() throws {
        var original = desktopLayout()
        original.remembered = LayoutRevision(windows: original.saved.windows, desktopSnapshot: original.saved.desktopSnapshot)
        original.history = [original.saved]
        original.options.excludedDesktopIDs = ["two"]
        let result = AutoModePolicy.restorationLayout(original)
        #expect(result.saved.windows.map(\.desktopAssignment) == [.desktop("one"), .desktop("three")])
        #expect(result.remembered?.windows.map(\.desktopAssignment) == [.desktop("one"), .desktop("three")])
        #expect(result.history == original.history)
        #expect(original.saved.windows.count == 3)
        #expect(original.saved.desktopSnapshot?.desktop(id: "two")?.isActive == true)
        #expect(result.saved.desktopSnapshot?.desktop(id: "two")?.isActive == false)
        #expect(result.remembered?.desktopSnapshot?.desktop(id: "two")?.isActive == false)
    }

    @Test func excludedMiddleDesktopKeepsLaterWindowsInTheirOriginalOrdinalSlot() throws {
        var original = desktopLayout()
        original.options.excludedDesktopIDs = ["two"]
        let snapshot = try #require(AutoModePolicy.restorationLayout(original).effectiveDesktopSnapshot)
        let plan = DesktopRestorePlanner.plan(snapshot: snapshot, displayMapping: ["laptop": "laptop"])
        #expect(snapshot.displays[0].desktops.map(\.ordinal) == [0, 1, 2])
        #expect(plan.targets["three"] == DesktopTarget(displayID: "laptop", ordinal: 2))
        #expect(plan.requiredCounts["laptop"] == 3)
        #expect(plan.activeTargets.isEmpty)
    }

    @Test func fullyExcludedRevisionCannotCreateOrActivateDesktops() {
        var original = desktopLayout()
        original.options.excludedDesktopIDs = ["one", "two", "three"]
        original.remembered = LayoutRevision(windows: original.saved.windows, desktopSnapshot: original.saved.desktopSnapshot)
        let result = AutoModePolicy.restorationLayout(original)
        #expect(result.saved.windows.isEmpty)
        #expect(result.remembered?.windows.isEmpty == true)
        #expect(result.saved.desktopSnapshot == nil)
        #expect(result.remembered?.desktopSnapshot == nil)
    }

    @Test func appExclusionsApplyAlongsideDesktopExclusions() {
        var original = desktopLayout()
        original.saved.windows[0].identity.bundleID = "excluded.app"
        original.options.excludedDesktopIDs = ["two"]
        original.excludedBundleIDs = ["excluded.app"]
        let result = AutoModePolicy.restorationLayout(original)
        #expect(result.effectiveWindows.map(\.desktopAssignment) == [.desktop("three")])
    }

    @Test func unknownAndAllDesktopMembershipsAreNotMisclassifiedAsSpecificExcludedDesktop() {
        var original = desktopLayout()
        original.saved.windows[0].desktopAssignment = nil
        original.saved.windows[1].desktopAssignment = .allDesktops
        original.options.excludedDesktopIDs = ["one", "two", "three"]
        let result = AutoModePolicy.restorationLayout(original)
        #expect(result.effectiveWindows.map(\.desktopAssignment) == [nil, .allDesktops])
        #expect(result.effectiveDesktopSnapshot != nil)
        #expect(result.effectiveDesktopSnapshot?.displays[0].desktops.contains(where: \.isActive) == false)
    }
}
