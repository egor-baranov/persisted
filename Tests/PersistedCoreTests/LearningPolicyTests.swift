import Testing
import PersistedCore

@Suite("Remembering safeguards")
struct LearningPolicyTests {
    var layout: Layout {
        var value = CoreFixtures.layout(windows: [CoreFixtures.saved(), CoreFixtures.saved(CoreFixtures.live(2, title: "Missing"))])
        value.options.rememberAdjustments = true
        return value
    }
    var moved: LiveWindow {
        var value = CoreFixtures.live()
        value.frame.x += 80
        return value
    }

    @Test func learningUpdatesGeometryPreservingMembershipAndExplicitSave() {
        let original = layout
        let capture = WindowCapture(windows: [moved, CoreFixtures.live(3, title: "New unsaved")])
        let windows = LearningPolicy.updatedWindows(layout: original, capture: capture, topology: CoreFixtures.topology,
                                                    beganGeneration: 4, endedGeneration: 4, stable: true, fullyRestored: true)
        #expect(windows?.count == 2)
        #expect(windows?.map(\.id) == original.saved.windows.map(\.id))
        #expect(windows?.first?.frame == moved.frame)
        #expect(windows?.last == original.saved.windows.last)
        #expect(original.saved.windows.first?.frame == CoreFixtures.live().frame)
        #expect(original.remembered == nil)
    }

    @Test func disconnectCollapseCannotReplaceMultimonitorLayout() {
        let original = layout
        let collapsed = WindowCapture(windows: [moved])
        let laptopOnly = DisplayTopology(displays: [CoreFixtures.primary], lid: .open)
        let update = LearningPolicy.updatedWindows(layout: original, capture: collapsed, topology: laptopOnly,
                                                   beganGeneration: 5, endedGeneration: 5, stable: true, fullyRestored: true)
        #expect(update == nil)
        #expect(original.topology.displays.count == 2)
        #expect(original.saved.windows.count == 2)
    }

    @Test func transitionOrPartialRestorationAlwaysFreezesLearning() {
        for blocked in 0...5 {
            let result = LearningPolicy.updatedWindows(layout: layout, capture: WindowCapture(windows: [moved]),
                topology: CoreFixtures.topology, beganGeneration: 5, endedGeneration: blocked == 0 ? 6 : 5,
                stable: blocked != 1, fullyRestored: blocked != 2,
                isOwnMutation: blocked == 3, temporaryMapping: blocked == 4)
            if blocked < 5 { #expect(result == nil) } else { #expect(result != nil) }
        }
    }

    @Test func emptyPartialAndPermissionDeniedCapturesNeverReplaceLayout() {
        let captures = [WindowCapture(),
                        WindowCapture(windows: [moved], issues: [CaptureIssue(bundleID: "another.app", message: "Timed out")]),
                        WindowCapture(windows: [moved], permissionGranted: false)]
        for capture in captures {
            #expect(LearningPolicy.updatedWindows(layout: layout, capture: capture, topology: CoreFixtures.topology,
                beganGeneration: 1, endedGeneration: 1, stable: true, fullyRestored: true) == nil)
        }
    }

    @Test func disabledRememberingAndExclusionsAreRespected() {
        var disabled = layout
        disabled.options.rememberAdjustments = false
        #expect(LearningPolicy.updatedWindows(layout: disabled, capture: WindowCapture(windows: [moved]),
            topology: CoreFixtures.topology, beganGeneration: 1, endedGeneration: 1, stable: true, fullyRestored: true) == nil)
        #expect(LearningPolicy.updatedWindows(layout: layout, capture: WindowCapture(windows: [moved]),
            topology: CoreFixtures.topology, beganGeneration: 1, endedGeneration: 1, stable: true, fullyRestored: true,
            exclusions: [WindowExclusion(bundleID: "example.editor")]) == nil)
    }

    @Test func offlineEditProtectionAlsoBlocksLegacyRememberingUntilApplied() {
        var edited = layout
        edited.editedAwaitingApply = true
        let capture = WindowCapture(windows: [moved])
        #expect(LearningPolicy.updatedWindows(layout: edited, capture: capture,
            topology: CoreFixtures.topology, beganGeneration: 1, endedGeneration: 1,
            stable: true, fullyRestored: true) == nil)
        #expect(edited.options.rememberAdjustments)
        edited.editedAwaitingApply = false
        #expect(LearningPolicy.updatedWindows(layout: edited, capture: capture,
            topology: CoreFixtures.topology, beganGeneration: 1, endedGeneration: 1,
            stable: true, fullyRestored: true) != nil)
    }

    @Test func excludedDesktopGeometryIsFrozenWhileIncludedDesktopAdjustmentsAreRemembered() {
        var original = layout
        original.saved.windows[0].desktopAssignment = .desktop("excluded")
        original.saved.windows[1].desktopAssignment = .desktop("included")
        original.options.excludedDesktopIDs = ["excluded"]
        var excluded = moved
        excluded.desktopAssignment = .desktop("excluded")
        var included = CoreFixtures.live(2, title: "Missing")
        included.desktopAssignment = .desktop("included")
        included.frame.y += 60
        let desktops = DesktopSnapshot(displays: [DesktopDisplay(displayID: "laptop", desktops: [
            SavedDesktop(id: "excluded", ordinal: 0), SavedDesktop(id: "included", ordinal: 1)
        ])], separateDisplays: true)
        original.saved.desktopSnapshot = desktops
        let result = LearningPolicy.updatedWindows(layout: original,
            capture: WindowCapture(windows: [excluded, included], desktopSnapshot: desktops),
            topology: CoreFixtures.topology, beganGeneration: 3, endedGeneration: 3,
            stable: true, fullyRestored: true)
        #expect(result?.first == original.saved.windows.first)
        #expect(result?.last?.frame == included.frame)
        #expect(result?.last?.desktopAssignment == .desktop("included"))
    }

    @Test func ambiguousDisplayLearningRequiresCurrentConfirmationForSameSetup() {
        var ambiguous = layout
        ambiguous.topology.displays[1].identityIsAmbiguous = true
        let topology = ambiguous.topology
        let capture = WindowCapture(windows: [moved])
        let unconfirmed = LearningPolicy.updatedWindows(layout: ambiguous, capture: capture, topology: topology,
            beganGeneration: 4, endedGeneration: 4, stable: true, fullyRestored: true)
        #expect(unconfirmed == nil)
        let confirmed = LearningPolicy.updatedWindows(layout: ambiguous, capture: capture, topology: topology,
            beganGeneration: 4, endedGeneration: 4, stable: true, fullyRestored: true, displayMappingConfirmed: true)
        #expect(confirmed?.first?.frame == moved.frame)
        #expect(confirmed?.map(\.id) == ambiguous.saved.windows.map(\.id))
        #expect(confirmed?.last == ambiguous.saved.windows.last)

        var anotherSetup = topology
        anotherSetup.displays[1].uuid = "ANOTHER-DESK"
        #expect(LearningPolicy.updatedWindows(layout: ambiguous, capture: capture, topology: anotherSetup,
            beganGeneration: 4, endedGeneration: 4, stable: true, fullyRestored: true, displayMappingConfirmed: true) == nil)
        #expect(LearningPolicy.updatedWindows(layout: ambiguous, capture: capture, topology: topology,
            beganGeneration: 4, endedGeneration: 5, stable: true, fullyRestored: true, displayMappingConfirmed: true) == nil)
        ambiguous.importedNeedsMapping = true
        #expect(LearningPolicy.updatedWindows(layout: ambiguous, capture: capture, topology: topology,
            beganGeneration: 4, endedGeneration: 4, stable: true, fullyRestored: true, displayMappingConfirmed: true) == nil)
    }
}
