//
//  ContentView.swift
//  Smooth Talker
//
//  Created by Sem Visscher on 24/12/2024.
//

import AppKit
import AVKit
import SwiftUI

struct ContentView: View {
    @StateObject private var purchaseManager = PurchaseManager.shared
    @StateObject private var hotkeyManager = HotkeyManager.shared
    @State private var credentials = Preferences.shared.credentials
    @AppStorage("inputText") private var inputText = "Have a nice day!"
    @State private var result: String = ""
    @State private var isLoading = false
    @State private var isInitializing = false
    @State private var selectedVoice: TTSVoice?
    @AppStorage("speakingSpeed") private var speakingSpeed = 1.0
    @State private var api: TextToSpeechProviding?
    @State private var availableVoices: [TTSVoice] = []
    @State private var selectedLanguage: String = "en-US"
    @State private var availableLanguages: [String] = []
    @AppStorage("hotkey") private var hotkey = HotkeyFormatter.defaultHotkey
    @State private var editingHotkey = false
    @State private var hotkeyCaptureTask: Task<Void, Never>?
    @State var loadVoicesTask: Task<Void, Never>?
    @State private var isCredentialsSheetPresented = false
    @State private var isUnlockSheetPresented = false
    @State private var isRemoveGoogleCloudConfirmationPresented = false
    @State private var pendingLockedVoice: TTSVoice?
    @State private var deferredPremiumVoiceName: String?
    @State private var onboardingStep: MandatoryOnboardingStep = .accessibility
    @State private var isAppReviewDemoModeEnabled = Preferences.shared.isAppReviewDemoModeEnabled

    private let inputLimit = 70
    private static let appReviewDemoLanguage = "en-US"
    private static let appReviewDemoVoiceName = "en-US-Chirp3-HD-Sadaltager"
    private static let appReviewDemoSampleText = "Gift Helper: Preparing App Store Review information."

    var filteredVoices: [TTSVoice] {
        if selectedLanguage.isEmpty {
            return availableVoices
        }
        return availableVoices.filter { voice in
            voice.languageCodes.contains(selectedLanguage)
        }
    }

    private var filteredVoiceGroups: [VoiceGroup] {
        VoiceCategory.allCases.compactMap { category in
            let voices = filteredVoices.filter { VoiceCategory(for: $0.name) == category }
            guard !voices.isEmpty else { return nil }
            return VoiceGroup(category: category, voices: voices)
        }
    }

    private var canSpeak: Bool {
        let selectedVoiceCanPlay = selectedVoice.map { !isVoiceLocked($0) } ?? false
        return hasTextToSpeechAccess && !inputText.isEmpty && !isLoading && !isInitializing && selectedVoiceCanPlay
    }

    private var hasGoogleCloudCredentials: Bool {
        !credentials.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasTextToSpeechAccess: Bool {
        hasGoogleCloudCredentials || isAppReviewDemoModeEnabled
    }

    private var googleCloudNeedsOnboarding: Bool {
        !hasTextToSpeechAccess || hasError
    }

    private var speakingSpeedBinding: Binding<Double> {
        Binding(
            get: {
                SpeakingSpeed.normalize(speakingSpeed)
            },
            set: { newValue in
                let normalizedSpeed = SpeakingSpeed.normalize(newValue)
                Preferences.shared.speakingSpeed = normalizedSpeed
                speakingSpeed = normalizedSpeed
            }
        )
    }

    private var mandatoryOnboardingStep: MandatoryOnboardingStep? {
        if !hotkeyManager.canCaptureHotkey {
            return .accessibility
        }

        if onboardingStep == .accessibilitySuccess {
            return .accessibilitySuccess
        }

        if onboardingStep == .googleCloudSuccess && !googleCloudNeedsOnboarding {
            return .googleCloudSuccess
        }

        if googleCloudNeedsOnboarding {
            return .googleCloud
        }

        return nil
    }

    private var hasError: Bool {
        result.localizedCaseInsensitiveContains("error") ||
        result.localizedCaseInsensitiveContains("failed")
    }

    private var cloudStatus: ConnectionStatus {
        if !hasTextToSpeechAccess {
            return .notConfigured
        }

        if isInitializing {
            return .loading
        }

        if hasError {
            return .error
        }

        if !availableVoices.isEmpty {
            return .connected
        }

        return .notConfigured
    }

    private var readyStatus: ReadyStatus {
        if !hasTextToSpeechAccess {
            return ReadyStatus(
                title: "Not configured",
                message: "Connect Google Cloud Text-to-Speech to start using Smooth Talker.",
                symbolName: "exclamationmark.circle.fill",
                color: .orange
            )
        }

        if isInitializing {
            return ReadyStatus(
                title: "Loading voices",
                message: "Smooth Talker is checking your Google Cloud Text-to-Speech credentials.",
                symbolName: "arrow.triangle.2.circlepath",
                color: .orange
            )
        }

        if hasError {
            return ReadyStatus(
                title: "Needs attention",
                message: result,
                symbolName: "xmark.circle.fill",
                color: .red
            )
        }

        if selectedVoice == nil {
            return ReadyStatus(
                title: "Choose a voice",
                message: "Select a voice before speaking text.",
                symbolName: "person.wave.2.fill",
                color: .orange
            )
        }

        if !hotkeyManager.isAccessibilityTrusted {
            return ReadyStatus(
                title: "Needs Accessibility",
                message: hotkeyManager.accessibilityStatusMessage,
                symbolName: "keyboard.badge.ellipsis",
                color: .orange
            )
        }

        if !hotkeyManager.isHotkeyRegistered {
            return ReadyStatus(
                title: "Shortcut unavailable",
                message: hotkeyManager.accessibilityStatusMessage,
                symbolName: "keyboard.badge.exclamationmark",
                color: .red
            )
        }

        return ReadyStatus(
            title: "Ready",
            message: "Select text in any app and press \(hotkey) to hear it read aloud.",
            symbolName: "checkmark.circle.fill",
            color: .green
        )
    }

    var body: some View {
        rootContent
            .background(Color(nsColor: .windowBackgroundColor))
            .frame(minWidth: 900, minHeight: 620)
            .sheet(isPresented: $isCredentialsSheetPresented) {
                CredentialsSetupSheet { newCredentials, voices in
                    saveValidatedCredentials(newCredentials, voices: voices)
                } onReviewDemoSave: { demoToken, voices in
                    saveAppReviewDemoAccess(token: demoToken, voices: voices)
                }
            }
            .sheet(isPresented: $isUnlockSheetPresented) {
                PremiumVoicesUnlockSheet(
                    purchaseManager: purchaseManager,
                    lockedVoice: pendingLockedVoice
                ) {
                    selectPendingLockedVoiceIfUnlocked()
                }
            }
            .alert("Remove Google Cloud setup?", isPresented: $isRemoveGoogleCloudConfirmationPresented) {
                Button("Cancel", role: .cancel) {}

                Button("Remove", role: .destructive) {
                    clearCredentials()
                }
            } message: {
                Text("You'll need to connect Google Cloud Text-to-Speech again before using Smooth Talker.")
            }
            .onAppear {
                normalizeStoredHotkey()
                normalizeStoredSpeakingSpeed()

                if inputText.count > inputLimit {
                    inputText = String(inputText.prefix(inputLimit))
                }

                isAppReviewDemoModeEnabled = Preferences.shared.isAppReviewDemoModeEnabled

                if hasTextToSpeechAccess && availableVoices.isEmpty {
                    startLoadVoicesTask(resetAPI: false)
                }

                if !hotkeyManager.canCaptureHotkey {
                    onboardingStep = .accessibility
                } else if googleCloudNeedsOnboarding {
                    onboardingStep = .googleCloud
                }
            }
            .onDisappear {
                stopEditingHotkey()
            }
            .task {
                await purchaseManager.start()
            }
            .onChange(of: credentials) { _, newValue in
                if !newValue.isEmpty {
                    startLoadVoicesTask(resetAPI: true)
                } else if !isAppReviewDemoModeEnabled {
                    TextToSpeechClient.resetSharedInstances()
                    api = nil
                    availableVoices = []
                    availableLanguages = []
                    selectedVoice = nil
                    result = ""
                    onboardingStep = .googleCloud
                }
            }
            .onChange(of: selectedVoice) { oldValue, newValue in
                if let voice = newValue, isVoiceLocked(voice) {
                    pendingLockedVoice = voice
                    isUnlockSheetPresented = true
                    selectedVoice = oldValue.flatMap { isVoiceLocked($0) ? nil : $0 } ?? firstAccessibleVoice()
                    return
                }

                Preferences.shared.voiceName = newValue?.name ?? ""
                Preferences.shared.language = newValue?.languageCodes.first ?? "unknown"
            }
            .onChange(of: purchaseManager.premiumVoicesEntitlementStatus) { _, status in
                switch status {
                case .checking:
                    break
                case .owned:
                    selectDeferredPremiumVoiceIfAvailable()
                    selectPendingLockedVoiceIfUnlocked()
                case .notOwned:
                    ensureSelectedVoiceIsAccessible()
                }
            }
            .onChange(of: hotkeyManager.isAccessibilityTrusted) { _, isTrusted in
                onboardingStep = isTrusted ? .accessibilitySuccess : .accessibility
            }
            .onChange(of: editingHotkey) { _, newValue in
                if newValue {
                    startEditingHotkey()
                } else {
                    stopEditingHotkey()
                }
            }
    }

    @ViewBuilder
    private var rootContent: some View {
        if let mandatoryOnboardingStep {
            MandatoryOnboardingGate(
                step: mandatoryOnboardingStep,
                hotkeyManager: hotkeyManager,
                googleCloudErrorMessage: hasError ? result : nil,
                onAccessibilityContinue: continueFromAccessibilitySuccess,
                onGoogleCloudConnected: handleOnboardingGoogleCloudConnected,
                onReviewDemoConnected: handleOnboardingReviewDemoConnected,
                onGoogleCloudContinue: continueFromGoogleCloudSuccess
            )
        } else {
            mainAppContent
        }
    }

    private var mainAppContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                inputArea
                settingsCard
                cloudCard
                StatusCard(status: readyStatus)
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 22)
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text("Smooth Talker")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)

                Text("Assistive text-to-speech for selected text")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
    }

    private var inputArea: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                LimitedTextField(
                    text: $inputText,
                    characterLimit: inputLimit,
                    placeholder: "Text to speak"
                )
                    .padding(.horizontal, 16)
                    .padding(.trailing, 76)
                    .frame(height: 50)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                    )

                Text("\(inputText.count) / \(inputLimit)")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 16)
                    .padding(.bottom, 7)
            }
            .frame(maxWidth: .infinity)

            Button(action: {
                speakText(inputText)
            }) {
                Label("Speak", systemImage: "play.fill")
                    .font(.system(size: 17, weight: .bold))
                    .frame(width: 164, height: 50)
            }
            .buttonStyle(OrangeProminentButtonStyle())
            .disabled(!canSpeak)
        }
    }

    private var settingsCard: some View {
        SettingsCard {
            VStack(spacing: 14) {
                SettingsRow(symbolName: "globe", title: "Language") {
                    if availableLanguages.isEmpty {
                        PlaceholderValue(text: languagePlaceholderText)
                    } else {
                        Picker("Language", selection: $selectedLanguage) {
                            Text("All Languages").tag("")
                            ForEach(availableLanguages, id: \.self) { language in
                                Text(language).tag(language)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .controlSize(.regular)
                        .frame(maxWidth: .infinity)
                        .onChange(of: selectedLanguage) {
                            selectedVoice = firstAccessibleVoice(in: filteredVoices)
                        }
                    }
                }

                SettingsRow(symbolName: "person.wave.2", title: "Voice") {
                    if availableVoices.isEmpty {
                        PlaceholderValue(text: voicePlaceholderText)
                    } else {
                        Picker("Voice", selection: $selectedVoice) {
                            ForEach(filteredVoiceGroups) { group in
                                Section(header: Text(group.category.title)) {
                                    ForEach(group.voices, id: \.name) { voice in
                                        Text(voiceMenuTitle(for: voice)).tag(voice as TTSVoice?)
                                    }
                                }
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .controlSize(.regular)
                        .frame(maxWidth: .infinity)
                    }
                }

                SettingsRow(symbolName: "speedometer", title: "Speaking Speed") {
                    HStack(spacing: 12) {
                        Text("-")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.secondary)

                        ZStack(alignment: .leading) {
                            Slider(value: speakingSpeedBinding, in: SpeakingSpeed.minimum...SpeakingSpeed.maximum)
                                .tint(.orange)

                            GeometryReader { proxy in
                                Circle()
                                    .fill(Color.secondary.opacity(0.55))
                                    .frame(width: 5, height: 5)
                                    .position(
                                        x: CGFloat(SpeakingSpeed.markerPosition(sliderWidth: Double(proxy.size.width))),
                                        y: proxy.size.height / 2
                                    )
                            }
                            .allowsHitTesting(false)
                        }
                        .frame(height: 28)

                        Text("+")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.secondary)

                        Text(SpeakingSpeed.formatted(speakingSpeed))
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(.orange)
                            .frame(width: 66, height: 34)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color(nsColor: .textBackgroundColor))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                            )
                    }
                }

                Divider()
                    .padding(.leading, 76)

                SettingsRow(symbolName: "keyboard", title: "Keyboard Shortcut") {
                    HStack(spacing: 10) {
                        Text(editingHotkey ? "Press keys" : hotkey)
                            .font(.system(size: 15, weight: .medium))
                            .frame(maxWidth: .infinity, minHeight: 34)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color(nsColor: .textBackgroundColor))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                            )

                        if !hotkeyManager.isAccessibilityTrusted {
                            Button("Open Settings") {
                                hotkeyManager.requestAccessibilityPermission()
                            }
                            .controlSize(.regular)
                            .frame(width: 118)

                            Button("Recheck") {
                                hotkeyManager.refreshAccessibilityStatus(prompt: false)
                            }
                            .controlSize(.regular)
                            .frame(width: 86)
                        } else {
                            Button(editingHotkey ? "Listening..." : "Change...") {
                                editingHotkey = true
                            }
                            .controlSize(.regular)
                            .frame(width: 122)
                            .disabled(editingHotkey || !hotkeyManager.canCaptureHotkey)
                        }
                    }
                }
            }
        }
    }

    private var languagePlaceholderText: String {
        if isInitializing {
            return "Loading languages..."
        }

        return hasGoogleCloudCredentials ? "No languages loaded" : "Connect Google Cloud Text-to-Speech first"
    }

    private var voicePlaceholderText: String {
        if isInitializing {
            return "Loading voices..."
        }

        return hasGoogleCloudCredentials ? "No voices loaded" : "Connect Google Cloud Text-to-Speech first"
    }

    private var cloudCard: some View {
        SettingsCard {
            HStack(spacing: 16) {
                IconTile(symbolName: cloudStatus.symbolName, color: cloudStatus.color)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Google Cloud Text-to-Speech")
                        .font(.system(size: 17, weight: .semibold))

                    Text(cloudStatus.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(cloudStatus.color)
                }

                Spacer(minLength: 16)

                if !hasTextToSpeechAccess {
                    Button("Connect Google Cloud...") {
                        isCredentialsSheetPresented = true
                    }
                    .controlSize(.regular)
                } else {
                    Button("Remove") {
                        isRemoveGoogleCloudConfirmationPresented = true
                    }
                    .controlSize(.regular)
                }
            }
        }
    }

    private func saveValidatedCredentials(_ newCredentials: String, voices: [TTSVoice]) {
        let trimmedCredentials = newCredentials.trimmingCharacters(in: .whitespacesAndNewlines)
        Preferences.shared.clearAppReviewDemoMode()
        isAppReviewDemoModeEnabled = false
        Preferences.shared.credentials = trimmedCredentials
        credentials = trimmedCredentials
        isCredentialsSheetPresented = false
        TextToSpeechClient.resetSharedInstances()
        applyVoices(voices)
        result = "Google Cloud Text-to-Speech connected. Ready to read aloud."
    }

    private func saveAppReviewDemoAccess(token: String, voices: [TTSVoice]) {
        Preferences.shared.enableAppReviewDemoMode(token: token)
        isAppReviewDemoModeEnabled = true
        Preferences.shared.credentials = ""
        credentials = ""
        isCredentialsSheetPresented = false
        TextToSpeechClient.resetSharedInstances()
        applyVoices(voices)
        applyAppReviewDemoDefaults()
        result = "App Review demo connected. Ready to read aloud."
    }

    private func continueFromAccessibilitySuccess() {
        onboardingStep = .googleCloud
    }

    private func handleOnboardingGoogleCloudConnected(_ newCredentials: String, voices: [TTSVoice]) {
        saveValidatedCredentials(newCredentials, voices: voices)
        onboardingStep = .googleCloudSuccess
    }

    private func handleOnboardingReviewDemoConnected(_ token: String, voices: [TTSVoice]) {
        saveAppReviewDemoAccess(token: token, voices: voices)
        onboardingStep = .googleCloudSuccess
    }

    private func continueFromGoogleCloudSuccess() {
        onboardingStep = .googleCloud
    }

    private func clearCredentials() {
        Preferences.shared.credentials = ""
        Preferences.shared.clearAppReviewDemoMode()
        credentials = ""
        isAppReviewDemoModeEnabled = false
        TextToSpeechClient.resetSharedInstances()
        api = nil
        availableVoices = []
        availableLanguages = []
        selectedVoice = nil
        result = ""
    }

    private func normalizeStoredHotkey() {
        saveHotkey(hotkey)
    }

    private func normalizeStoredSpeakingSpeed() {
        let normalizedSpeed = Preferences.shared.speakingSpeed
        if speakingSpeed != normalizedSpeed {
            speakingSpeed = normalizedSpeed
        }
    }

    private func saveHotkey(_ newHotkey: String) {
        let canonicalHotkey = HotkeyFormatter.canonicalize(newHotkey)
        Preferences.shared.hotkey = canonicalHotkey
        hotkey = canonicalHotkey
    }

    private func startEditingHotkey() {
        hotkeyCaptureTask?.cancel()
        hotkeyCaptureTask = Task { @MainActor in
            let capturedHotkey = await HotkeyManager.shared.hotkey?.waitForHotkey()
            guard !Task.isCancelled else { return }

            if let capturedHotkey, !capturedHotkey.isEmpty {
                saveHotkey(capturedHotkey)
            }

            hotkeyCaptureTask = nil
            editingHotkey = false
        }
    }

    private func stopEditingHotkey() {
        hotkeyCaptureTask?.cancel()
        hotkeyCaptureTask = nil
        HotkeyManager.shared.hotkey?.cancelHotkeyCapture()
        editingHotkey = false
    }

    private func startLoadVoicesTask(resetAPI: Bool) {
        loadVoicesTask?.cancel()
        loadVoicesTask = Task {
            loadVoices(resetAPI: resetAPI)
        }
    }

    private func loadVoices(resetAPI: Bool) {
        if resetAPI {
            TextToSpeechClient.resetSharedInstances()
        }

        isInitializing = true
        result = "Loading voices..."
        TextToSpeechClient.getInstance { apiResult in
            switch apiResult {
            case .success(let api):
                self.api = api
                api.fetchVoices { fetchResult in
                    DispatchQueue.main.async {
                        switch fetchResult {
                        case .success(let voices):
                            if voices.isEmpty {
                                result = "Google Cloud Text-to-Speech connected, but no voices were returned. Try again in a moment."
                            } else {
                                applyVoices(voices)
                                result = "Success! Ready to read aloud."
                            }
                        case .failure(let error):
                            self.availableVoices = []
                            self.availableLanguages = []
                            self.selectedVoice = nil
                            result = GoogleTTSError.userMessage(for: error)
                        }

                        isInitializing = false
                    }
                }
            case .failure(let error):
                DispatchQueue.main.async {
                    self.availableVoices = []
                    self.availableLanguages = []
                    self.selectedVoice = nil
                    result = GoogleTTSError.userMessage(for: error)
                    isInitializing = false
                }
            }
        }
    }

    private func applyVoices(_ voices: [TTSVoice]) {
        let selectableVoices = voices.filter(isSelectableGoogleVoice).sorted(by: compareVoicesByCategory)
        availableVoices = selectableVoices

        let allLanguages = Set(selectableVoices.flatMap { $0.languageCodes })
        availableLanguages = Array(allLanguages).sorted()

        if selectedVoice == nil ||
            !selectableVoices.contains(where: { $0.name == selectedVoice?.name }) ||
            selectedVoice.map(isVoiceLocked) == true {
            let savedVoiceName = Preferences.shared.voiceName
            if !savedVoiceName.isEmpty {
                if let savedVoice = selectableVoices.first(where: { $0.name == savedVoiceName }) {
                    if isVoiceLocked(savedVoice) {
                        deferredPremiumVoiceName = savedVoice.name
                        selectedLanguage = savedVoice.languageCodes.first ?? selectedLanguage
                    } else {
                        selectedVoice = savedVoice
                    }
                }

                if let voice = selectedVoice {
                    selectedLanguage = voice.languageCodes.first ?? "en-US"
                }
            }

            if selectedVoice == nil, let firstVoice = firstAccessibleVoice() {
                selectedVoice = firstVoice
                selectedLanguage = firstVoice.languageCodes.first ?? "en-US"
            }

            Preferences.shared.language = selectedLanguage
        }
    }

    private func applyAppReviewDemoDefaults() {
        inputText = String(Self.appReviewDemoSampleText.prefix(inputLimit))
        speakingSpeed = SpeakingSpeed.markerNormal
        Preferences.shared.speakingSpeed = SpeakingSpeed.markerNormal

        if let demoVoice = availableVoices.first(where: { $0.name == Self.appReviewDemoVoiceName }) {
            selectedVoice = demoVoice
            if demoVoice.languageCodes.contains(Self.appReviewDemoLanguage) {
                selectedLanguage = Self.appReviewDemoLanguage
            } else {
                selectedLanguage = demoVoice.languageCodes.first ?? Self.appReviewDemoLanguage
            }
        } else {
            if availableLanguages.contains(Self.appReviewDemoLanguage) {
                selectedLanguage = Self.appReviewDemoLanguage
            }

            selectedVoice = firstAccessibleVoice(in: filteredVoices)
        }

        Preferences.shared.voiceName = selectedVoice?.name ?? ""
        Preferences.shared.language = selectedLanguage
    }

    private func isSelectableGoogleVoice(_ voice: TTSVoice) -> Bool {
        voice.name.range(of: #"^[a-z]{2,3}-[A-Z]{2}-"#, options: .regularExpression) != nil
    }

    private func voiceMenuTitle(for voice: TTSVoice) -> String {
        if isVoiceLocked(voice) {
            return "\(voice.displayName) (Locked)"
        }

        return voice.displayName
    }

    private func isVoiceLocked(_ voice: TTSVoice) -> Bool {
        guard VoiceCategory(for: voice.name).requiresPremiumUnlock else {
            return false
        }

        switch purchaseManager.premiumVoicesEntitlementStatus {
        case .checking, .owned:
            return false
        case .notOwned:
            return !isAppReviewDemoModeEnabled
        }
    }

    private func firstAccessibleVoice(in voices: [TTSVoice]? = nil) -> TTSVoice? {
        let candidates = voices ?? filteredVoices
        return candidates.first { !isVoiceLocked($0) } ?? availableVoices.first { !isVoiceLocked($0) }
    }

    private func ensureSelectedVoiceIsAccessible() {
        if let selectedVoice, isVoiceLocked(selectedVoice) {
            self.selectedVoice = firstAccessibleVoice()
        } else if selectedVoice == nil {
            selectedVoice = firstAccessibleVoice()
        }
    }

    private func selectDeferredPremiumVoiceIfAvailable() {
        guard let deferredPremiumVoiceName,
              let voice = availableVoices.first(where: { $0.name == deferredPremiumVoiceName }),
              !isVoiceLocked(voice) else {
            return
        }

        self.deferredPremiumVoiceName = nil
        selectedVoice = voice
        selectedLanguage = voice.languageCodes.first ?? selectedLanguage
    }

    private func selectPendingLockedVoiceIfUnlocked() {
        guard purchaseManager.hasPremiumVoices,
              let voice = pendingLockedVoice else {
            return
        }

        pendingLockedVoice = nil
        isUnlockSheetPresented = false
        selectedVoice = voice
    }

    private func compareVoicesByCategory(_ lhs: TTSVoice, _ rhs: TTSVoice) -> Bool {
        let lhsCategory = VoiceCategory(for: lhs.name)
        let rhsCategory = VoiceCategory(for: rhs.name)

        if lhsCategory != rhsCategory {
            return lhsCategory.rawValue < rhsCategory.rawValue
        }

        return lhs.name < rhs.name
    }

    private func speakText(_ text: String) {
        SpeechManager.shared.speak(text)
    }
}

private struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
            )
    }
}

private struct SettingsRow<Content: View>: View {
    let symbolName: String
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 16) {
            IconTile(symbolName: symbolName, color: .primary)

            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 160, alignment: .leading)

            content
                .frame(maxWidth: .infinity)
        }
        .frame(minHeight: 44)
    }
}

private struct IconTile: View {
    let symbolName: String
    let color: Color

    var body: some View {
        Image(systemName: symbolName)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 44, height: 44)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
            )
    }
}

private struct PlaceholderValue: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            )
    }
}

private struct PremiumVoicesUnlockSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var purchaseManager: PurchaseManager

    let lockedVoice: TTSVoice?
    let onUnlocked: () -> Void

    private var priceText: String {
        purchaseManager.premiumVoicesProduct?.displayPrice ?? "$9.99"
    }

    private var contentLeadingInset: CGFloat {
        44 + 14
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                IconTile(symbolName: "lock.open.fill", color: .orange)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Unlock Premium Voices")
                        .font(.system(size: 24, weight: .bold, design: .rounded))

                    Text(lockedVoice?.displayName ?? "Premium Google voices")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            Text("Standard and WaveNet voices are free. Unlock Casual, Neural2, News, Polyglot, Chirp HD, Chirp3 HD, Studio, and other premium voices forever for \(priceText).")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, contentLeadingInset)

            if let statusMessage = purchaseManager.statusMessage {
                Text(statusMessage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, contentLeadingInset)
            }

            HStack(spacing: 10) {
                Spacer(minLength: 0)

                Button {
                    dismiss()
                } label: {
                    Label("Cancel", systemImage: "xmark")
                        .frame(minWidth: 112, minHeight: 30)
                }
                .controlSize(.large)

                Button {
                    Task {
                        await purchaseManager.restorePurchases()
                        if purchaseManager.hasPremiumVoices {
                            onUnlocked()
                            dismiss()
                        }
                    }
                } label: {
                    Label("Restore purchases", systemImage: "arrow.clockwise")
                        .frame(minWidth: 156, minHeight: 30)
                }
                .controlSize(.large)
                .disabled(purchaseManager.isLoading)

                Button {
                    Task {
                        await purchaseManager.purchasePremiumVoices()
                        if purchaseManager.hasPremiumVoices {
                            onUnlocked()
                            dismiss()
                        }
                    }
                } label: {
                    Label("Buy premium voices", systemImage: "cart.fill")
                        .frame(minWidth: 156, minHeight: 30)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.large)
                .disabled(purchaseManager.isLoading)
            }
            .padding(.top, 2)
        }
        .padding(24)
        .frame(width: 560, alignment: .leading)
        .onAppear {
            purchaseManager.clearStatusMessage()
        }
        .onChange(of: purchaseManager.hasPremiumVoices) { _, hasPremiumVoices in
            guard hasPremiumVoices else { return }
            onUnlocked()
            dismiss()
        }
    }
}

private struct StatusCard: View {
    let status: ReadyStatus

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: status.symbolName)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(status.color)
                .symbolEffect(.pulse, value: status.title)
                .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 4) {
                Text(status.title)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(status.color)

                Text(status.message)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 16)

            WaveformView(color: status.color)
                .frame(width: 118, height: 30)
                .opacity(status.title == "Ready" ? 0.7 : 0.25)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
        )
    }
}

private struct WaveformView: View {
    let color: Color

    private let samples: [CGFloat] = [0.2, 0.45, 0.25, 0.75, 0.18, 0.62, 0.28, 0.9, 0.3, 0.5, 0.2, 0.72, 0.34, 0.42, 0.24, 0.8, 0.22, 0.48, 0.28]

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let step = width / CGFloat(max(samples.count - 1, 1))

            Path { path in
                for index in samples.indices {
                    let x = CGFloat(index) * step
                    let y = height / 2 - ((samples[index] - 0.5) * height * 0.82)

                    if index == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
            }
            .stroke(color.opacity(0.52), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

private enum MandatoryOnboardingStep {
    case accessibility
    case accessibilitySuccess
    case googleCloud
    case googleCloudSuccess
}

private struct MandatoryOnboardingGate: View {
    let step: MandatoryOnboardingStep
    @ObservedObject var hotkeyManager: HotkeyManager
    let googleCloudErrorMessage: String?
    let onAccessibilityContinue: () -> Void
    let onGoogleCloudConnected: (String, [TTSVoice]) -> Void
    let onReviewDemoConnected: (String, [TTSVoice]) -> Void
    let onGoogleCloudContinue: () -> Void

    var body: some View {
        Group {
            switch step {
            case .accessibility:
                OnboardingPageShell(activeDot: 0) {
                    accessibilityVisual

                    Text("Enable assistive selected-text reading")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .multilineTextAlignment(.center)

                    Text("Smooth Talker uses macOS Accessibility to access the text you select in other apps. When you press your shortcut, Smooth Talker reads the selected text aloud, providing assistive reading support.")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(5)
                        .frame(maxWidth: 720)

                    Button {
                        hotkeyManager.requestAccessibilityPermission()
                    } label: {
                        Text("OPEN ACCESSIBILITY")
                            .font(.system(size: 15, weight: .bold))
                            .frame(minWidth: 190, minHeight: 42)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(.orange)
                    .keyboardShortcut(.defaultAction)
                    .padding(.top, 8)
                }

            case .accessibilitySuccess:
                OnboardingPageShell(activeDot: 0) {
                    OnboardingSuccessVisual(symbolName: "figure.wave")

                    Text("Assistive reading permission enabled")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 760)

                    Button {
                        onAccessibilityContinue()
                    } label: {
                        Text("CONTINUE")
                            .font(.system(size: 15, weight: .bold))
                            .frame(minWidth: 116, minHeight: 42)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(.orange)
                    .keyboardShortcut(.defaultAction)
                    .padding(.top, 14)
                }

            case .googleCloud:
                OnboardingPageShell(activeDot: 1) {
                    GoogleCloudOnboardingVisual()

                    Text("Set up Google Cloud Text-to-Speech")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .multilineTextAlignment(.center)

                    Text("Smooth Talker uses Google Cloud Text-to-Speech for natural voices. Connect Google Cloud to create and validate Text-to-Speech credentials automatically.")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                        .frame(maxWidth: 760)

                    if let googleCloudErrorMessage {
                        Label(googleCloudErrorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 660)
                    }

                    GoogleCloudSetupPanel(presentation: .onboarding) { credentials, voices in
                        onGoogleCloudConnected(credentials, voices)
                    } onReviewDemoSave: { token, voices in
                        onReviewDemoConnected(token, voices)
                    }
                    .frame(maxWidth: 620)
                    .padding(.top, 4)
                }

            case .googleCloudSuccess:
                OnboardingPageShell(activeDot: 1) {
                    OnboardingSuccessVisual(symbolName: "cloud.fill")

                    Text("Google Cloud Text-to-Speech setup complete")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 760)

                    Button {
                        onGoogleCloudContinue()
                    } label: {
                        Text("CONTINUE")
                            .font(.system(size: 15, weight: .bold))
                            .frame(minWidth: 116, minHeight: 42)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(.orange)
                    .keyboardShortcut(.defaultAction)
                    .padding(.top, 14)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var accessibilityVisual: some View {
        LoopingOnboardingVideoView(resourceName: "My Movie")
            .frame(width: 470, height: 264)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.08), radius: 18, y: 10)
            .padding(.bottom, 8)
    }
}

private struct OnboardingPageShell<Content: View>: View {
    let activeDot: Int
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            VStack(spacing: 18) {
                content
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 56)

            Spacer(minLength: 22)

            HStack(spacing: 8) {
                ForEach(0..<2, id: \.self) { index in
                    Circle()
                        .fill(index == activeDot ? Color.orange : Color.secondary.opacity(0.2))
                        .frame(width: 9, height: 9)
                }
            }
            .padding(.bottom, 46)
            .accessibilityHidden(true)
        }
    }
}

private struct OnboardingSuccessVisual: View {
    let symbolName: String

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.orange.opacity(0.08))
                .frame(width: 184, height: 184)

            Circle()
                .fill(Color.green.opacity(0.14))
                .frame(width: 128, height: 128)

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 76, weight: .bold))
                .foregroundStyle(.green)
                .shadow(color: .green.opacity(0.22), radius: 14, y: 8)

            Image(systemName: symbolName)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.orange)
                .offset(x: 58, y: -54)
        }
        .frame(width: 220, height: 190)
        .padding(.bottom, 8)
        .accessibilityHidden(true)
    }
}

private struct GoogleCloudOnboardingVisual: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .frame(width: 356, height: 190)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.08), radius: 18, y: 10)

            VStack(spacing: 18) {
                HStack(spacing: 8) {
                    Circle().fill(Color.red.opacity(0.35)).frame(width: 9, height: 9)
                    Circle().fill(Color.yellow.opacity(0.55)).frame(width: 9, height: 9)
                    Circle().fill(Color.green.opacity(0.45)).frame(width: 9, height: 9)
                    Spacer()
                }
                .frame(width: 300)

                HStack(spacing: 18) {
                    Image(systemName: "cloud.fill")
                        .font(.system(size: 58, weight: .semibold))
                        .foregroundStyle(.blue)

                    VStack(alignment: .leading, spacing: 10) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.secondary.opacity(0.24))
                            .frame(width: 150, height: 12)

                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.secondary.opacity(0.18))
                            .frame(width: 188, height: 12)

                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.orange.opacity(0.92))
                            .frame(width: 92, height: 24)
                    }
                }

                HStack(spacing: 10) {
                    Image(systemName: "key.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.orange)

                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                        .frame(width: 220, height: 30)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .stroke(Color.orange.opacity(0.45), lineWidth: 1)
                        )
                }
            }
        }
        .frame(width: 420, height: 220)
        .padding(.bottom, 6)
        .accessibilityHidden(true)
    }
}

private struct LoopingOnboardingVideoView: View {
    @StateObject private var playerModel: OnboardingVideoPlayerModel

    init(resourceName: String) {
        _playerModel = StateObject(wrappedValue: OnboardingVideoPlayerModel(resourceName: resourceName))
    }

    var body: some View {
        Group {
            if let player = playerModel.player {
                OnboardingPlayerView(player: player)
                    .onAppear {
                        playerModel.play()
                    }
                    .onDisappear {
                        playerModel.pause()
                    }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "film")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.secondary)

                    Text("Open Accessibility Settings, add Smooth Talker, then turn on assistive reading access.")
                        .font(.system(size: 12, weight: .medium))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 18)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .controlBackgroundColor))
            }
        }
    }
}

@MainActor
private final class OnboardingVideoPlayerModel: ObservableObject {
    let player: AVQueuePlayer?
    private var playerLooper: AVPlayerLooper?

    init(resourceName: String) {
        let videoURL = Bundle.main.url(forResource: resourceName, withExtension: "mp4", subdirectory: "Resources") ??
            Bundle.main.url(forResource: resourceName, withExtension: "mp4")

        guard let videoURL else {
            player = nil
            return
        }

        let playerItem = AVPlayerItem(url: videoURL)
        let player = AVQueuePlayer()
        player.isMuted = true

        self.player = player
        playerLooper = AVPlayerLooper(player: player, templateItem: playerItem)
    }

    func play() {
        player?.seek(to: .zero)
        player?.play()
    }

    func pause() {
        player?.pause()
    }
}

private struct OnboardingPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.player = player
        playerView.controlsStyle = .none
        playerView.videoGravity = .resizeAspectFill
        return playerView
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
    }
}

private enum CredentialValidationState {
    case idle
    case validating(String)
    case success(String)
    case failure(String)

    var isValidating: Bool {
        if case .validating = self {
            return true
        }

        return false
    }
}

private struct CredentialsSetupSheet: View {
    let onSave: (String, [TTSVoice]) -> Void
    let onReviewDemoSave: (String, [TTSVoice]) -> Void

    var body: some View {
        GoogleCloudSetupPanel(presentation: .compactSheet, onSave: onSave, onReviewDemoSave: onReviewDemoSave)
    }
}

private enum GoogleCloudSetupPresentation {
    case compactSheet
    case onboarding
}

private struct GoogleCloudSetupPanel: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var automaticSetup = GoogleCloudSetupModel()
    @State private var validationState: CredentialValidationState = .idle
    @State private var isReviewDemoCodeVisible = false
    @State private var reviewDemoCode = ""
    let presentation: GoogleCloudSetupPresentation
    let onSave: (String, [TTSVoice]) -> Void
    let onReviewDemoSave: (String, [TTSVoice]) -> Void

    init(
        presentation: GoogleCloudSetupPresentation,
        onSave: @escaping (String, [TTSVoice]) -> Void,
        onReviewDemoSave: @escaping (String, [TTSVoice]) -> Void
    ) {
        self.presentation = presentation
        self.onSave = onSave
        self.onReviewDemoSave = onReviewDemoSave
    }

    var body: some View {
        Group {
            switch presentation {
            case .compactSheet:
                compactBody
            case .onboarding:
                onboardingBody
            }
        }
        .onChange(of: automaticSetup.generatedCredentialsJSON) { _, credentialsJSON in
            guard let credentialsJSON else { return }
            automaticSetup.resetGeneratedCredentials()
            validateAndConnect(credentialsJSON)
        }
    }

    private var compactBody: some View {
        VStack(alignment: .trailing, spacing: 14) {
            setupStatus

            HStack(spacing: 8) {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                setupButton
            }

            reviewDemoSection
        }
        .padding(24)
        .frame(width: 360)
    }

    private var onboardingBody: some View {
        VStack(spacing: 12) {
            setupStatus
                .frame(maxWidth: 560)

            setupButton

            reviewDemoSection
        }
    }

    private var setupButton: some View {
        Button {
            connect()
        } label: {
            Text(setupButtonTitle)
                .font(.system(size: 15, weight: .bold))
                .frame(minWidth: presentation == .onboarding ? 190 : 0, minHeight: presentation == .onboarding ? 42 : 0)
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
        .controlSize(presentation == .onboarding ? .large : .regular)
        .tint(.orange)
        .disabled(isConnectDisabled)
    }

    private var reviewDemoSection: some View {
        VStack(alignment: presentation == .onboarding ? .center : .trailing, spacing: 8) {
            Button("App Review Demo") {
                validationState = .idle
                isReviewDemoCodeVisible.toggle()
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .disabled(isConnectDisabled)

            if isReviewDemoCodeVisible {
                HStack(spacing: 8) {
                    SecureField("Demo code", text: $reviewDemoCode)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: presentation == .onboarding ? 260 : 190)

                    Button("Start Demo") {
                        connectReviewDemo()
                    }
                    .disabled(isConnectDisabled || reviewDemoCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .frame(maxWidth: .infinity, alignment: presentation == .onboarding ? .center : .trailing)
            }
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private var setupStatus: some View {
        if let status = currentSetupStatus {
            Label(status.message, systemImage: status.symbolName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(status.color)
                .multilineTextAlignment(presentation == .onboarding ? .center : .leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: presentation == .onboarding ? .center : .leading)
        }
    }

    private var currentSetupStatus: (message: String, symbolName: String, color: Color)? {
        switch validationState {
        case .idle:
            break
        case .validating(let message):
            return (message, "arrow.triangle.2.circlepath", .orange)
        case .success(let message):
            return (message, "checkmark.circle.fill", .green)
        case .failure(let message):
            return (message, "exclamationmark.triangle.fill", .red)
        }

        switch automaticSetup.stage {
        case .idle:
            if presentation == .onboarding {
                return (automaticSetup.statusMessage, "cloud.fill", .secondary)
            }

            return nil
        case .waitingForBilling:
            return (automaticSetup.statusMessage, "creditcard.fill", .orange)
        case .readyToValidate:
            return (automaticSetup.statusMessage, "arrow.triangle.2.circlepath", .orange)
        case .failed(let message):
            return (message, "exclamationmark.triangle.fill", .red)
        default:
            if automaticSetup.stage.isBusy {
                return (automaticSetup.statusMessage, "arrow.triangle.2.circlepath", .orange)
            }

            return nil
        }
    }

    private var isConnectDisabled: Bool {
        automaticSetup.stage.isBusy ||
            validationState.isValidating
    }

    private var setupButtonTitle: String {
        switch presentation {
        case .compactSheet:
            return "Connect"
        case .onboarding:
            return "CONNECT GOOGLE CLOUD"
        }
    }

    private func connect() {
        validationState = .idle
        automaticSetup.startAutomaticSetup()
    }

    private func connectReviewDemo() {
        let token = reviewDemoCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            validationState = .failure("Enter the App Review demo code.")
            return
        }

        validationState = .validating("Connecting App Review demo...")
        ReviewDemoTTSAPI.resetSharedInstance()
        ReviewDemoTTSAPI.getInstance(token: token) { api in
            api.fetchVoices { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let voices):
                        guard !voices.isEmpty else {
                            validationState = .failure("App Review demo connected, but no voices were returned. Try again in a moment.")
                            return
                        }

                        onReviewDemoSave(token, voices)
                        validationState = .success("App Review demo connected.")
                    case .failure(let error):
                        validationState = .failure(GoogleTTSError.userMessage(for: error))
                        ReviewDemoTTSAPI.resetSharedInstance()
                    }
                }
            }
        }
    }

    private func validateAndConnect(_ credentialsJSON: String) {
        let trimmedCredentials = credentialsJSON.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            let info = try GoogleServiceAccountCredentials.validate(trimmedCredentials)
            validationState = .validating("Finalizing Google Cloud Text-to-Speech setup for \(info.projectID)...")
        } catch {
            validationState = .failure(error.localizedDescription)
            return
        }

        fetchVoicesWithRetry(credentialsJSON: trimmedCredentials, attempt: 1)
    }

    private func fetchVoicesWithRetry(credentialsJSON: String, attempt: Int) {
        GoogleTTSAPI.resetSharedInstance()
        GoogleTTSAPI.getInstance(credentialsJson: credentialsJSON) { api in
            api.fetchVoices { result in
                DispatchQueue.main.async {
                    handleVoiceValidationResult(result, credentialsJSON: credentialsJSON, attempt: attempt)
                }
            }
        }
    }

    private func handleVoiceValidationResult(_ result: Result<[TTSVoice], Error>, credentialsJSON: String, attempt: Int) {
        switch result {
        case .success(let voices):
            guard !voices.isEmpty else {
                retryOrFail(
                    credentialsJSON: credentialsJSON,
                    attempt: attempt,
                    message: "Google Cloud Text-to-Speech connected, but voices are still loading. Trying again..."
                )
                return
            }

            onSave(credentialsJSON, voices)
            validationState = .success("Connected to Google Cloud Text-to-Speech.")
        case .failure(let error):
            if shouldRetryValidation(error), attempt < 5 {
                retryOrFail(
                    credentialsJSON: credentialsJSON,
                    attempt: attempt,
                    message: "Google Cloud Text-to-Speech is finishing setup. Trying again..."
                )
            } else {
                validationState = .failure(GoogleTTSError.userMessage(for: error))
                GoogleTTSAPI.resetSharedInstance()
            }
        }
    }

    private func retryOrFail(credentialsJSON: String, attempt: Int, message: String) {
        guard attempt < 5 else {
            validationState = .failure("Google Cloud Text-to-Speech connected, but no voices were returned. Try again in a moment.")
            GoogleTTSAPI.resetSharedInstance()
            return
        }

        validationState = .validating(message)
        let delay = DispatchTime.now() + .seconds(attempt * 2)
        DispatchQueue.main.asyncAfter(deadline: delay) {
            fetchVoicesWithRetry(credentialsJSON: credentialsJSON, attempt: attempt + 1)
        }
    }

    private func shouldRetryValidation(_ error: Error) -> Bool {
        if let googleError = error as? GoogleTTSError {
            switch googleError {
            case .httpError(let code, let body):
                let searchable = body?.lowercased() ?? ""
                return code == 403 ||
                    code == 404 ||
                    code == 429 ||
                    (500...599).contains(code) ||
                    searchable.contains("disabled") ||
                    searchable.contains("not been used") ||
                    searchable.contains("billing") ||
                    searchable.contains("permission")
            case .noToken, .invalidResponse, .noData:
                return true
            default:
                return false
            }
        }

        if let urlError = error as? URLError {
            return urlError.code == .timedOut ||
                urlError.code == .cannotFindHost ||
                urlError.code == .cannotConnectToHost ||
                urlError.code == .networkConnectionLost
        }

        return false
    }
}

private struct ReadyStatus {
    let title: String
    let message: String
    let symbolName: String
    let color: Color
}

private enum ConnectionStatus {
    case connected
    case loading
    case notConfigured
    case error

    var title: String {
        switch self {
        case .connected:
            return "Connected"
        case .loading:
            return "Loading"
        case .notConfigured:
            return "Not configured"
        case .error:
            return "Connection issue"
        }
    }

    var symbolName: String {
        switch self {
        case .connected:
            return "checkmark.icloud.fill"
        case .loading:
            return "icloud.and.arrow.down.fill"
        case .notConfigured:
            return "icloud.slash.fill"
        case .error:
            return "exclamationmark.icloud.fill"
        }
    }

    var color: Color {
        switch self {
        case .connected:
            return .green
        case .loading:
            return .orange
        case .notConfigured:
            return .secondary
        case .error:
            return .red
        }
    }
}

private struct OrangeProminentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.orange.gradient)
            )
            .shadow(color: .orange.opacity(configuration.isPressed ? 0.1 : 0.18), radius: configuration.isPressed ? 3 : 8, y: configuration.isPressed ? 1 : 3)
            .opacity(isEnabled ? (configuration.isPressed ? 0.86 : 1) : 0.48)
    }
}

private struct VoiceGroup: Identifiable {
    let category: VoiceCategory
    let voices: [TTSVoice]

    var id: VoiceCategory { category }
}

enum VoiceCategory: Int, CaseIterable {
    case standard
    case waveNet
    case casual
    case neural2
    case news
    case polyglot
    case chirpHD
    case chirp3HD
    case studio
    case other

    init(for voiceName: String) {
        if voiceName.contains("-Standard-") {
            self = .standard
        } else if voiceName.contains("-Wavenet-") || voiceName.contains("-WaveNet-") {
            self = .waveNet
        } else if voiceName.contains("-Casual-") {
            self = .casual
        } else if voiceName.contains("-Neural2-") {
            self = .neural2
        } else if voiceName.contains("-News-") {
            self = .news
        } else if voiceName.contains("-Polyglot-") {
            self = .polyglot
        } else if voiceName.contains("-Chirp-HD-") {
            self = .chirpHD
        } else if voiceName.contains("-Chirp3-HD-") {
            self = .chirp3HD
        } else if voiceName.contains("-Studio-") {
            self = .studio
        } else {
            self = .other
        }
    }

    var title: String {
        switch self {
        case .standard:
            return "Standard"
        case .waveNet:
            return "WaveNet"
        case .casual:
            return "Casual"
        case .neural2:
            return "Neural2"
        case .news:
            return "News"
        case .polyglot:
            return "Polyglot"
        case .chirpHD:
            return "Chirp HD"
        case .chirp3HD:
            return "Chirp3 HD"
        case .studio:
            return "Studio"
        case .other:
            return "Other"
        }
    }

    var isFree: Bool {
        self == .standard || self == .waveNet
    }

    var requiresPremiumUnlock: Bool {
        !isFree
    }
}

private struct LimitedTextField: NSViewRepresentable {
    @Binding var text: String
    let characterLimit: Int
    let placeholder: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, characterLimit: characterLimit)
    }

    func makeNSView(context: Context) -> NSTextField {
        let textField = NSTextField(string: String(text.prefix(characterLimit)))
        textField.placeholderString = placeholder
        textField.delegate = context.coordinator
        textField.formatter = CharacterLimitFormatter(characterLimit: characterLimit)
        textField.font = .systemFont(ofSize: 16)
        textField.isBordered = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.lineBreakMode = .byTruncatingTail
        textField.cell?.usesSingleLineMode = true
        textField.cell?.truncatesLastVisibleLine = true
        return textField
    }

    func updateNSView(_ textField: NSTextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.characterLimit = characterLimit

        if let formatter = textField.formatter as? CharacterLimitFormatter {
            formatter.characterLimit = characterLimit
        } else {
            textField.formatter = CharacterLimitFormatter(characterLimit: characterLimit)
        }

        let limitedText = String(text.prefix(characterLimit))
        if text != limitedText {
            text = limitedText
        }

        guard textField.currentEditor() == nil, textField.stringValue != limitedText else {
            return
        }

        textField.stringValue = limitedText
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var characterLimit: Int

        init(text: Binding<String>, characterLimit: Int) {
            self.text = text
            self.characterLimit = characterLimit
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else {
                return
            }

            let limitedText = String(textField.stringValue.prefix(characterLimit))
            if textField.stringValue != limitedText {
                textField.stringValue = limitedText
                textField.currentEditor()?.string = limitedText
                textField.currentEditor()?.selectedRange = NSRange(location: (limitedText as NSString).length, length: 0)
            }

            if text.wrappedValue != limitedText {
                text.wrappedValue = limitedText
            }
        }
    }
}

private final class CharacterLimitFormatter: Formatter {
    var characterLimit: Int

    init(characterLimit: Int) {
        self.characterLimit = characterLimit
        super.init()
    }

    required init?(coder: NSCoder) {
        characterLimit = 0
        super.init(coder: coder)
    }

    override func string(for obj: Any?) -> String? {
        guard let string = obj as? String else {
            return nil
        }

        return String(string.prefix(characterLimit))
    }

    override func getObjectValue(
        _ obj: AutoreleasingUnsafeMutablePointer<AnyObject?>?,
        for string: String,
        errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?
    ) -> Bool {
        obj?.pointee = String(string.prefix(characterLimit)) as NSString
        return true
    }

    override func isPartialStringValid(
        _ partialStringPtr: AutoreleasingUnsafeMutablePointer<NSString>,
        proposedSelectedRange proposedSelRangePtr: NSRangePointer?,
        originalString origString: String,
        originalSelectedRange origSelRange: NSRange,
        errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?
    ) -> Bool {
        let proposedString = partialStringPtr.pointee as String
        guard proposedString.count > characterLimit else {
            return true
        }

        let limitedString = String(proposedString.prefix(characterLimit))
        partialStringPtr.pointee = limitedString as NSString
        proposedSelRangePtr?.pointee = NSRange(location: (limitedString as NSString).length, length: 0)
        return false
    }
}

#Preview {
    ContentView()
}
