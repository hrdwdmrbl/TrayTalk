//
//  ContentView.swift
//  TrayTalk
//
//  Created by Sem Visscher on 24/12/2024.
//

import SwiftUI
import AVFoundation

struct ContentView: View {
    @AppStorage("credentials") private var credentials = ""
    @AppStorage("inputText") private var inputText = "Have a nice day!"
    @State private var result: String = ""
    @State private var isLoading = false
    @State private var isInitializing = false
    @State private var selectedVoice: TTSVoice?
    @AppStorage("speakingSpeed") private var speakingSpeed = 1.0
    @AppStorage("speakingPitch") private var speakingPitch = 0.0
    @State private var api: GoogleTTSAPI?
    @State private var availableVoices: [TTSVoice] = []
    @State private var selectedLanguage: String = "en-US"
    @State private var availableLanguages: [String] = []
    @EnvironmentObject private var hotkeyManager: HotkeyManager
    @AppStorage("selectedEffect") private var selectedEffect = AudioEffect.none
    @AppStorage("hotkey") private var hotkey = "option + `"
    @State private var editingHotkey = false
    @State private var currentRequest: Task<Void, Never>?
    @FocusState private var apiFocused: Bool
    @State var loadVoicesTask: Task<Void, Never>?
    
    var filteredVoices: [TTSVoice] {
        if selectedLanguage.isEmpty {
            return availableVoices
        }
        return availableVoices.filter { voice in
            voice.languageCodes.contains(selectedLanguage)
        }
    }
    
    var body: some View {
        VStack(spacing: 20) {
            Group {
                VStack(alignment: .leading) {
                    Text("Google Cloud service account (json):")
                    TextEditor(text: $credentials)
                        .frame(height: 100)
                        .font(.system(.body, design: .monospaced))
                        .border(Color.gray, width: 1)
                        .focused($apiFocused)
                }
                
                HStack(spacing: 8) {
                    TextField("Enter text to speak", text: $inputText)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                    
                    Button(action: {
                        speakText(inputText)
                    }) {
                            Text("Test")
                                .frame(width: 80)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(credentials.isEmpty || inputText.isEmpty || isLoading || isInitializing || selectedVoice == nil)
                }
            }
            .padding(.horizontal)
            
            VStack(alignment: .leading, spacing: 12) {
                Group {
                    Text("Language:")
                        .bold()
                    if availableLanguages.isEmpty {
                        Text("Loading languages...")
                            .foregroundColor(.gray)
                    } else {
                        Picker("Language", selection: $selectedLanguage) {
                            Text("All Languages").tag("")
                            ForEach(availableLanguages, id: \.self) { language in
                                Text(language).tag(language)
                            }
                        }
                        .pickerStyle(MenuPickerStyle())
                        .onChange(of: selectedLanguage) {
                            selectedVoice = nil
                        }
                    }
                    
                    Text("Voice:")
                        .bold()
                    if availableVoices.isEmpty {
                        Text("Loading voices...")
                            .foregroundColor(.gray)
                    } else {
                        Picker("Voice", selection: $selectedVoice) {
                            ForEach(filteredVoices, id: \.name) { voice in
                                Text(voice.displayName).tag(voice as TTSVoice?)
                            }
                        }
                        .pickerStyle(MenuPickerStyle())
                    }
                    
                    Text("Audio Effect:")
                        .bold()
                    Picker("Audio Effect", selection: $selectedEffect) {
                        ForEach(AudioEffect.allCases, id: \.self) { effect in
                            Text(effect.displayName).tag(effect)
                        }
                    }
                    .pickerStyle(MenuPickerStyle())
                }
                
                Group {
                    Text("Speaking Speed: \(speakingSpeed, specifier: "%.2f")x")
                        .bold()
                    Slider(value: $speakingSpeed, in: 0.25...4.0)
                    
                    Text("Pitch: \(speakingPitch, specifier: "%.1f")")
                        .bold()
                    Slider(value: $speakingPitch, in: -20.0...20.0, step: 0.5)
                }
                
                Group {
                    Button(editingHotkey ? "Press keys" : "Hotkey: \(hotkey)") {
                        editingHotkey = true
                    }
                }
            }
            .padding(.horizontal)
            
            if !result.isEmpty {
                Text(result)
                    .foregroundColor(result.contains("Error") ? .red : .green)
                    .multilineTextAlignment(.center)
            }
            
            Spacer()
            
            Text("Press \(hotkey) to speak selected text")
                .font(.caption)
                .foregroundColor(.gray)
        }
        .padding(.vertical)
        .frame(minWidth: 400, minHeight: 600)
        .onAppear {
            if !credentials.isEmpty && availableVoices.isEmpty {
                startLoadVoicesTask()
            }
        }
        .onChange(of: credentials) { _, newValue in
            if !newValue.isEmpty {
                startLoadVoicesTask()
            }
        }
        .onChange(of: selectedVoice, {_, newValue in
            Preferences.shared.voiceName = selectedVoice?.name ?? ""
            Preferences.shared.language = selectedVoice?.languageCodes.first ?? "unknown"
            print("changed voice")
        })
        .onChange(of: editingHotkey) { _, newValue in
            if newValue {
                apiFocused = false

                Task {
                    // listen for keydown events
                    hotkey = (await HotkeyManager.shared.hotkey?.waitForHotkey()) ?? ""
                    editingHotkey = false
                }
            }
        }
    }
    
    private func startLoadVoicesTask() {
        loadVoicesTask?.cancel()
        loadVoicesTask = Task {
            loadVoices()
        }
    }
    
    private func loadVoices() {
        isInitializing = true
        result = "Loading voices..."
        GoogleTTSAPI.getInstance(credentialsJson: credentials) { api in
            self.api = api
            api.fetchVoices { voices in
                DispatchQueue.main.async {
                    self.availableVoices = voices.sorted { v1, v2 in
                        v1.name < v2.name
                    }
                    
                    // Extract unique languages
                    let allLanguages = Set(voices.flatMap { $0.languageCodes })
                    self.availableLanguages = Array(allLanguages).sorted()
                    
                    // Try to restore previous voice selection
                    if self.selectedVoice == nil {
                        let savedVoiceName = Preferences.shared.voiceName
                        if !savedVoiceName.isEmpty {
                            self.selectedVoice = voices.first { $0.name == savedVoiceName }
                            // If we found a saved voice, set its language
                            if let voice = self.selectedVoice {
                                self.selectedLanguage = voice.languageCodes.first ?? "en-US"
                            }
                        }
                        // If no saved voice or saved voice not found, default to first voice
                        if self.selectedVoice == nil, let firstVoice = voices.first {
                            self.selectedVoice = firstVoice
                            self.selectedLanguage = firstVoice.languageCodes.first ?? "en-US"
                        }
                        
                        Preferences.shared.language = selectedLanguage
                    }
                    if voices.isEmpty {
                        result = "Failed to fetch voices, is the API key correct?"
                    } else {
                        result = "Success! Ready to play"
                    }
                                        
                    isInitializing = false
                }
            }
        }
    }
    
    private func speakText(_ text: String) {
        SpeechManager.shared.speak(text)
    }
}


#Preview {
    ContentView()
}
