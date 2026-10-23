import Foundation

/// Pure decisions shared by automatic saving and restoration. Choosing a layout
/// does not authorize applying it: callers still honor its Auto and Save switches.
public enum AutoModePolicy {
    public static func layout(for topology: DisplayTopology, library: Library,
                              selectedLayoutID: UUID? = nil) -> Layout? {
        func eligible(_ layout: Layout) -> Bool {
            // Auto saving keeps lid configurations distinct even when a layout's
            // manual restore policy permits either lid state. Equal display counts
            // or names are never enough to identify the physical setup.
            layout.topology.setupKey == topology.setupKey
                && SetupMatcher.compatible(layout, with: topology)
                && SetupMatcher.mapping(for: layout, to: topology) != nil
        }

        if let registeredID = library.autoLayoutIDs[topology.setupKey],
           let registered = library.layouts.first(where: { $0.id == registeredID }) {
            // Keep an explicit disabled association authoritative. If its physical
            // identity becomes unsafe, do not silently substitute another layout.
            return eligible(registered) ? registered : nil
        }
        if let preferredID = library.preferredLayouts[topology.setupKey],
           let preferred = library.layouts.first(where: { $0.id == preferredID }), eligible(preferred) {
            return preferred
        }
        let preferredIDs = Set(library.preferredLayouts.values)
        if let preferred = library.layouts.first(where: { preferredIDs.contains($0.id) && eligible($0) }) {
            return preferred
        }
        if let selectedLayoutID,
           let selected = library.layouts.first(where: { $0.id == selectedLayoutID }), eligible(selected) {
            return selected
        }
        // Library order is the persisted catalog order, including user reordering.
        return library.layouts.first(where: eligible)
    }

    /// Produces a temporary restore view; the stored layout and its history remain
    /// untouched. Excluded desktop slots stay in the inventory so Desktop 3 does
    /// not become Desktop 2 merely because Desktop 2 is excluded. Missing earlier
    /// slots may therefore still be created to reach a later included desktop.
    public static func restorationLayout(_ layout: Layout) -> Layout {
        var result = layout
        let excludedDesktops = layout.options.excludedDesktopIDs
        func filtered(_ revision: LayoutRevision) -> LayoutRevision {
            var revision = revision
            revision.windows.removeAll { window in
                if layout.excludedBundleIDs.contains(window.identity.bundleID) { return true }
                if case .desktop(let id) = window.desktopAssignment { return excludedDesktops.contains(id) }
                return false
            }
            if var snapshot = revision.desktopSnapshot {
                for displayIndex in snapshot.displays.indices {
                    for desktopIndex in snapshot.displays[displayIndex].desktops.indices {
                        if excludedDesktops.contains(snapshot.displays[displayIndex].desktops[desktopIndex].id) {
                            snapshot.displays[displayIndex].desktops[desktopIndex].isActive = false
                        }
                    }
                }
                // An entirely excluded setup must not create desktops or switch
                // Spaces just because the saved inventory still has empty slots.
                revision.desktopSnapshot = revision.windows.isEmpty && snapshot.desktopIDs.isSubset(of: excludedDesktops)
                    ? nil : snapshot
            }
            return revision
        }
        result.saved = filtered(layout.saved)
        result.remembered = layout.remembered.map(filtered)
        return result
    }
}
