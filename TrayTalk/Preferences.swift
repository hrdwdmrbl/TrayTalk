import Foundation
import Security

enum SpeakingSpeed {
    static let minimum = 0.25
    static let maximum = 4.0
    static let markerNormal = 1.0
    static let step = 0.1
    static let sliderThumbDiameter = 22.0
    static let markerVisualOffset = -1.0

    static func normalize(_ value: Double) -> Double {
        guard value.isFinite else { return markerNormal }

        let clampedValue = min(max(value, minimum), maximum)
        let roundedStepValue = ((clampedValue / step) + 1e-9).rounded(.toNearestOrAwayFromZero) * step
        let roundedValue = min(max(roundedStepValue, 0.3), maximum)

        if abs(clampedValue - minimum) <= abs(clampedValue - roundedValue) {
            return minimum
        }

        return (roundedValue * 10).rounded() / 10
    }

    static func formatted(_ value: Double) -> String {
        let normalizedValue = normalize(value)
        if normalizedValue == minimum {
            return String(format: "%.2fx", normalizedValue)
        }

        return String(format: "%.1fx", normalizedValue)
    }

    static var markerFraction: Double {
        (markerNormal - minimum) / (maximum - minimum)
    }

    static func markerPosition(sliderWidth: Double) -> Double {
        let usableWidth = max(0, sliderWidth - sliderThumbDiameter)
        return (sliderThumbDiameter / 2) + (usableWidth * markerFraction) + markerVisualOffset
    }
}

private enum GoogleCredentialsStore {
    private static let service = "com.cyberofficeindustries.smoothtalker.google-credentials"
    private static let account = "service-account-json"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    static func load() -> String? {
        var query = baseQuery
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status != errSecItemNotFound else { return nil }
        guard status == errSecSuccess else {
            return nil
        }

        guard let data = item as? Data,
              let credentials = String(data: data, encoding: .utf8) else {
            return nil
        }

        return credentials
    }

    @discardableResult
    static func save(_ credentials: String) -> Bool {
        guard let data = credentials.data(using: .utf8) else {
            return false
        }

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }

        guard updateStatus == errSecItemNotFound else {
            return false
        }

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            return false
        }

        return true
    }

    @discardableResult
    static func clear() -> Bool {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            return false
        }

        return true
    }
}

class Preferences {
    static let shared = Preferences()
    private let defaults = UserDefaults.standard
    
    private enum Keys {
        static let credentials = "credentials"
        static let inputText = "inputText"
        static let voiceName = "voiceName"
        static let language = "language"
        static let speakingSpeed = "speakingSpeed"
        static let hotkey = "hotkey"
        static let secondLaunch = "secondLaunch"
        static let googleCloudProjectID = "googleCloudProjectID"
        static let appReviewDemoModeEnabled = "appReviewDemoModeEnabled"
        static let appReviewDemoToken = "appReviewDemoToken"
    }
    
    var credentials: String {
        get {
            if let credentials = GoogleCredentialsStore.load() {
                return credentials
            }

            guard let legacyCredentials = defaults.string(forKey: Keys.credentials),
                  !legacyCredentials.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return ""
            }

            do {
                _ = try GoogleServiceAccountCredentials.validate(legacyCredentials)
            } catch {
                return legacyCredentials
            }

            if GoogleCredentialsStore.save(legacyCredentials) {
                defaults.removeObject(forKey: Keys.credentials)
            }

            return legacyCredentials
        }
        set {
            let trimmedValue = newValue.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !trimmedValue.isEmpty else {
                GoogleCredentialsStore.clear()
                defaults.removeObject(forKey: Keys.credentials)
                return
            }

            if GoogleCredentialsStore.save(trimmedValue) {
                defaults.removeObject(forKey: Keys.credentials)
            }
        }
    }

    var googleCloudProjectID: String? {
        get {
            let projectID = defaults.string(forKey: Keys.googleCloudProjectID)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return projectID?.isEmpty == false ? projectID : nil
        }
        set {
            let projectID = newValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if projectID.isEmpty {
                defaults.removeObject(forKey: Keys.googleCloudProjectID)
            } else {
                defaults.set(projectID, forKey: Keys.googleCloudProjectID)
            }
        }
    }

    var isAppReviewDemoModeEnabled: Bool {
        get {
            defaults.bool(forKey: Keys.appReviewDemoModeEnabled) &&
                !appReviewDemoToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        set {
            defaults.set(newValue, forKey: Keys.appReviewDemoModeEnabled)
        }
    }

    var appReviewDemoToken: String {
        get {
            defaults.string(forKey: Keys.appReviewDemoToken) ?? ""
        }
        set {
            let trimmedValue = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedValue.isEmpty else {
                defaults.removeObject(forKey: Keys.appReviewDemoToken)
                defaults.set(false, forKey: Keys.appReviewDemoModeEnabled)
                return
            }

            defaults.set(trimmedValue, forKey: Keys.appReviewDemoToken)
        }
    }

    func enableAppReviewDemoMode(token: String) {
        appReviewDemoToken = token
        isAppReviewDemoModeEnabled = true
    }

    func clearAppReviewDemoMode() {
        defaults.set(false, forKey: Keys.appReviewDemoModeEnabled)
        defaults.removeObject(forKey: Keys.appReviewDemoToken)
    }
    
    var inputText: String {
        get { defaults.string(forKey: Keys.inputText) ?? "Have a nice day!" }
        set { defaults.set(newValue, forKey: Keys.inputText) }
    }
    
    var voiceName: String {
        get { defaults.string(forKey: Keys.voiceName) ?? "" }
        set { defaults.set(newValue, forKey: Keys.voiceName) }
    }
    
    var language: String {
        get { defaults.string(forKey: Keys.language) ?? "" }
        set { defaults.set(newValue, forKey: Keys.language) }
    }
    
    var speakingSpeed: Double {
        get {
            let normalizedSpeed = SpeakingSpeed.normalize(defaults.double(forKey: Keys.speakingSpeed))
            defaults.set(normalizedSpeed, forKey: Keys.speakingSpeed)
            return normalizedSpeed
        }
        set {
            defaults.set(SpeakingSpeed.normalize(newValue), forKey: Keys.speakingSpeed)
        }
    }

    var hotkey: String {
        get {
            let canonicalHotkey = HotkeyFormatter.canonicalize(defaults.string(forKey: Keys.hotkey))
            defaults.set(canonicalHotkey, forKey: Keys.hotkey)
            return canonicalHotkey
        }
        set {
            defaults.set(HotkeyFormatter.canonicalize(newValue), forKey: Keys.hotkey)
        }
    }
    
    var secondLaunch: Bool {
        get { defaults.bool(forKey: Keys.secondLaunch) }
        set { defaults.set(newValue, forKey: Keys.secondLaunch) }
    }
    
    private init() {
        // Set default values for the doubles
        if defaults.object(forKey: Keys.speakingSpeed) == nil {
            defaults.set(1.0, forKey: Keys.speakingSpeed)
        }
    }
} 
