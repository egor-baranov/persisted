import Testing
import PersistedCore

@Suite("Display identity and explicit mappings")
struct SetupMatcherTests {
    @Test func geometryChangesDoNotCreateNewSetup() {
        let first = CoreFixtures.topology
        var changed = first
        changed.displays[0].isPrimary = false
        changed.displays[1].isPrimary = true
        changed.displays[1].frame = Rect(x: -1200, y: 300, width: 1200, height: 1900)
        changed.displays[1].usableFrame = Rect(x: -1200, y: 300, width: 1200, height: 1876)
        changed.displays[1].scale = 2
        changed.displays[1].rotation = 90
        #expect(first.setupKey == changed.setupKey)
        #expect(first.geometryKey != changed.geometryKey)
        #expect(!first.isEquivalent(to: changed))
        #expect(SetupMatcher.compatible(CoreFixtures.layout(), with: changed))
        #expect(SetupMatcher.mapping(for: CoreFixtures.layout(), to: changed) == ["laptop": "laptop", "office": "office"])
    }

    @Test func identityIgnoresEnumerationOrderAndDisplayLabel() {
        var changed = CoreFixtures.topology
        changed.displays.reverse()
        changed.displays[0].name = "My portrait monitor"
        #expect(CoreFixtures.topology.setupKey == changed.setupKey)
        #expect(CoreFixtures.topology.isEquivalent(to: changed))
    }

    @Test func sameCountDifferentDeskIsDifferentSetup() {
        var home = CoreFixtures.topology
        home.displays[1].id = "home"
        home.displays[1].uuid = "HOME"
        #expect(home.setupKey != CoreFixtures.topology.setupKey)
        #expect(!SetupMatcher.compatible(CoreFixtures.layout(), with: home))
    }

    @Test func lidUnknownIsNotGuessedFromBuiltInActivity() {
        var changed = CoreFixtures.topology
        changed.lid = .unknown
        let layout = CoreFixtures.layout()
        #expect(!SetupMatcher.compatible(layout, with: changed))
        var ignoring = layout
        ignoring.options.lidPolicy = .ignore
        #expect(SetupMatcher.compatible(ignoring, with: changed))
        var explicitUnknown = layout
        explicitUnknown.topology.lid = .unknown
        #expect(SetupMatcher.compatible(explicitUnknown, with: changed))
        changed.lid = .closed
        #expect(!SetupMatcher.compatible(layout, with: changed))
        changed.lid = .open
        changed.displays[0].isActive = false
        #expect(!SetupMatcher.compatible(ignoring, with: changed))
    }

    @Test func mirrorGroupsAreSingleSurfaceAndSourceMayChange() {
        var source = CoreFixtures.external
        source.id = "first"; source.uuid = "FIRST"; source.isPrimary = true
        var mirror = source
        mirror.id = "second"; mirror.uuid = "SECOND"; mirror.isPrimary = false; mirror.mirrorSourceID = source.id
        let topology = DisplayTopology(displays: [source, mirror], lid: .notApplicable)
        #expect(topology.surfaces.count == 1)
        var swapped = topology
        swapped.displays[0].mirrorSourceID = "second"
        swapped.displays[1].mirrorSourceID = nil
        #expect(topology.setupKey == swapped.setupKey)
        let layout = CoreFixtures.layout(windows: [], topology: topology)
        #expect(SetupMatcher.mapping(for: layout, to: swapped) == ["first": "second"])
        swapped.displays[0].mirrorSourceID = nil
        #expect(topology.setupKey != swapped.setupKey)
    }

    @Test func ambiguityNeedsCompleteApprovedMapping() {
        var topology = CoreFixtures.topology
        topology.displays[1].identityIsAmbiguous = true
        let layout = CoreFixtures.layout(topology: topology)
        #expect(!SetupMatcher.compatible(layout, with: topology))
        #expect(SetupMatcher.mapping(for: layout, to: topology) == nil)
        var approved = DisplayMapping(layoutID: layout.id, targetSetupKey: topology.setupKey,
                                      assignments: ["laptop": "laptop", "office": "office"])
        #expect(SetupMatcher.mapping(for: layout, to: topology, approved: approved) != nil)
        approved.assignments.removeValue(forKey: "office")
        #expect(SetupMatcher.mapping(for: layout, to: topology, approved: approved) == nil)
        approved.skipped.insert("office")
        #expect(SetupMatcher.mapping(for: layout, to: topology, approved: approved) == ["laptop": "laptop"])
        approved.targetSetupKey = "previous setup"
        #expect(SetupMatcher.mapping(for: layout, to: topology, approved: approved) == nil)
    }

    @Test func duplicateIdentitySignalsCannotBecomeAutomatic() {
        var topology = CoreFixtures.topology
        topology.displays[1].uuid = topology.displays[0].uuid
        let layout = CoreFixtures.layout(topology: topology)
        #expect(SetupMatcher.mapping(for: layout, to: topology) == nil)
    }

    @Test func importedLayoutsStayInactiveUntilMappingResolved() {
        var layout = CoreFixtures.layout()
        layout.importedNeedsMapping = true
        #expect(!SetupMatcher.compatible(layout, with: CoreFixtures.topology))
        let approved = DisplayMapping(layoutID: layout.id, targetSetupKey: CoreFixtures.topology.setupKey,
                                      assignments: ["laptop": "laptop", "office": "office"])
        #expect(SetupMatcher.mapping(for: layout, to: CoreFixtures.topology, approved: approved) != nil)
    }

    @Test func manualLaptopLayoutUsesBuiltInWithExtraDisplays() {
        let layout = CoreFixtures.layout(windows: [], topology: .init(displays: [CoreFixtures.primary], lid: .open))
        var current = CoreFixtures.topology
        current.displays[0].id = "new-laptop"
        current.displays[0].uuid = "CHANGED-LAPTOP-UUID"
        current.displays[0].frame = Rect(x: 0, y: 0, width: 1728, height: 1117)
        current.displays[0].usableFrame = current.displays[0].frame
        #expect(SetupMatcher.manualMapping(for: layout, to: current) == ["laptop": "new-laptop"])
        #expect(!SetupMatcher.compatible(layout, with: current))
        #expect(SetupMatcher.mapping(for: layout, to: current) == nil)
    }

    @Test func unrelatedAmbiguousMonitorsDoNotBlockBuiltInDetection() {
        let layout = CoreFixtures.layout(windows: [], topology: .init(displays: [CoreFixtures.primary], lid: .open))
        let current = DisplayTopology(displays: [CoreFixtures.primary,
                                                monitor("left", ambiguous: true),
                                                monitor("right", ambiguous: true)], lid: .open)
        #expect(SetupMatcher.manualMapping(for: layout, to: current) == ["laptop": "laptop"])
        #expect(!SetupMatcher.compatible(layout, with: current))
    }

    @Test func duplicatedUUIDAcrossRolesDoesNotOverrideBuiltInDetection() {
        let layout = CoreFixtures.layout(windows: [], topology: .init(displays: [CoreFixtures.primary], lid: .open))
        var builtin = CoreFixtures.primary
        builtin.id = "new-laptop"
        builtin.uuid = "CHANGED-LAPTOP-UUID"
        var external = CoreFixtures.external
        external.uuid = CoreFixtures.primary.uuid
        let current = DisplayTopology(displays: [external, builtin], lid: .open)
        #expect(SetupMatcher.manualMapping(for: layout, to: current) == ["laptop": "new-laptop"])
    }

    @Test func explicitRestoreConsolidatesOntoOnlyUsableTarget() {
        var inactive = CoreFixtures.external
        inactive.isActive = false
        let current = DisplayTopology(displays: [CoreFixtures.primary, inactive], lid: .open)
        #expect(SetupMatcher.manualMapping(for: CoreFixtures.layout(), to: current)
                == ["laptop": "laptop", "office": "laptop"])
        #expect(SetupMatcher.mapping(for: CoreFixtures.layout(), to: current) == nil)

        inactive.isActive = true
        inactive.usableFrame = Rect()
        let unusableExternal = DisplayTopology(displays: [CoreFixtures.primary, inactive], lid: .open)
        #expect(SetupMatcher.suggestedMapping(for: CoreFixtures.layout(), to: unusableExternal)
                == ["laptop": "laptop", "office": "laptop"])
        inactive.isActive = false
        let noTarget = DisplayTopology(displays: [inactive], lid: .closed)
        #expect(SetupMatcher.suggestedMapping(for: CoreFixtures.layout(), to: noTarget).isEmpty)
        #expect(SetupMatcher.manualMapping(for: CoreFixtures.layout(), to: noTarget) == nil)
    }

    @Test func uniqueExternalReplacementDoesNotBroadenDockingCompatibility() {
        var replacement = CoreFixtures.external
        replacement.id = "home"
        replacement.uuid = "HOME"
        replacement.name = "Different monitor"
        let current = DisplayTopology(displays: [replacement, CoreFixtures.primary], lid: .open)
        #expect(SetupMatcher.manualMapping(for: CoreFixtures.layout(), to: current)
                == ["laptop": "laptop", "office": "home"])
        #expect(!SetupMatcher.compatible(CoreFixtures.layout(), with: current))
        #expect(SetupMatcher.mapping(for: CoreFixtures.layout(), to: current) == nil)
    }

    @Test func strongIdentityIsReservedBeforeReplacementRegardlessOfOrder() {
        let unknown = monitor("old", name: "Old monitor")
        let known = monitor("known", name: "Known monitor", uuid: "KNOWN")
        let replacement = monitor("replacement", name: "Replacement")
        var sameMonitor = known
        sameMonitor.id = "known-new-id"
        let current = DisplayTopology(displays: [sameMonitor, replacement], lid: .notApplicable)
        for sourceOrder in [[unknown, known], [known, unknown]] {
            let layout = CoreFixtures.layout(windows: [], topology: .init(displays: sourceOrder, lid: .notApplicable))
            #expect(SetupMatcher.manualMapping(for: layout, to: current)
                    == ["known": "known-new-id", "old": "replacement"])
        }
    }

    @Test func uniqueSerialModelAndNameHintsSurviveChangedUUIDs() {
        var serial = monitor("serial", name: "Saved one", uuid: "OLD-ONE")
        serial.vendor = 7; serial.model = 11; serial.serial = 42
        var model = monitor("model", name: "Saved two", uuid: "OLD-TWO")
        model.vendor = 8; model.model = 12
        let named = monitor("named", name: "  Studio   Portrait ", uuid: "OLD-THREE")
        let layout = CoreFixtures.layout(windows: [], topology: .init(displays: [serial, model, named], lid: .notApplicable))
        var newSerial = serial
        newSerial.id = "new-serial"; newSerial.uuid = "NEW-ONE"; newSerial.name = "New one"
        var newModel = model
        newModel.id = "new-model"; newModel.uuid = "NEW-TWO"; newModel.name = "New two"
        var newNamed = named
        newNamed.id = "new-named"; newNamed.uuid = "NEW-THREE"; newNamed.name = "studio portrait"
        // Additional unmatched monitors prevent a successful result by elimination alone.
        let current = DisplayTopology(displays: [monitor("extra-a"), newNamed, newModel,
                                                monitor("extra-b"), newSerial], lid: .notApplicable)
        #expect(SetupMatcher.manualMapping(for: layout, to: current)
                == ["serial": "new-serial", "model": "new-model", "named": "new-named"])
    }

    @Test func duplicateMonitorsRemainUnresolvedButKnownChoicesPrefill() {
        let saved = DisplayTopology(displays: [CoreFixtures.primary, monitor("saved-a", ambiguous: true),
                                              monitor("saved-b", ambiguous: true)], lid: .open)
        let current = DisplayTopology(displays: [monitor("current-b", ambiguous: true), CoreFixtures.primary,
                                                monitor("current-a", ambiguous: true)], lid: .open)
        let layout = CoreFixtures.layout(windows: [], topology: saved)
        #expect(SetupMatcher.suggestedMapping(for: layout, to: current) == ["laptop": "laptop"])
        #expect(SetupMatcher.manualMapping(for: layout, to: current) == nil)
        #expect(!SetupMatcher.compatible(layout, with: current))
    }

    @Test func adapterAmbiguityCannotBeResolvedUsingAppendedIDsOrDockUUIDs() {
        let saved = DisplayTopology(displays: [monitor("first", uuid: "DOCK-ONE", ambiguous: true),
                                              monitor("second", uuid: "DOCK-TWO", ambiguous: true)], lid: .notApplicable)
        let layout = CoreFixtures.layout(windows: [], topology: saved)
        #expect(SetupMatcher.suggestedMapping(for: layout, to: saved).isEmpty)
        #expect(SetupMatcher.manualMapping(for: layout, to: saved) == nil)
    }

    @Test func twoSavedCandidatesCannotClaimOneOfSeveralTargets() {
        let layout = CoreFixtures.layout(windows: [], topology: .init(displays: [monitor("saved-a"),
                                                                                 monitor("saved-b")], lid: .notApplicable))
        let current = DisplayTopology(displays: [CoreFixtures.primary, monitor("external")], lid: .open)
        #expect(SetupMatcher.suggestedMapping(for: layout, to: current).isEmpty)
        #expect(SetupMatcher.manualMapping(for: layout, to: current) == nil)
    }

    @Test func manualMirrorDetectionFollowsRootChangesWithAdditionalMonitors() {
        let first = monitor("first", name: "First", uuid: "FIRST")
        var second = monitor("second", name: "Second", uuid: "SECOND")
        second.mirrorSourceID = first.id
        let layout = CoreFixtures.layout(windows: [], topology: .init(displays: [first, second], lid: .notApplicable))
        var currentFirst = first
        currentFirst.mirrorSourceID = second.id
        second.mirrorSourceID = nil
        let current = DisplayTopology(displays: [CoreFixtures.primary, currentFirst, second], lid: .open)
        #expect(SetupMatcher.manualMapping(for: layout, to: current) == ["first": "second"])
    }

    @Test func splitMirrorGroupIsNotArbitrarilyAssignedToOneMember() {
        let first = monitor("first", name: "First", uuid: "FIRST")
        var second = monitor("second", name: "Second", uuid: "SECOND")
        second.mirrorSourceID = first.id
        let layout = CoreFixtures.layout(windows: [], topology: .init(displays: [first, second], lid: .notApplicable))
        second.mirrorSourceID = nil
        let current = DisplayTopology(displays: [first, second], lid: .notApplicable)
        #expect(SetupMatcher.suggestedMapping(for: layout, to: current).isEmpty)
        #expect(SetupMatcher.manualMapping(for: layout, to: current) == nil)
    }

    @Test func importedSuggestionsStillRequireReview() {
        var layout = CoreFixtures.layout()
        layout.importedNeedsMapping = true
        #expect(SetupMatcher.suggestedMapping(for: layout, to: CoreFixtures.topology)
                == ["laptop": "laptop", "office": "office"])
        #expect(SetupMatcher.manualMapping(for: layout, to: CoreFixtures.topology) == nil)
        #expect(SetupMatcher.mapping(for: layout, to: CoreFixtures.topology) == nil)
    }

    private func monitor(_ id: String, name: String = "Identical monitor", uuid: String? = nil,
                         ambiguous: Bool = false) -> DisplayRecord {
        DisplayRecord(id: id, name: name, uuid: uuid, vendor: 55, model: 66,
                      identityIsAmbiguous: ambiguous,
                      frame: Rect(x: 1440, y: 0, width: 1920, height: 1080))
    }
}
