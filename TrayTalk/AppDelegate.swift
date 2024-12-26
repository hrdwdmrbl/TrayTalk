//
//  AppDelegate.swift
//  TrayTalk
//
//  Created by Sem Visscher on 25/12/2024.
//

import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarItem: NSStatusItem?
    private var window: NSWindow?
    private var settingsWindow: NSWindow?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // register hotkey
        _ = HotkeyManager.shared

        // Hide from the Dock
        NSApp.setActivationPolicy(.accessory)
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApp.activate(ignoringOtherApps: true)
        
        statusBarItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusBarItem?.button {
            button.target = self
            button.image = NSImage(systemSymbolName: "speaker.wave.2.bubble.left", accessibilityDescription: "TrayTalk")
        }
        
        let menu = NSMenu()
        
        let settingsMenuItem = NSMenuItem(title: "Settings", action: #selector(openSettings), keyEquivalent: "")
        let quitMenuItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "")
        
        menu.addItem(settingsMenuItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(quitMenuItem)
        
        statusBarItem?.menu = menu
        
        SpeechManager.shared.appDelegate = self
    }

    
    @objc func openSettings(_ sender: NSStatusBarButton) {
        window = NSApplication.shared.windows.first
        
        if let window = window {
            if !window.canBecomeKey {
                return createSettingsWindow()
            }
            // If the settings window is already open, bring it to the front
            NSApplication.shared.activate(ignoringOtherApps: true)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(self)
        } else {
            print("window is not available")
            // Create the settings window if it doesn't exist
            createSettingsWindow()
        }
    }
    
    func createSettingsWindow() {
        let contentView = ContentView()
        
        let windowWidth: CGFloat = 900
        let windowHeight: CGFloat = 630
        
        let settingsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        
        settingsWindow.title = "TrayTalk"
        settingsWindow.contentView = NSHostingView(rootView: contentView)
        
        settingsWindow.center()
        settingsWindow.isReleasedWhenClosed = false
        
        self.window = settingsWindow
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow.makeKeyAndOrderFront(nil)
    }
    
    
    func setTrayLoading(_ loading: Bool) {
        if loading {
            statusBarItem?.button?.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath.icloud", accessibilityDescription: "Loading")
        } else {
            statusBarItem?.button?.image = NSImage(systemSymbolName: "speaker.wave.2.bubble.left", accessibilityDescription: "TrayTalk")
        }
    }
    
    @objc func quitApp(_ sender: NSStatusBarButton) {
        NSApplication.shared.terminate(self)
    }
}

