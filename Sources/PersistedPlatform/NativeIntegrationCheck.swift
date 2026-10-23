import AppKit
import Foundation
import PersistedCore
import OSLog

/// Explicitly opt-in native verification. The bundle allowlist is checked before
/// every placement, including cleanup; no user-application window is ever targeted.
@MainActor
public enum NativeIntegrationCheck {
    private struct Report: Codable, Sendable {
        var completed = false
        var succeeded = false
        var permissionGranted = false
        var elapsedSeconds: Double = 0
        var capturedWindowCount = 0
        var captureIssueCount = 0
        var restoredOriginalWindowCount = 0
        var checks: [String: Bool] = [:]
        var outcomes: [String: Int] = [:]
        var errors: [String] = []
    }
    private struct CleanupResult: Sendable {
        var restored = 0
        var outcomes: [String: Int] = [:]
        var errors: [String] = []
    }

    public static func run(accessibility: AccessibilityService, topologyService: DisplayTopologyService, output: URL) async {
        let started = ContinuousClock.now
        var report = Report()
        guard let bundle = Bundle.main.bundleIdentifier else {
            report.errors.append("The check must run from the packaged Persisted application.")
            finish(&report, started: started, output: output)
            return
        }
        let harnessBundleID = bundle + ".Harness"
        report.permissionGranted = PermissionService().isTrusted
        guard report.permissionGranted else {
            report.errors.append("Accessibility permission is unavailable; no permission prompt or placement was attempted.")
            finish(&report, started: started, output: output)
            return
        }
        let launchIssues = await ApplicationLauncher().launch(bundleIDs: [harnessBundleID])
        if !launchIssues.isEmpty {
            report.errors.append("The integration fixture could not be launched within its time budget.")
        }
        let waitDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        var capture = WindowCapture()
        repeat {
            capture = await harnessCapture(accessibility, bundleID: harnessBundleID)
            report.captureIssueCount += capture.issues.count
            report.permissionGranted = capture.permissionGranted
            if !capture.permissionGranted || capture.windows.count >= 4 || Task.isCancelled { break }
            do { try await Task.sleep(for: .milliseconds(350)) } catch { break }
        } while ContinuousClock.now < waitDeadline
        let originals = capture.windows.filter { $0.identity.bundleID == harnessBundleID }
        report.capturedWindowCount = originals.count
        guard capture.permissionGranted, capture.isComplete, originals.count >= 4, !Task.isCancelled else {
            report.errors.append("Four inspectable fixture windows were not available before the wait ended.")
            finish(&report, started: started, output: output)
            return
        }
        let topology = topologyService.snapshot()
        guard !topology.surfaces.isEmpty,
              originals.allSatisfy({ !$0.hidden && !$0.minimized && !$0.fullscreen && $0.frame.isValid }) else {
            report.errors.append("The fixture must have ordinary visible windows on a usable display.")
            finish(&report, started: started, output: output)
            return
        }
        let gate = MutationGate()
        await exercise(originals, topology: topology, harnessBundleID: harnessBundleID,
                       accessibility: accessibility, topologyService: topologyService, gate: gate, report: &report)
        gate.invalidate()
        // Unstructured cleanup deliberately has its own cancellation state and gate.
        // Even if the checking task was cancelled, all surviving original fixture
        // windows are offered their original frames before the report is committed.
        let cleanup = await Task { @MainActor in
            await restoreOriginals(originals, topology: topology, harnessBundleID: harnessBundleID,
                                   accessibility: accessibility, topologyService: topologyService)
        }.value
        report.restoredOriginalWindowCount = cleanup.restored
        for (kind, count) in cleanup.outcomes { report.outcomes["cleanup." + kind, default: 0] += count }
        report.errors.append(contentsOf: cleanup.errors)
        report.checks["originalFramesRestored"] = cleanup.restored == originals.count
        report.succeeded = report.errors.isEmpty && !report.checks.isEmpty && report.checks.values.allSatisfy { $0 }
        finish(&report, started: started, output: output)
    }

    private static func harnessCapture(_ accessibility: AccessibilityService, bundleID: String) async -> WindowCapture {
        // Exclude other applications at enumeration, then filter again defensively.
        let others = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)).subtracting([bundleID])
        var result = await accessibility.capture(exclusions: others.map { WindowExclusion(bundleID: $0) })
        result.windows = result.windows.filter { $0.identity.bundleID == bundleID }
        return result
    }

    private static func exercise(_ originals: [LiveWindow], topology: DisplayTopology, harnessBundleID: String,
                                 accessibility: AccessibilityService, topologyService: DisplayTopologyService,
                                 gate: MutationGate, report: inout Report) async {
        let generation = gate.current
        let repeated = await harnessCapture(accessibility, bundleID: harnessBundleID)
        report.captureIssueCount += repeated.issues.count
        let repeatedIDs = Set(repeated.windows.map(\.id))
        let duplicateGroups = Dictionary(grouping: originals, by: { $0.identity.normalizedTitle }).values.filter { $0.count > 1 }
        report.checks["duplicateTitlesHaveDistinctLiveTokens"] = !duplicateGroups.isEmpty && duplicateGroups.allSatisfy { group in Set(group.map(\.id)).count == group.count }
        report.checks["liveTokensSurviveRecapture"] = repeated.isComplete && originals.allSatisfy { repeatedIDs.contains($0.id) }
        guard repeated.isComplete, !Task.isCancelled else {
            report.errors.append("Fixture recapture was incomplete or the check was cancelled.")
            return
        }
        var alreadyPositioned = 0
        var verifiedMoves = 0
        for original in originals {
            guard original.identity.bundleID == harnessBundleID else { continue }
            guard topologyService.snapshot().isEquivalent(to: topology), !Task.isCancelled else {
                report.errors.append("The display setup changed or the check was cancelled.")
                return
            }
            guard let live = repeated.windows.first(where: { $0.id == original.id && $0.instance == original.instance }),
                  let saved = CoordinateMapper.save(original, in: topology),
                  let display = CoordinateMapper.sourceDisplay(for: original.frame, in: topology) else {
                report.errors.append("An original fixture reference could not be revalidated.")
                continue
            }
            let usable = CoordinateMapper.usableAX(display, in: topology)
            let noChange = PlannedPlacement(savedWindow: saved, liveWindow: live, targetFrame: original.frame, targetUsableFrame: usable)
            let already = await accessibility.place(noChange, generation: generation, gate: gate, automatic: false)
            record(already, in: &report)
            if already.kind == .alreadyPositioned { alreadyPositioned += 1 }
            let offset = CoordinateMapper.clamp(Rect(x: original.frame.x + 24, y: original.frame.y + 18,
                width: original.frame.width + 38, height: original.frame.height + 26), to: usable)
            let changed = PlannedPlacement(savedWindow: saved, liveWindow: live, targetFrame: offset, targetUsableFrame: usable)
            let moved = await accessibility.place(changed, generation: generation, gate: gate, automatic: false)
            record(moved, in: &report)
            if moved.kind.succeeded, let actual = moved.actualFrame, actual.approximatelyEquals(offset) { verifiedMoves += 1 }
        }
        report.checks["alreadyPositionedSkippedWrites"] = alreadyPositioned == originals.count
        report.checks["offsetAndResizeVerified"] = verifiedMoves == originals.count
        guard topologyService.snapshot().isEquivalent(to: topology), !Task.isCancelled else {
            report.errors.append("The display setup changed or the check was cancelled before the constraint check.")
            return
        }
        let current = await harnessCapture(accessibility, bundleID: harnessBundleID)
        report.captureIssueCount += current.issues.count
        guard let minimum = current.windows.first(where: { $0.identity.accessibilityID == "minimum-size" && $0.identity.bundleID == harnessBundleID }),
              let original = originals.first(where: { $0.id == minimum.id && $0.instance == minimum.instance }),
              let saved = CoordinateMapper.save(original, in: topology),
              let display = CoordinateMapper.sourceDisplay(for: original.frame, in: topology) else {
            report.errors.append("The fixture minimum-size window was unavailable.")
            return
        }
        let usable = CoordinateMapper.usableAX(display, in: topology)
        let deliberatelySmall = Rect(x: usable.maxX - 120, y: usable.maxY - 100, width: 120, height: 100)
        let constrained = await accessibility.place(.init(savedWindow: saved, liveWindow: minimum,
            targetFrame: deliberatelySmall, targetUsableFrame: usable), generation: generation, gate: gate, automatic: false)
        record(constrained, in: &report)
        if let actual = constrained.actualFrame {
            let reachable = CoordinateMapper.clamp(actual, to: usable)
            report.checks["applicationMinimumSizeRespected"] = constrained.kind == .adjustedToConstraints && actual.width >= 479 && actual.height >= 299
            report.checks["constrainedWindowRemainsReachable"] = abs(actual.x - reachable.x) <= 2 && abs(actual.y - reachable.y) <= 2
        } else {
            report.checks["applicationMinimumSizeRespected"] = false
            report.checks["constrainedWindowRemainsReachable"] = false
        }
    }

    private static func restoreOriginals(_ originals: [LiveWindow], topology: DisplayTopology, harnessBundleID: String,
                                         accessibility: AccessibilityService, topologyService: DisplayTopologyService) async -> CleanupResult {
        var result = CleanupResult()
        let gate = MutationGate()
        let latest = await harnessCapture(accessibility, bundleID: harnessBundleID)
        let currentTopology = topologyService.snapshot()
        for original in originals {
            guard original.identity.bundleID == harnessBundleID,
                  let live = latest.windows.first(where: { $0.id == original.id && $0.instance == original.instance && $0.identity.bundleID == harnessBundleID }),
                  let saved = CoordinateMapper.save(original, in: topology) else {
                result.errors.append("A fixture window disappeared before cleanup.")
                continue
            }
            guard let destination = currentTopology.surfaces.first(where: { $0.id == saved.displayID }) else {
                result.errors.append("An original fixture display disappeared before cleanup.")
                continue
            }
            let restored = await accessibility.place(.init(savedWindow: saved, liveWindow: live, targetFrame: original.frame,
                targetUsableFrame: CoordinateMapper.usableAX(destination, in: currentTopology)), generation: gate.current, gate: gate, automatic: false)
            result.outcomes[restored.kind.rawValue, default: 0] += 1
            if restored.kind.succeeded, restored.actualFrame?.approximatelyEquals(original.frame) == true { result.restored += 1 }
            else { result.errors.append("A fixture window could not be returned to its original frame.") }
        }
        return result
    }

    private static func record(_ outcome: WindowOutcome, in report: inout Report) {
        report.outcomes[outcome.kind.rawValue, default: 0] += 1
    }
    private static func finish(_ report: inout Report, started: ContinuousClock.Instant, output: URL) {
        let elapsed = started.duration(to: .now).components
        report.elapsedSeconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        report.completed = true
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: output, options: .atomic)
        } catch {
            Logger(subsystem: "app.persisted", category: "Integration").error("Native integration report could not be written.")
        }
    }
}
