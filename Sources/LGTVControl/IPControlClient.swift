import CommonCrypto
import Darwin
import Foundation

final class IPControlClient {
    private let host: String
    private let port: Int32
    private let derivedKey: Data?
    private var persistentFd: Int32 = -1

    private static let salt: [UInt8] = [99, 97, 184, 14, 155, 220, 166, 99, 141, 7, 32, 242, 204, 86, 143, 185]
    private static let blockSize = 16
    private static let pbkdf2Iterations: UInt32 = 16384

    init(host: String, keycode: String?, port: Int32 = 9761) {
        self.host = host
        self.port = port
        self.derivedKey = keycode.flatMap { Self.deriveKey($0) }
    }

    private static func deriveKey(_ keycode: String) -> Data? {
        guard keycode.range(of: "^[A-Z0-9]{8}$", options: .regularExpression) != nil else {
            return nil
        }
        var derived = [UInt8](repeating: 0, count: blockSize)
        let status = CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            keycode, keycode.utf8.count,
            salt, salt.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
            pbkdf2Iterations,
            &derived, blockSize
        )
        guard status == kCCSuccess else { return nil }
        return Data(derived)
    }

    func sendKey(_ key: String) throws {
        let response = try sendCommand("KEY_ACTION \(key)")
        guard response == "OK" else {
            throw TVControlError.webOS("IP control: \(response)")
        }
    }

    func connect() throws {
        disconnect()
        persistentFd = try openSocket()
    }

    func disconnect() {
        if persistentFd >= 0 {
            Darwin.close(persistentFd)
            persistentFd = -1
        }
    }

    private func sendCommand(_ command: String) throws -> String {
        let message = command + "\r"
        let encoded: Data
        if let derivedKey {
            encoded = try performEncrypt(message, key: derivedKey)
        } else {
            encoded = Data(message.utf8)
        }

        let responseData = try tcpSendReceive(encoded)

        if let derivedKey {
            return try performDecrypt(responseData, key: derivedKey)
        } else {
            guard let text = String(data: responseData, encoding: .utf8) else {
                throw TVControlError.invalidJSON
            }
            return text.trimmingCharacters(in: .newlines)
        }
    }

    private func performEncrypt(_ message: String, key: Data) throws -> Data {
        let padded = padMessage(message)
        guard let paddedData = padded.data(using: .utf8) else {
            throw TVControlError.invalidJSON
        }

        var iv = [UInt8](repeating: 0, count: Self.blockSize)
        for i in 0..<Self.blockSize {
            iv[i] = UInt8.random(in: 0...254)
        }
        let ivData = Data(iv)

        let encryptedIV = try aesECB(.doEncrypt, data: ivData, key: key)
        let encryptedData = try aesCBC(.doEncrypt, data: paddedData, key: key, iv: ivData)

        return encryptedIV + encryptedData
    }

    private func performDecrypt(_ cipher: Data, key: Data) throws -> String {
        guard cipher.count > Self.blockSize else {
            throw TVControlError.webOS("IP control response too short.")
        }

        let iv = try aesECB(.doDecrypt, data: cipher.prefix(Self.blockSize), key: key)
        let decrypted = try aesCBC(.doDecrypt, data: cipher.dropFirst(Self.blockSize), key: key, iv: iv)

        guard let text = String(data: decrypted, encoding: .utf8) else {
            throw TVControlError.invalidJSON
        }
        if let idx = text.firstIndex(of: "\n") {
            return String(text[..<idx])
        }
        return text
    }

    private func padMessage(_ message: String) -> String {
        var msg = message
        if msg.count % Self.blockSize == 0 {
            msg += " "
        }
        let remainder = msg.count % Self.blockSize
        if remainder != 0 {
            let padding = Self.blockSize - remainder
            msg += String(repeating: Character(UnicodeScalar(UInt8(padding))), count: padding)
        }
        return msg
    }

    private enum AESDirection {
        case doEncrypt, doDecrypt
        var cc: CCOperation {
            switch self {
            case .doEncrypt: return CCOperation(kCCEncrypt)
            case .doDecrypt: return CCOperation(kCCDecrypt)
            }
        }
    }

    private func aesECB(_ op: AESDirection, data: Data, key: Data) throws -> Data {
        var out = [UInt8](repeating: 0, count: data.count + Self.blockSize)
        var outLen: size_t = 0
        let status = data.withUnsafeBytes { dataPtr in
            key.withUnsafeBytes { keyPtr in
                CCCrypt(
                    op.cc, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                    keyPtr.baseAddress, key.count,
                    nil,
                    dataPtr.baseAddress, data.count,
                    &out, out.count, &outLen
                )
            }
        }
        guard status == kCCSuccess else {
            throw TVControlError.webOS("AES-ECB failed (\(status)).")
        }
        return Data(out.prefix(outLen))
    }

    private func aesCBC(_ op: AESDirection, data: Data, key: Data, iv: Data) throws -> Data {
        var out = [UInt8](repeating: 0, count: data.count + Self.blockSize)
        var outLen: size_t = 0
        let status = data.withUnsafeBytes { dataPtr in
            key.withUnsafeBytes { keyPtr in
                iv.withUnsafeBytes { ivPtr in
                    CCCrypt(
                        op.cc, CCAlgorithm(kCCAlgorithmAES), 0,
                        keyPtr.baseAddress, key.count,
                        ivPtr.baseAddress,
                        dataPtr.baseAddress, data.count,
                        &out, out.count, &outLen
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            throw TVControlError.webOS("AES-CBC failed (\(status)).")
        }
        return Data(out.prefix(outLen))
    }

    private func openSocket() throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else {
            throw TVControlError.socket(String(cString: strerror(errno)))
        }

        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr(host)

        let connectResult = withUnsafePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connectResult == 0 else {
            Darwin.close(fd)
            throw TVControlError.socket("TCP connect to \(host):\(port) failed.")
        }
        return fd
    }

    private func tcpSendReceive(_ data: Data) throws -> Data {
        let usePersistent = persistentFd >= 0
        let fd: Int32 = usePersistent ? persistentFd : try openSocket()
        defer {
            if !usePersistent {
                Darwin.close(fd)
            }
        }

        let sent = data.withUnsafeBytes { ptr in
            Darwin.send(fd, ptr.baseAddress, data.count, 0)
        }
        guard sent == data.count else {
            throw TVControlError.socket("TCP send failed.")
        }

        var buffer = [UInt8](repeating: 0, count: 4096)
        let received = recv(fd, &buffer, buffer.count, 0)
        guard received > 0 else {
            throw TVControlError.timeout("IP control receive")
        }

        return Data(buffer[0..<received])
    }
}
