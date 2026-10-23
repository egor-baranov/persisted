import Foundation

/// Learns a complete arrangement for one physical setup. The coordinator supplies a
/// debounced capture taken outside restores, display transitions, and user exclusions.
public enum AutoLearningPolicy {
    /// A restored group occupies an ordinary desktop slot, not necessarily the same
    /// native Space that supplied its original UUID. Rebind those local hints before
    /// resuming learning so exclusions and saved assignments keep their logical IDs.
    ///
    /// The caller must verify the complete restore and capture first. A nil result
    /// means identity cannot be reconciled safely; keep offline-edit protection set.
    /// Full-screen entries must already occupy the same slots and retain identity.
    public static func rebindingDesktopHints(_ saved: DesktopSnapshot, afterRestore captured: DesktopSnapshot,
                                             topology: DisplayTopology) -> DesktopSnapshot? {
        guard saved.separateDisplays == captured.separateDisplays,
              Set(saved.displays.map(\.displayID)) == Set(captured.displays.map(\.displayID)),
              normalize(saved, against: nil, topology: topology) != nil,
              normalize(captured, against: nil, topology: topology) != nil else { return nil }
        var rebound = saved
        var expectedIDs: [String: String] = [:]
        for displayIndex in rebound.displays.indices {
            let previous = saved.displays[displayIndex]
            guard let current = captured.displays.first(where: { $0.displayID == previous.displayID }),
                  previous.ordinaryDesktops.count == current.ordinaryDesktops.count else { return nil }
            let hints = current.desktops.compactMap { desktop -> String? in
                guard let hint = desktop.uuidHint, !hint.isEmpty else { return nil }
                return hint.lowercased()
            }
            guard Set(hints).count == hints.count else { return nil }
            let oldFullscreen = previous.desktops.filter { $0.kind == .fullscreen }.sorted { $0.ordinal < $1.ordinal }
            let newFullscreen = current.desktops.filter { $0.kind == .fullscreen }.sorted { $0.ordinal < $1.ordinal }
            guard oldFullscreen.count == newFullscreen.count else { return nil }
            for (old, new) in zip(oldFullscreen, newFullscreen) {
                let sameHint = old.uuidHint.map { !$0.isEmpty && $0.lowercased() == new.uuidHint?.lowercased() } ?? false
                let sameIDWithoutConflictingHints = old.id == new.id &&
                    (old.uuidHint == nil || new.uuidHint == nil || old.uuidHint?.lowercased() == new.uuidHint?.lowercased())
                guard old.ordinal == new.ordinal, sameHint || sameIDWithoutConflictingHints else { return nil }
                expectedIDs[new.id] = old.id
            }
            for (old, new) in zip(previous.ordinaryDesktops, current.ordinaryDesktops) {
                guard let index = rebound.displays[displayIndex].desktops.firstIndex(where: { $0.id == old.id }) else { return nil }
                rebound.displays[displayIndex].desktops[index].uuidHint = new.uuidHint
                expectedIDs[new.id] = old.id
            }
        }
        // UUID matching runs before ID/ordinal fallback. Simulate that exact path:
        // absent hints must never let an old native ID steal a reordered group.
        guard let normalized = normalize(captured, against: rebound, topology: topology),
              normalized.ids == expectedIDs, !snapshotChanged(rebound, normalized.snapshot) else { return nil }
        return rebound
    }

    public static func updatedRevision(layout: Layout, capture: WindowCapture, topology: DisplayTopology,
                                       references: [UUID: UUID] = [:], exclusions: [WindowExclusion] = []) -> LayoutRevision? {
        guard !layout.editedAwaitingApply, layout.options.autoModeEnabled, layout.options.autoSaveEnabled, !layout.importedNeedsMapping,
              capture.isComplete, !capture.windows.isEmpty || capture.desktopSnapshot != nil,
              layout.topology.setupKey == topology.setupKey,
              Set(layout.topology.surfaces.map(\.id)) == Set(topology.surfaces.map(\.id)),
              Set(capture.windows.map(\.id)).count == capture.windows.count,
              let normalized = normalize(capture.desktopSnapshot, against: layout.effectiveDesktopSnapshot,
                                         topology: topology) else { return nil }

        var live = capture.windows
        for index in live.indices {
            if case let .desktop(id) = live[index].desktopAssignment {
                guard let stableID = normalized.ids[id] else { return nil }
                live[index].desktopAssignment = .desktop(stableID)
            }
        }
        let previous = layout.effectiveWindows
        let matches = WindowMatcher.match(saved: previous, live: live, references: references)
        // Do not convert a possibly renamed or ambiguously matched saved window into
        // a new entry while also retaining the original as a missing window.
        guard matches.ambiguous.isEmpty else { return nil }
        let matchedLiveIDs = Set(matches.matches.values.map(\.id))
        let unmatchedSaved = previous.filter { matches.matches[$0.id] == nil }

        func excluded(identity: WindowIdentity, assignment: DesktopAssignment?) -> Bool {
            if layout.excludedBundleIDs.contains(identity.bundleID) || exclusions.contains(where: { $0.excludes(identity) }) {
                return true
            }
            if case let .desktop(id) = assignment { return layout.options.excludedDesktopIDs.contains(id) }
            return false
        }

        var result: [SavedWindow] = []
        for saved in previous {
            guard !excluded(identity: saved.identity, assignment: saved.desktopAssignment),
                  let observed = matches.matches[saved.id],
                  !excluded(identity: observed.identity, assignment: observed.desktopAssignment) else {
                result.append(saved); continue
            }
            // Unknown native membership must not erase a known saved assignment.
            if saved.desktopAssignment != nil && observed.desktopAssignment == nil {
                result.append(saved); continue
            }
            guard var updated = CoordinateMapper.save(observed, in: topology, desktopSnapshot: normalized.snapshot) else { return nil }
            updated.id = saved.id
            updated.matchingRule = saved.matchingRule
            // A changing browser tab or document title does not change window identity
            // for this capture. Keep the user's saved matching evidence and preferences.
            updated.identity = saved.identity
            result.append(windowChanged(saved, updated) ? updated : saved)
        }
        // Existing order and IDs are retained. New entries use deterministic live order
        // so capture enumeration order cannot reorder the saved arrangement.
        var savedIDs = Set(result.map(\.id))
        for observed in live.sorted(by: { $0.id.uuidString < $1.id.uuidString }) where !matchedLiveIDs.contains(observed.id) {
            guard !excluded(identity: observed.identity, assignment: observed.desktopAssignment) else { continue }
            if observed.desktopAssignment == nil && !layout.options.excludedDesktopIDs.isEmpty { continue }
            // A missing match is not proof of a new window: titles can change. Keep
            // uncertain same-application candidates out until references or distinct
            // documents establish that they are additional windows.
            let couldBeRenamed = unmatchedSaved.contains { saved in
                saved.identity.bundleID == observed.identity.bundleID
                    && saved.identity.role == observed.identity.role && saved.identity.subrole == observed.identity.subrole
                    && !differentDocuments(saved.identity, observed.identity)
            }
            guard !couldBeRenamed, savedIDs.insert(observed.id).inserted else { continue }
            guard var saved = CoordinateMapper.save(observed, in: topology, desktopSnapshot: normalized.snapshot) else { return nil }
            // This is the AX worker's opaque UUID, not a CGWindowID. Retaining it for
            // a new saved entry lets the coordinator establish an exact live reference
            // even when several new windows share the same title and geometry.
            saved.id = observed.id
            result.append(saved)
        }

        let snapshot = retainingReferencedDesktops(in: normalized.snapshot, previous: layout.effectiveDesktopSnapshot,
                                                   windows: result, excludedIDs: layout.options.excludedDesktopIDs)
        let windowsChanged = result.count != previous.count || zip(previous, result).contains { windowChanged($0, $1) }
        guard windowsChanged || snapshotChanged(layout.effectiveDesktopSnapshot, snapshot) else { return nil }
        let revision = LayoutRevision(windows: result, desktopSnapshot: snapshot)
        // Validate the complete revision before returning it, including retained windows
        // from closed applications and their desktop references.
        var candidate = layout
        candidate.remembered = revision
        var library = Library()
        library.layouts = [candidate]
        do { try LayoutRepository.validate(library) } catch { return nil }
        return revision
    }

    private static func windowChanged(_ previous: SavedWindow, _ current: SavedWindow) -> Bool {
        previous.displayID != current.displayID || previous.desktopAssignment != current.desktopAssignment
            || !previous.frame.approximatelyEquals(current.frame)
            || !previous.sourceUsableFrame.approximatelyEquals(current.sourceUsableFrame)
    }

    private static func differentDocuments(_ previous: WindowIdentity, _ current: WindowIdentity) -> Bool {
        guard let first = previous.documentID?.trimmingCharacters(in: .whitespacesAndNewlines), !first.isEmpty,
              let second = current.documentID?.trimmingCharacters(in: .whitespacesAndNewlines), !second.isEmpty else { return false }
        return first != second
    }

    private struct NormalizedSnapshot {
        var snapshot: DesktopSnapshot?
        var ids: [String: String]
    }

    private static func normalize(_ incoming: DesktopSnapshot?, against previous: DesktopSnapshot?,
                                  topology: DisplayTopology) -> NormalizedSnapshot? {
        guard let incoming else { return previous == nil ? .init(snapshot: nil, ids: [:]) : nil }
        let incomingDesktops = incoming.displays.flatMap(\.desktops)
        guard !incoming.displays.isEmpty,
              Set(incoming.displays.map(\.displayID)).count == incoming.displays.count,
              Set(incomingDesktops.map(\.id)).count == incomingDesktops.count,
              Set(incoming.displays.map(\.displayID)).isSubset(of: Set(topology.surfaces.map(\.id))),
              previous == nil || previous?.separateDisplays == incoming.separateDisplays else { return nil }
        for display in incoming.displays {
            guard display.desktops.map(\.ordinal).sorted() == Array(0..<display.desktops.count),
                  display.desktops.contains(where: { $0.kind == .ordinary }),
                  display.desktops.filter(\.isActive).count <= 1 else { return nil }
        }
        var ids: [String: String] = [:]
        var consumed: Set<String> = []
        let priorIDs = previous?.desktopIDs ?? []
        for display in incoming.displays {
            let prior = (incoming.separateDisplays
                ? previous?.displays.first { $0.displayID == display.displayID }
                : previous?.displays.first)?.desktops ?? []
            let ordered = display.desktops.sorted { $0.ordinal < $1.ordinal }
            // Match UUID hints as a complete first pass so an ordinal fallback cannot
            // steal a desktop that merely moved earlier or later in Mission Control.
            for desktop in ordered {
                guard let hint = desktop.uuidHint?.lowercased(), !hint.isEmpty else { continue }
                let candidates = prior.filter { $0.kind == desktop.kind && $0.uuidHint?.lowercased() == hint }
                let peers = ordered.filter { $0.kind == desktop.kind && $0.uuidHint?.lowercased() == hint }
                if candidates.count == 1, peers.count == 1, let match = candidates.first,
                   consumed.insert(match.id).inserted { ids[desktop.id] = match.id }
            }
            for desktop in ordered where ids[desktop.id] == nil {
                if let match = prior.first(where: { $0.id == desktop.id && $0.kind == desktop.kind }),
                   consumed.insert(match.id).inserted { ids[desktop.id] = match.id }
            }
            for desktop in ordered where ids[desktop.id] == nil {
                if let match = prior.first(where: { $0.ordinal == desktop.ordinal && $0.kind == desktop.kind && !consumed.contains($0.id) }) {
                    consumed.insert(match.id); ids[desktop.id] = match.id
                }
            }
            for desktop in ordered where ids[desktop.id] == nil {
                var id = desktop.id
                var suffix = 0
                while consumed.contains(id) || priorIDs.contains(id) {
                    suffix += 1
                    id = "auto:\(display.displayID):\(desktop.kind.rawValue):\(desktop.ordinal):\(suffix)"
                }
                consumed.insert(id); ids[desktop.id] = id
            }
        }
        var snapshot = incoming
        for displayIndex in snapshot.displays.indices {
            for desktopIndex in snapshot.displays[displayIndex].desktops.indices {
                let id = snapshot.displays[displayIndex].desktops[desktopIndex].id
                snapshot.displays[displayIndex].desktops[desktopIndex].id = ids[id]!
            }
            snapshot.displays[displayIndex].desktops.sort { $0.ordinal < $1.ordinal }
        }
        let priorOrder = previous?.displays.map(\.displayID) ?? topology.displays.map(\.id)
        snapshot.displays.sort {
            let first = priorOrder.firstIndex(of: $0.displayID) ?? Int.max
            let second = priorOrder.firstIndex(of: $1.displayID) ?? Int.max
            return first == second ? $0.displayID < $1.displayID : first < second
        }
        return .init(snapshot: snapshot, ids: ids)
    }

    private static func retainingReferencedDesktops(in incoming: DesktopSnapshot?, previous: DesktopSnapshot?,
                                                    windows: [SavedWindow], excludedIDs: Set<String>) -> DesktopSnapshot? {
        guard var incoming, let previous else { return incoming }
        let references = Set(windows.compactMap { window -> String? in
            if case let .desktop(id) = window.desktopAssignment { return id }
            return nil
        }).union(excludedIDs)
        let capturedIDs = incoming.desktopIDs
        for oldDisplay in previous.displays {
            let missing = oldDisplay.desktops.filter { references.contains($0.id) && !capturedIDs.contains($0.id) }
                .sorted { $0.ordinal < $1.ordinal }
            guard !missing.isEmpty else { continue }
            let index: Int
            if let existing = incoming.displays.firstIndex(where: { $0.displayID == oldDisplay.displayID }) { index = existing }
            else {
                index = incoming.displays.count
                incoming.displays.append(.init(displayID: oldDisplay.displayID, desktops: []))
            }
            for var desktop in missing {
                if incoming.displays[index].desktops.contains(where: \.isActive) { desktop.isActive = false }
                incoming.displays[index].desktops.insert(desktop, at: min(desktop.ordinal, incoming.displays[index].desktops.count))
            }
            for ordinal in incoming.displays[index].desktops.indices {
                incoming.displays[index].desktops[ordinal].ordinal = ordinal
            }
        }
        return incoming
    }

    /// Enumeration order, local UUID hints, and switching the visible desktop alone
    /// do not change the saved arrangement.
    private static func snapshotChanged(_ previous: DesktopSnapshot?, _ current: DesktopSnapshot?) -> Bool {
        guard let previous, let current else { return (previous == nil) != (current == nil) }
        guard previous.separateDisplays == current.separateDisplays,
              Set(previous.displays.map(\.displayID)) == Set(current.displays.map(\.displayID)) else { return true }
        for display in previous.displays {
            guard let other = current.displays.first(where: { $0.displayID == display.displayID }) else { return true }
            let old = display.desktops.sorted { $0.ordinal < $1.ordinal }
            let new = other.desktops.sorted { $0.ordinal < $1.ordinal }
            if old.count != new.count || zip(old, new).contains(where: { $0.id != $1.id || $0.kind != $1.kind }) { return true }
        }
        return false
    }
}
