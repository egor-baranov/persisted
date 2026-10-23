import Testing
import PersistedCore

@Suite("Capture, plan and partial outcomes")
struct RestorePlannerTests {
    let mapping = ["laptop": "laptop", "office": "office"]

    @Test func planCarriesRevisionGenerationAndOnlySavedMembers() {
        let layout = CoreFixtures.layout()
        let capture = WindowCapture(windows: [CoreFixtures.live(), CoreFixtures.live(2, title: "Unrelated")])
        let plan = RestorePlanner.plan(layout: layout, topology: CoreFixtures.topology, capture: capture,
                                       generation: 42, mapping: mapping)
        #expect(plan.layoutID == layout.id)
        #expect(plan.revisionID == layout.saved.id)
        #expect(plan.generation == 42)
        #expect(plan.placements.count == 1)
        #expect(plan.unresolved.isEmpty)
        #expect(plan.placements[0].targetFrame == layout.saved.windows[0].frame)
        #expect(plan.placements[0].targetUsableFrame == CoordinateMapper.usableAX(CoreFixtures.primary, in: CoreFixtures.topology))
    }

    @Test(arguments: 0...4) func plansEveryWindowAcrossDynamicDisplayCounts(externalCount: Int) {
        let displays = [CoreFixtures.primary] + (0..<externalCount).map { index in
            DisplayRecord(id: "external-\(index)", name: "Display \(index)", uuid: "DISPLAY-\(index)",
                          frame: Rect(x: Double(index + 1) * 1440, y: 0, width: 1440, height: 900))
        }
        let topology = DisplayTopology(displays: displays, lid: .open)
        let live = displays.enumerated().map { index, display in
            let usable = CoordinateMapper.usableAX(display, in: topology)
            return CoreFixtures.live(index + 10, title: "Window \(index)",
                frame: Rect(x: usable.x + 20, y: usable.y + 20, width: 500, height: 300))
        }
        let saved = live.map { CoreFixtures.saved($0, topology: topology) }
        let layout = CoreFixtures.layout(windows: saved, topology: topology)
        let mapping = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0.id) })
        let plan = RestorePlanner.plan(layout: layout, topology: topology, capture: WindowCapture(windows: live),
                                       generation: 1, mapping: mapping)
        #expect(plan.placements.count == externalCount + 1)
        #expect(plan.unresolved.isEmpty)
        #expect(Set(plan.placements.map { $0.savedWindow.displayID }).count == externalCount + 1)
    }

    @Test func partialCaptureDoesNotBlockHealthyApplications() {
        let one = CoreFixtures.saved()
        let two = CoreFixtures.saved(CoreFixtures.live(2, title: "Mail", bundle: "example.mail"))
        let three = CoreFixtures.saved(CoreFixtures.live(3, title: "Browser", bundle: "example.browser"))
        let layout = CoreFixtures.layout(windows: [one, two, three])
        let capture = WindowCapture(windows: [CoreFixtures.live()], issues: [CaptureIssue(bundleID: "example.mail", message: "Application did not respond.")])
        let plan = RestorePlanner.plan(layout: layout, topology: CoreFixtures.topology, capture: capture,
                                       generation: 1, mapping: mapping)
        #expect(plan.placements.count == 1)
        #expect(plan.unresolved.first(where: { $0.id == two.id })?.kind == .missingWindow)
        #expect(plan.unresolved.first(where: { $0.id == three.id })?.kind == .missingApplication)
    }

    @Test func runningApplicationWithNoWindowsIsNotMissingApplication() {
        let capture = WindowCapture(runningBundleIDs: ["example.editor"])
        let plan = RestorePlanner.plan(layout: CoreFixtures.layout(), topology: CoreFixtures.topology,
                                       capture: capture, generation: 1, mapping: mapping)
        #expect(plan.unresolved.first?.kind == .missingWindow)
    }

    @Test func diaTabChangeStillPlansSavedWindowPlacementWithoutSessionReferences() {
        let original = CoreFixtures.live(title: "Ripple — Local control", bundle: "company.thebrowser.dia",
            document: "https://example.com/ripple", accessibility: "bigBrowserWindow_444BF09E-3F7E-463C-83FE-01EF3DFA6C93")
        let saved = CoreFixtures.saved(original)
        var current = original
        current.id = CoreFixtures.id(11)
        current.identity.title = "Another tab"
        current.identity.documentID = "https://example.com/another"
        current.frame.x += 180
        let plan = RestorePlanner.plan(layout: CoreFixtures.layout(windows: [saved]), topology: CoreFixtures.topology,
            capture: WindowCapture(windows: [current], runningBundleIDs: [original.identity.bundleID]),
            generation: 3, mapping: mapping)
        #expect(plan.unresolved.isEmpty)
        #expect(plan.placements.count == 1)
        #expect(plan.placements.first?.liveWindow.id == current.id)
        #expect(plan.placements.first?.targetFrame == saved.frame)
    }

    @Test func minimizedHiddenAndFullscreenRemainUntouched() {
        for state in 0...2 {
            var live = CoreFixtures.live()
            live.minimized = state == 0
            live.hidden = state == 1
            live.fullscreen = state == 2
            let plan = RestorePlanner.plan(layout: CoreFixtures.layout(), topology: CoreFixtures.topology,
                                           capture: WindowCapture(windows: [live]), generation: 1, mapping: mapping)
            #expect(plan.placements.isEmpty)
            #expect(plan.unresolved.first?.kind == .unsupported)
        }
    }

    @Test func permissionsAndMissingDisplaysPreventMutations() {
        let denied = RestorePlanner.plan(layout: CoreFixtures.layout(), topology: CoreFixtures.topology,
                                          capture: WindowCapture(windows: [CoreFixtures.live()], permissionGranted: false),
                                          generation: 1, mapping: mapping)
        #expect(denied.placements.isEmpty)
        let disconnected = RestorePlanner.plan(layout: CoreFixtures.layout(), topology: DisplayTopology(),
                                                capture: WindowCapture(windows: [CoreFixtures.live()]), generation: 2, mapping: mapping)
        #expect(disconnected.placements.isEmpty)
        #expect(disconnected.unresolved.count == 1)
    }

    @Test func capabilitiesCheckedOnlyForNecessaryWrites() {
        var live = CoreFixtures.live()
        live.capabilities = WindowCapabilities(canMove: false, canResize: false)
        let already = RestorePlanner.plan(layout: CoreFixtures.layout(), topology: CoreFixtures.topology,
                                          capture: WindowCapture(windows: [live]), generation: 1, mapping: mapping)
        #expect(already.placements.count == 1)
        live.frame.x += 100
        let cannotMove = RestorePlanner.plan(layout: CoreFixtures.layout(), topology: CoreFixtures.topology,
                                             capture: WindowCapture(windows: [live]), generation: 1, mapping: mapping)
        #expect(cannotMove.placements.isEmpty)
        live.capabilities.canMove = true
        let moveOnly = RestorePlanner.plan(layout: CoreFixtures.layout(), topology: CoreFixtures.topology,
                                           capture: WindowCapture(windows: [live]), generation: 1, mapping: mapping)
        #expect(moveOnly.placements.count == 1)
    }

    @Test func exclusionsAndSkippedDisplaysProduceExplicitOutcomes() {
        let layout = CoreFixtures.layout()
        let excluded = RestorePlanner.plan(layout: layout, topology: CoreFixtures.topology,
                                           capture: WindowCapture(windows: [CoreFixtures.live()]), generation: 1,
                                           mapping: mapping, exclusions: [WindowExclusion(bundleID: "example.editor")])
        #expect(excluded.placements.isEmpty)
        #expect(excluded.unresolved.first?.explanation == "Excluded in Settings.")
        let skipped = RestorePlanner.plan(layout: layout, topology: CoreFixtures.topology,
                                          capture: WindowCapture(windows: [CoreFixtures.live()]), generation: 1, mapping: [:])
        #expect(skipped.placements.isEmpty)
        #expect(skipped.unresolved.count == 1)
    }
}
