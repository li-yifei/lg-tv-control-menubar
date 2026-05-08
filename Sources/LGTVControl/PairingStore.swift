import Foundation
import Security

private enum KeychainHelper {
    static let service = "com.lgtv-control"

    static func save(account: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

final class PairingStore {
    private let path: String
    var configPath: String { path }

    init(path: String) {
        self.path = path
    }

    func configuredHost() -> String? {
        guard let raw = try? loadRawIfExists() else { return nil }
        return raw["host"] as? String
    }

    func loadConfig() throws -> PairingConfig {
        guard FileManager.default.fileExists(atPath: path) else {
            throw TVControlError.missingConfig(path)
        }
        let raw = try loadRawIfExists()
        guard let host = raw["host"] as? String, !host.isEmpty else {
            throw TVControlError.missingHost
        }

        let clientKey = KeychainHelper.load(account: "clientKey") ?? raw["clientKey"] as? String
        let ipControlKeycode = KeychainHelper.load(account: "ipControlKeycode") ?? raw["ipControlKeycode"] as? String

        migrateSecret("clientKey", from: raw)
        migrateSecret("ipControlKeycode", from: raw)

        return PairingConfig(
            host: host,
            model: raw["model"] as? String,
            mac: raw["mac"] as? String,
            wakeMACs: raw["wakeMACs"] as? [String] ?? [],
            clientKey: clientKey,
            ipControlKeycode: ipControlKeycode
        )
    }

    func saveHost(_ host: String) throws {
        var raw = (try? loadRawIfExists()) ?? [:]
        raw["host"] = host
        raw["savedAt"] = isoNow()
        try saveRaw(raw)
    }

    func saveClientKey(_ clientKey: String, host: String) throws {
        _ = KeychainHelper.save(account: "clientKey", value: clientKey)
        var raw = (try? loadRawIfExists()) ?? [:]
        raw["host"] = host
        raw.removeValue(forKey: "clientKey")
        raw["savedAt"] = isoNow()
        try saveRaw(raw)
    }

    func saveWakeMACs(_ macs: [String]) throws {
        let normalized = uniqueMACs(macs)
        guard let primary = normalized.first else { return }
        var raw = (try? loadRawIfExists()) ?? [:]
        raw["mac"] = primary
        raw["wakeMACs"] = normalized
        raw["wakeMACsSavedAt"] = isoNow()
        try saveRaw(raw)
    }

    private func migrateSecret(_ key: String, from raw: [String: Any]) {
        guard let value = raw[key] as? String, !value.isEmpty,
              KeychainHelper.load(account: key) == nil else { return }
        if KeychainHelper.save(account: key, value: value) {
            var updated = raw
            updated.removeValue(forKey: key)
            try? saveRaw(updated)
        }
    }

    private func loadRawIfExists() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: path) else {
            return [:]
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TVControlError.invalidJSON
        }
        return object
    }

    private func saveRaw(_ raw: [String: Any]) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private func isoNow() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}

func uniqueMACs(_ macs: [String]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []

    for mac in macs {
        let normalized = normalizeMAC(mac)
        guard !normalized.isEmpty, !seen.contains(normalized) else { continue }
        seen.insert(normalized)
        result.append(normalized)
    }

    return result
}

func normalizeMAC(_ mac: String) -> String {
    let compact = mac
        .replacingOccurrences(of: "-", with: "")
        .replacingOccurrences(of: ":", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()

    guard compact.count == 12,
          compact.allSatisfy({ $0.isHexDigit }) else {
        return ""
    }

    var parts: [String] = []
    var index = compact.startIndex
    for _ in 0..<6 {
        let next = compact.index(index, offsetBy: 2)
        parts.append(String(compact[index..<next]))
        index = next
    }
    return parts.joined(separator: ":")
}
