import Foundation

final class ReviewDemoTTSAPI: TextToSpeechProviding {
    private static var shared: ReviewDemoTTSAPI?
    private static let defaultEndpointURL = URL(string: "https://smoothtalker-review-tts.root-e66.workers.dev")!

    private let endpointURL: URL
    private let token: String
    private let audioTasksQueue = DispatchQueue(label: "com.kriyak.smoothtalker.review-demo-tts.audio-tasks")
    private var audioTasksBySession: [UUID: [UUID: URLSessionDataTask]] = [:]
    private var cancelledAudioSessions: Set<UUID> = []

    static func getInstance(token: String, completion: @escaping (ReviewDemoTTSAPI) -> Void) {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)

        if let existing = shared,
           existing.token == trimmedToken,
           existing.endpointURL == defaultEndpointURL {
            completion(existing)
            return
        }

        let api = ReviewDemoTTSAPI(endpointURL: defaultEndpointURL, token: trimmedToken)
        shared = api
        completion(api)
    }

    static func cancelAudioRequests(except activeSpeechID: UUID) {
        shared?.cancelAudioRequests(excluding: activeSpeechID)
    }

    static func resetSharedInstance() {
        shared = nil
    }

    private init(endpointURL: URL, token: String) {
        self.endpointURL = endpointURL
        self.token = token
    }

    func fetchVoices(languageCode: String? = nil, completion: @escaping (Result<[TTSVoice], Error>) -> Void) {
        var urlComponents = URLComponents(url: endpoint(path: "/v1/app-review/tts/voices"), resolvingAgainstBaseURL: false)
        if let languageCode {
            urlComponents?.queryItems = [URLQueryItem(name: "languageCode", value: languageCode)]
        }

        guard let url = urlComponents?.url else {
            completion(.failure(GoogleTTSError.invalidURL))
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error {
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

                guard let data else {
                    completion(.failure(GoogleTTSError.noData))
                    return
                }

                do {
                    let response = try JSONDecoder().decode(VoicesResponse.self, from: data)
                    completion(.success(response.voices))
                } catch {
                    completion(.failure(error))
                }
            }
        }.resume()
    }

    func getAudio(
        text: String,
        language: String,
        voiceName: String,
        speed _: Double,
        speechID: UUID,
        chunkLabel _: String,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        registerAudioSession(speechID)

        let requestID = UUID()
        var request = URLRequest(url: endpoint(path: "/v1/app-review/tts/synthesize"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "text": text,
                "languageCode": language,
                "voiceName": voiceName,
                "audioEncoding": "MP3"
            ])
        } catch {
            completion(.failure(GoogleTTSError.jsonEncodingError))
            return
        }

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            self.removeAudioTask(requestID, from: speechID)

            DispatchQueue.main.async {
                if let error {
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

                guard let data else {
                    completion(.failure(GoogleTTSError.noData))
                    return
                }

                do {
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

    private func endpoint(path: String) -> URL {
        URL(string: path, relativeTo: endpointURL)!.absoluteURL
    }
}
