import Foundation

protocol TextToSpeechProviding: AnyObject {
    func fetchVoices(languageCode: String?, completion: @escaping (Result<[TTSVoice], Error>) -> Void)
    func getAudio(
        text: String,
        language: String,
        voiceName: String,
        speed: Double,
        speechID: UUID,
        chunkLabel: String,
        completion: @escaping (Result<Data, Error>) -> Void
    )
    func cancelAudioRequests(excluding activeSpeechID: UUID)
}

extension TextToSpeechProviding {
    func fetchVoices(completion: @escaping (Result<[TTSVoice], Error>) -> Void) {
        fetchVoices(languageCode: nil, completion: completion)
    }
}

extension GoogleTTSAPI: TextToSpeechProviding {}

enum TextToSpeechClient {
    static func getInstance(completion: @escaping (Result<TextToSpeechProviding, Error>) -> Void) {
        if Preferences.shared.isAppReviewDemoModeEnabled {
            ReviewDemoTTSAPI.getInstance(token: Preferences.shared.appReviewDemoToken) { api in
                completion(.success(api))
            }
            return
        }

        let credentials = Preferences.shared.credentials
        guard !credentials.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            completion(.failure(GoogleTTSError.invalidCredentials))
            return
        }

        GoogleTTSAPI.getInstance(credentialsJson: credentials) { api in
            completion(.success(api))
        }
    }

    static func resetSharedInstances() {
        GoogleTTSAPI.resetSharedInstance()
        ReviewDemoTTSAPI.resetSharedInstance()
    }

    static func cancelAudioRequests(except activeSpeechID: UUID) {
        GoogleTTSAPI.cancelAudioRequests(except: activeSpeechID)
        ReviewDemoTTSAPI.cancelAudioRequests(except: activeSpeechID)
    }
}
