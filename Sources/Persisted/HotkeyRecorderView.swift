import SwiftUI
import AppKit
import Carbon
import PersistedCore
import PersistedPlatform

/// A focused native control records a single key press, without an event tap or keyboard monitor.
struct HotkeyRecorderView: View {
    let hotkey: LayoutHotkey?
    let onChange: (LayoutHotkey?) -> Void
    @State private var isRecording = false
    @State private var validationMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ShortcutRecorderControl(
                hotkey: hotkey,
                onChange: onChange,
                onRecordingChange: { isRecording = $0 },
                onValidation: { validationMessage = $0 }
            )
            .frame(width: 190, height: 28)
            if let validationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Shortcut not accepted. \(validationMessage)")
            } else {
                Text(isRecording
                     ? "Press a shortcut. Esc cancels; Delete clears."
                     : "Use ⌘ or ⌃ with a key, or F1–F20.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct ShortcutRecorderControl: NSViewRepresentable {
    let hotkey: LayoutHotkey?
    let onChange: (LayoutHotkey?) -> Void
    let onRecordingChange: (Bool) -> Void
    let onValidation: (String?) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let button = ShortcutRecorderButton(frame: .zero)
        configure(button)
        return button
    }

    func updateNSView(_ button: ShortcutRecorderButton, context: Context) { configure(button) }

    static func dismantleNSView(_ button: ShortcutRecorderButton, coordinator: ()) {
        button.finishRecording()
    }

    private func configure(_ button: ShortcutRecorderButton) {
        button.hotkey = hotkey
        button.onChange = onChange
        button.onRecordingChange = onRecordingChange
        button.onValidation = onValidation
        button.refreshTitle()
    }
}

@MainActor
private final class ShortcutRecorderButton: NSButton {
    var hotkey: LayoutHotkey?
    var onChange: ((LayoutHotkey?) -> Void)?
    var onRecordingChange: ((Bool) -> Void)?
    var onValidation: ((String?) -> Void)?
    private var recording = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        focusRingType = .exterior
        target = self
        action = #selector(beginRecording)
        setAccessibilityLabel("Layout keyboard shortcut")
        setAccessibilityHelp("Activate to record a global shortcut. Press Escape to cancel, Delete to clear, or Tab to move on.")
        refreshTitle()
    }

    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }

    @objc private func beginRecording() {
        guard !recording, window?.makeFirstResponder(self) == true else { return }
        recording = true
        onValidation?(nil)
        NotificationCenter.default.post(name: GlobalHotkeyService.recordingDidBegin, object: self)
        onRecordingChange?(true)
        refreshTitle()
    }

    func finishRecording() {
        guard recording else { return }
        recording = false
        NotificationCenter.default.post(name: GlobalHotkeyService.recordingDidEnd, object: self)
        onRecordingChange?(false)
        refreshTitle()
    }

    func refreshTitle() {
        title = recording ? "Type shortcut…" : (hotkey?.displayString ?? "Record Shortcut…")
        setAccessibilityValue(recording ? "Recording" : (hotkey?.displayString ?? "No shortcut"))
    }

    override func resignFirstResponder() -> Bool {
        finishRecording()
        return super.resignFirstResponder()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window)
        if newWindow !== window { finishRecording() }
        if let newWindow {
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowDidResignKey),
                name: NSWindow.didResignKeyNotification, object: newWindow
            )
        }
        super.viewWillMove(toWindow: newWindow)
    }

    @objc private func windowDidResignKey(_ notification: Notification) { finishRecording() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording, window?.firstResponder === self, event.type == .keyDown else {
            return super.performKeyEquivalent(with: event)
        }
        record(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        if recording {
            record(event)
        } else if event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_Space) {
            beginRecording()
        } else {
            super.keyDown(with: event)
        }
    }

    private func record(_ event: NSEvent) {
        guard !event.isARepeat else { return }
        switch Int(event.keyCode) {
        case kVK_Escape:
            onValidation?(nil)
            finishRecording()
            return
        case kVK_Tab:
            finishRecording()
            if event.modifierFlags.contains(.shift) { window?.selectPreviousKeyView(self) }
            else { window?.selectNextKeyView(self) }
            return
        case kVK_Delete, kVK_ForwardDelete:
            onValidation?(nil)
            finishRecording()
            hotkey = nil
            refreshTitle()
            onChange?(nil)
            return
        default: break
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        let shortcut = LayoutHotkey(
            keyCode: UInt32(event.keyCode), modifiers: modifiers, key: Self.keyLabel(for: event)
        )
        guard shortcut.isValid else {
            onValidation?("Include Command or Control, or choose a function key (F1–F20).")
            NSSound.beep()
            return
        }
        guard !(shortcut.keyCode == UInt32(kVK_ANSI_L) && modifiers == UInt32(cmdKey | shiftKey)) else {
            onValidation?("⇧⌘L is reserved for the quick switcher.")
            NSSound.beep()
            return
        }
        onValidation?(nil)
        finishRecording()
        hotkey = shortcut
        refreshTitle()
        onChange?(shortcut)
    }

    private static func keyLabel(for event: NSEvent) -> String {
        let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                            kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        if let index = functionKeys.firstIndex(of: Int(event.keyCode)) { return "F\(index + 1)" }
        let specialKeys: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_ANSI_KeypadEnter: "⌤",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_Help: "Help"
        ]
        if let label = specialKeys[Int(event.keyCode)] { return label }

        // Translate without modifiers so Shift–2 is shown as ⇧2, rather than ⇧@.
        if let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
           let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) {
            let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
            if let bytes = CFDataGetBytePtr(data) {
                let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
                var deadKeyState: UInt32 = 0
                var length = 0
                var characters = [UniChar](repeating: 0, count: 8)
                let status = UCKeyTranslate(
                    layout, event.keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState,
                    characters.count, &length, &characters
                )
                if status == noErr, length > 0 {
                    return String(utf16CodeUnits: characters, count: length).uppercased()
                }
            }
        }
        return (event.charactersIgnoringModifiers ?? "").uppercased()
    }
}
