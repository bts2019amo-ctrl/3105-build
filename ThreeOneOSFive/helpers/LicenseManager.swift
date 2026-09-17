import Foundation
import UIKit
import Security

@MainActor
final class LicenseManager: ObservableObject {
    @Published private(set) var isLoading = true
    @Published private(set) var isAuthorized = false
    @Published private(set) var message: String?
    @Published private(set) var expirationDate: Date?

    // API oficial do Proxy System para validar chaves iOS com validade por dias.
    // The endpoint is public; PROXY_API_KEY remains server-side only.
    private let endpoint = EndpointVault.licenseURLString
    private let keychainService = "com.bts2019amo.3105.activation"
    private let legacyKeychainService = "com.apple.mobile.MobileHouseArrest.activation"
    private let keychainAccount = "license-key"
    private let deviceKeychainService = "com.bts2019amo.3105.device"
    private let legacyDeviceKeychainService = "com.apple.mobile.MobileHouseArrest.device"
    private let deviceKeychainAccount = "device-id"
    private let expirationDateKey = "license.expiration-date"
    private var storedKey: String?
    private var deviceID: String
    private var refreshInFlight = false
    private var lastValidationAt: Date?

    init() {
        storedKey = Self.loadKey(service: keychainService, account: keychainAccount)
            ?? Self.loadKey(service: legacyKeychainService, account: keychainAccount)
        if let storedKey {
            try? Self.saveKey(storedKey, service: keychainService, account: keychainAccount)
        }
        // A key is written to the Keychain only after a successful validation. Keychain data
        // survives app termination and normal uninstall/reinstall cycles on the same device.
        isAuthorized = false
        isLoading = storedKey != nil
        expirationDate = UserDefaults.standard.object(forKey: expirationDateKey) as? Date
        if let existingDeviceID = Self.loadKey(service: deviceKeychainService, account: deviceKeychainAccount), !existingDeviceID.isEmpty {
            deviceID = existingDeviceID
        } else if let legacyDeviceID = Self.loadKey(service: legacyDeviceKeychainService, account: deviceKeychainAccount), !legacyDeviceID.isEmpty {
            deviceID = legacyDeviceID
            try? Self.saveKey(legacyDeviceID, service: deviceKeychainService, account: deviceKeychainAccount)
        } else {
            let newDeviceID = UIDevice.current.identifierForVendor?.uuidString.lowercased()
                ?? UUID().uuidString.lowercased()
            try? Self.saveKey(
                newDeviceID,
                service: deviceKeychainService,
                account: deviceKeychainAccount
            )
            deviceID = newDeviceID
        }
    }

    func refresh() {
        guard !refreshInFlight else { return }
        if let lastValidationAt, Date().timeIntervalSince(lastValidationAt) < 60 {
            return
        }
        refreshInFlight = true
        // Do not replace the main UI with the login/loading screen while a known
        // session is being refreshed in the background.
        if !isAuthorized { isLoading = true }
        guard let key = storedKey, !key.isEmpty else {
            isAuthorized = false
            isLoading = false
            refreshInFlight = false
            return
        }
        Task {
            do {
                let result = try await validateWithRetry(key: key)
                if result.isValid {
                    isAuthorized = true
                    message = nil
                    updateExpiration(result.expirationDate)
                    lastValidationAt = Date()
                } else {
                    revoke()
                    message = result.message ?? "Invalid or expired key."
                }
            } catch let error as LicenseValidationError {
                if case .definitiveInvalid(let invalidMessage) = error {
                    revoke()
                    message = invalidMessage ?? error.localizedDescription
                } else {
                    let hasPreviouslyValidatedKey = storedKey != nil
                    isAuthorized = hasPreviouslyValidatedKey
                    message = hasPreviouslyValidatedKey ? nil : error.localizedDescription
                }
            } catch {
                // Network errors, timeouts, malformed responses and rate limits are not
                // proof that a key is invalid. Keep a key that was previously accepted;
                // only an explicit invalid/expired response reaches revoke() above.
                let hasPreviouslyValidatedKey = storedKey != nil
                isAuthorized = hasPreviouslyValidatedKey
                message = hasPreviouslyValidatedKey ? nil : "Unable to verify the license right now."
                lastValidationAt = Date()
            }
            isLoading = false
            refreshInFlight = false
        }
    }

    func activate(key rawKey: String) async {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            message = "Enter a license key."
            return
        }
        isLoading = true
        message = nil
        do {
            let result = try await validateWithRetry(key: key)
            guard result.isValid else {
                isAuthorized = false
                message = result.message ?? "Invalid or expired key."
                isLoading = false
                return
            }
            try Self.saveKey(key, service: keychainService, account: keychainAccount)
            storedKey = key
            updateExpiration(result.expirationDate)
            isAuthorized = true
            lastValidationAt = Date()
            message = nil
        } catch {
            // If this device already had a validated key, do not turn a temporary
            // connection/API failure into a logout. A first activation still requires
            // a successful server response because storedKey is nil at this point.
            isAuthorized = storedKey != nil
            message = error.localizedDescription
        }
        isLoading = false
    }

    private func revoke() {
        Self.deleteKey(service: keychainService, account: keychainAccount)
        storedKey = nil
        isAuthorized = false
        expirationDate = nil
        UserDefaults.standard.removeObject(forKey: expirationDateKey)
    }

    private static func isRevocationMessage(_ message: String?) -> Bool {
        guard let message else { return false }
        let text = message.lowercased()
        return text.contains("expired") || text.contains("expirada")
            || text.contains("expirado") || text.contains("revoked")
            || text.contains("revogada") || text.contains("revogado")
    }

    private func updateExpiration(_ value: Date?) {
        guard let value else { return }
        expirationDate = value
        UserDefaults.standard.set(value, forKey: expirationDateKey)
    }

    private struct ValidationResult {
        let isValid: Bool
        let message: String?
        let expirationDate: Date?
    }

    private enum LicenseValidationError: LocalizedError {
        case invalidResponse
        case definitiveInvalid(message: String?)
        case server(status: Int, message: String?)

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "The activation service returned an unreadable response."
            case .definitiveInvalid(let message):
                return message ?? "Invalid or expired key."
            case .server(let status, let message):
                return message.map { "Activation service (HTTP \(status)): \($0)" }
                    ?? "Activation service returned HTTP \(status)."
            }
        }
    }

    private func validateWithRetry(key: String) async throws -> ValidationResult {
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                return try await validate(key: key)
            } catch let error as LicenseValidationError {
                if case .definitiveInvalid = error { throw error }
                lastError = error
            } catch {
                lastError = error
            }
            if attempt < 2 {
                try? await Task.sleep(nanoseconds: UInt64(500_000_000 * (attempt + 1)))
            }
        }
        throw lastError ?? LicenseValidationError.invalidResponse
    }

    private func validate(key: String) async throws -> ValidationResult {
        if key.hasPrefix("PROXYSYSTEM-ANDROID-") {
            throw LicenseValidationError.definitiveInvalid(
                message: "Esta é uma chave Android. Use uma chave iOS do Proxy System."
            )
        }
        guard key.hasPrefix("PROXY-SYSTEM-") else {
            throw LicenseValidationError.definitiveInvalid(
                message: "Chave inválida para iOS. Use uma chave iOS do Proxy System."
            )
        }
        var components = URLComponents(string: endpoint)!
        var json: [String: Any] = [
            "key": key,
            "deviceId": deviceID
        ]
        let payload: [String: Any] = ["json": json]
        let inputData = try JSONSerialization.data(withJSONObject: payload)
        components.queryItems = [
            URLQueryItem(name: "input", value: String(data: inputData, encoding: .utf8)!)
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any] else {
            throw LicenseValidationError.invalidResponse
        }
        let fields = Self.findLicenseFields(in: root)
        let responseMessage = fields["message"] as? String ?? fields["reason"] as? String
        guard (200..<300).contains(http.statusCode) else {
            let lowerMessage = responseMessage?.lowercased() ?? ""
            let bodyClearlyInvalid = lowerMessage.contains("invalid")
                || lowerMessage.contains("expired")
                || lowerMessage.contains("revoked")
                || lowerMessage.contains("not found")
                || lowerMessage.contains("não encontrada")
                || lowerMessage.contains("chave inválida")
            if (http.statusCode == 401 || http.statusCode == 403) && bodyClearlyInvalid {
                throw LicenseValidationError.definitiveInvalid(message: responseMessage)
            }
            throw LicenseValidationError.server(status: http.statusCode, message: responseMessage)
        }
        guard !fields.isEmpty else {
            throw LicenseValidationError.invalidResponse
        }
        let status = (fields["status"] as? String)?.lowercased()
        let active = Self.booleanValue(fields["active"])
        let valid = Self.booleanValue(fields["valid"] ?? fields["isValid"] ?? fields["is_valid"])
        let success = Self.booleanValue(fields["success"] ?? fields["ok"])
        let expirationValue = Self.firstValue(in: fields, keys: [
            "expiresAt", "expirationDate", "expires", "expiry", "validUntil",
            "expiration", "expiresAtMs", "expirationTimestamp", "expires_at",
            "expiration_date", "valid_until", "expiration_timestamp"
        ])
        var expirationDate = Self.expirationDate(from: expirationValue)
        let remainingSeconds = Self.numberValue(from: fields, keys: [
            "remainingSeconds", "secondsLeft", "expiresIn", "remaining_seconds",
            "seconds_left", "expires_in"
        ])
        let remainingDays = Self.numberValue(from: fields, keys: [
            "daysRemaining", "daysLeft", "days_remaining", "days_left"
        ])
        if expirationDate == nil, let remainingSeconds, remainingSeconds > 0 {
            expirationDate = Date(timeIntervalSinceNow: remainingSeconds)
        } else if expirationDate == nil, let remainingDays, remainingDays > 0 {
            expirationDate = Date(timeIntervalSinceNow: remainingDays * 24 * 60 * 60)
        }
        let expiredByDate = expirationDate.map { $0 <= Date() } ?? false
        let expiredByDuration = (remainingSeconds ?? remainingDays).map { $0 <= 0 } ?? false
        let activeStatus = status.map { ["active", "valid", "enabled", "ok", "success"].contains($0) } ?? false
        let definitiveInvalidStatus = status.map {
            ["invalid", "expired", "revoked", "disabled", "inactive", "not_found", "notfound",
             "blocked", "banned", "device_mismatch", "pending"].contains($0)
        } ?? false
        let invalidMessage = responseMessage.map { message in
            let text = message.lowercased()
            return text.contains("invalid") || text.contains("expired") || text.contains("revoked")
                || text.contains("not found") || text.contains("não encontrada")
                || text.contains("nao encontrada") || text.contains("não encontrado")
                || text.contains("nao encontrado") || text.contains("chave inválida")
                || text.contains("chave invalida") || text.contains("chave expirada")
                || text.contains("chave revogada") || text.contains("chave desativada")
        } ?? false
        if !definitiveInvalidStatus && !invalidMessage,
           active == false && valid == false && success == false {
            throw LicenseValidationError.invalidResponse
        }
        let hasPositiveServerSignal = activeStatus || active == true || valid == true || success == true
        let serverSaysValid = !definitiveInvalidStatus && !invalidMessage && hasPositiveServerSignal
        let isValid = serverSaysValid && !expiredByDate && !expiredByDuration
        return ValidationResult(
            isValid: isValid,
            message: responseMessage,
            expirationDate: expirationDate
        )
    }

    private static func publicIPAddress() async -> String? {
        guard let url = URL(string: "https://api.ipify.org") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.setValue("text/plain", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return value
    }

    private static func booleanValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String {
            switch value.lowercased() {
            case "true", "yes", "valid", "active", "1": return true
            case "false", "no", "invalid", "expired", "0": return false
            default: return nil
            }
        }
        return nil
    }

    private static func numberValue(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func firstValue(in fields: [String: Any], keys: [String]) -> Any? {
        for key in keys {
            if let value = fields[key] { return value }
        }
        return nil
    }

    private static func numberValue(from fields: [String: Any], keys: [String]) -> Double? {
        numberValue(firstValue(in: fields, keys: keys))
    }

    private static func expirationDate(from value: Any?) -> Date? {
        if let number = numberValue(value) {
            return Date(timeIntervalSince1970: number > 100_000_000_000 ? number / 1000 : number)
        }
        guard let text = value as? String else { return nil }
        if let date = ISO8601DateFormatter().date(from: text) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: text)
    }

    private static func findLicenseFields(in value: Any) -> [String: Any] {
        if let dictionary = value as? [String: Any] {
            let strongKeys = [
                "valid", "active", "success", "ok", "isValid", "is_valid", "status",
                "expiresAt", "expirationDate", "expires", "expiry", "validUntil",
                "expiration", "expiresAtMs", "expirationTimestamp", "remainingSeconds",
                "secondsLeft", "expiresIn", "daysRemaining", "daysLeft", "message", "reason",
                "expires_at", "expiration_date", "valid_until", "expiration_timestamp",
                "remaining_seconds", "seconds_left", "expires_in", "days_remaining", "days_left"
            ]
            let hasNestedPayload = dictionary.keys.contains { ["result", "data", "json"].contains($0) }
            let hasStrongLicenseField = strongKeys.contains { key in
                dictionary[key] != nil && key != "success" && key != "ok"
            }
            if hasStrongLicenseField || (!hasNestedPayload && strongKeys.contains(where: { dictionary[$0] != nil })) {
                return dictionary
            }
            for child in dictionary.values {
                let found = findLicenseFields(in: child)
                if !found.isEmpty { return found }
            }
            if strongKeys.contains(where: { dictionary[$0] != nil }) { return dictionary }
        } else if let array = value as? [Any] {
            for child in array {
                let found = findLicenseFields(in: child)
                if !found.isEmpty { return found }
            }
        }
        return [:]
    }

    private static func saveKey(_ value: String, service: String, account: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else {
            throw NSError(domain: "LicenseManager", code: -1)
        }
        var item = query
        attributes.forEach { item[$0.key] = $0.value }
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
            throw NSError(domain: "LicenseManager", code: -1)
        }
    }

    private static func loadKey(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func deleteKey(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
