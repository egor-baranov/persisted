import Foundation

extension DisplayRecord {
    /// A runtime CG display number must never be supplied as `id` by an adapter.
    var durableIdentity: String {
        if let uuid, !uuid.isEmpty { return "uuid:" + uuid.lowercased() }
        if serial != 0 { return "hardware:\(vendor):\(model):\(serial)" }
        return "hint:" + id
    }
}

extension DisplayTopology {
    public var setupKey: String { identityKey(includeLid: true) }

    public var geometryKey: String {
        let records = displays.map { display in
            [display.durableIdentity, display.id, String(display.isPrimary), String(display.isActive),
             rectKey(display.frame), rectKey(display.usableFrame), String(display.scale), String(display.rotation)]
        }.sorted { $0.lexicographicallyPrecedes($1) }
        return canonical([setupKey, canonical(records)])
    }

    public func isEquivalent(to other: DisplayTopology) -> Bool {
        setupKey == other.setupKey && geometryKey == other.geometryKey
    }

    fileprivate func identityKey(includeLid: Bool) -> String {
        // Group membership is stable if macOS chooses another output as the mirror source.
        let records = displays.map { display -> [String] in
            let members = mirrorGroup(containing: display).map(\.durableIdentity).sorted()
            return [display.durableIdentity, String(display.isBuiltIn),
                    display.isBuiltIn ? String(display.isActive) : "output",
                    canonical(members)]
        }.sorted { $0.lexicographicallyPrecedes($1) }
        return canonical([includeLid ? lid.rawValue : "any-lid", canonical(records)])
    }

    fileprivate func mirrorGroup(containing display: DisplayRecord) -> [DisplayRecord] {
        var ids: Set<String> = [display.id]
        var changed = true
        while changed {
            changed = false
            for candidate in displays {
                guard let source = candidate.mirrorSourceID else { continue }
                if ids.contains(source) || ids.contains(candidate.id) {
                    if ids.insert(source).inserted { changed = true }
                    if ids.insert(candidate.id).inserted { changed = true }
                }
            }
        }
        return displays.filter { ids.contains($0.id) }
    }
}

private func canonical<T: Encodable>(_ value: T) -> String {
    // JSON provides unambiguous delimiters even when an identity contains punctuation.
    String(data: (try? JSONEncoder().encode(value)) ?? Data(), encoding: .utf8) ?? ""
}

private func rectKey(_ rect: Rect) -> String {
    canonical([rect.x, rect.y, rect.width, rect.height])
}

public enum SetupMatcher {
    public static func compatible(_ layout: Layout, with topology: DisplayTopology) -> Bool {
        guard !layout.importedNeedsMapping, !topology.surfaces.isEmpty,
              !layout.topology.hasAmbiguousIdentity, !topology.hasAmbiguousIdentity,
              uniqueIdentities(layout.topology), uniqueIdentities(topology) else { return false }
        return sameSetup(layout, topology)
    }

    public static func mapping(for layout: Layout, to topology: DisplayTopology,
                               approved: DisplayMapping? = nil) -> [String: String]? {
        let sourceIDs = Set(layout.topology.surfaces.map(\.id))
        let targetIDs = Set(topology.surfaces.map(\.id))
        guard !targetIDs.isEmpty else { return nil }
        if let approved, approved.layoutID == layout.id, approved.targetSetupKey == topology.setupKey {
            guard Set(approved.assignments.keys).isSubset(of: sourceIDs),
                  Set(approved.assignments.values).isSubset(of: targetIDs),
                  approved.skipped.isSubset(of: sourceIDs),
                  Set(approved.assignments.keys).isDisjoint(with: approved.skipped),
                  Set(approved.assignments.keys).union(approved.skipped) == sourceIDs else { return nil }
            return approved.assignments
        }
        guard compatible(layout, with: topology) else { return nil }
        var result: [String: String] = [:]
        var consumed: Set<String> = []
        for source in layout.topology.surfaces.sorted(by: { $0.id < $1.id }) {
            let sourceMembers = layout.topology.mirrorGroup(containing: source).map(\.durableIdentity).sorted()
            let candidates = topology.surfaces.filter {
                topology.mirrorGroup(containing: $0).map(\.durableIdentity).sorted() == sourceMembers
            }
            guard candidates.count == 1, let target = candidates.first, consumed.insert(target.id).inserted else { return nil }
            result[source.id] = target.id
        }
        return result
    }

    /// Best-effort choices for an explicit restore or its mapping sheet. Extra displays
    /// do not invalidate a known match. This deliberately does not change which setups
    /// qualify for automatic docking restores.
    public static func suggestedMapping(for layout: Layout, to topology: DisplayTopology) -> [String: String] {
        let sources = layout.topology.surfaces
        let targets = topology.surfaces.filter { $0.usableFrame.isValid }
        guard !sources.isEmpty, !targets.isEmpty,
              Set(sources.map(\.id)).count == sources.count,
              Set(targets.map(\.id)).count == targets.count else { return [:] }

        // With just one destination there is no display choice to make. Explicit
        // restores may consolidate several saved surfaces onto this one display.
        if let target = targets.first, targets.count == 1 {
            return Dictionary(uniqueKeysWithValues: sources.map { ($0.id, target.id) })
        }

        let sourceGroups = Dictionary(uniqueKeysWithValues: sources.map {
            ($0.id, layout.topology.mirrorGroup(containing: $0))
        })
        let targetGroups = Dictionary(uniqueKeysWithValues: targets.map {
            ($0.id, topology.mirrorGroup(containing: $0))
        })
        var result: [String: String] = [:]
        var consumed: Set<String> = []

        // Evaluate a whole tier before accepting any matches. A weaker match cannot
        // steal the destination of a stronger match because of enumeration order.
        func assignUnique(_ matches: ([DisplayRecord], [DisplayRecord]) -> Bool) {
            let remainingSources = sources.filter { result[$0.id] == nil }
            let remainingTargets = targets.filter { !consumed.contains($0.id) }
            let candidates = Dictionary(uniqueKeysWithValues: remainingSources.map { source in
                (source.id, remainingTargets.filter {
                    matches(sourceGroups[source.id]!, targetGroups[$0.id]!)
                }.map(\.id))
            })
            var accepted: [(String, String)] = []
            for source in remainingSources {
                guard let choices = candidates[source.id], choices.count == 1,
                      let target = choices.first,
                      candidates.values.filter({ $0.contains(target) }).count == 1 else { continue }
                accepted.append((source.id, target))
            }
            for (source, target) in accepted {
                result[source] = target
                consumed.insert(target)
            }
        }

        // Match physical members, not just mirror roots: macOS may select a different
        // source for the same mirror group. Ambiguous adapter identities are not proof.
        assignUnique { source, target in
            source.contains { saved in
                !saved.identityIsAmbiguous && target.contains {
                    !$0.identityIsAmbiguous && saved.durableIdentity == $0.durableIdentity
                        && saved.isBuiltIn == $0.isBuiltIn
                }
            }
        }
        assignUnique { source, target in
            source.contains(where: \.isBuiltIn) && target.contains(where: \.isBuiltIn)
        }
        assignUnique { source, target in
            source.contains { saved in
                saved.serial != 0 && !saved.identityIsAmbiguous && target.contains {
                    !$0.identityIsAmbiguous && saved.vendor == $0.vendor
                        && saved.model == $0.model && saved.serial == $0.serial
                        && saved.isBuiltIn == $0.isBuiltIn
                }
            }
        }
        assignUnique { source, target in
            source.contains { saved in
                saved.vendor != 0 && saved.model != 0 && target.contains {
                    saved.vendor == $0.vendor && saved.model == $0.model
                        && saved.isBuiltIn == $0.isBuiltIn
                }
            }
        }
        assignUnique { source, target in
            source.contains { saved in
                let name = normalizedDisplayName(saved.name)
                return !name.isEmpty && name != "display" && target.contains {
                    name == normalizedDisplayName($0.name) && saved.isBuiltIn == $0.isBuiltIn
                }
            }
        }
        // A single remaining external monitor is an obvious replacement even when
        // its model differs. Multiple indistinguishable monitors remain unresolved.
        assignUnique { source, target in
            !source.contains(where: \.isBuiltIn) && !target.contains(where: \.isBuiltIn)
        }
        return result
    }

    /// Complete automatic choice for a user-initiated restore. Imported layouts still
    /// require review, although their mapping sheet can use the same suggestions.
    public static func manualMapping(for layout: Layout, to topology: DisplayTopology) -> [String: String]? {
        guard !layout.importedNeedsMapping, !layout.topology.surfaces.isEmpty else { return nil }
        let result = suggestedMapping(for: layout, to: topology)
        guard result.count == layout.topology.surfaces.count else { return nil }
        return result
    }

    private static func normalizedDisplayName(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func sameSetup(_ layout: Layout, _ topology: DisplayTopology) -> Bool {
        let includeLid = layout.options.lidPolicy == .exact
        return layout.topology.identityKey(includeLid: includeLid) == topology.identityKey(includeLid: includeLid)
    }

    private static func uniqueIdentities(_ topology: DisplayTopology) -> Bool {
        Set(topology.displays.map(\.durableIdentity)).count == topology.displays.count
    }
}
