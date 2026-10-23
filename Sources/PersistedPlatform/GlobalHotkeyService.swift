import AppKit
import Carbon.HIToolbox
import PersistedCore

/// Registers only explicit shortcuts; it does not monitor keyboard input.
@MainActor
public final class GlobalHotkeyService {
    public private(set) var quickSwitcherError: String?
    /// Reports results when registrations are restored after shortcut recording.
    public var registrationDidChange: (@MainActor ([UUID: String], String?) -> Void)?
    public nonisolated static let recordingDidBegin = Notification.Name("Persisted.ShortcutRecordingDidBegin")
    public nonisolated static let recordingDidEnd = Notification.Name("Persisted.ShortcutRecordingDidEnd")

    private struct Combination: Hashable {
        let keyCode: UInt32
        let modifiers: UInt32
        init(_ shortcut: LayoutHotkey) {
            keyCode = shortcut.keyCode
            modifiers = shortcut.modifiers
        }
    }

    private let resources = HotkeyResources()
    private var generation: UUID?
    private var layoutIDs: [UInt32: UUID] = [:]
    private var onLayout: (@MainActor (UUID) -> Void)?
    private var onQuickSwitcher: (@MainActor () -> Void)?
    private var layouts: [Layout] = []
    private var isRecording = false
    private static let signature: OSType = 0x50525354 // PRST
    private static let quickSwitcherID: UInt32 = 1
    private static let quickSwitcher = LayoutHotkey(
        keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(cmdKey | shiftKey), key: "L"
    )

    public init() {
        resources.observers = [
            NotificationCenter.default.addObserver(forName: Self.recordingDidBegin, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setRecording(true) }
            },
            NotificationCenter.default.addObserver(forName: Self.recordingDidEnd, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setRecording(false) }
            }
        ]
    }

    /// Replaces registrations, reporting every invalid, duplicate, or unavailable shortcut.
    @discardableResult
    public func register(
        layouts: [Layout],
        onLayout: @escaping @MainActor (UUID) -> Void,
        onQuickSwitcher: @escaping @MainActor () -> Void
    ) -> [UUID: String] {
        stopRegistrations()
        self.layouts = layouts
        self.onLayout = onLayout
        self.onQuickSwitcher = onQuickSwitcher
        guard !isRecording else { return [:] }
        let generation = UUID()
        self.generation = generation
        let context = HotkeyContext(owner: self, generation: generation)
        resources.context = context
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)
        )
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(), { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var hotkey = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &hotkey
                )
                guard status == noErr, hotkey.signature == 0x50525354 else {
                    return OSStatus(eventNotHandledErr)
                }
                let context = Unmanaged<HotkeyContext>.fromOpaque(userData).takeUnretainedValue()
                let identifier = hotkey.id
                // Carbon callbacks must not directly enter actor-isolated app state.
                Task { @MainActor [context] in
                    context.owner?.handle(identifier, generation: context.generation)
                }
                return noErr
            },
            1, &eventType, Unmanaged.passUnretained(context).toOpaque(), &resources.handler
        )
        guard handlerStatus == noErr else {
            let message = "Keyboard shortcuts could not start (macOS error \(handlerStatus))."
            quickSwitcherError = message
            return Dictionary(layouts.compactMap { layout in
                layout.hotkey == nil ? nil : (layout.id, message)
            }, uniquingKeysWith: { first, _ in first })
        }

        let quickStatus = install(Self.quickSwitcher, identifier: Self.quickSwitcherID)
        if quickStatus != noErr { quickSwitcherError = Self.message(for: quickStatus) }

        let groups = Dictionary(grouping: layouts.filter { $0.hotkey != nil }) {
            Combination($0.hotkey!)
        }
        var errors: [UUID: String] = [:]
        var identifier: UInt32 = 2
        for layout in layouts {
            guard let shortcut = layout.hotkey else { continue }
            guard shortcut.isValid else {
                errors[layout.id] = "Use Command or Control with a key, or a function key (F1–F20)."
                continue
            }
            let combination = Combination(shortcut)
            guard combination != Combination(Self.quickSwitcher) else {
                errors[layout.id] = "⇧⌘L opens the quick switcher. Choose another shortcut."
                continue
            }
            guard groups[combination]?.count == 1 else {
                errors[layout.id] = "This shortcut is assigned to more than one layout. Choose a unique shortcut."
                continue
            }
            let status = install(shortcut, identifier: identifier)
            if status == noErr {
                layoutIDs[identifier] = layout.id
            } else {
                errors[layout.id] = Self.message(for: status)
            }
            identifier += 1
        }
        return errors
    }

    public func stop() {
        stopRegistrations()
        layouts = []
        onLayout = nil
        onQuickSwitcher = nil
        registrationDidChange = nil
        isRecording = false
    }

    private func stopRegistrations() {
        generation = nil
        resources.stop()
        layoutIDs.removeAll()
        quickSwitcherError = nil
    }

    private func setRecording(_ recording: Bool) {
        guard isRecording != recording else { return }
        isRecording = recording
        if recording {
            stopRegistrations()
        } else if let onLayout, let onQuickSwitcher {
            let errors = register(layouts: layouts, onLayout: onLayout, onQuickSwitcher: onQuickSwitcher)
            registrationDidChange?(errors, quickSwitcherError)
        }
    }

    private func install(_ shortcut: LayoutHotkey, identifier: UInt32) -> OSStatus {
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode, shortcut.modifiers,
            EventHotKeyID(signature: Self.signature, id: identifier), GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive), &reference
        )
        if status == noErr, let reference { resources.hotkeys.append(reference) }
        return status
    }

    fileprivate func handle(_ identifier: UInt32, generation: UUID) {
        // Discard an event queued before a registration change or shutdown.
        guard self.generation == generation else { return }
        if identifier == Self.quickSwitcherID {
            onQuickSwitcher?()
        } else if let layoutID = layoutIDs[identifier] {
            onLayout?(layoutID)
        }
    }

    private static func message(for status: OSStatus) -> String {
        if status == eventHotKeyExistsErr {
            return "This shortcut is already in use by macOS or another app. Choose another shortcut."
        }
        return "macOS could not register this shortcut (error \(status)). Choose another shortcut."
    }

    deinit {
        // Resources and refcon outlive the instance until main-thread cleanup finishes.
        let resources = resources
        Task { @MainActor in resources.dispose() }
    }
}

@MainActor
private final class HotkeyContext {
    weak var owner: GlobalHotkeyService?
    let generation: UUID
    init(owner: GlobalHotkeyService, generation: UUID) {
        self.owner = owner
        self.generation = generation
    }
}

@MainActor
private final class HotkeyResources {
    var handler: EventHandlerRef?
    var hotkeys: [EventHotKeyRef] = []
    var context: HotkeyContext?
    var observers: [NSObjectProtocol] = []

    func stop() {
        for hotkey in hotkeys { UnregisterEventHotKey(hotkey) }
        hotkeys.removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
        context = nil
    }

    func dispose() {
        stop()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }
}
