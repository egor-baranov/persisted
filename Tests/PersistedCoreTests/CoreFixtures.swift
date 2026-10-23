import Foundation
import PersistedCore

enum CoreFixtures {
    static let primary = DisplayRecord(id: "laptop", name: "Built-in", uuid: "LAPTOP", isBuiltIn: true,
                                       isPrimary: true, frame: Rect(x: 0, y: 0, width: 1440, height: 900),
                                       usableFrame: Rect(x: 0, y: 40, width: 1440, height: 836), scale: 2)
    static let external = DisplayRecord(id: "office", name: "Office", uuid: "OFFICE",
                                        frame: Rect(x: 1440, y: 0, width: 1920, height: 1080),
                                        usableFrame: Rect(x: 1440, y: 0, width: 1920, height: 1056))
    static var topology: DisplayTopology { DisplayTopology(displays: [primary, external], lid: .open) }
    static func id(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!
    }
    static func live(_ number: Int = 1, title: String = "Notes", bundle: String = "example.editor",
                     document: String? = nil, accessibility: String? = nil,
                     frame: Rect = Rect(x: 100, y: 100, width: 700, height: 500),
                     launch: TimeInterval = 10) -> LiveWindow {
        LiveWindow(id: id(number), instance: ApplicationInstance(pid: 42, launchDate: Date(timeIntervalSince1970: launch)),
                   identity: WindowIdentity(bundleID: bundle, appName: "Editor", accessibilityID: accessibility,
                                            documentID: document, title: title), frame: frame)
    }
    static func saved(_ live: LiveWindow = live(), topology: DisplayTopology = topology) -> SavedWindow {
        var saved = CoordinateMapper.save(live, in: topology)!
        saved.id = id(1000 + Int(live.id.uuidString.suffix(3))!)
        return saved
    }
    static func layout(windows: [SavedWindow]? = nil, topology: DisplayTopology = topology) -> Layout {
        Layout(name: "Work", topology: topology, windows: windows ?? [saved()])
    }
}
