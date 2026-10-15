//
//  AppDelegate.swift
//  Smooth Talker
//
//  Created by Sem Visscher on 25/12/2024.
//

import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarItem: NSStatusItem?
    private var window: NSWindow?
    private var settingsWindow: NSWindow?
    private var speedSlider: NSSlider?
    private var speedValueLabel: NSTextField?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // register hotkey
        _ = HotkeyManager.shared
        Task {
            await PurchaseManager.shared.start()
        }

        NSApp.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApp.activate(ignoringOtherApps: true)
        
        statusBarItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusBarItem?.button {
            button.target = self
            button.image = NSImage(systemSymbolName: "speaker.wave.2.bubble.left", accessibilityDescription: "Smooth Talker")
        }
        
        let menu = NSMenu()
        menu.delegate = self
        
        let settingsMenuItem = NSMenuItem(title: "Settings", action: #selector(openSettings), keyEquivalent: "")
        let quitMenuItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "")
        
        menu.addItem(settingsMenuItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(createSpeedMenuItem())
        menu.addItem(NSMenuItem.separator())
        menu.addItem(quitMenuItem)
        
        statusBarItem?.menu = menu
        
        SpeechManager.shared.appDelegate = self

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )
    }

    
    @objc func openSettings(_ sender: NSStatusBarButton) {
        showSettingsWindow()
    }
    
    func createSettingsWindow() {
        let contentView = ContentView()
        
        let windowWidth: CGFloat = 1040
        let windowHeight: CGFloat = 680
        
        let settingsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        
        settingsWindow.title = "Smooth Talker"
        settingsWindow.minSize = NSSize(width: 900, height: 620)
        settingsWindow.contentView = NSHostingView(rootView: contentView)
        
        settingsWindow.center()
        settingsWindow.isReleasedWhenClosed = false
        
        self.window = settingsWindow
        self.settingsWindow = settingsWindow
        bringWindowToFront(settingsWindow)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @objc private func windowWillClose(_ notification: Notification) {
        HotkeyManager.shared.hotkey?.cancelHotkeyCapture()

        DispatchQueue.main.async { [weak self] in
            self?.hideFromDockIfNoWindowsRemain()
        }
    }

    private func showSettingsWindow() {
        if let window = settingsWindow ?? reusableAppWindow() {
            bringWindowToFront(window)
        } else {
            createSettingsWindow()
        }
    }

    private func bringWindowToFront(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(self)
    }

    private func hideFromDockIfNoWindowsRemain() {
        guard visibleAppWindows().isEmpty else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    private func reusableAppWindow() -> NSWindow? {
        NSApp.windows.first { isAppWindow($0) }
    }

    private func visibleAppWindows() -> [NSWindow] {
        NSApp.windows.filter { $0.isVisible && isAppWindow($0) }
    }

    private func isAppWindow(_ window: NSWindow) -> Bool {
        window.canBecomeKey && window.styleMask.contains(.titled)
    }
    
    
    func setTrayLoading(_ loading: Bool) {
        if loading {
            statusBarItem?.button?.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath.icloud", accessibilityDescription: "Loading")
        } else {
            statusBarItem?.button?.image = NSImage(systemSymbolName: "speaker.wave.2.bubble.left", accessibilityDescription: "Smooth Talker")
        }
    }
    
    @objc func quitApp(_ sender: NSStatusBarButton) {
        NSApplication.shared.terminate(self)
    }

    private func createSpeedMenuItem() -> NSMenuItem {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 40))

        let titleLabel = NSTextField(labelWithString: "Speed")
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        titleLabel.alignment = .left

        let slider = NSSlider(value: Preferences.shared.speakingSpeed, minValue: SpeakingSpeed.minimum, maxValue: SpeakingSpeed.maximum, target: self, action: #selector(speedSliderChanged(_:)))
        slider.isContinuous = true
        slider.controlSize = .small

        let sliderContainer = NSView()
        sliderContainer.translatesAutoresizingMaskIntoConstraints = false
        slider.translatesAutoresizingMaskIntoConstraints = false
        sliderContainer.addSubview(slider)

        let marker = SpeedMarkerView()
        marker.translatesAutoresizingMaskIntoConstraints = false
        sliderContainer.addSubview(marker)

        let valueLabel = NSTextField(labelWithString: formatSpeed(slider.doubleValue))
        valueLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        valueLabel.alignment = .right
        valueLabel.widthAnchor.constraint(equalToConstant: 48).isActive = true

        let stackView = NSStackView(views: [titleLabel, sliderContainer, valueLabel])
        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.spacing = 8
        stackView.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            stackView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            stackView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            titleLabel.widthAnchor.constraint(equalToConstant: 42),
            sliderContainer.widthAnchor.constraint(equalToConstant: 130),
            sliderContainer.heightAnchor.constraint(equalToConstant: 20),
            slider.leadingAnchor.constraint(equalTo: sliderContainer.leadingAnchor),
            slider.trailingAnchor.constraint(equalTo: sliderContainer.trailingAnchor),
            slider.centerYAnchor.constraint(equalTo: sliderContainer.centerYAnchor),
            marker.widthAnchor.constraint(equalToConstant: 5),
            marker.heightAnchor.constraint(equalToConstant: 5),
            marker.centerXAnchor.constraint(
                equalTo: sliderContainer.leadingAnchor,
                constant: CGFloat(SpeakingSpeed.markerPosition(sliderWidth: 130))
            ),
            marker.centerYAnchor.constraint(equalTo: sliderContainer.centerYAnchor)
        ])

        speedSlider = slider
        speedValueLabel = valueLabel

        let menuItem = NSMenuItem()
        menuItem.view = container
        return menuItem
    }

    @objc private func speedSliderChanged(_ sender: NSSlider) {
        let normalizedSpeed = SpeakingSpeed.normalize(sender.doubleValue)
        Preferences.shared.speakingSpeed = normalizedSpeed
        sender.doubleValue = normalizedSpeed
        speedValueLabel?.stringValue = formatSpeed(normalizedSpeed)
    }

    private func formatSpeed(_ speed: Double) -> String {
        SpeakingSpeed.formatted(speed)
    }
}

private final class SpeedMarkerView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.55).cgColor
        layer?.cornerRadius = 2.5
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        let savedSpeed = Preferences.shared.speakingSpeed
        speedSlider?.doubleValue = savedSpeed
        speedValueLabel?.stringValue = formatSpeed(savedSpeed)
    }
}
