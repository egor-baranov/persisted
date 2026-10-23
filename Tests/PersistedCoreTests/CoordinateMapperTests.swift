import Testing
import PersistedCore

@Suite("Logical point geometry")
struct CoordinateMapperTests {
    @Test func appKitAXRoundTripUsesPrimaryTopEdge() {
        let primary = Rect(x: 0, y: 0, width: 1440, height: 900)
        let cases = [Rect(x: -900, y: 100, width: 800, height: 600),
                     Rect(x: 300, y: 1000, width: 400, height: 700),
                     Rect(x: 300, y: -900, width: 400, height: 700)]
        for rect in cases {
            let ax = CoordinateMapper.appKitToAX(rect, primaryFrame: primary)
            #expect(ax.x == rect.x)
            #expect(ax.y == primary.maxY - rect.maxY)
            #expect(ax.width == rect.width)
            #expect(ax.height == rect.height)
            #expect(CoordinateMapper.axToAppKit(ax, primaryFrame: primary) == rect)
        }
    }

    @Test(arguments: 0...7) func dynamicDisplayCount(externalCount: Int) {
        let displays = [CoreFixtures.primary] + (0..<externalCount).map { index in
            DisplayRecord(id: "external-\(index)", name: "Display \(index)", uuid: "unique-\(index)",
                          frame: Rect(x: Double(index + 1) * 1440, y: 0, width: 1440, height: 900))
        }
        let topology = DisplayTopology(displays: displays, lid: .open)
        #expect(topology.surfaces.count == externalCount + 1)
        for display in displays {
            let bounds = CoordinateMapper.usableAX(display, in: topology)
            let frame = Rect(x: bounds.x + 20, y: bounds.y + 20, width: 500, height: 300)
            #expect(CoordinateMapper.sourceDisplay(for: frame, in: topology)?.id == display.id)
        }
    }

    @Test func noUsableDisplaysCannotCapture() {
        let topology = DisplayTopology(displays: [])
        #expect(CoordinateMapper.save(CoreFixtures.live(), in: topology) == nil)
        #expect(CoordinateMapper.sourceDisplay(for: CoreFixtures.live().frame, in: topology) == nil)
    }

    @Test func largestIntersectionAndDeterministicOffscreenFallback() {
        let topology = CoreFixtures.topology
        #expect(CoordinateMapper.sourceDisplay(for: Rect(x: 1300, y: 100, width: 800, height: 400), in: topology)?.id == "office")
        let offscreen = Rect(x: -3000, y: 500, width: 400, height: 300)
        #expect(CoordinateMapper.sourceDisplay(for: offscreen, in: topology)?.id == "laptop")
        #expect(CoordinateMapper.sourceDisplay(for: offscreen, in: DisplayTopology(displays: topology.displays.reversed(), lid: .open))?.id == "laptop")
    }

    @Test func captureStoresAllThreeGeometries() {
        let live = CoreFixtures.live()
        let saved = CoreFixtures.saved(live)
        #expect(saved.frame == live.frame)
        #expect(saved.sourceUsableFrame == Rect(x: 0, y: 24, width: 1440, height: 836))
        #expect(saved.relativeFrame == Rect(x: 100, y: 76, width: 700, height: 500))
        #expect(abs(saved.normalizedFrame.y - 76.0 / 836.0) < 0.000001)
        #expect(CoordinateMapper.targetFrame(for: saved, on: CoreFixtures.primary,
                                             in: CoreFixtures.topology, preserveSize: false) == saved.frame)
    }

    @Test func portraitMixedScaleAndPrimaryChangeReprojects() {
        let saved = CoreFixtures.saved()
        var display = CoreFixtures.primary
        display.frame = Rect(x: -900, y: 200, width: 900, height: 1600)
        display.usableFrame = Rect(x: -900, y: 200, width: 900, height: 1576)
        display.scale = 1
        display.rotation = 90
        display.isPrimary = false
        var external = CoreFixtures.external
        external.isPrimary = true
        let changed = DisplayTopology(displays: [display, external], lid: .open)
        let usable = CoordinateMapper.usableAX(display, in: changed)
        let result = CoordinateMapper.targetFrame(for: saved, on: display, in: changed, preserveSize: false)
        #expect(abs(result.x - (usable.x + saved.normalizedFrame.x * usable.width)) < 0.001)
        #expect(abs(result.width - saved.normalizedFrame.width * usable.width) < 0.001)
        #expect(result.minY >= usable.minY)
        #expect(result.maxY <= usable.maxY)
        let preserved = CoordinateMapper.targetFrame(for: saved, on: display, in: changed, preserveSize: true)
        #expect(preserved.width == saved.frame.width)
        #expect(preserved.height == saved.frame.height)
    }

    @Test func clampKeepsTitleBarReachableAndHonorsVisibleArea() {
        let area = Rect(x: -900, y: -300, width: 900, height: 700)
        #expect(CoordinateMapper.clamp(Rect(x: -3000, y: -2000, width: 400, height: 400), to: area)
                == Rect(x: -900, y: -300, width: 400, height: 400))
        #expect(CoordinateMapper.clamp(Rect(x: 100, y: 200, width: 1200, height: 1000), to: area)
                == Rect(x: -900, y: -300, width: 1200, height: 1000))
    }

    @Test func invalidGeometryIsNeverCaptured() {
        var live = CoreFixtures.live()
        live.frame.x = .nan
        #expect(CoordinateMapper.save(live, in: CoreFixtures.topology) == nil)
        live.frame = Rect(x: 0, y: 0, width: -4, height: 4)
        #expect(CoordinateMapper.save(live, in: CoreFixtures.topology) == nil)
    }
}
