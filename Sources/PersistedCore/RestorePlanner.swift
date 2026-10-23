import Foundation

public enum RestorePlanner {
    public static func plan(layout: Layout, topology: DisplayTopology, capture: WindowCapture,
                            generation: UInt64, mapping: [String: String], references: [UUID: UUID] = [:],
                            exclusions: [WindowExclusion] = []) -> RestorePlan {
        let saved = layout.effectiveWindows.filter { !layout.excludedBundleIDs.contains($0.identity.bundleID) }
        let eligible = saved.filter { entry in !exclusions.contains { $0.excludes(entry.identity) } }
        let live = capture.windows.filter { window in !exclusions.contains { $0.excludes(window.identity) } }
        let matched = WindowMatcher.match(saved: eligible, live: live, references: references)
        var placements: [PlannedPlacement] = []
        var outcomes: [WindowOutcome] = []
        for entry in saved {
            func unresolved(_ kind: WindowOutcomeKind, _ explanation: String) {
                outcomes.append(WindowOutcome(id: entry.id, appName: entry.identity.appName,
                                              kind: kind, explanation: explanation))
            }
            guard !exclusions.contains(where: { $0.excludes(entry.identity) }) else {
                unresolved(.unsupported, "Excluded in Settings."); continue
            }
            guard capture.permissionGranted else {
                unresolved(.unsupported, "Accessibility permission is required."); continue
            }
            guard let targetID = mapping[entry.displayID],
                  let display = topology.surfaces.first(where: { $0.id == targetID }) else {
                unresolved(.unsupported, "The saved display is skipped or needs a display mapping."); continue
            }
            guard !matched.ambiguous.contains(entry.id) else {
                unresolved(.ambiguous, "More than one window could match. Assign a window to continue."); continue
            }
            guard let window = matched.matches[entry.id] else {
                let appEnumerated = capture.runningBundleIDs.contains(entry.identity.bundleID)
                let issue = capture.issues.first { $0.bundleID == entry.identity.bundleID }
                if let issue {
                    unresolved(.missingWindow, issue.message)
                } else {
                    unresolved(appEnumerated ? .missingWindow : .missingApplication,
                               appEnumerated ? "The saved window is not currently available." : "The application has no available windows.")
                }
                continue
            }
            guard !window.fullscreen else {
                unresolved(.unsupported, "Full-screen windows are preserved. Leave full screen and apply again."); continue
            }
            guard !window.minimized else {
                unresolved(.unsupported, "Minimized windows are preserved. Restore the window and apply again."); continue
            }
            guard !window.hidden else {
                unresolved(.unsupported, "Hidden applications are preserved. Show the application and apply again."); continue
            }
            let target = CoordinateMapper.targetFrame(for: entry, on: display, in: topology,
                                                     preserveSize: layout.options.preserveWindowSize)
            guard target.isValid else {
                unresolved(.unsupported, "The saved geometry is invalid."); continue
            }
            let requiresMove = abs(window.frame.x - target.x) > 2 || abs(window.frame.y - target.y) > 2
            let requiresResize = abs(window.frame.width - target.width) > 2 || abs(window.frame.height - target.height) > 2
            guard !requiresMove || window.capabilities.canMove else {
                unresolved(.unsupported, "This window does not allow changing its position."); continue
            }
            guard !requiresResize || window.capabilities.canResize else {
                unresolved(.unsupported, "This window does not allow changing its size."); continue
            }
            placements.append(PlannedPlacement(savedWindow: entry, liveWindow: window, targetFrame: target,
                                                targetUsableFrame: CoordinateMapper.usableAX(display, in: topology)))
        }
        return RestorePlan(layoutID: layout.id, revisionID: layout.remembered?.id ?? layout.saved.id,
                           generation: generation, topology: topology, placements: placements,
                           unresolved: outcomes, mappings: mapping)
    }
}
