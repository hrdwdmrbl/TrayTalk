import Foundation
import AppKit
import Carbon.HIToolbox
import ApplicationServices
import Cocoa


class HotkeyManager: ObservableObject {
    static var shared = HotkeyManager()
    var hotkey: GlobalHotkey?
    
    init() {
        hotkey = GlobalHotkey { text in
            SpeechManager.shared.speak(text)
        }
    }
}


class GlobalHotkey: NSObject {
    private var eventTap: CFMachPort?
    private let callback: (String) -> Void
    private var waitingForHotkey = false
    private var detectedHotkey = ""
    private var hotkeyContinuation: CheckedContinuation<String, Never>?
    private var runLoopSource: CFRunLoopSource?
    
    init(callback: @escaping (String) -> Void) {
        self.callback = callback
        super.init()
        checkAccessibilityPermissions()
    }

    private func checkAccessibilityPermissions() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let accessEnabled = AXIsProcessTrustedWithOptions(options as CFDictionary)

        if accessEnabled {
            print("Accessibility permissions granted")
            registerHotkey()
        } else {
            print("Please enable accessibility permissions in System Preferences")
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Accessibility Permissions Required"
                alert.informativeText = "Please enable accessibility permissions for this app in System Preferences > Security & Privacy > Privacy > Accessibility"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Open System Preferences")
                alert.addButton(withTitle: "Later")
                
                if alert.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
            }
        }
    }
    
    private func reEnableEventTap() {
        if let eventTap = eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: true)
        }
    }

    private func registerHotkey() {
        unregisterHotkey()
        
        let eventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        eventTap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                    place: .headInsertEventTap,
                                    options: .defaultTap,
                                    eventsOfInterest: CGEventMask(eventMask),
                                    callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let globalHotkey = Unmanaged<GlobalHotkey>.fromOpaque(refcon).takeUnretainedValue()
            
            if type == .tapDisabledByTimeout {
                print("tap disabled due to timeout")

                // restart it
                HotkeyManager.shared.hotkey?.reEnableEventTap()

                return Unmanaged.passUnretained(event)
            }
            
            if type == .keyDown {
                let eventString = globalHotkey.eventToString(with: event)
                let hotkey = Preferences.shared.hotkey
                if globalHotkey.waitingForHotkey {
                    // Resume the continuation with the detected hotkey
                    globalHotkey.detectedHotkey = eventString
                    globalHotkey.hotkeyContinuation?.resume(returning: eventString)
                    globalHotkey.waitingForHotkey = false
                    return nil // Suppress the event
                } else if hotkey == eventString {
                    if type == .keyUp {
                        print("hotkey key up")
                        return nil
                    }
                    Task {
                        globalHotkey.handleHotkeyPressed()
                    }
                    return nil // Suppress the event
                }
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))

        guard let eventTap = eventTap else {
            print("Failed to create event tap")
            return
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)

        print("Event tap registered")
    }
    
    func unregisterHotkey() {
        if let eventTap = eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        eventTap = nil
        if let runLoopSource = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
    }


    func waitForHotkey() async -> String {
        waitingForHotkey = true
        detectedHotkey = ""

        return await withCheckedContinuation { continuation in
            // Save continuation for later use
            self.hotkeyContinuation = continuation
        }
    }


    private func handleHotkeyPressed() {
        print("Hotkey pressed")
        if let selectedText = getSelectedText() {
            print("Selected text: \(selectedText)")
            callback(selectedText)
        } else {
            print("No text selected")
        }
    }

    private func getSelectedText() -> String? {
        if let selectedText = getSelectedTextUsingAccessibility() {
            return selectedText
        } else {
            return getSelectedTextUsingClipboardWithoutAppleScript()
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
        let appleScriptCode = """
        use AppleScript version "2.4"
        use scripting additions
        use framework "Foundation"
        use framework "AppKit"

        -- Back up clipboard contents:
        set savedClipboard to the clipboard

        set thePasteboard to current application's NSPasteboard's generalPasteboard()
        set theCount to thePasteboard's changeCount()

        -- Copy selected text to clipboard:
        tell application "System Events" to keystroke "c" using {command down}
        delay 0.1 -- Without this, the clipboard may have stale data.

        if thePasteboard's changeCount() is theCount then
            return ""
        end if

        set theSelectedText to the clipboard

        set the clipboard to savedClipboard

        return theSelectedText
        """ // borowed from https://github.com/yetone/get-selected-text/blob/main/src/macos.rs

        var error: NSDictionary?
        let script = NSAppleScript(source: appleScriptCode)

        if let result = script?.executeAndReturnError(&error) {
            return result.stringValue
        } else {
            if let error = error {
                print("Error executing AppleScript: \(error)")
            }
            return nil
        }
    }

    private func getSelectedTextUsingClipboardWithoutAppleScript() -> String? {
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
        
        // Simulate ⌘C to copy selected text
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

    private func eventToString(with cgEvent: CGEvent) -> String {
        guard let event = NSEvent(cgEvent: cgEvent) else {
            return ""
        }
        
        let modifierFlags = event.modifierFlags
        let characters = event.charactersIgnoringModifiers?.uppercased()
        
        var modifierString = ""
        
        if modifierFlags.contains(.command) {
            modifierString += "Command + "
        }
        if modifierFlags.contains(.option) {
            modifierString += "Option + "
        }
        if modifierFlags.contains(.control) {
            modifierString += "Control + "
        }
        if modifierFlags.contains(.shift) {
            modifierString += "Shift + "
        }
        
        return modifierString + (characters ?? "")
    }

    deinit {
        unregisterHotkey()
    }
}
