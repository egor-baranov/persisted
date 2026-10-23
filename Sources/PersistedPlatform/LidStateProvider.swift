import Foundation
import IOKit
import IOKit.pwr_mgt
import PersistedCore

/// All resources and callback contexts belong to the main thread. This is a best-effort
/// hardware observation; display inactivity is deliberately not used as a lid signal.
@MainActor
public final class LidStateProvider {
    // IOPM.h's function-like macro is not imported by Swift. Expand its public
    // definition: iokit_family_msg(sub_iokit_powermanagement, 0x100), with
    // sys_iokit = 0x38 << 26 and sub_iokit_powermanagement = 13 << 14.
    private nonisolated static let clamshellStateChangeMessage: UInt32 = (0x38 << 26) | (13 << 14) | 0x100
    private var port: IONotificationPortRef?
    private var notification: io_object_t = 0
    private var callback: (@MainActor @Sendable () -> Void)?
    public init() {}

    public func state() -> LidState {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return .unknown }
        defer { IOObjectRelease(service) }
        if let value = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
           CFGetTypeID(value) == CFBooleanGetTypeID(), let closed = value as? Bool {
            return closed ? .closed : .open
        }
        // A missing property alone does not establish desktop hardware. Use the actual
        // hardware model, and leave unfamiliar future machines honestly unknown.
        var count = 0
        guard sysctlbyname("hw.model", nil, &count, nil, 0) == 0, count > 1 else { return .unknown }
        var bytes = [CChar](repeating: 0, count: count)
        guard sysctlbyname("hw.model", &bytes, &count, nil, 0) == 0 else { return .unknown }
        let model = String(decoding: bytes.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        if ["iMac", "Macmini", "MacPro", "MacStudio"].contains(where: model.hasPrefix) { return .notApplicable }
        // Apple-silicon model identifiers may be generic MacN,N. The chassis-type
        // property, if exposed, explicitly distinguishes laptop (9/10/14) from desktop.
        let platform = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        if platform != 0 {
            defer { IOObjectRelease(platform) }
            if let value = IORegistryEntryCreateCFProperty(platform, "chassis-type" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data,
               let chassis = value.first, [3, 4, 5, 6, 7, 13, 15, 16].contains(chassis) { return .notApplicable }
        }
        return .unknown
    }

    public func start(onChange: @escaping @MainActor @Sendable () -> Void) {
        stop()
        callback = onChange
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.port = port
        IONotificationPortSetDispatchQueue(port, .main)
        let status = IOServiceAddInterestNotification(port, service, kIOGeneralInterest, { context, _, message, _ in
            guard message == LidStateProvider.clamshellStateChangeMessage, let context else { return }
            let owner = Unmanaged<LidStateProvider>.fromOpaque(context).takeUnretainedValue()
            // The port dispatch queue is explicitly the main queue.
            MainActor.assumeIsolated { owner.callback?() }
        }, Unmanaged.passUnretained(self).toOpaque(), &notification)
        if status != KERN_SUCCESS { stop() }
    }

    public func stop() {
        if notification != 0 { IOObjectRelease(notification); notification = 0 }
        if let port { IONotificationPortSetDispatchQueue(port, nil); IONotificationPortDestroy(port) }
        port = nil
        callback = nil
    }
}
