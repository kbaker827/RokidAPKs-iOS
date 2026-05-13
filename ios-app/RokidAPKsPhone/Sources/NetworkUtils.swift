import Foundation
import ifaddrs

/// Resolves the best local IPv4 address for a Wi-Fi or hotspot interface.
/// Mirrors the scoring logic in the original Kotlin WifiLanUploadSession.
enum NetworkUtils {
    static func localWiFiIPAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(first) }

        var bestAddress: String?
        var bestScore = Int.min

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let iface = ptr {
            defer { ptr = iface.pointee.ifa_next }

            let flags = Int32(iface.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }
            guard let sa = iface.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }

            let name = String(cString: iface.pointee.ifa_name)
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(sa, socklen_t(sa.pointee.sa_len), &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST)
            let address = String(cString: buf)

            guard isWiFiLike(name), isPrivateLAN(address) else { continue }

            let score = scoreInterface(name: name, address: address)
            if score > bestScore {
                bestScore = score
                bestAddress = address
            }
        }
        return bestAddress
    }

    private static func isWiFiLike(_ name: String) -> Bool {
        let l = name.lowercased()
        // en0 = Wi-Fi on iPhone; bridge/ap* = hotspot
        return l == "en0" || l.hasPrefix("en") || l.hasPrefix("ap") || l.contains("wifi") || l.contains("wlan")
    }

    private static func isPrivateLAN(_ addr: String) -> Bool {
        if addr.hasPrefix("192.168.") || addr.hasPrefix("10.") { return true }
        let parts = addr.split(separator: ".").compactMap { Int($0) }
        return parts.count >= 2 && parts[0] == 172 && (16...31).contains(parts[1])
    }

    private static func scoreInterface(name: String, address: String) -> Int {
        var score = 0
        let l = name.lowercased()
        if l == "en0" { score += 200 }
        else if l.hasPrefix("en") { score += 150 }
        else if l.hasPrefix("ap") { score += 130 }
        else if l.contains("wifi") || l.contains("wlan") { score += 120 }

        if address.hasPrefix("192.168.") { score += 80 }
        else if address.hasPrefix("10.") { score += 60 }
        else if address.hasPrefix("172.") { score += 40 }
        return score
    }
}
