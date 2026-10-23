import Foundation

public struct MatchResult: Sendable {
    public var matches: [UUID: LiveWindow]
    public var ambiguous: Set<UUID>
    public init(matches: [UUID: LiveWindow] = [:], ambiguous: Set<UUID> = []) {
        self.matches = matches; self.ambiguous = ambiguous
    }
}

public enum WindowMatcher {
    /// References are ephemeral tokens issued by the AX worker. The worker must issue new
    /// tokens when the process launch date changes, including PID reuse after a restart.
    public static func match(saved: [SavedWindow], live: [LiveWindow],
                             references: [UUID: UUID] = [:]) -> MatchResult {
        var result = MatchResult()
        var used = Set<UUID>()
        let ordered = saved.sorted { $0.id.uuidString < $1.id.uuidString }
        let duplicateLiveIDs = Set(Dictionary(grouping: live, by: \.id).filter { $0.value.count > 1 }.keys)
        let candidates = live.filter { !duplicateLiveIDs.contains($0.id) }
        let savedIDs = Set(ordered.map(\.id))
        let relevantReferences = references.filter { savedIDs.contains($0.key) }
        let referenceCounts = Dictionary(grouping: relevantReferences.values, by: { $0 }).mapValues(\.count)

        for entry in ordered {
            guard let token = references[entry.id], let window = candidates.first(where: { $0.id == token }),
                  sameWindowKind(entry.identity, window.identity) else { continue }
            guard referenceCounts[token] == 1 else { result.ambiguous.insert(entry.id); continue }
            result.matches[entry.id] = window
            used.insert(window.id)
        }

        // Only accept mutually unique strongest evidence. Removing a strong document match
        // may then disambiguate another window, without any arbitrary array-order tie break.
        var changed = true
        while changed {
            changed = false
            let remaining = ordered.filter { result.matches[$0.id] == nil && !result.ambiguous.contains($0.id) }
            var edges: [UUID: [(window: LiveWindow, score: Int)]] = [:]
            for entry in remaining {
                edges[entry.id] = candidates.filter { !used.contains($0.id) }.compactMap { window in
                    guard let score = evidence(saved: entry, live: window) else { return nil }
                    return (window, score)
                }
            }
            var accepted: [(SavedWindow, LiveWindow)] = []
            for entry in remaining {
                guard let options = edges[entry.id], let top = options.map(\.score).max() else { continue }
                let best = options.filter { $0.score == top }
                guard best.count == 1, let candidate = best.first else { continue }
                let contenders = remaining.compactMap { other -> (UUID, Int)? in
                    guard let edge = edges[other.id]?.first(where: { $0.window.id == candidate.window.id }) else { return nil }
                    return (other.id, edge.score)
                }
                guard let highest = contenders.map({ $0.1 }).max(), top == highest,
                      contenders.filter({ $0.1 == highest }).count == 1 else { continue }
                accepted.append((entry, candidate.window))
            }
            for (entry, window) in accepted where !used.contains(window.id) {
                result.matches[entry.id] = window
                used.insert(window.id)
                changed = true
            }
        }

        for entry in ordered where result.matches[entry.id] == nil {
            if candidates.contains(where: { evidence(saved: entry, live: $0) != nil }) {
                result.ambiguous.insert(entry.id)
            }
        }
        return result
    }

    private static func evidence(saved: SavedWindow, live: LiveWindow) -> Int? {
        let expected = saved.identity, observed = live.identity
        guard sameWindowKind(expected, observed), live.frame.isValid else { return nil }
        switch saved.matchingRule {
        case .exactTitle(let title):
            return observed.title == title ? 85 : nil
        case .titleContains(let text):
            guard !text.isEmpty else { return nil }
            return observed.title.localizedCaseInsensitiveContains(text) ? 80 : nil
        case .automatic:
            // Dia identifies its browser container with a UUID. Its title and document
            // describe the selected tab, so either can change without replacing the window.
            // Keep this exception narrow: ordinary AX identifiers may be reused by apps.
            if let identifier = diaBrowserWindowID(expected), identifier == diaBrowserWindowID(observed) {
                return 130
            }
            let expectedDocument = nonempty(expected.documentID), actualDocument = nonempty(observed.documentID)
            if let expectedDocument, let actualDocument {
                // A known different document outweighs a coincidentally identical title.
                guard expectedDocument == actualDocument else { return nil }
                return 120
            }
            let titleMatches = !expected.normalizedTitle.isEmpty && expected.normalizedTitle == observed.normalizedTitle
            // Other AX identifiers are not guaranteed durable across an application restart.
            // Until stability is established by a live reference they need corroboration.
            if let identifier = nonempty(expected.accessibilityID), identifier == nonempty(observed.accessibilityID), titleMatches {
                return 100
            }
            guard titleMatches else { return nil }
            // Geometry supports an identity match but never breaks duplicate-title ties.
            // Window positions often collapse on unplug and are unsafe identity evidence.
            return 60
        }
    }

    private static func sameWindowKind(_ first: WindowIdentity, _ second: WindowIdentity) -> Bool {
        first.bundleID == second.bundleID && first.role == second.role && first.subrole == second.subrole
    }

    private static func diaBrowserWindowID(_ identity: WindowIdentity) -> UUID? {
        let prefix = "bigBrowserWindow_"
        guard identity.bundleID == "company.thebrowser.dia",
              identity.role == "AXWindow", identity.subrole == "AXStandardWindow",
              let identifier = identity.accessibilityID, identifier.hasPrefix(prefix) else { return nil }
        let suffix = String(identifier.dropFirst(prefix.count))
        guard suffix.count == 36 else { return nil }
        return UUID(uuidString: suffix)
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
