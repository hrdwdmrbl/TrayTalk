import Foundation

struct GoogleServiceAccountCredentials {
    let projectID: String
    let clientEmail: String

    static func validate(_ json: String) throws -> GoogleServiceAccountCredentials {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw GoogleCredentialsValidationError.empty
        }

        guard let data = trimmed.data(using: .utf8) else {
            throw GoogleCredentialsValidationError.invalidEncoding
        }

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw GoogleCredentialsValidationError.malformedJSON
        }

        guard let dictionary = object as? [String: Any] else {
            throw GoogleCredentialsValidationError.notObject
        }

        func stringValue(_ key: String) throws -> String {
            guard let value = dictionary[key] as? String,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw GoogleCredentialsValidationError.missingField(key)
            }
            return value
        }

        let type = try stringValue("type")
        guard type == "service_account" else {
            throw GoogleCredentialsValidationError.wrongType
        }

        let projectID = try stringValue("project_id")
        _ = try stringValue("private_key_id")
        let privateKey = try stringValue("private_key")
        let clientEmail = try stringValue("client_email")
        _ = try stringValue("client_id")
        let tokenURI = try stringValue("token_uri")

        guard privateKey.contains("-----BEGIN PRIVATE KEY-----"),
              privateKey.contains("-----END PRIVATE KEY-----") else {
            throw GoogleCredentialsValidationError.invalidPrivateKey
        }

        guard clientEmail.contains("@"),
              clientEmail.hasSuffix(".iam.gserviceaccount.com") else {
            throw GoogleCredentialsValidationError.invalidClientEmail
        }

        guard let url = URL(string: tokenURI),
              let host = url.host?.lowercased(),
              host.contains("google") else {
            throw GoogleCredentialsValidationError.invalidTokenURI
        }

        return GoogleServiceAccountCredentials(projectID: projectID, clientEmail: clientEmail)
    }
}

enum GoogleCredentialsValidationError: LocalizedError {
    case empty
    case invalidEncoding
    case malformedJSON
    case notObject
    case missingField(String)
    case wrongType
    case invalidPrivateKey
    case invalidClientEmail
    case invalidTokenURI

    var errorDescription: String? {
        switch self {
        case .empty:
            return "Smooth Talker could not create credentials. Try Automatic Setup again."
        case .invalidEncoding:
            return "Google Cloud returned credentials Smooth Talker could not read. Try Automatic Setup again."
        case .malformedJSON:
            return "Google Cloud returned credentials Smooth Talker could not read. Try Automatic Setup again."
        case .notObject:
            return "Google Cloud returned credentials in an unexpected format. Try Automatic Setup again."
        case .missingField(let field):
            return "Google Cloud returned incomplete credentials. Try Automatic Setup again. Missing: \(field)."
        case .wrongType:
            return "Google Cloud returned credentials in an unexpected format. Try Automatic Setup again."
        case .invalidPrivateKey:
            return "Google Cloud returned incomplete credentials. Try Automatic Setup again."
        case .invalidClientEmail:
            return "Google Cloud returned credentials for the wrong account type. Try Automatic Setup again."
        case .invalidTokenURI:
            return "The token URI does not look like a Google authentication endpoint."
        }
    }
}
