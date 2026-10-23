import AppKit
import ApplicationServices
import ServiceManagement
import PersistedCore

public enum SystemEvent: Sendable {
    case displayChanged, lidChanged, sleep, wake, screenSleep, screenWake
    case sessionInactive, sessionActive, applicationsChanged, windowsChanged, permissionChanged
}

@MainActor
public final class PermissionService: PermissionChecking {
    public init() {}
    public var isTrusted: Bool { AXIsProcessTrusted() }
    public func request() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
    public func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

@MainActor
public final class LoginItemService {
    public init() {}
    public var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    public var requiresApproval: Bool { SMAppService.mainApp.status == .requiresApproval }
    public var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled: "Enabled"
        case .requiresApproval: "Approval required in System Settings"
        case .notFound: "Install Persisted in Applications to enable launch at login"
        case .notRegistered: "Off"
        @unknown default: "Status unavailable"
        }
    }
    public func setEnabled(_ enabled: Bool) async throws {
        if enabled { try SMAppService.mainApp.register() }
        else { try await SMAppService.mainApp.unregister() }
    }
    public func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}

@MainActor
public final class ApplicationLauncher: ApplicationLaunching {
    private enum LaunchResult: Sendable { case opened, failed, timedOut, cancelled }
    private struct PendingLaunch {
        let continuation: CheckedContinuation<LaunchResult, Never>
        var timeout: Task<Void, Never>?
    }
    private var pending: [UUID: PendingLaunch] = [:]
    public init() {}
    public func launch(bundleIDs: Set<String>) async -> [CaptureIssue] {
        var issues: [CaptureIssue] = []
        for identifier in bundleIDs.sorted() {
            guard !Task.isCancelled else { break }
            guard NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty else { continue }
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else {
                issues.append(.init(bundleID: identifier, message: "Application is not installed.")); continue
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.createsNewApplicationInstance = false
            switch await open(url, configuration: configuration) {
            case .opened: break
            case .failed: issues.append(.init(bundleID: identifier, message: "Application could not be opened."))
            case .timedOut: issues.append(.init(bundleID: identifier, message: "Application startup exceeded its time budget. Retry when its windows are available."))
            case .cancelled: return issues
            }
        }
        return issues
    }

    private func open(_ url: URL, configuration: NSWorkspace.OpenConfiguration) async -> LaunchResult {
        let request = UUID()
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return .cancelled }
            return await withCheckedContinuation { continuation in
                pending[request] = PendingLaunch(continuation: continuation)
                pending[request]?.timeout = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    self?.finish(request, result: .timedOut)
                }
                NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] _, error in
                    let succeeded = error == nil
                    Task { @MainActor [weak self] in self?.finish(request, result: succeeded ? .opened : .failed) }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(request, result: .cancelled) }
        }
    }

    private func finish(_ request: UUID, result: LaunchResult) {
        guard let request = pending.removeValue(forKey: request) else { return }
        request.timeout?.cancel()
        request.continuation.resume(returning: result)
    }
}
