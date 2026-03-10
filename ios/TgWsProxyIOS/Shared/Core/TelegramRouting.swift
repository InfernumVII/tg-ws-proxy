import Foundation

enum TelegramRouting {
    static let telegramRanges: [(UInt32, UInt32)] = [
        (ipv4ToUInt32("185.76.151.0"), ipv4ToUInt32("185.76.151.255")),
        (ipv4ToUInt32("149.154.160.0"), ipv4ToUInt32("149.154.175.255")),
        (ipv4ToUInt32("91.105.192.0"), ipv4ToUInt32("91.105.193.255")),
        (ipv4ToUInt32("91.108.0.0"), ipv4ToUInt32("91.108.255.255"))
    ]

    static let ipToDC: [String: Int] = [
        "149.154.175.50": 1, "149.154.175.51": 1, "149.154.175.54": 1,
        "149.154.167.41": 2, "149.154.167.50": 2, "149.154.167.51": 2, "149.154.167.220": 2,
        "149.154.175.100": 3, "149.154.175.101": 3,
        "149.154.167.91": 4, "149.154.167.92": 4,
        "91.108.56.100": 5, "91.108.56.126": 5, "91.108.56.101": 5, "91.108.56.116": 5,
        "91.105.192.100": 203
    ]

    static func isTelegramIP(_ host: String) -> Bool {
        guard let number = ipv4ToUInt32Optional(host) else {
            return false
        }
        return telegramRanges.contains { lower, upper in
            lower <= number && number <= upper
        }
    }

    static func wsDomains(dc: Int, isMedia: Bool?) -> [String] {
        let base = dc > 5 ? "telegram.org" : "web.telegram.org"
        if isMedia == nil || isMedia == true {
            return ["kws\(dc)-1.\(base)", "kws\(dc).\(base)"]
        }
        return ["kws\(dc).\(base)", "kws\(dc)-1.\(base)"]
    }

    private static func ipv4ToUInt32(_ address: String) -> UInt32 {
        ipv4ToUInt32Optional(address) ?? 0
    }

    private static func ipv4ToUInt32Optional(_ address: String) -> UInt32? {
        let octets = address.split(separator: ".")
        guard octets.count == 4 else { return nil }

        var value: UInt32 = 0
        for octet in octets {
            guard let byte = UInt8(octet) else { return nil }
            value = (value << 8) | UInt32(byte)
        }
        return value
    }
}
