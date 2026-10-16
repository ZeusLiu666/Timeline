import Foundation
import Security

struct NutstoreCredentials: Sendable, Equatable {
    let username: String
    let password: String

    init(username: String, password: String) {
        self.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        self.password = password.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isValid: Bool {
        !username.isEmpty && username.contains("@") && !username.contains(":")
            && !username.contains(where: { $0.isNewline }) && !password.isEmpty
    }
}

protocol NutstoreCredentialStoring {
    func load(username: String) throws -> NutstoreCredentials?
    func save(_ credentials: NutstoreCredentials) throws
    func delete(username: String) throws
}

enum NutstoreCredentialError: LocalizedError {
    case invalidCredentials
    case unreadable
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            return "请填写坚果云账户邮箱和为 Timeline 生成的第三方应用密码。"
        case .unreadable:
            return "本机保存的坚果云凭据无法读取，请重新填写第三方应用密码。"
        case let .keychain(status):
            // OSStatus is safe to display; never include a query or secret in errors.
            return "无法访问本机钥匙串（错误 \(status)）。请解锁设备后重试。"
        }
    }
}

/// The application password stays on this device. It is never put in UserDefaults,
/// the Timeline database, a sync snapshot, or the synchronizable Keychain.
struct NutstoreKeychainCredentialStore: NutstoreCredentialStoring {
    private static let service = "com.zeusliu.Timeline.Nutstore"

    /// A device identity must not arrive through iCloud Keychain or a device
    /// restore: every installation writes only its own remote snapshot.
    static func deviceID() throws -> UUID {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "device-id",
            kSecAttrSynchronizable as String: false
        ]
        func read() throws -> UUID? {
            var lookup = query
            lookup[kSecReturnData as String] = true
            lookup[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            let status = SecItemCopyMatching(lookup as CFDictionary, &item)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess else { throw NutstoreCredentialError.keychain(status) }
            guard let data = item as? Data, let string = String(data: data, encoding: .utf8),
                  let id = UUID(uuidString: string) else { throw NutstoreCredentialError.unreadable }
            return id
        }
        if let id = try read() { return id }
        let id = UUID()
        var item = query
        item[kSecValueData as String] = Data(id.uuidString.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem, let existing = try read() { return existing }
        guard status == errSecSuccess else { throw NutstoreCredentialError.keychain(status) }
        return id
    }

    func load(username: String) throws -> NutstoreCredentials? {
        var query = itemQuery(username: username)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw NutstoreCredentialError.keychain(status) }
        guard let data = item as? Data, let password = String(data: data, encoding: .utf8) else {
            throw NutstoreCredentialError.unreadable
        }
        return NutstoreCredentials(username: username, password: password)
    }

    func save(_ credentials: NutstoreCredentials) throws {
        guard credentials.isValid else { throw NutstoreCredentialError.invalidCredentials }
        let query = itemQuery(username: credentials.username)
        let attributes: [String: Any] = [
            kSecValueData as String: Data(credentials.password.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            for (key, value) in attributes { item[key] = value }
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw NutstoreCredentialError.keychain(added) }
        } else if status != errSecSuccess {
            throw NutstoreCredentialError.keychain(status)
        }
    }

    func delete(username: String) throws {
        let status = SecItemDelete(itemQuery(username: username) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NutstoreCredentialError.keychain(status)
        }
    }

    private func itemQuery(username: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: username.trimmingCharacters(in: .whitespacesAndNewlines),
            kSecAttrSynchronizable as String: false
        ]
    }
}

struct NutstoreSyncPreferences {
    var username: String
    var enabled: Bool
    var lastSync: Date?
    var lastSyncAttempt: Date?
    var lastSyncedContentFingerprint: String?

    init(defaults: UserDefaults = .standard) {
        username = defaults.string(forKey: "Timeline.nutstore.username.v1") ?? ""
        enabled = defaults.bool(forKey: "Timeline.nutstore.enabled.v1")
        lastSync = defaults.object(forKey: "Timeline.nutstore.lastSync.v1") as? Date
        lastSyncAttempt = defaults.object(forKey: "Timeline.nutstore.lastSyncAttempt.v1") as? Date
        lastSyncedContentFingerprint = defaults.string(forKey: "Timeline.nutstore.lastSyncedContentFingerprint.v1")
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(username.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "Timeline.nutstore.username.v1")
        defaults.set(enabled, forKey: "Timeline.nutstore.enabled.v1")
        defaults.set(lastSync, forKey: "Timeline.nutstore.lastSync.v1")
        defaults.set(lastSyncAttempt, forKey: "Timeline.nutstore.lastSyncAttempt.v1")
        defaults.set(lastSyncedContentFingerprint, forKey: "Timeline.nutstore.lastSyncedContentFingerprint.v1")
    }
}
