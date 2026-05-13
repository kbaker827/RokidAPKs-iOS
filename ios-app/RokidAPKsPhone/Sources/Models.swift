import Foundation

// MARK: - Transfer state machine

enum TransferPhase: Equatable {
    case idle
    case waitingForGlasses
    case connected
    case transferring(progress: Double)
    case complete(message: String)
    case failed(String)

    static func == (lhs: TransferPhase, rhs: TransferPhase) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.waitingForGlasses, .waitingForGlasses), (.connected, .connected):
            return true
        case (.transferring(let a), .transferring(let b)): return a == b
        case (.complete(let a), .complete(let b)): return a == b
        case (.failed(let a), .failed(let b)): return a == b
        default: return false
        }
    }
}

// MARK: - Protocol messages

/// Offer sent from the iOS phone to the glasses companion over the control channel.
/// Framing matches the original Kotlin implementation: 4-byte big-endian length + UTF-8 JSON body.
struct TransferOffer {
    let hostIp: String
    let port: Int
    let apkSize: Int64
    let md5Hex: String
    let fileName: String

    func toJSONData() throws -> Data {
        let dict: [String: Any] = [
            "type": "offer",
            "transportMode": "wifi_lan",
            "hostIp": hostIp,
            "port": port,
            "apkSize": apkSize,
            "md5": md5Hex,
            "fileName": fileName,
        ]
        return try JSONSerialization.data(withJSONObject: dict)
    }
}

/// Result sent back from the glasses companion after the APK install attempt.
struct TransferResult {
    let success: Bool
    let message: String
}

// MARK: - Errors

enum TransferError: LocalizedError {
    case noWiFi
    case glassesFailed(String)
    case timeout
    case connectionClosed

    var errorDescription: String? {
        switch self {
        case .noWiFi:
            return "No Wi-Fi or hotspot address found. Connect the iPhone to the same network as the glasses."
        case .glassesFailed(let msg):
            return "Glasses reported failure: \(msg)"
        case .timeout:
            return "Timed out waiting for the glasses companion to connect or respond."
        case .connectionClosed:
            return "Control connection closed unexpectedly."
        }
    }
}
