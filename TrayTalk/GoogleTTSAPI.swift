//
//  api.swift
//  TrayTalk
//
//  Created by Sem Visscher on 24/12/2024.
//

import Foundation
import OAuth2

struct TTSVoice: Hashable, Codable {
    let name: String
    let languageCodes: [String]
    let ssmlGender: String
    let naturalSampleRateHertz: Int
    
    var displayName: String {
        // Just use the name from the API and gender
        return "\(name) (\(ssmlGender.lowercased()))"
    }
}

struct VoicesResponse: Codable {
    let voices: [TTSVoice]
}


enum AudioEffect: String, CaseIterable {
    case none = ""
    case wearable = "wearable-class-device"
    case handset = "handset-class-device"
    case headphone = "headphone-class-device"
    case smallSpeaker = "small-bluetooth-speaker-class-device"
    case mediumSpeaker = "medium-bluetooth-speaker-class-device"
    case largeSpeaker = "large-home-entertainment-class-device"
    case carSpeaker = "large-automotive-class-device"
    case telephony = "telephony-class-application"
    
    var displayName: String {
        switch self {
        case .none: return "No Effect"
        case .wearable: return "Wearable"
        case .handset: return "Handset"
        case .headphone: return "Headphone"
        case .smallSpeaker: return "Small Speaker"
        case .mediumSpeaker: return "Medium Speaker"
        case .largeSpeaker: return "Large Speaker"
        case .carSpeaker: return "Car Speaker"
        case .telephony: return "Telephony"
        }
    }
}


enum GoogleTTSError: LocalizedError {
    case invalidURL
    case invalidCredentials
    case authenticationFailed(String)
    case noToken
    case invalidResponse
    case httpError(Int, String?)
    case noData
    case jsonEncodingError
    
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .invalidCredentials:
            return "Invalid credentials data"
        case .authenticationFailed(let message):
            return "Authentication failed: \(message)"
        case .noToken:
            return "No token received"
        case .invalidResponse:
            return "Invalid response from server"
        case .httpError(let code, let body):
            if let body = body {
                return "HTTP Error \(code): \(body)"
            }
            return "HTTP Error \(code)"
        case .noData:
            return "No data received"
        case .jsonEncodingError:
            return "Failed to encode request body"
        }
    }
}


class GoogleTTSAPI {
    // Singleton instance
    private static var shared: GoogleTTSAPI?
    
    private let credentials: String
    private let baseURL = "https://texttospeech.googleapis.com/v1/text:synthesize"
    private let scope = "https://www.googleapis.com/auth/cloud-platform"
    private let voicesURL = "https://texttospeech.googleapis.com/v1/voices"
    
    // Cache for the access token
    private var _cachedToken: String?
    private var tokenExpirationDate: Date?
    private var isInitializing = false
    private var initializationCompletion: (() -> Void)?
    
    private var voices: [TTSVoice] = []
    
    var cachedToken: String? {
        if isTokenValid() {
            return _cachedToken
        }
        return nil
    }
    
    static func getInstance(credentialsJson: String, completion: @escaping (GoogleTTSAPI) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            if let existing = shared {
                DispatchQueue.main.async {
                    completion(existing)
                }
                return
            }
            
            let api = GoogleTTSAPI(credentialsJson: credentialsJson)
            shared = api
            
            api.initializeToken {
                DispatchQueue.main.async {
                    completion(api)
                }
            }
        }
    }
    
    private init(credentialsJson: String) {
        self.credentials = credentialsJson
    }
    
    private func initializeToken(completion: @escaping () -> Void) {
        if isInitializing {
            initializationCompletion = completion
            return
        }
        
        isInitializing = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.getAccessToken { result in
                DispatchQueue.main.async {
                    self?.isInitializing = false
                    self?.initializationCompletion?()
                    self?.initializationCompletion = nil
                    completion()
                }
            }
        }
    }
    
    private func isTokenValid() -> Bool {
        guard let expirationDate = tokenExpirationDate,
              let _ = _cachedToken else {
            return false
        }
        
        // Add a 5-minute buffer to ensure token doesn't expire during use
        let bufferedDate = expirationDate.addingTimeInterval(-300)
        return bufferedDate > Date()
    }
    
    private func getAccessToken(completion: @escaping (Result<String, Error>) -> Void) {
        print("Getting access token...")
        
        // Check if we have a valid cached token
        if let token = cachedToken, isTokenValid() {
            print("Using cached token")
            completion(.success(token))
            return
        }
        
        guard let credentialsData = credentials.data(using: .utf8) else {
            print("Failed to convert credentials to data")
            completion(.failure(GoogleTTSError.invalidCredentials))
            return
        }
        
        print(credentialsData)
        
        guard let authentication = ServiceAccountTokenProvider(
            credentialsData: credentialsData,
            scopes: [scope]
        ) else {
            print("Failed to create authentication provider")
            completion(.failure(GoogleTTSError.authenticationFailed("Failed to create token provider")))
            return
        }
        
        print("Requesting new token...")
        try! authentication.withToken { [weak self] token, error in
            if let error = error {
                print("Token error: \(error.localizedDescription)")
                completion(.failure(GoogleTTSError.authenticationFailed(error.localizedDescription)))
                return
            }
            
            guard let token = token,
                  let accessToken = token.AccessToken else {
                print("No token received")
                completion(.failure(GoogleTTSError.noToken))
                return
            }
            
            // Cache the new token and its expiration date
            self?._cachedToken = accessToken
            if let expiresIn = token.ExpiresIn {
                self?.tokenExpirationDate = Date().addingTimeInterval(TimeInterval(expiresIn))
            }
            
            print("Got new access token: \(accessToken.prefix(10))...")
            completion(.success(accessToken))
        }
    }
    
    func getAudio(text: String, language: String, voiceName: String, speed: Double, pitch: Double, effect: AudioEffect = .none, completion: @escaping (Result<Data, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            print("Starting getAudio for text: \(text) with voice: \(voiceName) at speed: \(speed) and pitch: \(pitch)")
            self?.getAccessToken { result in
                switch result {
                case .success(let token):
                    print("Proceeding with audio request using token")
                    self?.performAudioRequest(with: token,
                                              text: text,
                                              language: language,
                                              voiceName: voiceName,
                                              speed: speed,
                                              pitch: pitch,
                                              effect: effect,
                                              completion: completion)
                case .failure(let error):
                    print("Token acquisition failed: \(error)")
                    DispatchQueue.main.async {
                        completion(.failure(error))
                    }
                }
            }
        }
    }
    
    private func performAudioRequest(with token: String, text: String, language: String, voiceName: String, speed: Double, pitch: Double, effect: AudioEffect = .none, completion: @escaping (Result<Data, Error>) -> Void) {
        print("Starting audio request...")
        guard let url = URL(string: baseURL) else {
            print("Invalid URL: \(baseURL)")
            completion(.failure(GoogleTTSError.invalidURL))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        var audioConfig: [String: Any] = [
            "audioEncoding": "MP3",
            // "speakingRate": speed, // we are speeding it up afterwards for better quality
            "speakingRate": 1.0,
            "pitch": pitch
        ]
        
        if effect != .none {
            audioConfig["effectsProfileId"] = [effect.rawValue]
        }
        
        let requestBody: [String: Any] = [
            "input": [
                "text": text
            ],
            "voice": [
                "languageCode": language,
                "name": voiceName
            ],
            "audioConfig": audioConfig
        ]

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: requestBody)
            request.httpBody = jsonData
            print("Request body prepared: \(String(data: jsonData, encoding: .utf8) ?? "")")
        } catch {
            print("JSON encoding error: \(error)")
            completion(.failure(GoogleTTSError.jsonEncodingError))
            return
        }

        print("Creating URLSession task...")
        let task = URLSession.shared.dataTask(with: request) { (data, response, error) in
            DispatchQueue.main.async {
                print("Received response from server")
                if let error = error {
                    print("Network error: \(error)")
                    completion(.failure(error))
                    return
                }
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    print("Invalid response type")
                    completion(.failure(GoogleTTSError.invalidResponse))
                    return
                }
                
                print("Got response with status code: \(httpResponse.statusCode)")
                print("Response headers: \(httpResponse.allHeaderFields)")
                
                guard (200...299).contains(httpResponse.statusCode) else {
                    let errorBody = data.flatMap { String(data: $0, encoding: .utf8) }
                    print("HTTP error \(httpResponse.statusCode): \(errorBody ?? "no error body")")
                    completion(.failure(GoogleTTSError.httpError(httpResponse.statusCode, errorBody)))
                    return
                }
                
                guard let data = data else {
                    print("No data in response")
                    completion(.failure(GoogleTTSError.noData))
                    return
                }
                
                do {
                    // Parse the JSON response
                    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let audioContent = json["audioContent"] as? String,
                          let audioData = Data(base64Encoded: audioContent) else {
                        print("Failed to extract audio content from response")
                        completion(.failure(GoogleTTSError.invalidResponse))
                        return
                    }
                    
                    print("Success! Decoded \(audioData.count) bytes of audio data")
                    completion(.success(audioData))
                } catch {
                    print("JSON parsing error: \(error)")
                    completion(.failure(error))
                }
            }
        }
        
        print("Resuming task...")
        task.resume()
        print("Task resumed")
    }
    
    func fetchVoices(languageCode: String? = nil, completion: @escaping ([TTSVoice]) -> Void) {
        getAccessToken { [weak self] result in
            switch result {
            case .success(let token):
                var urlComponents = URLComponents(string: self?.voicesURL ?? "")
                
                if let languageCode = languageCode {
                    urlComponents?.queryItems = [URLQueryItem(name: "languageCode", value: languageCode)]
                    
                }
                
                guard let url = urlComponents?.url else {
                    print("Invalid URL")
                    completion([])
                    return
                }
                
                var request = URLRequest(url: url)
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                
                URLSession.shared.dataTask(with: request) { data, response, error in
                    guard let data = data else {
                        print("No data received: \(error?.localizedDescription ?? "Unknown error")")
                        completion([])
                        return
                    }
                    
                    do {
                        let decoder = JSONDecoder()
                        let response = try decoder.decode(VoicesResponse.self, from: data)
                        DispatchQueue.main.async {
                            self?.voices = response.voices
                            completion(response.voices)
                        }
                    } catch {
                        print("Decoding error: \(error)")
                        completion([])
                    }
                }.resume()
                
            case .failure(let error):
                print("Failed to get token for voices: \(error)")
                completion([])
            }
        }
    }
}
