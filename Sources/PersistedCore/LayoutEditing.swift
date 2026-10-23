import Foundation

public enum LayoutEditError: LocalizedError, Equatable, Sendable {
    case missingWindow, missingDisplay, missingDesktop, missingDesktopSnapshot
    case wrongDesktopDisplay, invalidFrame, desktopMoveOutOfBounds, fullscreenDesktop
    case desktopLimit, desktopNotEmpty, lastOrdinaryDesktop

    public var errorDescription: String? {
        switch self {
        case .missingWindow: "This saved window is no longer available."
        case .missingDisplay: "Choose a display recorded in this layout."
        case .missingDesktop: "Choose a desktop recorded in this layout."
        case .missingDesktopSnapshot: "Add a desktop before assigning windows to desktops."
        case .wrongDesktopDisplay: "This desktop belongs to another display. Move the window to that display first."
        case .invalidFrame: "Enter finite window coordinates and a positive width and height."
        case .desktopMoveOutOfBounds: "The desktop cannot move further in that direction."
        case .fullscreenDesktop: "Full-screen Spaces cannot be removed or reordered here."
        case .desktopLimit: "A display can contain at most 16 ordinary desktops."
        case .desktopNotEmpty: "Move the saved windows to another desktop before removing this desktop."
        case .lastOrdinaryDesktop: "Keep at least one ordinary desktop on each display."
        }
    }
}

/// A value-only editor for a saved revision. None of these operations move live windows
/// or change the original layout. The caller owns history, persistence, and conflict checks.
public struct LayoutEditDraft: Hashable, Sendable {
    public let layoutID: UUID
    public let sourceRevisionID: UUID
    public let sourceRevision: LayoutRevision
    public let topology: DisplayTopology
    public private(set) var revision: LayoutRevision
    private let sourceLayout: Layout

    public init(layout: Layout) {
        layoutID = layout.id
        sourceRevision = layout.remembered ?? layout.saved
        sourceRevisionID = sourceRevision.id
        topology = layout.topology
        revision = sourceRevision
        sourceLayout = layout
    }

    public var hasChanges: Bool {
        revision.windows != sourceRevision.windows || revision.desktopSnapshot != sourceRevision.desktopSnapshot
    }

    /// AX global coordinates in logical points. Editor frame inputs are relative to
    /// this rectangle's top-left corner, including on monitors left of or above the main display.
    public func displayUsableFrame(displayID: String) -> Rect? {
        guard let display = topology.surfaces.first(where: { $0.id == displayID }) else { return nil }
        let usable = CoordinateMapper.usableAX(display, in: topology)
        return usable.isValid ? usable : nil
    }

    public mutating func setWindowFrame(windowID: UUID, relativeFrame: Rect) throws {
        let index = try windowIndex(windowID)
        guard let usable = displayUsableFrame(displayID: revision.windows[index].displayID) else { throw LayoutEditError.missingDisplay }
        let updated = try applying(relativeFrame: relativeFrame, usable: usable, to: revision.windows[index])
        revision.windows[index] = updated
    }

    /// Reprojects the saved proportion onto another display and bounds it to that
    /// work area. A nil desktop ID deliberately leaves membership unknown.
    public mutating func moveWindow(windowID: UUID, toDisplayID: String, desktopID: String?) throws {
        let index = try windowIndex(windowID)
        guard let display = topology.surfaces.first(where: { $0.id == toDisplayID }),
              let usable = displayUsableFrame(displayID: toDisplayID) else { throw LayoutEditError.missingDisplay }
        let assignment = desktopID.map(DesktopAssignment.desktop)
        try validate(assignment: assignment, displayID: toDisplayID)
        let saved = revision.windows[index]
        let target = CoordinateMapper.targetFrame(for: saved, on: display, in: topology,
                                                 preserveSize: sourceLayout.options.preserveWindowSize)
        let relative = Rect(x: target.x - usable.x, y: target.y - usable.y, width: target.width, height: target.height)
        var updated = try applying(relativeFrame: relative, usable: usable, to: saved)
        updated.displayID = toDisplayID
        updated.desktopAssignment = assignment
        revision.windows[index] = updated
    }

    public mutating func assignDesktop(windowID: UUID, assignment: DesktopAssignment?) throws {
        let index = try windowIndex(windowID)
        try validate(assignment: assignment, displayID: revision.windows[index].displayID)
        revision.windows[index].desktopAssignment = assignment
    }

    /// Offsets count ordinary desktops. Full-screen entries retain their exact slots,
    /// while each ordinary desktop's ID, active state, and window assignments travel with it.
    public mutating func moveDesktop(id: String, offset: Int) throws {
        let location = try desktopLocation(id)
        guard var snapshot = revision.desktopSnapshot else { throw LayoutEditError.missingDesktopSnapshot }
        var ordered = snapshot.displays[location.display].desktops.sorted { $0.ordinal < $1.ordinal }
        guard ordered.first(where: { $0.id == id })?.kind == .ordinary else { throw LayoutEditError.fullscreenDesktop }
        let ordinarySlots = ordered.indices.filter { ordered[$0].kind == .ordinary }
        var ordinary = ordinarySlots.map { ordered[$0] }
        guard let from = ordinary.firstIndex(where: { $0.id == id }) else { throw LayoutEditError.missingDesktop }
        let (destination, overflow) = from.addingReportingOverflow(offset)
        guard !overflow, ordinary.indices.contains(destination) else { throw LayoutEditError.desktopMoveOutOfBounds }
        guard destination != from else { return }
        let moving = ordinary.remove(at: from)
        ordinary.insert(moving, at: destination)
        for (index, slot) in ordinarySlots.enumerated() { ordered[slot] = ordinary[index] }
        for ordinal in ordered.indices { ordered[ordinal].ordinal = ordinal }
        snapshot.displays[location.display].desktops = ordered
        revision.desktopSnapshot = snapshot
    }

    /// Legacy layouts acquire one ordinary desktop per saved surface before the new
    /// desktop is added. Existing unknown window memberships remain unknown.
    @discardableResult public mutating func addDesktop(displayID: String) throws -> String {
        guard displayUsableFrame(displayID: displayID) != nil else { throw LayoutEditError.missingDisplay }
        var snapshot = revision.desktopSnapshot ?? DesktopSnapshot(displays: topology.surfaces.map {
            .init(displayID: $0.id, desktops: [.init(id: UUID().uuidString, ordinal: 0, isActive: true)])
        }, separateDisplays: true)
        let index: Int
        if !snapshot.separateDisplays, !snapshot.displays.isEmpty { index = 0 }
        else if let existing = snapshot.displays.firstIndex(where: { $0.displayID == displayID }) { index = existing }
        else {
            index = snapshot.displays.count
            snapshot.displays.append(.init(displayID: displayID, desktops: []))
        }
        var ordered = snapshot.displays[index].desktops.sorted { $0.ordinal < $1.ordinal }
        guard ordered.filter({ $0.kind == .ordinary }).count < 16, ordered.count < 128 else { throw LayoutEditError.desktopLimit }
        let existingIDs = snapshot.desktopIDs
        var id = UUID().uuidString
        while existingIDs.contains(id) { id = UUID().uuidString }
        ordered.append(.init(id: id, ordinal: ordered.count, isActive: ordered.isEmpty))
        snapshot.displays[index].desktops = ordered
        revision.desktopSnapshot = snapshot
        return id
    }

    public mutating func removeDesktop(id: String) throws {
        let location = try desktopLocation(id)
        guard var snapshot = revision.desktopSnapshot else { throw LayoutEditError.missingDesktopSnapshot }
        var ordered = snapshot.displays[location.display].desktops.sorted { $0.ordinal < $1.ordinal }
        guard let index = ordered.firstIndex(where: { $0.id == id }) else { throw LayoutEditError.missingDesktop }
        guard ordered[index].kind == .ordinary else { throw LayoutEditError.fullscreenDesktop }
        guard ordered.filter({ $0.kind == .ordinary }).count > 1 else { throw LayoutEditError.lastOrdinaryDesktop }
        guard !revision.windows.contains(where: { $0.desktopAssignment == .desktop(id) }) else { throw LayoutEditError.desktopNotEmpty }
        let removed = ordered.remove(at: index)
        if removed.isActive {
            let ordinary = ordered.indices.filter { ordered[$0].kind == .ordinary }
            let replacement = ordinary.first(where: { ordered[$0].ordinal > removed.ordinal }) ?? ordinary.last
            if let replacement { ordered[replacement].isActive = true }
        }
        for ordinal in ordered.indices { ordered[ordinal].ordinal = ordinal }
        snapshot.displays[location.display].desktops = ordered
        revision.desktopSnapshot = snapshot
    }

    public mutating func setActiveDesktop(id: String) throws {
        let location = try desktopLocation(id)
        guard var snapshot = revision.desktopSnapshot else { throw LayoutEditError.missingDesktopSnapshot }
        for index in snapshot.displays[location.display].desktops.indices {
            snapshot.displays[location.display].desktops[index].isActive = snapshot.displays[location.display].desktops[index].id == id
        }
        revision.desktopSnapshot = snapshot
    }

    /// Creates a fresh revision only after validating it against the source layout's
    /// original topology and non-editor metadata. The source revision remains unchanged.
    public func validatedRevision() throws -> LayoutRevision {
        let result = LayoutRevision(windows: revision.windows, desktopSnapshot: revision.desktopSnapshot)
        var candidate = sourceLayout
        candidate.saved = result
        candidate.remembered = nil
        var library = Library()
        library.layouts = [candidate]
        try LayoutRepository.validate(library)
        return result
    }

    private func windowIndex(_ id: UUID) throws -> Int {
        guard let index = revision.windows.firstIndex(where: { $0.id == id }) else { throw LayoutEditError.missingWindow }
        return index
    }

    private func desktopLocation(_ id: String) throws -> (display: Int, desktop: Int) {
        guard let snapshot = revision.desktopSnapshot else { throw LayoutEditError.missingDesktopSnapshot }
        for display in snapshot.displays.indices {
            if let desktop = snapshot.displays[display].desktops.firstIndex(where: { $0.id == id }) { return (display, desktop) }
        }
        throw LayoutEditError.missingDesktop
    }

    private func validate(assignment: DesktopAssignment?, displayID: String) throws {
        guard let assignment else { return }
        guard let snapshot = revision.desktopSnapshot else { throw LayoutEditError.missingDesktopSnapshot }
        switch assignment {
        case .desktop(let id):
            guard let owner = snapshot.displayID(for: id) else { throw LayoutEditError.missingDesktop }
            guard !snapshot.separateDisplays || owner == displayID else { throw LayoutEditError.wrongDesktopDisplay }
        case .allDesktops:
            guard !snapshot.separateDisplays || snapshot.displays.contains(where: { $0.displayID == displayID }) else {
                throw LayoutEditError.missingDesktop
            }
        }
    }

    private func applying(relativeFrame: Rect, usable: Rect, to saved: SavedWindow) throws -> SavedWindow {
        guard relativeFrame.isValid, usable.isValid else { throw LayoutEditError.invalidFrame }
        let width = min(max(relativeFrame.width, 20), usable.width)
        let height = min(max(relativeFrame.height, 20), usable.height)
        let relative = Rect(x: min(max(relativeFrame.x, 0), usable.width - width),
                            y: min(max(relativeFrame.y, 0), usable.height - height), width: width, height: height)
        let frame = Rect(x: usable.x + relative.x, y: usable.y + relative.y, width: width, height: height)
        let normalized = Rect(x: relative.x / usable.width, y: relative.y / usable.height,
                              width: width / usable.width, height: height / usable.height)
        guard frame.isValid, relative.isValid, normalized.isValid else { throw LayoutEditError.invalidFrame }
        var updated = saved
        updated.frame = frame
        updated.sourceUsableFrame = usable
        updated.relativeFrame = relative
        updated.normalizedFrame = normalized
        return updated
    }
}
