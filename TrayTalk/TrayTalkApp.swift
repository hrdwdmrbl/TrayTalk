//
//  TrayTalkApp.swift
//  Smooth Talker
//
//  Created by Sem Visscher on 24/12/2024.
//

import AppKit
import SwiftUI

@main
struct SmoothTalkerApp: App {
    @NSApplicationDelegateAdaptor var appDelegate: AppDelegate
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1040, height: 680)
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("Close Window") {
                    closeVisibleWindow()
                }
                .keyboardShortcut("q", modifiers: .command)
            }
        }
    }

    private func closeVisibleWindow() {
        let window = NSApp.keyWindow ??
            NSApp.mainWindow ??
            NSApp.windows.first { $0.isVisible && $0.canBecomeKey }

        window?.performClose(nil)
    }
}
