import Darwin
import Foundation

final class LGTVController {
    private let store: PairingStore

    init(configPath explicitConfigPath: String? = nil) {
        let configPath = explicitConfigPath
            ?? ProcessInfo.processInfo.environment["LG_TV_CONFIG"]
            ?? (NSHomeDirectory() + "/.config/lgtv-pairing.json")
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

    func saveIPControlKeycode(_ keycode: String) throws {
        try store.saveIPControlKeycode(keycode)
    }

    func clearIPControlKeycode() throws {
        try store.clearIPControlKeycode()
    }

    func currentIPControlKeycode() -> String? {
        store.currentIPControlKeycode()
    }

    func sendIPControlKey(_ key: String) throws {
        let config = try store.loadConfig()
        let client = IPControlClient(host: config.host, keycode: config.ipControlKeycode)
        try client.sendKey(key)
    }

    func launchFactoryApp(irKey: String, pin: String) throws {
        try withRegisteredClient { client, _ in
            _ = try client.request(
                uri: "ssap://system.launcher/launch",
                payload: [
                    "id": "com.webos.app.factorywin",
                    "params": ["id": "executeFactory", "irKey": irKey],
                ]
            )
        }
        guard !pin.isEmpty else { return }
        let config = try store.loadConfig()
        let ipClient = IPControlClient(host: config.host, keycode: config.ipControlKeycode)
        try ipClient.connect()
        defer { ipClient.disconnect() }
        Thread.sleep(forTimeInterval: 1.8)
        for digit in pin {
            try ipClient.sendKey("number\(digit)")
            Thread.sleep(forTimeInterval: 0.45)
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
