//
//  api.swift
//  Smooth Talker
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

private struct GoogleErrorResponse: Codable {
    let error: GoogleErrorDetail?
}

private struct GoogleErrorDetail: Codable {
    let code: Int?
    let message: String?
    let status: String?
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

    var userMessage: String {
        switch self {
        case .invalidURL:
            return "Smooth Talker could not reach Google Cloud because the service URL is invalid."
        case .invalidCredentials:
            return "The Google Cloud credentials could not be read. Run Automatic Setup again."
        case .authenticationFailed(let message):
            return "Google rejected the credentials. Run Automatic Setup again. \(message)"
        case .noToken:
            return "Google did not return an access token. Run Automatic Setup again."
        case .invalidResponse:
            return "Google Cloud returned a response Smooth Talker could not understand. Try again in a moment."
        case .httpError(let code, let body):
            return Self.userMessage(forHTTPStatus: code, body: body)
        case .noData:
            return "Google Cloud did not return any data. Check your network connection and try again."
        case .jsonEncodingError:
            return "Smooth Talker could not prepare the text-to-speech request."
        }
    }

    static func userMessage(for error: Error) -> String {
        if let googleError = error as? GoogleTTSError {
            return googleError.userMessage
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet:
                return "You appear to be offline. Connect to the internet and try again."
            case .timedOut:
                return "The request to Google Cloud timed out. Try again in a moment."
            default:
                return "Network error: \(urlError.localizedDescription)"
            }
        }

        return error.localizedDescription
    }

    private static func userMessage(forHTTPStatus code: Int, body: String?) -> String {
        let googleMessage = body.flatMap { body -> String? in
            guard let data = body.data(using: .utf8),
                  let response = try? JSONDecoder().decode(GoogleErrorResponse.self, from: data) else {
                return nil
            }
            return response.error?.message
        }

        let searchableMessage = (googleMessage ?? body ?? "").lowercased()

        if searchableMessage.contains("billing") {
            return "Billing is not enabled for this Google Cloud project. Open Google Cloud Billing, attach a billing account, then try again."
        }

        if searchableMessage.contains("disabled") ||
            searchableMessage.contains("not been used") ||
            searchableMessage.contains("serviceusage") {
            return "The Cloud Text-to-Speech API is not enabled for this project. Enable it in Google Cloud, then try again."
        }

        switch code {
        case 400:
            return googleMessage ?? "Google Cloud could not accept this request. Check the selected voice and credentials."
        case 401:
            return "The Google Cloud credentials could not be authenticated. Run Automatic Setup again."
        case 403:
            return googleMessage ?? "Smooth Talker does not have access to Cloud Text-to-Speech, or the project needs billing/API setup."
        case 404:
            return "Google Cloud could not find the requested Text-to-Speech resource. Confirm the API is enabled for this project."
        case 429:
            return "This Google Cloud project has hit a Text-to-Speech quota limit. Wait a bit or check quotas in Google Cloud."
        case 500...599:
            return "Google Cloud is having trouble right now. Try again in a moment."
        default:
            if let googleMessage {
                return "Google Cloud error \(code): \(googleMessage)"
            }
            return "Google Cloud returned HTTP \(code)."
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
    private let audioTasksQueue = DispatchQueue(label: "com.kriyak.smoothtalker.google-tts.audio-tasks")
    private var audioTasksBySession: [UUID: [UUID: URLSessionDataTask]] = [:]
    private var cancelledAudioSessions: Set<UUID> = []
    
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
    
    static func cancelAudioRequests(except activeSpeechID: UUID) {
        shared?.cancelAudioRequests(excluding: activeSpeechID)
    }
    
    static func resetSharedInstance() {
        shared = nil
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
        // Check if we have a valid cached token
        if let token = cachedToken, isTokenValid() {
            completion(.success(token))
            return
        }
        
        guard let credentialsData = credentials.data(using: .utf8) else {
            completion(.failure(GoogleTTSError.invalidCredentials))
            return
        }
        
        guard let authentication = ServiceAccountTokenProvider(
            credentialsData: credentialsData,
            scopes: [scope]
        ) else {
            completion(.failure(GoogleTTSError.authenticationFailed("Failed to create token provider")))
            return
        }
        
        do {
            try authentication.withToken { [weak self] token, error in
                if let error = error {
                    completion(.failure(GoogleTTSError.authenticationFailed(error.localizedDescription)))
                    return
                }
                
                guard let token = token,
                      let accessToken = token.AccessToken else {
                    completion(.failure(GoogleTTSError.noToken))
                    return
                }
                
                // Cache the new token and its expiration date
                self?._cachedToken = accessToken
                if let expiresIn = token.ExpiresIn {
                    self?.tokenExpirationDate = Date().addingTimeInterval(TimeInterval(expiresIn))
                }
                
                completion(.success(accessToken))
            }
        } catch {
            completion(.failure(GoogleTTSError.authenticationFailed(error.localizedDescription)))
        }
    }
    
    func cancelAudioRequests(excluding activeSpeechID: UUID) {
        audioTasksQueue.sync {
            let inactiveSessionIDs = audioTasksBySession.keys.filter { $0 != activeSpeechID }
            
            for sessionID in inactiveSessionIDs {
                audioTasksBySession[sessionID]?.values.forEach { $0.cancel() }
                audioTasksBySession.removeValue(forKey: sessionID)
                cancelledAudioSessions.insert(sessionID)
            }
        }
    }
    
    func getAudio(text: String, language: String, voiceName: String, speed: Double, speechID: UUID, chunkLabel _: String, completion: @escaping (Result<Data, Error>) -> Void) {
        registerAudioSession(speechID)
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.getAccessToken { result in
                switch result {
                case .success(let token):
                    guard self?.isAudioSessionCancelled(speechID) == false else {
                        return
                    }
                    
                    self?.performAudioRequest(with: token,
                                              text: text,
                                              language: language,
                                              voiceName: voiceName,
                                              speed: speed,
                                              speechID: speechID,
                                              completion: completion)
                case .failure(let error):
                    DispatchQueue.main.async {
                        completion(.failure(error))
                    }
                }
            }
        }
    }
    
    private func performAudioRequest(with token: String, text: String, language: String, voiceName: String, speed: Double, speechID: UUID, completion: @escaping (Result<Data, Error>) -> Void) {
        guard let url = URL(string: baseURL) else {
            completion(.failure(GoogleTTSError.invalidURL))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let audioConfig: [String: Any] = [
            "audioEncoding": "MP3",
            // "speakingRate": speed, // we are speeding it up afterwards for better quality
            "speakingRate": 1.0
        ]
        
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
        } catch {
            completion(.failure(GoogleTTSError.jsonEncodingError))
            return
        }

        let requestID = UUID()
        let task = URLSession.shared.dataTask(with: request) { (data, response, error) in
            self.removeAudioTask(requestID, from: speechID)
            
            DispatchQueue.main.async {
                if let error = error {
                    completion(.failure(error))
                    return
                }
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    completion(.failure(GoogleTTSError.invalidResponse))
                    return
                }
                
                guard (200...299).contains(httpResponse.statusCode) else {
                    let errorBody = data.flatMap { String(data: $0, encoding: .utf8) }
                    completion(.failure(GoogleTTSError.httpError(httpResponse.statusCode, errorBody)))
                    return
                }
                
                guard let data = data else {
                    completion(.failure(GoogleTTSError.noData))
                    return
                }
                
                do {
                    // Parse the JSON response
                    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let audioContent = json["audioContent"] as? String,
                          let audioData = Data(base64Encoded: audioContent) else {
                        completion(.failure(GoogleTTSError.invalidResponse))
                        return
                    }
                    
                    completion(.success(audioData))
                } catch {
                    completion(.failure(error))
                }
            }
        }
        
        guard registerAudioTask(task, requestID: requestID, for: speechID) else { return }
        task.resume()
    }
    
    private func registerAudioSession(_ speechID: UUID) {
        audioTasksQueue.sync {
            if audioTasksBySession[speechID] == nil {
                audioTasksBySession[speechID] = [:]
            }
            cancelledAudioSessions.remove(speechID)
        }
    }
    
    private func registerAudioTask(_ task: URLSessionDataTask, requestID: UUID, for speechID: UUID) -> Bool {
        audioTasksQueue.sync {
            guard !cancelledAudioSessions.contains(speechID) else {
                task.cancel()
                return false
            }
            
            audioTasksBySession[speechID, default: [:]][requestID] = task
            return true
        }
    }
    
    private func removeAudioTask(_ requestID: UUID, from speechID: UUID) {
        audioTasksQueue.sync {
            guard var tasks = audioTasksBySession[speechID] else { return }
            
            tasks.removeValue(forKey: requestID)
            
            if tasks.isEmpty {
                audioTasksBySession.removeValue(forKey: speechID)
            } else {
                audioTasksBySession[speechID] = tasks
            }
        }
    }
    
    private func isAudioSessionCancelled(_ speechID: UUID) -> Bool {
        audioTasksQueue.sync {
            cancelledAudioSessions.contains(speechID)
        }
    }
    
    func fetchVoices(languageCode: String? = nil, completion: @escaping (Result<[TTSVoice], Error>) -> Void) {
        getAccessToken { [weak self] result in
            switch result {
            case .success(let token):
                var urlComponents = URLComponents(string: self?.voicesURL ?? "")
                
                if let languageCode = languageCode {
                    urlComponents?.queryItems = [URLQueryItem(name: "languageCode", value: languageCode)]
                    
                }
                
                guard let url = urlComponents?.url else {
                    completion(.failure(GoogleTTSError.invalidURL))
                    return
                }
                
                var request = URLRequest(url: url)
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                
                URLSession.shared.dataTask(with: request) { data, response, error in
                    if let error = error {
                        DispatchQueue.main.async {
                            completion(.failure(error))
                        }
                        return
                    }
                    
                    guard let httpResponse = response as? HTTPURLResponse else {
                        DispatchQueue.main.async {
                            completion(.failure(GoogleTTSError.invalidResponse))
                        }
                        return
                    }
                    
                    guard (200...299).contains(httpResponse.statusCode) else {
                        let errorBody = data.flatMap { String(data: $0, encoding: .utf8) }
                        DispatchQueue.main.async {
                            completion(.failure(GoogleTTSError.httpError(httpResponse.statusCode, errorBody)))
                        }
                        return
                    }
                    
                    guard let data = data else {
                        DispatchQueue.main.async {
                            completion(.failure(GoogleTTSError.noData))
                        }
                        return
                    }
                    
                    do {
                        let decoder = JSONDecoder()
                        let response = try decoder.decode(VoicesResponse.self, from: data)
                        DispatchQueue.main.async {
                            self?.voices = response.voices
                            completion(.success(response.voices))
                        }
                    } catch {
                        DispatchQueue.main.async {
                            completion(.failure(error))
                        }
                    }
                }.resume()
                
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
}
