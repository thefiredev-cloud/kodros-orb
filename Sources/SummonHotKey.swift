import Cocoa
import Carbon.HIToolbox

// MARK: - Global summon hotkey

// Option-Space reaches the orb from any app. Carbon's RegisterEventHotKey is
// the only route that needs no Accessibility grant and swallows the keystroke:
// a global NSEvent monitor cannot consume events, so the space would still land
// in whatever app has focus.
//
// The callback is a C function pointer and cannot capture self. main.swift
// enforces a single instance, so one file-scope weak target is the whole story.
private var hotKeyRef: EventHotKeyRef?
private var hotKeyHandler: EventHandlerRef?
private weak var hotKeyTarget: AppDelegate?

private func hotKeyFired(_ callRef: EventHandlerCallRef?,
                         _ event: EventRef?,
                         _ context: UnsafeMutableRawPointer?) -> OSStatus {
    DispatchQueue.main.async { hotKeyTarget?.summonFromHotKey() }
    return noErr
}

extension AppDelegate {
    static let summonHotKeyLabel = "⌥Space"

    func installSummonHotKey() {
        hotKeyTarget = self
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), hotKeyFired,
                                            1, &spec, nil, &hotKeyHandler)
        guard installed == noErr else {
            appendOutput("[system] Summon hotkey handler failed with OSStatus \(installed). Click the orb instead.",
                         color: kYellow)
            return
        }
        // 'MORB' — a signature only has to be unique to this process.
        let id = EventHotKeyID(signature: OSType(0x4D4F5242), id: 1)
        let status = RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), id,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            appendOutput("[system] \(AppDelegate.summonHotKeyLabel) is already taken by another app, so summon is off (OSStatus \(status)). Click the orb instead.",
                         color: kYellow)
        }
    }

    func removeSummonHotKey() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
        if let handler = hotKeyHandler { RemoveEventHandler(handler) }
        hotKeyRef = nil
        hotKeyHandler = nil
    }

    // Summon only. Escape dismisses, through cancelOperation: on the composer.
    //
    // This deliberately does not toggle. Measured on 2026-08-03: for this
    // LSUIElement app behind a nonactivating panel, panel.isKeyWindow reads 0
    // on consecutive presses even while typing still lands in the composer,
    // and NSApp.isActive reads 1 while another app is frontmost. Neither can
    // answer "is the user already in the panel", so a toggle built on either
    // misfires. The responder chain has no such ambiguity.
    @objc func summonFromHotKey() {
        if !expanded { expandPanel() }
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        inputField.window?.makeFirstResponder(inputField)
    }
}
