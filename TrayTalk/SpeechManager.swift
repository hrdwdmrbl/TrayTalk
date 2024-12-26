//
//  SpeechManager.swift
//  TrayTalk
//
//  Created by Sem Visscher on 24/12/2024.
//

import Foundation
import AVFAudio
import AVFoundation
import Cocoa

class SpeechManager {
    static let shared = SpeechManager()
    
    private var currentRequest: Task<Void, Never>?
    private var audioPlayer = AudioPlayer()
    private var audioData: Data?
    var appDelegate: AppDelegate?
    
    private init() {}
    
    func speak(_ text: String) {
        DispatchQueue.main.async {
            self.appDelegate?.setTrayLoading(true)
        }
        // Cancel any existing request
        currentRequest?.cancel()
        audioPlayer.stop()
        
        
        if Preferences.shared.voiceName.isEmpty {
            return
        }
        
        // Create new task for the request
        currentRequest = Task {
            GoogleTTSAPI.getInstance(credentialsJson: Preferences.shared.credentials) { api in
                // Check if task was cancelled
                if Task.isCancelled { return }
                
                api.getAudio(text: text,
                             language: Preferences.shared.language,
                             voiceName: Preferences.shared.voiceName,
                             speed: Preferences.shared.speakingSpeed,
                             pitch: Preferences.shared.speakingPitch,
                             effect: Preferences.shared.effect
                ) { result in
                    // Check if task was cancelled
                    if Task.isCancelled { return }
                        
                    switch result {
                    case .success(let data):
                        self.audioData = data
                        self.audioPlayer.play(data: data)
                        DispatchQueue.main.async {
                            self.appDelegate?.setTrayLoading(false)
                        }
                    case .failure(let error):
                        print("\(error.localizedDescription)")
                    }
                }
            }
        }

    }
}


class AudioPlayer: ObservableObject {
    private var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var tempURL: URL?

    func play(data: Data) {
        // Stop any existing playback
        stop()

        do {
            // Write data to a temporary file for faster initialization
            let tempDirectory = FileManager.default.temporaryDirectory
            let fileURL = tempDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp3")
            try data.write(to: fileURL)
            tempURL = fileURL

            print("Creating and preparing player using file")
            // Create a player item using the temporary file
            playerItem = AVPlayerItem(url: fileURL)
            player = AVPlayer(playerItem: playerItem)
            Task {
                player?.defaultRate = Float(Preferences.shared.speakingSpeed)
                player?.automaticallyWaitsToMinimizeStalling = false
                
                // Start playback immediately
                player?.play()
            }

            print("Playback started")
        } catch {
            print("Failed to play audio: \(error)")
        }
    }

    func stop() {
        if let player = player {
            print("Stopping playback")
            player.pause() // Pause playback
        }
        player = nil
        playerItem = nil

        // Clean up the temporary file
        if let tempURL = tempURL {
            do {
                try FileManager.default.removeItem(at: tempURL)
                print("Temporary file removed")
            } catch {
                print("Failed to remove temporary file: \(error)")
            }
        }
        tempURL = nil
    }
}
