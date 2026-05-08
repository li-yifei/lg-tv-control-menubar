import Foundation

struct TVState {
    let host: String
    let model: String?
    let volume: Int?
    let muted: Bool?
    let currentAppId: String?
}

struct TVInput {
    let id: String
    let label: String
    let appId: String?
    let connected: Bool
    let hasSignal: Bool
}

struct PairingConfig {
    let host: String
    let model: String?
    let mac: String?
    let wakeMACs: [String]
    let clientKey: String?
    let ipControlKeycode: String?
}

enum TVControlError: Error, LocalizedError {
    case missingConfig(String)
    case missingHost
    case missingClientKey
    case missingMAC
    case invalidURL(String)
    case invalidJSON
    case timeout(String)
    case webOS(String)
    case socket(String)

    var errorDescription: String? {
        switch self {
        case .missingConfig(let path):
            return "Missing pairing config: \(path)"
        case .missingHost:
            return "Missing TV host."
        case .missingClientKey:
            return "Pair the TV first."
        case .missingMAC:
            return "Missing TV MAC address for Wake-on-LAN."
        case .invalidURL(let value):
            return "Invalid URL: \(value)"
        case .invalidJSON:
            return "Invalid JSON."
        case .timeout(let operation):
            return "\(operation) timed out."
        case .webOS(let message):
            return message
        case .socket(let message):
            return message
        }
    }
}
