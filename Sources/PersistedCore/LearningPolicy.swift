import Foundation

/// Pure learning gate. Callers debounce observations and retain the prior revision before committing.
public enum LearningPolicy {
    public static func updatedWindows(layout: Layout, capture: WindowCapture, topology: DisplayTopology,
                                      beganGeneration: UInt64, endedGeneration: UInt64,
                                      stable: Bool, fullyRestored: Bool, isOwnMutation: Bool = false,
                                      temporaryMapping: Bool = false, references: [UUID: UUID] = [:],
                                      exclusions: [WindowExclusion] = [], displayMappingConfirmed: Bool = false) -> [SavedWindow]? {
        let sameConfirmedSetup = displayMappingConfirmed && !layout.importedNeedsMapping && layout.topology.setupKey == topology.setupKey
        guard !layout.editedAwaitingApply, layout.options.rememberAdjustments, stable, fullyRestored, !isOwnMutation, !temporaryMapping,
              beganGeneration == endedGeneration, capture.isComplete, !capture.windows.isEmpty,
              SetupMatcher.compatible(layout, with: topology) || sameConfirmedSetup else { return nil }
        let matches = WindowMatcher.match(saved: layout.effectiveWindows,
                                          live: capture.windows.filter { window in
                                              !exclusions.contains { $0.excludes(window.identity) }
                                          }, references: references)
        var changed = false
        func desktopExcluded(_ assignment: DesktopAssignment?) -> Bool {
            if case .desktop(let id) = assignment { return layout.options.excludedDesktopIDs.contains(id) }
            return false
        }
        let result = layout.effectiveWindows.map { saved -> SavedWindow in
            guard !layout.excludedBundleIDs.contains(saved.identity.bundleID),
                  !desktopExcluded(saved.desktopAssignment),
                  !exclusions.contains(where: { $0.excludes(saved.identity) }),
                  let live = matches.matches[saved.id], !live.minimized, !live.hidden, !live.fullscreen,
                  !desktopExcluded(live.desktopAssignment),
                  let observed = CoordinateMapper.save(live, in: topology, desktopSnapshot: capture.desktopSnapshot) else { return saved }
            // Background learning changes geometry only. Keep desktop membership
            // paired with its original snapshot; explicit Update captures a new order.
            if saved.desktopAssignment != nil && saved.displayID != observed.displayID { return saved }
            guard !saved.frame.approximatelyEquals(observed.frame) || saved.displayID != observed.displayID else { return saved }
            // Only placement changes. Identity, inclusion, matching preferences and explicit
            // saved state remain untouched; missing entries cannot disappear during learning.
            var updated = saved
            updated.displayID = observed.displayID
            updated.frame = observed.frame
            updated.sourceUsableFrame = observed.sourceUsableFrame
            updated.relativeFrame = observed.relativeFrame
            updated.normalizedFrame = observed.normalizedFrame
            changed = true
            return updated
        }
        return changed ? result : nil
    }
}
