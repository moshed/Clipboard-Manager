import SwiftUI
import AppKit
import Carbon

struct KeyEventHandlerView: NSViewRepresentable {
    var onCopyPlain: () -> Void
    var onCopyFormatted: () -> Void
    var onDownArrow: () -> Void
    var onUpArrow: () -> Void
    var onRightArrow: () -> Void = {}
    var onLeftArrow: () -> Void = {}
    var onExpand: () -> Void
    var onDelete: () -> Void
    var onEnter: () -> Void
    var onShiftEnter: () -> Void
    var onTyping: (String) -> Void
    var onFocusSearch: () -> Void = {}
    var onToggleTab: () -> Void = {}
    var onToggleTabBackward: () -> Void = {}

    func makeNSView(context: Context) -> KeyCaptureView {
        let view = KeyCaptureView()
        view.onCopyPlain = onCopyPlain
        view.onCopyFormatted = onCopyFormatted
        view.onDownArrow = onDownArrow
        view.onUpArrow = onUpArrow
        view.onRightArrow = onRightArrow
        view.onLeftArrow = onLeftArrow
        view.onExpand = onExpand
        view.onDelete = onDelete
        view.onEnter = onEnter
        view.onShiftEnter = onShiftEnter
        view.onTyping = onTyping
        view.onFocusSearch = onFocusSearch
        view.onToggleTab = onToggleTab
        view.onToggleTabBackward = onToggleTabBackward
        return view
    }

    func updateNSView(_ nsView: KeyCaptureView, context: Context) {
        nsView.onCopyPlain = onCopyPlain
        nsView.onCopyFormatted = onCopyFormatted
        nsView.onDownArrow = onDownArrow
        nsView.onUpArrow = onUpArrow
        nsView.onRightArrow = onRightArrow
        nsView.onLeftArrow = onLeftArrow
        nsView.onExpand = onExpand
        nsView.onDelete = onDelete
        nsView.onEnter = onEnter
        nsView.onShiftEnter = onShiftEnter
        nsView.onTyping = onTyping
        nsView.onFocusSearch = onFocusSearch
        nsView.onToggleTab = onToggleTab
        nsView.onToggleTabBackward = onToggleTabBackward
    }
}

class KeyCaptureView: NSView {
    var onCopyPlain: (() -> Void)?
    var onCopyFormatted: (() -> Void)?
    var onDownArrow: (() -> Void)?
    var onUpArrow: (() -> Void)?
    var onRightArrow: (() -> Void)?
    var onLeftArrow: (() -> Void)?
    var onExpand: (() -> Void)?
    var onDelete: (() -> Void)?
    var onEnter: (() -> Void)?
    var onShiftEnter: (() -> Void)?
    var onTyping: ((String) -> Void)?
    var onFocusSearch: (() -> Void)?
    var onToggleTab: (() -> Void)?
    var onToggleTabBackward: (() -> Void)?

    private var localMonitor: Any?
    private let settings = SettingsManager.shared

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            setupMonitor()
        } else {
            removeMonitor()
        }
    }

    private func setupMonitor() {
        removeMonitor()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.window?.isKeyWindow == true else { return event }

            let inTextField = event.window?.firstResponder is NSTextView
            return self.handleKeyEvent(event, inTextField: inTextField) ? nil : event
        }
    }

    private func removeMonitor() {
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }

    private func handleKeyEvent(_ event: NSEvent, inTextField: Bool) -> Bool {
        // Don't intercept while recording a shortcut
        if isRecordingShortcut { return false }

        let keyCode = UInt32(event.keyCode)
        let flags = event.modifierFlags

        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }

        // Tab toggle shortcuts (check before Cmd passthrough)
        if let combo = settings.tabBackwardShortcut, combo.matches(keyCode: keyCode, modifiers: mods) {
            onToggleTabBackward?()
            return true
        }
        if let combo = settings.tabToggleShortcut, combo.matches(keyCode: keyCode, modifiers: mods) {
            onToggleTab?()
            return true
        }

        // Cmd+F to focus search
        if flags.contains(.command) {
            if let combo = settings.searchShortcut, combo.matches(keyCode: keyCode, modifiers: mods) {
                onFocusSearch?()
                return true
            }
            // Let system handle other Cmd shortcuts
            return false
        }

        // Arrow keys for navigation (but let text fields handle them normally)
        if !inTextField {
            switch Int(keyCode) {
            case kVK_DownArrow:
                onDownArrow?()
                return true
            case kVK_UpArrow:
                onUpArrow?()
                return true
            case kVK_RightArrow:
                onRightArrow?()
                return true
            case kVK_LeftArrow:
                onLeftArrow?()
                return true
            default:
                break
            }
        }

        // Copy/delete shortcuts work even in text fields, BUT only if they
        // use a modifier beyond just Shift (otherwise Enter/Delete are needed for typing)
        let hasRealModifier = mods & UInt32(cmdKey | optionKey | controlKey) != 0

        if let combo = settings.copyFormattedShortcut, combo.matches(keyCode: keyCode, modifiers: mods) {
            if !inTextField || hasRealModifier {
                onCopyFormatted?()
                return true
            }
        }

        if let combo = settings.copyPlainShortcut, combo.matches(keyCode: keyCode, modifiers: mods) {
            if !inTextField || hasRealModifier {
                onCopyPlain?()
                return true
            }
        }

        if let combo = settings.deleteShortcut, combo.matches(keyCode: keyCode, modifiers: mods) {
            if !inTextField || hasRealModifier {
                onDelete?()
                return true
            }
        }

        // Below here: only when NOT in a text field
        if inTextField { return false }

        if let expandCombo = settings.expandShortcut,
           expandCombo.matches(keyCode: keyCode, modifiers: mods) {
            onExpand?()
            return true
        }

        // Forward printable characters to search field (only if instant typing is on)
        if settings.instantTyping, let chars = event.characters, !chars.isEmpty {
            onTyping?(chars)
            return true
        }

        return false
    }

    deinit {
        removeMonitor()
    }
}
