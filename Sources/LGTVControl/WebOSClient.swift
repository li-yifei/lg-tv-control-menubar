import Foundation

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
