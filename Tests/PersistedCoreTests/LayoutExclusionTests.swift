import Testing
import PersistedCore

struct LayoutExclusionTests {
    @Test func plannerOmitsExcludedApplicationsWithoutChangingMembership() {
        let included = CoreFixtures.live(1, bundle: "included.app")
        let excluded = CoreFixtures.live(2, title: "Excluded", bundle: "excluded.app")
        var layout = CoreFixtures.layout(windows: [included, excluded].map { CoreFixtures.saved($0) })
        layout.excludedBundleIDs = ["excluded.app"]
        let plan = RestorePlanner.plan(layout: layout, topology: CoreFixtures.topology,
            capture: WindowCapture(windows: [included, excluded]), generation: 1,
            mapping: ["laptop": "laptop", "office": "office"])
        #expect(plan.placements.map { $0.savedWindow.id } == [layout.saved.windows[0].id])
        #expect(plan.unresolved.isEmpty)
        #expect(layout.effectiveWindows.count == 2)
    }

    @Test func learningPreservesExcludedWindowGeometryWhileUpdatingIncludedWindows() {
        let included = CoreFixtures.live(1, bundle: "included.app")
        let excluded = CoreFixtures.live(2, title: "Excluded", bundle: "excluded.app")
        var layout = CoreFixtures.layout(windows: [included, excluded].map { CoreFixtures.saved($0) })
        layout.options.rememberAdjustments = true
        layout.excludedBundleIDs = ["excluded.app"]
        var movedIncluded = included; movedIncluded.frame.x += 100
        var movedExcluded = excluded; movedExcluded.frame.x += 200
        let learned = LearningPolicy.updatedWindows(layout: layout,
            capture: WindowCapture(windows: [movedIncluded, movedExcluded]), topology: CoreFixtures.topology,
            beganGeneration: 2, endedGeneration: 2, stable: true, fullyRestored: true)
        #expect(learned?.map(\.id) == layout.saved.windows.map(\.id))
        #expect(learned?.first?.frame == movedIncluded.frame)
        #expect(learned?.last == layout.saved.windows.last)
        #expect(layout.saved.windows.first?.frame == included.frame)
    }

    @Test func movingOnlyExcludedWindowsDoesNotCreateRememberedRevision() {
        let window = CoreFixtures.live(1, bundle: "excluded.app")
        var layout = CoreFixtures.layout(windows: [CoreFixtures.saved(window)])
        layout.options.rememberAdjustments = true
        layout.excludedBundleIDs = ["excluded.app"]
        var moved = window; moved.frame.x += 100
        #expect(LearningPolicy.updatedWindows(layout: layout, capture: WindowCapture(windows: [moved]),
            topology: CoreFixtures.topology, beganGeneration: 2, endedGeneration: 2,
            stable: true, fullyRestored: true) == nil)
    }
}
