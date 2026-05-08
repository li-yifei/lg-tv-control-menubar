import AppKit
import AppIntents
import ArgumentParser
import Darwin
import Foundation

let launchSettingsOnStart = CommandLine.arguments.dropFirst().contains("--show-settings")

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

        return PairingConfig(
            host: host,
            model: raw["model"] as? String,
            mac: raw["mac"] as? String,
            wakeMACs: raw["wakeMACs"] as? [String] ?? [],
            clientKey: raw["clientKey"] as? String
        )
    }

    func saveHost(_ host: String) throws {
        var raw = (try? loadRawIfExists()) ?? [:]
        raw["host"] = host
        raw["savedAt"] = isoNow()
        try saveRaw(raw)
    }

    func saveClientKey(_ clientKey: String, host: String) throws {
        var raw = (try? loadRawIfExists()) ?? [:]
        raw["host"] = host
        raw["clientKey"] = clientKey
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

final class WebOSClient: NSObject, URLSessionDelegate {
    private let host: String
    private let clientKey: String?
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?

    init(host: String, clientKey: String?) {
        self.host = host
        self.clientKey = clientKey
        super.init()
    }

    func open() throws {
        let urlString = "wss://\(host):3001"
        guard let url = URL(string: urlString) else {
            throw TVControlError.invalidURL(urlString)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("null", forHTTPHeaderField: "Origin")
        let socket = session.webSocketTask(with: request)
        self.session = session
        self.socket = socket
        socket.resume()
    }

    func close() {
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        session?.invalidateAndCancel()
        session = nil
    }

    func register(forcePairing: Bool) throws -> String {
        var payload = registrationPayload(forcePairing: forcePairing)
        if !forcePairing, let clientKey, !clientKey.isEmpty {
            payload["client-key"] = clientKey
        }

        try sendJSON([
            "type": "register",
            "id": "register_0",
            "payload": payload,
        ])

        let deadline = Date().addingTimeInterval(forcePairing ? 90 : 25)
        while Date() < deadline {
            let message = try receiveJSON(timeout: 5)
            let type = message["type"] as? String

            if type == "registered" {
                let responsePayload = message["payload"] as? [String: Any]
                if let newClientKey = responsePayload?["client-key"] as? String, !newClientKey.isEmpty {
                    return newClientKey
                }
                if let clientKey, !clientKey.isEmpty {
                    return clientKey
                }
                throw TVControlError.missingClientKey
            }

            if type == "error" {
                throw TVControlError.webOS(message["error"] as? String ?? "webOS registration failed.")
            }
        }

        throw TVControlError.timeout("Pairing")
    }

    func request(uri: String, payload: [String: Any]? = nil) throws -> [String: Any] {
        let id = "request_\(UUID().uuidString)"
        var message: [String: Any] = [
            "id": id,
            "type": "request",
            "uri": uri,
        ]
        if let payload {
            message["payload"] = payload
        }

        try sendJSON(message)

        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            let response = try receiveJSON(timeout: 5)
            guard response["id"] as? String == id else { continue }

            if response["type"] as? String == "error" {
                throw TVControlError.webOS(response["error"] as? String ?? "webOS request failed.")
            }

            return response["payload"] as? [String: Any] ?? [:]
        }

        throw TVControlError.timeout(uri)
    }

    private func sendJSON(_ object: [String: Any]) throws {
        guard let socket else {
            throw TVControlError.socket("WebSocket is not open.")
        }

        let data = try JSONSerialization.data(withJSONObject: object)
        guard let text = String(data: data, encoding: .utf8) else {
            throw TVControlError.invalidJSON
        }

        var callbackError: Error?
        let semaphore = DispatchSemaphore(value: 0)
        socket.send(.string(text)) { error in
            callbackError = error
            semaphore.signal()
        }

        if semaphore.wait(timeout: .now() + 15) == .timedOut {
            throw TVControlError.timeout("WebSocket send")
        }
        if let callbackError {
            throw callbackError
        }
    }

    private func receiveJSON(timeout: TimeInterval) throws -> [String: Any] {
        guard let socket else {
            throw TVControlError.socket("WebSocket is not open.")
        }

        var result: Result<URLSessionWebSocketTask.Message, Error>?
        let semaphore = DispatchSemaphore(value: 0)
        socket.receive { messageResult in
            result = messageResult
            semaphore.signal()
        }

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            throw TVControlError.timeout("WebSocket receive")
        }

        switch result {
        case .success(.string(let text)):
            return try parseJSON(text)
        case .success(.data(let data)):
            guard let text = String(data: data, encoding: .utf8) else {
                throw TVControlError.invalidJSON
            }
            return try parseJSON(text)
        case .failure(let error):
            throw error
        case .none:
            throw TVControlError.socket("WebSocket receive failed.")
        @unknown default:
            throw TVControlError.socket("Unknown WebSocket message.")
        }
    }

    private func parseJSON(_ text: String) throws -> [String: Any] {
        guard let data = text.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TVControlError.invalidJSON
        }
        return object
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    private func registrationPayload(forcePairing: Bool) -> [String: Any] {
        [
            "forcePairing": forcePairing,
            "pairingType": "PROMPT",
            "manifest": [
                "manifestVersion": 1,
                "appVersion": "1.1",
                "signed": [
                    "created": "20140509",
                    "appId": "com.lge.test",
                    "vendorId": "com.lge",
                    "localizedAppNames": ["": "LG Remote App"],
                    "localizedVendorNames": ["": "LG Electronics"],
                    "permissions": [
                        "TEST_SECURE",
                        "CONTROL_INPUT_TEXT",
                        "CONTROL_MOUSE_AND_KEYBOARD",
                        "READ_INSTALLED_APPS",
                        "READ_LGE_SDX",
                        "READ_NOTIFICATIONS",
                        "SEARCH",
                        "WRITE_SETTINGS",
                        "WRITE_NOTIFICATION_ALERT",
                        "CONTROL_POWER",
                        "READ_CURRENT_CHANNEL",
                        "READ_RUNNING_APPS",
                        "READ_UPDATE_INFO",
                        "UPDATE_FROM_REMOTE_APP",
                        "READ_LGE_TV_INPUT_EVENTS",
                        "READ_TV_CURRENT_TIME",
                    ],
                    "serial": "2f930e2d2cfe083771f68e4fe7bb07",
                ],
                "permissions": [
                    "LAUNCH",
                    "LAUNCH_WEBAPP",
                    "APP_TO_APP",
                    "CLOSE",
                    "TEST_OPEN",
                    "TEST_PROTECTED",
                    "CONTROL_AUDIO",
                    "CONTROL_DISPLAY",
                    "CONTROL_INPUT_JOYSTICK",
                    "CONTROL_INPUT_MEDIA_RECORDING",
                    "CONTROL_INPUT_MEDIA_PLAYBACK",
                    "CONTROL_INPUT_TV",
                    "CONTROL_POWER",
                    "CONTROL_TV_SCREEN",
                    "READ_APP_STATUS",
                    "READ_CURRENT_CHANNEL",
                    "READ_INPUT_DEVICE_LIST",
                    "READ_NETWORK_STATE",
                    "READ_RUNNING_APPS",
                    "READ_TV_CHANNEL_LIST",
                    "WRITE_NOTIFICATION_TOAST",
                    "READ_POWER_STATE",
                    "READ_COUNTRY_INFO",
                    "READ_SETTINGS",
                ],
                "signatures": [
                    [
                        "signatureVersion": 1,
                        "signature": "eyJhbGdvcml0aG0iOiJSU0EtU0hBMjU2Iiwia2V5SWQiOiJ0ZXN0LXNpZ25pbmctY2VydCIsInNpZ25hdHVyZVZlcnNpb24iOjF9.hrVRgjCwXVvE2OOSpDZ58hR+59aFNwYDyjQgKk3auukd7pcegmE2CzPCa0bJ0ZsRAcKkCTJrWo5iDzNhMBWRyaMOv5zWSrthlf7G128qvIlpMT0YNY+n/FaOHE73uLrS/g7swl3/qH/BGFG2Hu4RlL48eb3lLKqTt2xKHdCs6Cd4RMfJPYnzgvI4BNrFUKsjkcu+WD4OO2A27Pq1n50cMchmcaXadJhGrOqH5YmHdOCj5NSHzJYrsW0HPlpuAx/ECMeIZYDh6RMqaFM2DXzdKX9NmmyqzJ3o/0lkk/N97gfVRLW5hA29yeAwaCViZNCP8iC9aO0q9fQojoa7NQnAtw==",
                    ],
                ],
            ],
        ]
    }
}

final class LGTVController {
    private let store: PairingStore

    init(configPath explicitConfigPath: String? = nil) {
        let configPath = explicitConfigPath
            ?? ProcessInfo.processInfo.environment["LG_TV_CONFIG"]
            ?? ProcessInfo.processInfo.environment["LG_C3_CONFIG"]
            ?? NSHomeDirectory() + "/.config/lg-webos-c3-pairing.json"
        self.store = PairingStore(path: configPath)
    }

    var configPath: String {
        store.configPath
    }

    func configuredHost() -> String? {
        store.configuredHost()
    }

    func pair(host: String, forcePairing: Bool) throws {
        try store.saveHost(host)
        let existingKey = (try? store.loadConfig().clientKey) ?? nil
        let client = WebOSClient(host: host, clientKey: forcePairing ? nil : existingKey)
        try client.open()
        defer { client.close() }
        let clientKey = try client.register(forcePairing: forcePairing)
        try store.saveClientKey(clientKey, host: host)
        try refreshWakeMACs(client: client)
    }

    func status() throws -> TVState {
        try withRegisteredClient { client, config in
            let payload = try client.request(uri: "ssap://audio/getVolume")
            let volumeStatus = payload["volumeStatus"] as? [String: Any]
            let foreground = try? client.request(uri: "ssap://com.webos.applicationManager/getForegroundAppInfo")
            try? refreshWakeMACs(client: client)
            return TVState(
                host: config.host,
                model: config.model,
                volume: intValue(volumeStatus?["volume"] ?? payload["volume"]),
                muted: boolValue(volumeStatus?["muteStatus"] ?? payload["muted"] ?? payload["mute"]),
                currentAppId: foreground?["appId"] as? String
            )
        }
    }

    func inputList() throws -> [TVInput] {
        try withRegisteredClient { client, _ in
            let payload = try client.request(uri: "ssap://tv/getExternalInputList")
            let devices = payload["devices"] as? [[String: Any]] ?? []
            return devices.compactMap { raw in
                guard let id = raw["id"] as? String else { return nil }
                let label = (raw["label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
                return TVInput(
                    id: id,
                    label: label,
                    appId: raw["appId"] as? String,
                    connected: boolValue(raw["connected"]) ?? false,
                    hasSignal: boolValue(raw["hdmiSignalExist"]) ?? false
                )
            }
        }
    }

    func switchInput(_ inputId: String) throws {
        try withRegisteredClient { client, _ in
            _ = try client.request(uri: "ssap://tv/switchInput", payload: ["inputId": inputId])
        }
    }

    func rawRequest(uri: String, payload: [String: Any]? = nil) throws -> [String: Any] {
        try withRegisteredClient { client, _ in
            try client.request(uri: uri, payload: payload)
        }
    }

    func volumeUp() throws {
        try withRegisteredClient { client, _ in
            _ = try client.request(uri: "ssap://audio/volumeUp")
        }
    }

    func volumeDown() throws {
        try withRegisteredClient { client, _ in
            _ = try client.request(uri: "ssap://audio/volumeDown")
        }
    }

    func setVolume(_ value: Int) throws {
        try withRegisteredClient { client, _ in
            _ = try client.request(uri: "ssap://audio/setVolume", payload: ["volume": max(0, min(100, value))])
        }
    }

    func toggleMute(currentMuted: Bool?) throws {
        try withRegisteredClient { client, _ in
            let muted: Bool
            if let currentMuted {
                muted = currentMuted
            } else {
                let payload = try client.request(uri: "ssap://audio/getVolume")
                let volumeStatus = payload["volumeStatus"] as? [String: Any]
                muted = boolValue(volumeStatus?["muteStatus"] ?? payload["muted"] ?? payload["mute"]) ?? false
            }
            _ = try client.request(uri: "ssap://audio/setMute", payload: ["mute": !muted])
        }
    }

    func setMute(_ muted: Bool) throws {
        try withRegisteredClient { client, _ in
            _ = try client.request(uri: "ssap://audio/setMute", payload: ["mute": muted])
        }
    }

    func powerOff() throws {
        try withRegisteredClient { client, _ in
            _ = try client.request(uri: "ssap://system/turnOff")
        }
    }

    func powerOn() throws {
        let config = try store.loadConfig()
        let macs = uniqueMACs(([config.mac].compactMap { $0 }) + config.wakeMACs)
        guard !macs.isEmpty else {
            throw TVControlError.missingMAC
        }

        var sentAny = false
        var lastError: Error?
        for mac in macs {
            do {
                try sendWakeOnLAN(mac: mac, host: config.host)
                sentAny = true
            } catch {
                lastError = error
            }
        }

        if !sentAny {
            throw lastError ?? TVControlError.socket("Wake-on-LAN failed.")
        }
    }

    private func withRegisteredClient<T>(_ work: (WebOSClient, PairingConfig) throws -> T) throws -> T {
        let config = try store.loadConfig()
        guard let clientKey = config.clientKey, !clientKey.isEmpty else {
            throw TVControlError.missingClientKey
        }

        let client = WebOSClient(host: config.host, clientKey: clientKey)
        try client.open()
        defer { client.close() }
        let freshKey = try client.register(forcePairing: false)
        if freshKey != clientKey {
            try store.saveClientKey(freshKey, host: config.host)
        }
        return try work(client, config)
    }

    private func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String {
            return Int(string)
        }
        return nil
    }

    private func boolValue(_ value: Any?) -> Bool? {
        if let bool = value as? Bool {
            return bool
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let string = value as? String {
            return ["true", "1", "yes"].contains(string.lowercased())
        }
        return nil
    }

    private func sendWakeOnLAN(mac: String, host: String) throws {
        let macBytes = try parseMAC(mac)
        var packet = [UInt8](repeating: 0xff, count: 6)
        for _ in 0..<16 {
            packet.append(contentsOf: macBytes)
        }

        var targets = ["255.255.255.255"]
        let hostParts = host.split(separator: ".")
        if hostParts.count == 4 {
            targets.append(hostParts[0...2].joined(separator: ".") + ".255")
        }

        let ports: [UInt16] = [9, 7]
        var sentAny = false
        var lastError: String?
        for target in targets {
            for port in ports {
                do {
                    try sendUDPPacket(packet, target: target, port: port)
                    sentAny = true
                } catch {
                    lastError = error.localizedDescription
                }
            }
        }

        guard sentAny else {
            throw TVControlError.socket(lastError ?? "Wake-on-LAN failed.")
        }
    }

    private func refreshWakeMACs(client: WebOSClient) throws {
        let payload = try client.request(uri: "ssap://com.webos.service.connectionmanager/getinfo")
        let macs = wakeMACs(from: payload)
        try store.saveWakeMACs(macs)
    }

    private func wakeMACs(from payload: [String: Any]) -> [String] {
        var macs: [String] = []
        for key in ["wifiInfo", "wiredInfo", "p2pInfo"] {
            guard let info = payload[key] as? [String: Any],
                  let mac = info["macAddress"] as? String else { continue }
            macs.append(mac)
        }
        return uniqueMACs(macs)
    }

    private func parseMAC(_ mac: String) throws -> [UInt8] {
        let normalized = mac.replacingOccurrences(of: "-", with: ":")
        let parts = normalized.split(separator: ":")
        guard parts.count == 6 else {
            throw TVControlError.socket("Invalid MAC address.")
        }
        return try parts.map { part in
            guard let byte = UInt8(part, radix: 16) else {
                throw TVControlError.socket("Invalid MAC address.")
            }
            return byte
        }
    }

    private func sendUDPPacket(_ packet: [UInt8], target: String, port: UInt16) throws {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else {
            throw TVControlError.socket(String(cString: strerror(errno)))
        }
        defer { close(fd) }

        var enabled: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &enabled, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr(target)

        let sent = packet.withUnsafeBytes { packetPointer -> ssize_t in
            withUnsafePointer(to: &address) { addressPointer in
                addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    sendto(fd, packetPointer.baseAddress, packet.count, 0, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        guard sent == packet.count else {
            throw TVControlError.socket(String(cString: strerror(errno)))
        }
    }
}

enum TVInputChoice: String, AppEnum {
    case hdmi1
    case hdmi2
    case hdmi3
    case hdmi4
    case lgChannels

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "TV Input")

    static let caseDisplayRepresentations: [TVInputChoice: DisplayRepresentation] = [
        .hdmi1: DisplayRepresentation(title: "HDMI 1"),
        .hdmi2: DisplayRepresentation(title: "HDMI 2"),
        .hdmi3: DisplayRepresentation(title: "HDMI 3"),
        .hdmi4: DisplayRepresentation(title: "HDMI 4"),
        .lgChannels: DisplayRepresentation(title: "LG Channels"),
    ]

    var inputId: String {
        switch self {
        case .hdmi1: return "HDMI_1"
        case .hdmi2: return "HDMI_2"
        case .hdmi3: return "HDMI_3"
        case .hdmi4: return "HDMI_4"
        case .lgChannels: return "MVPD_IP-com.webos.app.lgchannels"
        }
    }
}

struct TurnOnTVIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn On TV"
    static let description = IntentDescription("Turns on the paired LG TV.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        try LGTVController().powerOn()
        return .result(dialog: "Turning on the TV.")
    }
}

struct TurnOffTVIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn Off TV"
    static let description = IntentDescription("Turns off the paired LG TV.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        try LGTVController().powerOff()
        return .result(dialog: "Turning off the TV.")
    }
}

struct VolumeUpTVIntent: AppIntent {
    static let title: LocalizedStringResource = "TV Volume Up"
    static let description = IntentDescription("Raises the paired LG TV volume by one step.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        try LGTVController().volumeUp()
        return .result(dialog: "Volume up.")
    }
}

struct VolumeDownTVIntent: AppIntent {
    static let title: LocalizedStringResource = "TV Volume Down"
    static let description = IntentDescription("Lowers the paired LG TV volume by one step.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        try LGTVController().volumeDown()
        return .result(dialog: "Volume down.")
    }
}

struct SetTVVolumeIntent: AppIntent {
    static let title: LocalizedStringResource = "Set TV Volume"
    static let description = IntentDescription("Sets the paired LG TV volume from 0 to 100.")
    static let openAppWhenRun = false

    @Parameter(title: "Volume")
    var volume: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Set TV volume to \(\.$volume)")
    }

    func perform() async throws -> some IntentResult {
        let clampedVolume = max(0, min(100, volume))
        try LGTVController().setVolume(clampedVolume)
        return .result(dialog: "Set TV volume to \(clampedVolume).")
    }
}

struct ToggleTVMuteIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle TV Mute"
    static let description = IntentDescription("Toggles mute on the paired LG TV.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        try LGTVController().toggleMute(currentMuted: nil)
        return .result(dialog: "Toggled mute.")
    }
}

struct SwitchTVInputIntent: AppIntent {
    static let title: LocalizedStringResource = "Switch TV Input"
    static let description = IntentDescription("Switches the paired LG TV to an input.")
    static let openAppWhenRun = false

    @Parameter(title: "Input")
    var input: TVInputChoice

    static var parameterSummary: some ParameterSummary {
        Summary("Switch TV input to \(\.$input)")
    }

    func perform() async throws -> some IntentResult {
        try LGTVController().switchInput(input.inputId)
        return .result(dialog: "Switched TV input.")
    }
}

struct LGTVControlShortcuts: AppShortcutsProvider {
    static let shortcutTileColor: ShortcutTileColor = .blue

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TurnOnTVIntent(),
            phrases: [
                "Turn on \(.applicationName)",
                "Power on \(.applicationName)",
            ],
            shortTitle: "Turn On TV",
            systemImageName: "power.circle.fill"
        )
        AppShortcut(
            intent: TurnOffTVIntent(),
            phrases: [
                "Turn off \(.applicationName)",
                "Power off \(.applicationName)",
            ],
            shortTitle: "Turn Off TV",
            systemImageName: "power.circle"
        )
        AppShortcut(
            intent: SetTVVolumeIntent(),
            phrases: [
                "Set \(.applicationName) volume to \(\.$volume)",
                "Set TV volume in \(.applicationName) to \(\.$volume)",
            ],
            shortTitle: "Set Volume",
            systemImageName: "speaker.wave.2.fill"
        )
        AppShortcut(
            intent: VolumeUpTVIntent(),
            phrases: [
                "Turn up \(.applicationName)",
                "Increase \(.applicationName) volume",
            ],
            shortTitle: "Volume Up",
            systemImageName: "speaker.plus.fill"
        )
        AppShortcut(
            intent: VolumeDownTVIntent(),
            phrases: [
                "Turn down \(.applicationName)",
                "Decrease \(.applicationName) volume",
            ],
            shortTitle: "Volume Down",
            systemImageName: "speaker.minus.fill"
        )
        AppShortcut(
            intent: ToggleTVMuteIntent(),
            phrases: [
                "Mute \(.applicationName)",
                "Toggle mute in \(.applicationName)",
            ],
            shortTitle: "Mute",
            systemImageName: "speaker.slash.fill"
        )
        AppShortcut(
            intent: SwitchTVInputIntent(),
            phrases: [
                "Switch \(.applicationName) to \(\.$input)",
                "Change \(.applicationName) input to \(\.$input)",
            ],
            shortTitle: "Switch Input",
            systemImageName: "rectangle.connected.to.line.below"
        )
    }
}

enum ShortcutAction: String, CaseIterable {
    case volumeUp
    case volumeDown
    case toggleMute
    case powerOn
    case powerOff
    case pair
    case refresh
    case settings

    var title: String {
        switch self {
        case .volumeUp: return "Volume Up"
        case .volumeDown: return "Volume Down"
        case .toggleMute: return "Mute"
        case .powerOn: return "Power On"
        case .powerOff: return "Power Off"
        case .pair: return "Pair / Re-pair"
        case .refresh: return "Refresh"
        case .settings: return "Settings"
        }
    }

    var defaultKey: String {
        switch self {
        case .volumeUp: return "]"
        case .volumeDown: return "["
        case .toggleMute: return "m"
        case .powerOn: return "o"
        case .powerOff: return "f"
        case .pair: return "p"
        case .refresh: return "r"
        case .settings: return ","
        }
    }

    var defaultsKey: String {
        "shortcut.\(rawValue)"
    }

    var symbolName: String {
        switch self {
        case .volumeUp: return "speaker.plus.fill"
        case .volumeDown: return "speaker.minus.fill"
        case .toggleMute: return "speaker.slash.fill"
        case .powerOn: return "power.circle.fill"
        case .powerOff: return "power.circle"
        case .pair: return "link"
        case .refresh: return "arrow.clockwise"
        case .settings: return "gearshape"
        }
    }
}

final class AppSettings {
    static let shared = AppSettings()
    static let didChangeNotification = Notification.Name("LGTVControlSettingsDidChange")

    private let defaults = UserDefaults.standard

    private init() {
        var registered: [String: Any] = [
            "safeVolumeReminderEnabled": true,
            "safeVolumeThreshold": 20,
        ]
        for action in ShortcutAction.allCases {
            registered[action.defaultsKey] = action.defaultKey
        }
        defaults.register(defaults: registered)
    }

    var safeVolumeReminderEnabled: Bool {
        get { defaults.bool(forKey: "safeVolumeReminderEnabled") }
        set {
            defaults.set(newValue, forKey: "safeVolumeReminderEnabled")
            notifyChanged()
        }
    }

    var safeVolumeThreshold: Int {
        get { defaults.integer(forKey: "safeVolumeThreshold") }
        set {
            defaults.set(max(0, min(100, newValue)), forKey: "safeVolumeThreshold")
            notifyChanged()
        }
    }

    func shortcut(for action: ShortcutAction) -> String {
        defaults.string(forKey: action.defaultsKey) ?? action.defaultKey
    }

    func setShortcut(_ shortcut: String, for action: ShortcutAction) {
        defaults.set(normalizeShortcut(shortcut), forKey: action.defaultsKey)
        notifyChanged()
    }

    func resetShortcuts() {
        for action in ShortcutAction.allCases {
            defaults.set(action.defaultKey, forKey: action.defaultsKey)
        }
        notifyChanged()
    }

    private func normalizeShortcut(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased() == "space" {
            return " "
        }
        return trimmed.first.map { String($0).lowercased() } ?? ""
    }

    private func notifyChanged() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}

final class SettingsWindowController: NSWindowController, NSTextFieldDelegate {
    private let settings = AppSettings.shared
    private let safeVolumeCheckbox = NSButton(checkboxWithTitle: "Safety volume reminder", target: nil, action: nil)
    private let thresholdField = NSTextField()
    private let thresholdStepper = NSStepper()
    private let cliStatusLabel = NSTextField(labelWithString: "")
    private let cliButton = NSButton(title: "", target: nil, action: nil)
    private var shortcutFields: [ShortcutAction: NSTextField] = [:]

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 640),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.minSize = NSSize(width: 460, height: 580)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildContent()
        loadValues()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        refreshCLIInstallState()
    }

    private func buildContent() {
        guard let contentView = window?.contentView else { return }

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 18
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 28),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -28),
            root.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 28),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
        ])

        root.addArrangedSubview(sectionLabel("Volume Safety"))

        safeVolumeCheckbox.target = self
        safeVolumeCheckbox.action = #selector(safeVolumeChanged)
        root.addArrangedSubview(safeVolumeCheckbox)

        let thresholdRow = NSStackView()
        thresholdRow.orientation = .horizontal
        thresholdRow.alignment = .centerY
        thresholdRow.spacing = 10
        thresholdRow.translatesAutoresizingMaskIntoConstraints = false
        thresholdRow.addArrangedSubview(rowLabel("Reminder threshold"))
        thresholdField.alignment = .right
        thresholdField.target = self
        thresholdField.action = #selector(thresholdChanged)
        thresholdField.delegate = self
        thresholdField.translatesAutoresizingMaskIntoConstraints = false
        thresholdField.widthAnchor.constraint(equalToConstant: 64).isActive = true
        thresholdRow.addArrangedSubview(thresholdField)
        thresholdStepper.minValue = 0
        thresholdStepper.maxValue = 100
        thresholdStepper.increment = 1
        thresholdStepper.target = self
        thresholdStepper.action = #selector(thresholdStepperChanged)
        thresholdRow.addArrangedSubview(thresholdStepper)
        root.addArrangedSubview(thresholdRow)

        root.addArrangedSubview(spacer(height: 10))
        root.addArrangedSubview(sectionLabel("Command Line Tool"))

        let cliRow = NSStackView()
        cliRow.orientation = .horizontal
        cliRow.alignment = .centerY
        cliRow.spacing = 12
        cliRow.translatesAutoresizingMaskIntoConstraints = false
        cliStatusLabel.lineBreakMode = .byTruncatingMiddle
        cliStatusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cliRow.addArrangedSubview(cliStatusLabel)

        let cliSpacer = NSView()
        cliSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        cliRow.addArrangedSubview(cliSpacer)

        cliButton.target = self
        cliButton.action = #selector(toggleCLIInstall)
        cliButton.bezelStyle = .rounded
        cliRow.addArrangedSubview(cliButton)
        root.addArrangedSubview(cliRow)
        cliRow.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        root.addArrangedSubview(spacer(height: 10))
        root.addArrangedSubview(sectionLabel("Menu Shortcuts"))

        let shortcutsStack = NSStackView()
        shortcutsStack.orientation = .vertical
        shortcutsStack.alignment = .leading
        shortcutsStack.spacing = 8
        root.addArrangedSubview(shortcutsStack)

        for action in ShortcutAction.allCases {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 10
            row.addArrangedSubview(rowLabel(action.title))

            let field = NSTextField()
            field.alignment = .center
            field.identifier = NSUserInterfaceItemIdentifier(action.rawValue)
            field.target = self
            field.action = #selector(shortcutChanged(_:))
            field.delegate = self
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 70).isActive = true
            shortcutFields[action] = field
            row.addArrangedSubview(field)

            shortcutsStack.addArrangedSubview(row)
        }

        let filler = NSView()
        filler.setContentHuggingPriority(.defaultLow, for: .vertical)
        root.addArrangedSubview(filler)

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 12
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        let resetButton = NSButton(title: "Reset Shortcuts", target: self, action: #selector(resetShortcuts))
        buttonRow.addArrangedSubview(resetButton)

        let buttonSpacer = NSView()
        buttonSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        buttonRow.addArrangedSubview(buttonSpacer)

        let doneButton = NSButton(title: "Done", target: self, action: #selector(closeWindow))
        doneButton.bezelStyle = .rounded
        buttonRow.addArrangedSubview(doneButton)
        root.addArrangedSubview(buttonRow)
        buttonRow.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let field = label(text)
        field.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize + 1)
        return field
    }

    private func rowLabel(_ text: String) -> NSTextField {
        let field = label(text)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 170).isActive = true
        return field
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        return field
    }

    private func spacer(height: CGFloat) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        return view
    }

    private func loadValues() {
        safeVolumeCheckbox.state = settings.safeVolumeReminderEnabled ? .on : .off
        thresholdField.integerValue = settings.safeVolumeThreshold
        thresholdStepper.integerValue = settings.safeVolumeThreshold

        for action in ShortcutAction.allCases {
            shortcutFields[action]?.stringValue = displayShortcut(settings.shortcut(for: action))
        }
        refreshCLIInstallState()
    }

    @objc private func safeVolumeChanged() {
        settings.safeVolumeReminderEnabled = safeVolumeCheckbox.state == .on
    }

    @objc private func thresholdChanged() {
        saveThreshold(thresholdField.integerValue)
    }

    @objc private func thresholdStepperChanged() {
        saveThreshold(thresholdStepper.integerValue)
    }

    @objc private func shortcutChanged(_ sender: NSTextField) {
        guard let rawValue = sender.identifier?.rawValue,
              let action = ShortcutAction(rawValue: rawValue) else {
            return
        }
        settings.setShortcut(sender.stringValue, for: action)
        sender.stringValue = displayShortcut(settings.shortcut(for: action))
    }

    @objc private func resetShortcuts() {
        settings.resetShortcuts()
        loadValues()
    }

    @objc private func toggleCLIInstall() {
        do {
            if isCLIInstalled {
                try uninstallCLI()
            } else {
                try installCLI()
            }
            refreshCLIInstallState()
        } catch {
            showError(error.localizedDescription)
        }
    }

    @objc private func closeWindow() {
        window?.close()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if let field = obj.object as? NSTextField, field === thresholdField {
            saveThreshold(field.integerValue)
            return
        }

        guard let field = obj.object as? NSTextField,
              let rawValue = field.identifier?.rawValue,
              let action = ShortcutAction(rawValue: rawValue) else {
            return
        }
        settings.setShortcut(field.stringValue, for: action)
        field.stringValue = displayShortcut(settings.shortcut(for: action))
    }

    private func saveThreshold(_ value: Int) {
        settings.safeVolumeThreshold = value
        thresholdField.integerValue = settings.safeVolumeThreshold
        thresholdStepper.integerValue = settings.safeVolumeThreshold
    }

    private var cliInstallURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".local/bin/lgtv")
    }

    private var isCLIInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: cliInstallURL.path)
    }

    private func refreshCLIInstallState() {
        let displayPath = cliInstallURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        if isCLIInstalled {
            cliStatusLabel.stringValue = "Installed at \(displayPath)"
            cliButton.title = "Uninstall CLI"
        } else {
            cliStatusLabel.stringValue = "Not installed. Target: \(displayPath)"
            cliButton.title = "Install CLI"
        }
    }

    private func installCLI() throws {
        guard let executableURL = Bundle.main.executableURL else {
            throw TVControlError.socket("Could not find the app executable.")
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: cliInstallURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: cliInstallURL.path) {
            try fileManager.removeItem(at: cliInstallURL)
        }
        try fileManager.copyItem(at: executableURL, to: cliInstallURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cliInstallURL.path)
    }

    private func uninstallCLI() throws {
        if FileManager.default.fileExists(atPath: cliInstallURL.path) {
            try FileManager.default.removeItem(at: cliInstallURL)
        }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Command Line Tool"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func displayShortcut(_ shortcut: String) -> String {
        shortcut == " " ? "space" : shortcut
    }
}

final class SafetyVolumePromptView: NSView {
    private let onContinue: () -> Void
    private let onCancel: () -> Void

    init(targetVolume: Int, threshold: Int, onContinue: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.onContinue = onContinue
        self.onCancel = onCancel
        super.init(frame: NSRect(x: 0, y: 0, width: 360, height: 104))
        build(targetVolume: targetVolume, threshold: threshold)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func build(targetVolume: Int, threshold: Int) {
        let box = NSBox()
        box.boxType = .custom
        box.borderWidth = 1
        box.borderColor = NSColor.systemYellow.withAlphaComponent(0.7)
        box.fillColor = NSColor.systemYellow.withAlphaComponent(0.14)
        box.cornerRadius = 8
        box.translatesAutoresizingMaskIntoConstraints = false
        addSubview(box)

        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            box.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),
            box.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            box.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.contentView?.addSubview(stack)

        if let contentView = box.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
                stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
                stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
                stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
            ])
        }

        let title = NSTextField(labelWithString: "Volume safety")
        title.font = NSFont.boldSystemFont(ofSize: 12)
        stack.addArrangedSubview(title)

        let message = NSTextField(labelWithString: "Set volume to \(targetVolume)? Threshold is \(threshold).")
        message.font = NSFont.menuFont(ofSize: 0)
        message.lineBreakMode = .byTruncatingTail
        stack.addArrangedSubview(message)

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        buttons.addArrangedSubview(spacer)

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.bezelStyle = .rounded
        buttons.addArrangedSubview(cancelButton)

        let continueButton = NSButton(title: "Continue", target: self, action: #selector(continueAction))
        continueButton.bezelStyle = .rounded
        continueButton.bezelColor = .systemYellow
        continueButton.keyEquivalent = "\r"
        buttons.addArrangedSubview(continueButton)

        stack.addArrangedSubview(buttons)
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    @objc private func cancel() {
        onCancel()
    }

    @objc private func continueAction() {
        onContinue()
    }
}

final class SafetyVolumeSlider: NSSlider {
    var isTrackingMouse = false
    var onTrackingEnded: (() -> Void)?

    var safetyThreshold: Int = 20 {
        didSet {
            needsDisplay = true
        }
    }

    var safetyEnabled: Bool = true {
        didSet {
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawThresholdMark()
    }

    override func mouseDown(with event: NSEvent) {
        isTrackingMouse = true
        super.mouseDown(with: event)
        isTrackingMouse = false
        onTrackingEnded?()
    }

    private func drawThresholdMark() {
        guard safetyEnabled,
              maxValue > minValue,
              safetyThreshold > Int(minValue),
              safetyThreshold < Int(maxValue) else {
            return
        }

        let usableWidth = bounds.width - 12
        let ratio = CGFloat((Double(safetyThreshold) - minValue) / (maxValue - minValue))
        let x = bounds.minX + 6 + usableWidth * ratio
        let markRect = NSRect(x: x - 1, y: bounds.midY - 7, width: 2, height: 14)
        NSColor.systemYellow.setFill()
        NSBezierPath(roundedRect: markRect, xRadius: 1, yRadius: 1).fill()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let controller = LGTVController()
    private let settings = AppSettings.shared
    private var currentState: TVState?
    private var currentInputs: [TVInput] = []
    private var isBusy = false
    private var settingsWindowController: SettingsWindowController?
    private var shortcutItems: [ShortcutAction: NSMenuItem] = [:]
    private var menuKeyMonitor: Any?
    private var volumeMenuItem: NSMenuItem?
    private var safetyVolumePromptItem: NSMenuItem?
    private var safetyVolumeCancelHandler: (() -> Void)?
    private var safetyVolumeDidConfirm = false
    private var volumeControlsView: NSView?
    private let inputMenu = NSMenu()

    private let titleItem = NSMenuItem(title: "LG TV Control", action: nil, keyEquivalent: "")
    private let titleLabel = NSTextField(labelWithString: "LG TV Control")
    private let statusLineItem = NSMenuItem(title: "Volume: --", action: nil, keyEquivalent: "")
    private let slider = SafetyVolumeSlider(value: 0, minValue: 0, maxValue: 100, target: nil, action: #selector(sliderChanged(_:)))
    private let sliderLabel = NSTextField(labelWithString: "--")
    private let volumeDownButton = NSButton(frame: .zero)
    private let volumeUpButton = NSButton(frame: .zero)
    private let muteButton = NSButton(frame: .zero)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            if let image = NSImage(systemSymbolName: "tv.fill", accessibilityDescription: "LG TV Control") {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "LG"
            }
        }

        menu.delegate = self
        buildMenu()
        statusItem.menu = menu
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsChanged),
            name: AppSettings.didChangeNotification,
            object: nil
        )
        refreshStatus()
        if launchSettingsOnStart {
            DispatchQueue.main.async {
                self.openSettings()
            }
        }
    }

    private func buildMenu() {
        menu.autoenablesItems = false
        inputMenu.autoenablesItems = false
        titleItem.isEnabled = true
        titleItem.view = titleHeaderView()
        menu.addItem(titleItem)

        statusLineItem.isEnabled = false

        menu.addItem(NSMenuItem.separator())
        menu.addItem(sliderItem())
        menu.addItem(NSMenuItem.separator())

        menu.addItem(shortcutMenuItem(title: "Power On", action: #selector(powerOn), shortcutAction: .powerOn))
        menu.addItem(shortcutMenuItem(title: "Power Off", action: #selector(powerOff), shortcutAction: .powerOff))

        menu.addItem(NSMenuItem.separator())
        let inputItem = NSMenuItem(title: "Input", action: nil, keyEquivalent: "")
        inputItem.image = menuIcon("rectangle.connected.to.line.below")
        inputItem.submenu = inputMenu
        inputItem.isEnabled = true
        menu.addItem(inputItem)
        rebuildInputMenu()

        menu.addItem(NSMenuItem.separator())
        menu.addItem(shortcutMenuItem(title: "Pair / Re-pair", action: #selector(pairTV), shortcutAction: .pair))
        menu.addItem(shortcutMenuItem(title: "Settings...", action: #selector(openSettings), shortcutAction: .settings))
        menu.addItem(shortcutMenuItem(title: "Refresh", action: #selector(refreshStatusAction), shortcutAction: .refresh))
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.image = menuIcon("xmark.circle")
        quitItem.isEnabled = true
        menu.addItem(quitItem)

        for item in menu.items where item.action != nil {
            item.target = self
        }
        updateMenuShortcuts()
    }

    private func shortcutMenuItem(title: String, action: Selector, shortcutAction: ShortcutAction) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = menuIcon(shortcutAction.symbolName)
        item.isEnabled = true
        shortcutItems[shortcutAction] = item
        return item
    }

    private func titleHeaderView() -> NSView {
        let wrapper = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 34))
        titleLabel.frame = NSRect(x: 28, y: 8, width: 318, height: 18)
        titleLabel.font = NSFont.menuFont(ofSize: 0)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        wrapper.addSubview(titleLabel)
        return wrapper
    }

    private func menuIcon(_ symbolName: String) -> NSImage? {
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }

    private func rebuildInputMenu() {
        inputMenu.removeAllItems()

        if currentInputs.isEmpty {
            let item = NSMenuItem(title: "Loading...", action: nil, keyEquivalent: "")
            item.isEnabled = false
            inputMenu.addItem(item)
            return
        }

        for input in currentInputs {
            let item = NSMenuItem(title: inputTitle(input), action: #selector(selectInput(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = input.id
            item.image = menuIcon(input.hasSignal ? "cable.connector.horizontal" : "cable.connector")
            item.isEnabled = true
            if let currentAppId = currentState?.currentAppId,
               input.appId == currentAppId {
                item.state = .on
            }
            inputMenu.addItem(item)
        }
    }

    private func inputTitle(_ input: TVInput) -> String {
        let normalizedId = input.id.replacingOccurrences(of: "_", with: " ")
        if input.label.caseInsensitiveCompare(normalizedId) == .orderedSame || input.label == input.id {
            return normalizedId
        }
        return "\(input.label) (\(normalizedId))"
    }

    private func sliderItem() -> NSMenuItem {
        let item = NSMenuItem()
        item.isEnabled = true
        volumeMenuItem = item
        let wrapper = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 38))
        volumeControlsView = wrapper

        configureVolumeButton(volumeDownButton, symbolName: "speaker.minus.fill", action: #selector(volumeDown), tooltip: "Volume Down")
        configureVolumeButton(volumeUpButton, symbolName: "speaker.plus.fill", action: #selector(volumeUp), tooltip: "Volume Up")
        configureVolumeButton(muteButton, symbolName: ShortcutAction.toggleMute.symbolName, action: #selector(toggleMute), tooltip: "Mute")
        slider.numberOfTickMarks = 0
        slider.isContinuous = true
        slider.isEnabled = true
        slider.cell?.isEnabled = true
        slider.safetyThreshold = settings.safeVolumeThreshold
        slider.safetyEnabled = settings.safeVolumeReminderEnabled
        slider.target = self
        slider.onTrackingEnded = { [weak self] in
            self?.commitSliderValue()
        }
        sliderLabel.alignment = .right

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(row)

        row.addArrangedSubview(volumeDownButton)
        row.addArrangedSubview(slider)
        row.addArrangedSubview(volumeUpButton)
        row.addArrangedSubview(muteButton)
        row.addArrangedSubview(sliderLabel)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 28),
            row.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -28),
            row.centerYAnchor.constraint(equalTo: wrapper.centerYAnchor),
            volumeDownButton.widthAnchor.constraint(equalToConstant: 28),
            volumeDownButton.heightAnchor.constraint(equalToConstant: 28),
            volumeUpButton.widthAnchor.constraint(equalToConstant: 28),
            volumeUpButton.heightAnchor.constraint(equalToConstant: 28),
            muteButton.widthAnchor.constraint(equalToConstant: 28),
            muteButton.heightAnchor.constraint(equalToConstant: 28),
            sliderLabel.widthAnchor.constraint(equalToConstant: 26),
            slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),
        ])

        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        slider.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        item.view = wrapper
        return item
    }

    private func configureVolumeButton(_ button: NSButton, symbolName: String, action: Selector, tooltip: String) {
        button.target = self
        button.action = action
        button.title = ""
        button.translatesAutoresizingMaskIntoConstraints = false
        button.image = menuIcon(symbolName)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = .labelColor
        button.isEnabled = true
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.setButtonType(.momentaryChange)
        button.focusRingType = .none
        button.toolTip = tooltip
    }

    func menuWillOpen(_ menu: NSMenu) {
        installMenuKeyMonitor()
        refreshStatus()
    }

    func menuDidClose(_ menu: NSMenu) {
        removeMenuKeyMonitor()
        removeSafetyVolumePrompt(shouldCancel: true)
    }

    @objc private func selectInput(_ sender: NSMenuItem) {
        guard let inputId = sender.representedObject as? String else { return }
        runCommand(statusText: "Switching input...") { try self.controller.switchInput(inputId) }
    }

    @objc private func volumeUp() {
        if let volume = currentState?.volume {
            let targetVolume = min(100, volume + 1)
            if requiresSafeVolumeConfirmation(targetVolume: targetVolume) {
                showSafeVolumeConfirmation(targetVolume: targetVolume) {
                    self.runCommand(statusText: "Volume up...") { try self.controller.volumeUp() }
                }
                return
            }
        }
        runCommand(statusText: "Volume up...") { try self.controller.volumeUp() }
    }

    @objc private func volumeDown() {
        runCommand(statusText: "Volume down...") { try self.controller.volumeDown() }
    }

    @objc private func toggleMute() {
        runCommand(statusText: "Toggling mute...") { try self.controller.toggleMute(currentMuted: self.currentState?.muted) }
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        let value = Int(sender.integerValue)
        updateSliderLabel(value)
        guard (sender as? SafetyVolumeSlider)?.isTrackingMouse != true else {
            return
        }
        commitSliderValue()
    }

    private func commitSliderValue() {
        let rollbackVolume = currentState?.volume
        let value = Int(slider.integerValue)
        updateSliderLabel(value)
        guard value != rollbackVolume else {
            return
        }
        if requiresSafeVolumeConfirmation(targetVolume: value) {
            showSafeVolumeConfirmation(
                targetVolume: value,
                onContinue: {
                    self.runCommand(statusText: "Setting volume \(value)...") { try self.controller.setVolume(value) }
                },
                onCancel: {
                    self.restoreSliderVolume(to: rollbackVolume)
                }
            )
            return
        }
        runCommand(statusText: "Setting volume \(value)...") { try self.controller.setVolume(value) }
    }

    @objc private func powerOn() {
        runCommand(statusText: "Powering on...") { try self.controller.powerOn() }
    }

    @objc private func powerOff() {
        runCommand(statusText: "Powering off...") { try self.controller.powerOff() }
    }

    @objc private func pairTV() {
        let defaultHost = controller.configuredHost() ?? ""
        guard let host = promptForHost(defaultValue: defaultHost) else { return }
        runCommand(statusText: "Pairing...") { try self.controller.pair(host: host, forcePairing: true) }
    }

    @objc private func refreshStatusAction() {
        refreshStatus()
    }

    @objc private func openSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController()
        }
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.center()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func settingsChanged() {
        slider.safetyThreshold = settings.safeVolumeThreshold
        slider.safetyEnabled = settings.safeVolumeReminderEnabled
        updateSliderLabel(Int(slider.integerValue))
        updateMenuShortcuts()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func refreshStatus() {
        runCommand(statusText: "Refreshing...") {
            self.currentState = try self.controller.status()
            self.currentInputs = (try? self.controller.inputList()) ?? self.currentInputs
        }
    }

    private func runCommand(statusText: String, work: @escaping () throws -> Void) {
        guard !isBusy else { return }
        isBusy = true
        updateStatus(statusText)

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try work()
                if !["Refreshing...", "Powering off...", "Powering on..."].contains(statusText) {
                    self.currentState = try self.controller.status()
                    self.currentInputs = (try? self.controller.inputList()) ?? self.currentInputs
                }
                DispatchQueue.main.async {
                    self.applyState()
                    self.isBusy = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.updateStatus(error.localizedDescription)
                    self.isBusy = false
                }
            }
        }
    }

    private func applyState() {
        guard let state = currentState else {
            updateStatus("Volume: --")
            return
        }

        let volumeText = state.volume.map(String.init) ?? "--"
        let mutedText = state.muted == true ? " muted" : ""
        let modelText = state.model.map { " \($0)" } ?? ""
        statusLineItem.title = "Volume: \(volumeText)\(mutedText)"
        titleLabel.stringValue = "LG TV\(modelText)"
        muteButton.image = menuIcon(state.muted == true ? "speaker.wave.2.fill" : ShortcutAction.toggleMute.symbolName)
        rebuildInputMenu()

        if let volume = state.volume {
            slider.integerValue = volume
            updateSliderLabel(volume)
        } else {
            sliderLabel.stringValue = "--"
            sliderLabel.textColor = .labelColor
        }

        statusItem.button?.toolTip = "LG TV Volume \(volumeText)\(mutedText)"
        updateVolumeButtonTooltips()
    }

    private func updateStatus(_ text: String) {
        statusLineItem.title = text
        statusItem.button?.toolTip = text
    }

    private func updateMenuShortcuts() {
        for (action, item) in shortcutItems {
            let shortcut = settings.shortcut(for: action)
            item.keyEquivalent = shortcut
            item.keyEquivalentModifierMask = []
        }
        updateVolumeButtonTooltips()
    }

    private func updateVolumeButtonTooltips() {
        volumeDownButton.toolTip = tooltip(for: .volumeDown)
        volumeUpButton.toolTip = tooltip(for: .volumeUp)
        let muteTitle = currentState?.muted == true ? "Unmute" : "Mute"
        muteButton.toolTip = tooltip(title: muteTitle, shortcut: settings.shortcut(for: .toggleMute))
    }

    private func updateSliderLabel(_ value: Int) {
        sliderLabel.stringValue = String(value)
        if requiresSafeVolumeConfirmation(targetVolume: value) {
            sliderLabel.textColor = .systemYellow
        } else {
            sliderLabel.textColor = .labelColor
        }
    }

    private func tooltip(for action: ShortcutAction) -> String {
        tooltip(title: action.title, shortcut: settings.shortcut(for: action))
    }

    private func tooltip(title: String, shortcut: String) -> String {
        let display = displayShortcut(shortcut)
        return display.isEmpty ? title : "\(title) (\(display))"
    }

    private func installMenuKeyMonitor() {
        guard menuKeyMonitor == nil else { return }
        menuKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let action = self.volumeShortcutAction(for: event) else {
                return event
            }
            self.runVolumeShortcut(action)
            return nil
        }
    }

    private func removeMenuKeyMonitor() {
        guard let menuKeyMonitor else { return }
        NSEvent.removeMonitor(menuKeyMonitor)
        self.menuKeyMonitor = nil
    }

    private func volumeShortcutAction(for event: NSEvent) -> ShortcutAction? {
        let modifiersToIgnore: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        guard event.modifierFlags.intersection(modifiersToIgnore).isEmpty,
              let characters = event.charactersIgnoringModifiers?.lowercased() else {
            return nil
        }

        for action in [ShortcutAction.volumeUp, .volumeDown, .toggleMute] {
            if characters == settings.shortcut(for: action) {
                return action
            }
        }
        return nil
    }

    private func runVolumeShortcut(_ action: ShortcutAction) {
        switch action {
        case .volumeUp:
            volumeUp()
        case .volumeDown:
            volumeDown()
        case .toggleMute:
            toggleMute()
        default:
            break
        }
    }

    private func displayShortcut(_ shortcut: String) -> String {
        if shortcut == " " {
            return "Space"
        }
        return shortcut.count == 1 ? shortcut.uppercased() : shortcut
    }

    private func requiresSafeVolumeConfirmation(targetVolume: Int) -> Bool {
        settings.safeVolumeReminderEnabled && targetVolume > settings.safeVolumeThreshold
    }

    private func showSafeVolumeConfirmation(
        targetVolume: Int,
        onContinue: @escaping () -> Void,
        onCancel: @escaping () -> Void = {}
    ) {
        removeSafetyVolumePrompt(shouldCancel: false)

        safetyVolumeDidConfirm = false
        safetyVolumeCancelHandler = onCancel

        let promptItem = NSMenuItem()
        promptItem.isEnabled = true
        promptItem.view = SafetyVolumePromptView(
            targetVolume: targetVolume,
            threshold: settings.safeVolumeThreshold,
            onContinue: { [weak self] in
                self?.safetyVolumeDidConfirm = true
                self?.safetyVolumeCancelHandler = nil
                self?.removeSafetyVolumePrompt(shouldCancel: false)
                onContinue()
            },
            onCancel: { [weak self] in
                self?.removeSafetyVolumePrompt(shouldCancel: true)
            }
        )
        safetyVolumePromptItem = promptItem

        let insertIndex: Int
        if let volumeMenuItem,
           let volumeIndex = menu.items.firstIndex(of: volumeMenuItem) {
            insertIndex = volumeIndex + 1
        } else {
            insertIndex = min(2, menu.items.count)
        }
        menu.insertItem(promptItem, at: insertIndex)
    }

    private func removeSafetyVolumePrompt(shouldCancel: Bool) {
        if let safetyVolumePromptItem {
            menu.removeItem(safetyVolumePromptItem)
            self.safetyVolumePromptItem = nil
        }
        if shouldCancel, !safetyVolumeDidConfirm {
            let cancelHandler = safetyVolumeCancelHandler
            safetyVolumeCancelHandler = nil
            cancelHandler?()
        } else {
            safetyVolumeCancelHandler = nil
        }
        safetyVolumeDidConfirm = false
    }

    private func restoreSliderVolume(to rollbackVolume: Int?) {
        if let volume = rollbackVolume ?? currentState?.volume {
            slider.integerValue = volume
            updateSliderLabel(volume)
        }
    }

    private func promptForHost(defaultValue: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Pair LG TV"
        alert.informativeText = "Accept the pairing prompt on the TV after starting."
        alert.addButton(withTitle: "Pair")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "TV IP address"
        field.stringValue = defaultValue
        alert.accessoryView = field

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }
        let host = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return host.isEmpty ? nil : host
    }
}

enum OutputFormat: String, ExpressibleByArgument, CaseIterable {
    case text
    case json

    init?(argument: String) {
        self.init(rawValue: argument.lowercased())
    }
}

struct CommonOptions: ParsableArguments {
    @Option(name: .customLong("config"), help: "Pairing JSON path. Defaults to LG_TV_CONFIG, LG_C3_CONFIG, then ~/.config/lg-webos-c3-pairing.json.")
    var configPath: String?

    func controller() -> LGTVController {
        LGTVController(configPath: configPath)
    }
}

struct OutputOptions: ParsableArguments {
    @Option(name: .shortAndLong, help: "Output format: text or json.")
    var format: OutputFormat = .text

    @Flag(name: .customLong("json"), help: "Shortcut for --format json.")
    var json = false

    var resolvedFormat: OutputFormat {
        json ? .json : format
    }
}

struct QuietOptions: ParsableArguments {
    @Flag(name: .shortAndLong, help: "Suppress the final ok line.")
    var quiet = false
}

struct LGTVCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lgtv",
        abstract: "Control a paired LG webOS TV from the terminal.",
        discussion: """
        Reads existing pairing credentials from ~/.config/lg-webos-c3-pairing.json by default.
        Override the config path with --config PATH on a command, or set LG_TV_CONFIG.

        Examples:
          lgtv status
          lgtv status --json
          lgtv volume set 12
          lgtv volume up --steps 3
          lgtv mute on
          lgtv input list
          lgtv input switch HDMI_2
          lgtv power on
          lgtv raw ssap://audio/getVolume --json
        """,
        version: "0.3.0",
        subcommands: [
            StatusCommand.self,
            InputsCommand.self,
            PairCommand.self,
            VolumeCommand.self,
            MuteCommand.self,
            PowerCommand.self,
            InputCommand.self,
            RawCommand.self,
            ConfigCommand.self,
            AppCommand.self,
        ]
    )
}

struct StatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Print TV host, model, volume, mute state, and current foreground app."
    )

    @OptionGroup var common: CommonOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let state = try common.controller().status()
        switch output.resolvedFormat {
        case .json:
            try writeJSON(stateJSONObject(state))
        case .text:
            writeLine("Host: \(state.host)")
            writeLine("Model: \(state.model ?? "-")")
            writeLine("Volume: \(state.volume.map(String.init) ?? "-")")
            writeLine("Muted: \(state.muted.map(boolText) ?? "-")")
            writeLine("Current App: \(state.currentAppId ?? "-")")
        }
    }
}

struct InputsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inputs",
        abstract: "List TV input sources.",
        discussion: "Alias-style top-level command for `lgtv input list`."
    )

    @OptionGroup var common: CommonOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        try printInputs(controller: common.controller(), format: output.resolvedFormat)
    }
}

struct PairCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pair",
        abstract: "Pair or re-pair the TV and save the client key.",
        discussion: "When HOST is omitted, the saved host from the config file is used. Accept the prompt shown on the TV."
    )

    @OptionGroup var common: CommonOptions
    @OptionGroup var quiet: QuietOptions

    @Argument(help: "TV host or IP address. Uses the saved host when omitted.")
    var host: String?

    @Flag(name: .customLong("reuse-key"), help: "Try the saved client key before showing a TV pairing prompt.")
    var reuseKey = false

    func run() throws {
        let controller = common.controller()
        let resolvedHost = host ?? controller.configuredHost()
        guard let resolvedHost, !resolvedHost.isEmpty else {
            throw ValidationError("Missing host. Use `lgtv pair <host>`.")
        }
        try controller.pair(host: resolvedHost, forcePairing: !reuseKey)
        writeOK("paired \(resolvedHost)", quiet: quiet.quiet)
    }
}

struct VolumeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "volume",
        abstract: "Read or change TV volume.",
        subcommands: [
            VolumeGetCommand.self,
            VolumeSetCommand.self,
            VolumeUpCommand.self,
            VolumeDownCommand.self,
        ]
    )
}

struct VolumeGetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Print current TV volume.")

    @OptionGroup var common: CommonOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let state = try common.controller().status()
        switch output.resolvedFormat {
        case .json:
            try writeJSON([
                "volume": nullable(state.volume),
                "muted": nullable(state.muted),
            ])
        case .text:
            writeLine(state.volume.map(String.init) ?? "-")
        }
    }
}

struct VolumeSetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: "Set TV volume to an exact value from 0 to 100.")

    @OptionGroup var common: CommonOptions
    @OptionGroup var quiet: QuietOptions

    @Argument(help: "Volume value from 0 to 100.")
    var value: Int

    func validate() throws {
        guard (0...100).contains(value) else {
            throw ValidationError("Volume must be between 0 and 100.")
        }
    }

    func run() throws {
        try common.controller().setVolume(value)
        writeOK("ok", quiet: quiet.quiet)
    }
}

struct VolumeUpCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "up", abstract: "Raise TV volume by one or more steps.")

    @OptionGroup var common: CommonOptions
    @OptionGroup var quiet: QuietOptions

    @Option(name: .shortAndLong, help: "Number of one-step volume increments.")
    var steps = 1

    func validate() throws {
        guard steps >= 1 else {
            throw ValidationError("Steps must be at least 1.")
        }
    }

    func run() throws {
        let controller = common.controller()
        for _ in 0..<steps {
            try controller.volumeUp()
        }
        writeOK("ok", quiet: quiet.quiet)
    }
}

struct VolumeDownCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "down", abstract: "Lower TV volume by one or more steps.")

    @OptionGroup var common: CommonOptions
    @OptionGroup var quiet: QuietOptions

    @Option(name: .shortAndLong, help: "Number of one-step volume decrements.")
    var steps = 1

    func validate() throws {
        guard steps >= 1 else {
            throw ValidationError("Steps must be at least 1.")
        }
    }

    func run() throws {
        let controller = common.controller()
        for _ in 0..<steps {
            try controller.volumeDown()
        }
        writeOK("ok", quiet: quiet.quiet)
    }
}

struct MuteCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mute",
        abstract: "Read or change mute state.",
        subcommands: [
            MuteStatusCommand.self,
            MuteToggleCommand.self,
            MuteOnCommand.self,
            MuteOffCommand.self,
        ]
    )
}

struct MuteStatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Print current mute state.")

    @OptionGroup var common: CommonOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let state = try common.controller().status()
        switch output.resolvedFormat {
        case .json:
            try writeJSON(["muted": nullable(state.muted)])
        case .text:
            writeLine(state.muted.map(boolText) ?? "-")
        }
    }
}

struct MuteToggleCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "toggle", abstract: "Toggle mute.")

    @OptionGroup var common: CommonOptions
    @OptionGroup var quiet: QuietOptions

    func run() throws {
        try common.controller().toggleMute(currentMuted: nil)
        writeOK("ok", quiet: quiet.quiet)
    }
}

struct MuteOnCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "on", abstract: "Mute the TV.")

    @OptionGroup var common: CommonOptions
    @OptionGroup var quiet: QuietOptions

    func run() throws {
        try common.controller().setMute(true)
        writeOK("ok", quiet: quiet.quiet)
    }
}

struct MuteOffCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "off", abstract: "Unmute the TV.")

    @OptionGroup var common: CommonOptions
    @OptionGroup var quiet: QuietOptions

    func run() throws {
        try common.controller().setMute(false)
        writeOK("ok", quiet: quiet.quiet)
    }
}

struct PowerCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "power",
        abstract: "Turn the TV on or off.",
        subcommands: [
            PowerOnCommand.self,
            PowerOffCommand.self,
        ]
    )
}

struct PowerOnCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "on", abstract: "Wake the TV using Wake-on-LAN.")

    @OptionGroup var common: CommonOptions
    @OptionGroup var quiet: QuietOptions

    func run() throws {
        try common.controller().powerOn()
        writeOK("ok", quiet: quiet.quiet)
    }
}

struct PowerOffCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "off", abstract: "Turn the TV off through the webOS API.")

    @OptionGroup var common: CommonOptions
    @OptionGroup var quiet: QuietOptions

    func run() throws {
        try common.controller().powerOff()
        writeOK("ok", quiet: quiet.quiet)
    }
}

struct InputCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "input",
        abstract: "List, inspect, or switch TV input sources.",
        subcommands: [
            InputListCommand.self,
            InputCurrentCommand.self,
            InputSwitchCommand.self,
        ]
    )
}

struct InputListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List TV input sources.")

    @OptionGroup var common: CommonOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        try printInputs(controller: common.controller(), format: output.resolvedFormat)
    }
}

struct InputCurrentCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "current", abstract: "Print current foreground app ID.")

    @OptionGroup var common: CommonOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let state = try common.controller().status()
        switch output.resolvedFormat {
        case .json:
            try writeJSON(["currentAppId": nullable(state.currentAppId)])
        case .text:
            writeLine(state.currentAppId ?? "-")
        }
    }
}

struct InputSwitchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "switch", abstract: "Switch to an input ID from `lgtv input list`.")

    @OptionGroup var common: CommonOptions
    @OptionGroup var quiet: QuietOptions

    @Argument(help: "Input ID, for example HDMI_2 or MVPD_IP-com.webos.app.lgchannels.")
    var inputId: String

    func run() throws {
        try common.controller().switchInput(inputId)
        writeOK("ok", quiet: quiet.quiet)
    }
}

struct RawCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "raw",
        abstract: "Send a raw webOS SSAP request.",
        discussion: "Payload must be a JSON object. The response payload is printed as JSON."
    )

    @OptionGroup var common: CommonOptions

    @Argument(help: "SSAP URI, for example ssap://audio/getVolume.")
    var uri: String

    @Option(name: .shortAndLong, help: "JSON object payload, for example '{\"volume\":12}'.")
    var payload: String?

    @Flag(name: .customLong("json"), help: "Accepted for consistency. Raw responses are always JSON.")
    var json = false

    func run() throws {
        let requestPayload = try payload.map(parseJSONObject)
        let response = try common.controller().rawRequest(uri: uri, payload: requestPayload)
        try writeJSON(response)
    }
}

struct ConfigCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Inspect local CLI configuration.",
        subcommands: [
            ConfigPathCommand.self,
        ]
    )
}

struct ConfigPathCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "path", abstract: "Print the pairing config path used by this command.")

    @OptionGroup var common: CommonOptions

    func run() throws {
        writeLine(common.controller().configPath)
    }
}

struct AppCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "app",
        abstract: "Open the menu bar app from the CLI.",
        subcommands: [
            AppOpenCommand.self,
            AppSettingsCommand.self,
        ]
    )
}

struct AppOpenCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "open", abstract: "Open the menu bar app.")

    @OptionGroup var quiet: QuietOptions

    func run() throws {
        try openInstalledApp(showSettings: false)
        writeOK("ok", quiet: quiet.quiet)
    }
}

struct AppSettingsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "settings", abstract: "Open the app settings window.")

    @OptionGroup var quiet: QuietOptions

    func run() throws {
        try openInstalledApp(showSettings: true)
        writeOK("ok", quiet: quiet.quiet)
    }
}

func stateJSONObject(_ state: TVState) -> [String: Any] {
    [
        "host": state.host,
        "model": state.model ?? NSNull(),
        "volume": state.volume ?? NSNull(),
        "muted": state.muted ?? NSNull(),
        "currentAppId": state.currentAppId ?? NSNull(),
    ]
}

func inputJSONObject(_ input: TVInput) -> [String: Any] {
    [
        "id": input.id,
        "label": input.label,
        "appId": input.appId ?? NSNull(),
        "connected": input.connected,
        "hasSignal": input.hasSignal,
    ]
}

func printInputs(controller: LGTVController, format: OutputFormat) throws {
    let inputs = try controller.inputList()
    switch format {
    case .json:
        try writeJSON(inputs.map(inputJSONObject))
    case .text:
        writeLine("ID\tLABEL\tAPP_ID\tCONNECTED\tSIGNAL")
        for input in inputs {
            writeLine("\(input.id)\t\(input.label)\t\(input.appId ?? "-")\t\(boolText(input.connected))\t\(boolText(input.hasSignal))")
        }
    }
}

func nullable<T>(_ value: T?) -> Any {
    value ?? NSNull()
}

func parseJSONObject(_ raw: String) throws -> [String: Any] {
    guard let data = raw.data(using: .utf8),
          let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw ValidationError("Payload must be a JSON object.")
    }
    return object
}

func writeJSON(_ object: Any) throws {
    guard JSONSerialization.isValidJSONObject(object) else {
        throw TVControlError.invalidJSON
    }
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func writeLine(_ text: String) {
    FileHandle.standardOutput.write(Data("\(text)\n".utf8))
}

func writeOK(_ text: String, quiet: Bool) {
    guard !quiet else { return }
    writeLine(text)
}

func boolText(_ value: Bool) -> String {
    value ? "true" : "false"
}

func openInstalledApp(showSettings: Bool) throws {
    let bundlePath = Bundle.main.bundlePath
    let appPath = bundlePath.hasSuffix(".app")
        ? bundlePath
        : NSHomeDirectory() + "/Applications/LG TV Control.app"
    var arguments = [appPath]
    if showSettings {
        arguments.append(contentsOf: ["--args", "--show-settings"])
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw TVControlError.socket("Failed to open app at \(appPath).")
    }
}

func runCLIIfRequested() -> Bool {
    let args = normalizeLeadingGlobalOptions(Array(CommandLine.arguments.dropFirst()))
    let executableName = URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent
    let invokedAsCLI = executableName == "lgtv"
    guard let normalizedArgs = normalizedCLIArguments(args, invokedAsCLI: invokedAsCLI) else {
        return false
    }
    LGTVCLI.main(normalizedArgs)
    return true
}

func normalizedCLIArguments(_ args: [String], invokedAsCLI: Bool) -> [String]? {
    guard let first = args.first else {
        return invokedAsCLI ? ["--help"] : nil
    }

    if first == "--show-settings" {
        return nil
    }

    if first == "--cli" {
        let rest = Array(args.dropFirst())
        return rest.isEmpty ? ["--help"] : rest
    }

    switch first {
    case "--status":
        return ["status", "--format", "json"] + Array(args.dropFirst())
    case "--inputs":
        return ["inputs", "--format", "json"] + Array(args.dropFirst())
    case "--pair":
        return ["pair"] + Array(args.dropFirst())
    case "--set-volume":
        return ["volume", "set"] + Array(args.dropFirst())
    case "--volume-up":
        return ["volume", "up"] + Array(args.dropFirst())
    case "--volume-down":
        return ["volume", "down"] + Array(args.dropFirst())
    case "--toggle-mute":
        return ["mute", "toggle"] + Array(args.dropFirst())
    case "--power-on":
        return ["power", "on"] + Array(args.dropFirst())
    case "--power-off":
        return ["power", "off"] + Array(args.dropFirst())
    case "--set-input":
        return ["input", "switch"] + Array(args.dropFirst())
    case "--help", "-h", "--version", "help":
        return args
    default:
        let commandNames: Set<String> = [
            "status",
            "inputs",
            "pair",
            "volume",
            "mute",
            "power",
            "input",
            "raw",
            "config",
            "app",
        ]
        if commandNames.contains(first) || invokedAsCLI {
            return args
        }
        return nil
    }
}

func normalizeLeadingGlobalOptions(_ args: [String]) -> [String] {
    var index = 0
    var globalOptions: [String] = []

    while index < args.count {
        let argument = args[index]
        if argument == "--config" {
            globalOptions.append(argument)
            if index + 1 < args.count {
                globalOptions.append(args[index + 1])
                index += 2
            } else {
                index += 1
            }
            continue
        }
        if argument.hasPrefix("--config=") {
            globalOptions.append("--config")
            globalOptions.append(String(argument.dropFirst("--config=".count)))
            index += 1
            continue
        }
        break
    }

    guard !globalOptions.isEmpty else {
        return args
    }

    var rest = Array(args.dropFirst(index))
    guard !rest.isEmpty else {
        return globalOptions
    }

    let insertionIndex = commonOptionInsertionIndex(rest)
    rest.insert(contentsOf: globalOptions, at: insertionIndex)
    return rest
}

func commonOptionInsertionIndex(_ args: [String]) -> Int {
    guard let first = args.first else {
        return 0
    }

    let oneLevelCommands: Set<String> = [
        "status",
        "inputs",
        "pair",
        "raw",
        "--status",
        "--inputs",
        "--pair",
        "--set-volume",
        "--volume-up",
        "--volume-down",
        "--toggle-mute",
        "--power-on",
        "--power-off",
        "--set-input",
    ]
    if oneLevelCommands.contains(first) {
        return min(1, args.count)
    }

    let twoLevelCommands: Set<String> = [
        "volume",
        "mute",
        "power",
        "input",
        "config",
    ]
    if twoLevelCommands.contains(first) {
        return min(2, args.count)
    }

    return 0
}

if runCLIIfRequested() {
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
