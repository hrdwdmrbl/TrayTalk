import Foundation
import AppKit
import Carbon.HIToolbox
import ApplicationServices
import Cocoa
#if DEBUG
import OSLog
#endif

enum HotkeyFormatter {
    static let defaultHotkey = "Option + `"

    private static let modifierOrder = ["Command", "Option", "Control", "Shift"]
    private static let commandStyleModifiers = Set(["Command", "Option", "Control"])

    static func canonicalize(_ rawValue: String?) -> String {
        guard let rawValue else {
            return defaultHotkey
        }

        let parts = rawValue
            .split(separator: "+", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !parts.isEmpty else {
            return defaultHotkey
        }

        var modifiers = Set<String>()
        var keyParts: [String] = []

        for part in parts {
            if let modifier = canonicalModifier(part) {
                modifiers.insert(modifier)
            } else {
                keyParts.append(part)
            }
        }

        guard let key = keyParts.last.map(normalizeKey), !key.isEmpty else {
            return defaultHotkey
        }

        guard modifiers.contains(where: { commandStyleModifiers.contains($0) }) else {
            return defaultHotkey
        }

        let orderedModifiers = modifierOrder.filter { modifiers.contains($0) }
        let shortcut = (orderedModifiers + [key]).joined(separator: " + ")
        return isAllowedShortcut(shortcut) ? shortcut : defaultHotkey
    }

    static func shortcut(from event: NSEvent) -> String? {
        let modifierFlags = event.modifierFlags
        let hasCommandStyleModifier = modifierFlags.contains(.command) ||
            modifierFlags.contains(.option) ||
            modifierFlags.contains(.control)

        var parts: [String] = []

        if modifierFlags.contains(.command) {
            parts.append("Command")
        }
        if modifierFlags.contains(.option) {
            parts.append("Option")
        }
        if modifierFlags.contains(.control) {
            parts.append("Control")
        }
        if modifierFlags.contains(.shift) {
            parts.append("Shift")
        }

        guard hasCommandStyleModifier, !parts.isEmpty, let key = keyName(from: event) else {
            return nil
        }

        parts.append(key)

        let shortcut = canonicalize(parts.joined(separator: " + "))
        return shortcut == defaultHotkey || isAllowedShortcut(shortcut) ? shortcut : nil
    }

    static func isAllowedShortcut(_ shortcut: String) -> Bool {
        let canonicalShortcut = canonicalizeWithoutValidation(shortcut)
        let parts = canonicalShortcut
            .split(separator: "+", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let modifiers = Set(parts.compactMap(canonicalModifier))

        return modifiers.contains { commandStyleModifiers.contains($0) }
    }

    private static func keyName(from event: NSEvent) -> String? {
        switch Int(event.keyCode) {
        case kVK_Space:
            return "Space"
        case kVK_Tab:
            return "Tab"
        case kVK_Return, kVK_ANSI_KeypadEnter:
            return "Return"
        case kVK_Escape:
            return "Escape"
        case kVK_Delete, kVK_ForwardDelete:
            return "Delete"
        default:
            let characters = normalizeKey(event.charactersIgnoringModifiers ?? "")
            return characters.isEmpty ? nil : characters
        }
    }

    private static func canonicalModifier(_ value: String) -> String? {
        switch value.lowercased() {
        case "command", "cmd", "⌘":
            return "Command"
        case "option", "alt", "⌥":
            return "Option"
        case "control", "ctrl", "^", "⌃":
            return "Control"
        case "shift", "⇧":
            return "Shift"
        default:
            return nil
        }
    }

    private static func normalizeKey(_ value: String) -> String {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)

        switch trimmedValue.lowercased() {
        case "space":
            return "Space"
        case "tab":
            return "Tab"
        case "return", "enter":
            return "Return"
        case "escape", "esc":
            return "Escape"
        case "delete", "backspace":
            return "Delete"
        default:
            break
        }

        guard trimmedValue.count == 1 else {
            return trimmedValue
        }

        return trimmedValue.uppercased()
    }

    private static func canonicalizeWithoutValidation(_ rawValue: String) -> String {
        let parts = rawValue
            .split(separator: "+", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var modifiers = Set<String>()
        var keyParts: [String] = []

        for part in parts {
            if let modifier = canonicalModifier(part) {
                modifiers.insert(modifier)
            } else {
                keyParts.append(part)
            }
        }

        guard let key = keyParts.last.map(normalizeKey), !key.isEmpty else {
            return defaultHotkey
        }

        let orderedModifiers = modifierOrder.filter { modifiers.contains($0) }
        return (orderedModifiers + [key]).joined(separator: " + ")
    }
}

class HotkeyManager: ObservableObject {
    static var shared = HotkeyManager()
    @Published private(set) var isAccessibilityTrusted = false
    @Published private(set) var isHotkeyRegistered = false
    @Published private(set) var accessibilityStatusMessage = "Checking assistive reading access..."

    var hotkey: GlobalHotkey?
    private var activeObserver: NSObjectProtocol?
    private var permissionPollingTimer: Timer?
    private var permissionPollingAttempts = 0
    
    init() {
        hotkey = GlobalHotkey { text in
            SpeechManager.shared.speak(text)
        }

        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshAccessibilityStatus(prompt: false)
        }

        refreshAccessibilityStatus(prompt: false)
    }

    var canCaptureHotkey: Bool {
        isAccessibilityTrusted && isHotkeyRegistered
    }

    func refreshAccessibilityStatus(prompt: Bool) {
        let trusted = checkAccessibilityTrusted(prompt: prompt)
        isAccessibilityTrusted = trusted

        if trusted {
            stopPermissionPolling()
            registerIfPermitted()
        } else {
            hotkey?.unregisterHotkey()
            isHotkeyRegistered = false
            accessibilityStatusMessage = "Allow Smooth Talker in Privacy & Security > Accessibility so it can speak selected text when you invoke the assistive shortcut."
        }
    }

    func requestAccessibilityPermission() {
        refreshAccessibilityStatus(prompt: true)
        openAccessibilitySettings()
        startPermissionPolling()
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }

        NSWorkspace.shared.open(url)
    }

    private func registerIfPermitted() {
        guard isAccessibilityTrusted else {
            isHotkeyRegistered = false
            return
        }

        isHotkeyRegistered = hotkey?.registerHotkey() ?? false
        accessibilityStatusMessage = isHotkeyRegistered
            ? "Assistive reading shortcut enabled."
            : "Smooth Talker could not start the assistive reading shortcut. Try rechecking access."
    }

    private func startPermissionPolling() {
        stopPermissionPolling()
        permissionPollingAttempts = 0

        permissionPollingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }

            permissionPollingAttempts += 1
            refreshAccessibilityStatus(prompt: false)

            if isAccessibilityTrusted || permissionPollingAttempts >= 60 {
                timer.invalidate()
                permissionPollingTimer = nil
            }
        }
    }

    private func stopPermissionPolling() {
        permissionPollingTimer?.invalidate()
        permissionPollingTimer = nil
        permissionPollingAttempts = 0
    }

    private func checkAccessibilityTrusted(prompt: Bool) -> Bool {
        if prompt {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            return AXIsProcessTrustedWithOptions(options as CFDictionary)
        }

        return AXIsProcessTrusted()
    }

    deinit {
        if let activeObserver {
            NotificationCenter.default.removeObserver(activeObserver)
        }
        stopPermissionPolling()
    }
}


class GlobalHotkey: NSObject {
    private var eventTap: CFMachPort?
    private let callback: (String) -> Void
    private var waitingForHotkey = false
    private var detectedHotkey = ""
    private var hotkeyContinuation: CheckedContinuation<String?, Never>?
    private var runLoopSource: CFRunLoopSource?

    #if DEBUG
    private static let lifecycleLogger = Logger(
        subsystem: "com.cyberofficeindustries.smoothtalker",
        category: "GlobalHotkeyLifecycle"
    )
    #endif
    
    init(callback: @escaping (String) -> Void) {
        self.callback = callback
        super.init()
    }
    
    func reEnableEventTap() {
        debugLog("reEnableEventTap requested")
        if let eventTap = eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: true)
            debugLog("reEnableEventTap completed")
        }
    }

    @discardableResult
    func registerHotkey() -> Bool {
        debugLog("register requested; cleanup will run before creating new event tap")
        unregisterHotkey()
        
        let eventMask = (1 << CGEventType.keyDown.rawValue)
        eventTap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                    place: .headInsertEventTap,
                                    options: .defaultTap,
                                    eventsOfInterest: CGEventMask(eventMask),
                                    callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let globalHotkey = Unmanaged<GlobalHotkey>.fromOpaque(refcon).takeUnretainedValue()
            
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                globalHotkey.reEnableEventTap()

                return Unmanaged.passUnretained(event)
            }
            
            guard type == .keyDown else {
                return Unmanaged.passUnretained(event)
            }

            guard let eventString = globalHotkey.eventToString(with: event) else {
                return Unmanaged.passUnretained(event)
            }

            if globalHotkey.waitingForHotkey {
                globalHotkey.detectedHotkey = eventString
                let continuation = globalHotkey.hotkeyContinuation
                globalHotkey.hotkeyContinuation = nil
                globalHotkey.waitingForHotkey = false
                globalHotkey.debugLog("capture completed event=\(eventString)")
                continuation?.resume(returning: eventString)
                return nil
            } else if Preferences.shared.hotkey == eventString {
                globalHotkey.debugLog("matched global key event=\(eventString)")
                Task {
                    globalHotkey.handleHotkeyPressed()
                }
                return nil
            }

            return Unmanaged.passUnretained(event)
        }, userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))

        guard let eventTap = eventTap else {
            debugLog("register failed; CGEvent.tapCreate returned nil")
            return false
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        debugLog("register completed")
        return true
    }
    
    func unregisterHotkey() {
        debugLog("unregister requested")
        cancelHotkeyCapture()

        if let eventTap = eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        eventTap = nil
        if let runLoopSource = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
        debugLog("unregister completed")
    }


    func waitForHotkey() async -> String? {
        cancelHotkeyCapture()
        waitingForHotkey = true
        detectedHotkey = ""
        debugLog("capture started")

        return await withCheckedContinuation { continuation in
            self.hotkeyContinuation = continuation
        }
    }

    func cancelHotkeyCapture() {
        guard waitingForHotkey || hotkeyContinuation != nil else { return }

        debugLog("capture cancellation requested")
        waitingForHotkey = false
        detectedHotkey = ""
        let continuation = hotkeyContinuation
        hotkeyContinuation = nil
        continuation?.resume(returning: nil)
        debugLog("capture cancellation completed")
    }

    private func debugLog(_ message: String) {
        #if DEBUG
        let activeShortcut = Preferences.shared.hotkey
        Self.lifecycleLogger.notice(
            "\(message, privacy: .public); activeShortcut=\(activeShortcut, privacy: .public); eventTapExists=\(self.eventTap != nil, privacy: .public); runLoopSourceExists=\(self.runLoopSource != nil, privacy: .public); waitingForCapture=\(self.waitingForHotkey, privacy: .public)"
        )
        #endif
    }


    private func handleHotkeyPressed() {
        if let selectedText = getSelectedText() {
            callback(selectedText)
        }
    }

    private func getSelectedText() -> String? {
        if let selectedText = getSelectedTextUsingAccessibility() {
            return selectedText
        } else {
            return getSelectedTextUsingClipboard()
        }
    }
    
    private func getSelectedTextUsingAccessibility() -> String? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var selectedTextValue: AnyObject?
        let errorCode = AXUIElementCopyAttributeValue(systemWideElement, kAXFocusedUIElementAttribute as CFString, &selectedTextValue)

        if errorCode == .success {
            let selectedTextElement = selectedTextValue as! AXUIElement
            var selectedText: AnyObject?
            let textErrorCode = AXUIElementCopyAttributeValue(selectedTextElement, kAXSelectedTextAttribute as CFString, &selectedText)

            if textErrorCode == .success, let selectedTextString = selectedText as? String {
                return selectedTextString
            } else {
                return nil
            }
        } else {
            return nil
        }
    }
    
    private func getSelectedTextUsingClipboard() -> String? {
        let pasteboard = NSPasteboard.general
        
        // Save current clipboard items (duplicate them)
        let savedItems = pasteboard.pasteboardItems?.compactMap { originalItem -> NSPasteboardItem? in
            let newItem = NSPasteboardItem()
            for type in originalItem.types {
                if let data = originalItem.data(forType: type) {
                    newItem.setData(data, forType: type)
                }
            }
            return newItem
        }
        
        // Save the current change count
        let changeCount = pasteboard.changeCount
        
        // Simulate Command-C to copy selected text.
        let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: false)
        keyDown?.flags = CGEventFlags.maskCommand
        keyUp?.flags = CGEventFlags.maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
        
        // Wait at most 500ms for clipboard to update
        var attempts = 10
        while changeCount == pasteboard.changeCount && attempts > 0 {
            usleep(50_000) // Wait 50ms
            attempts -= 1
        }
        
        // Fetch the selected text
        let selectedText = pasteboard.string(forType: .string)
         
        // Restore clipboard using duplicated items
        if let savedItems = savedItems, pasteboard.changeCount != changeCount {
            pasteboard.clearContents()
            pasteboard.writeObjects(savedItems)
        }
        
        return selectedText
    }

    private func eventToString(with cgEvent: CGEvent) -> String? {
        guard let event = NSEvent(cgEvent: cgEvent) else {
            return nil
        }

        return HotkeyFormatter.shortcut(from: event)
    }

    deinit {
        unregisterHotkey()
    }
}
