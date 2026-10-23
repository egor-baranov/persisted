import Foundation

/// All persisted window rectangles and placement calculations use AX logical points.
public enum CoordinateMapper {
    public static func appKitToAX(_ rect: Rect, primaryFrame: Rect) -> Rect {
        Rect(x: rect.x, y: primaryFrame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    public static func axToAppKit(_ rect: Rect, primaryFrame: Rect) -> Rect {
        appKitToAX(rect, primaryFrame: primaryFrame)
    }

    public static func usableAX(_ display: DisplayRecord, in topology: DisplayTopology) -> Rect {
        appKitToAX(display.usableFrame, primaryFrame: topology.primaryFrame)
    }

    public static func sourceDisplay(for frame: Rect, in topology: DisplayTopology) -> DisplayRecord? {
        guard frame.isValid else { return nil }
        // Stable identity ordering resolves equal intersections, independent of NSScreen order.
        return topology.surfaces.sorted { a, b in
            let first = appKitToAX(a.frame, primaryFrame: topology.primaryFrame)
            let second = appKitToAX(b.frame, primaryFrame: topology.primaryFrame)
            let firstArea = intersectionArea(frame, first), secondArea = intersectionArea(frame, second)
            if firstArea != secondArea { return firstArea > secondArea }
            let firstDistance = distanceSquared(frame, first), secondDistance = distanceSquared(frame, second)
            if firstDistance != secondDistance { return firstDistance < secondDistance }
            return a.id < b.id
        }.first
    }

    public static func save(_ live: LiveWindow, in topology: DisplayTopology,
                            desktopSnapshot: DesktopSnapshot? = nil) -> SavedWindow? {
        guard live.frame.isValid else { return nil }
        let source: DisplayRecord?
        if let desktopSnapshot, case let .desktop(desktopID) = live.desktopAssignment {
            guard let desktopDisplay = desktopSnapshot.displayID(for: desktopID) else { return nil }
            // A spanning or offscreen window can intersect another display more than its
            // owning display. Its Space membership supplies the authoritative owner.
            source = desktopSnapshot.separateDisplays
                ? topology.surfaces.first { $0.id == desktopDisplay }
                : sourceDisplay(for: live.frame, in: topology)
        } else {
            source = sourceDisplay(for: live.frame, in: topology)
        }
        guard let source else { return nil }
        let usable = usableAX(source, in: topology)
        guard usable.isValid else { return nil }
        let relative = Rect(x: live.frame.x - usable.x, y: live.frame.y - usable.y,
                            width: live.frame.width, height: live.frame.height)
        let normalized = Rect(x: relative.x / usable.width, y: relative.y / usable.height,
                              width: relative.width / usable.width, height: relative.height / usable.height)
        return SavedWindow(identity: live.identity, displayID: source.id, frame: live.frame,
                           sourceUsableFrame: usable, relativeFrame: relative, normalizedFrame: normalized,
                           minimized: live.minimized, hidden: live.hidden, fullscreen: live.fullscreen,
                           capabilities: live.capabilities, desktopAssignment: live.desktopAssignment)
    }

    public static func targetFrame(for saved: SavedWindow, on display: DisplayRecord,
                                   in topology: DisplayTopology, preserveSize: Bool) -> Rect {
        let usable = usableAX(display, in: topology)
        guard usable.isValid else { return saved.frame }
        if saved.displayID == display.id && saved.sourceUsableFrame == usable {
            return clamp(saved.frame, to: usable)
        }
        let normalized = saved.normalizedFrame
        let frame = Rect(x: usable.x + normalized.x * usable.width,
                         y: usable.y + normalized.y * usable.height,
                         width: preserveSize ? saved.frame.width : normalized.width * usable.width,
                         height: preserveSize ? saved.frame.height : normalized.height * usable.height)
        return clamp(frame, to: usable)
    }

    /// Oversized application windows keep their dimensions, with a reachable title bar.
    /// Resizing to an application minimum is an execution concern, followed by another clamp.
    public static func clamp(_ rect: Rect, to usable: Rect) -> Rect {
        guard rect.isValid, usable.isValid else { return rect }
        let x: Double
        if rect.width <= usable.width {
            x = min(max(rect.x, usable.minX), usable.maxX - rect.width)
        } else {
            // Keep the left/title-bar controls reachable when the entire window cannot fit.
            x = usable.minX
        }
        let y = rect.height <= usable.height
            ? min(max(rect.y, usable.minY), usable.maxY - rect.height)
            : usable.minY
        return Rect(x: x, y: y, width: rect.width, height: rect.height)
    }

    private static func intersectionArea(_ a: Rect, _ b: Rect) -> Double {
        max(0, min(a.maxX, b.maxX) - max(a.minX, b.minX))
            * max(0, min(a.maxY, b.maxY) - max(a.minY, b.minY))
    }

    private static func distanceSquared(_ a: Rect, _ b: Rect) -> Double {
        let x = max(0, max(b.minX - a.maxX, a.minX - b.maxX))
        let y = max(0, max(b.minY - a.maxY, a.minY - b.maxY))
        return x * x + y * y
    }
}
