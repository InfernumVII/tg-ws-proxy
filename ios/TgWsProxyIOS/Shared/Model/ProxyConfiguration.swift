import Foundation

struct ProxyConfiguration: Codable, Equatable {
    var dcIP: [String]
    var verboseLogging: Bool

    init?(dcIP: [String], verboseLogging: Bool) {
        let normalized = dcIP
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !normalized.isEmpty else {
            return nil
        }

        guard normalized.allSatisfy(Self.isValidMapping(_:)) else {
            return nil
        }

        self.dcIP = normalized
        self.verboseLogging = verboseLogging
    }

    static let defaults = ProxyConfiguration(uncheckedDCIP: [
        "2:149.154.167.220",
        "4:149.154.167.220"
    ], verboseLogging: false)

    var dcMap: [Int: String] {
        Dictionary(uniqueKeysWithValues: dcIP.compactMap { line in
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let dc = Int(parts[0]), Self.isIPv4(parts[1]) else {
                return nil
            }
            return (dc, parts[1])
        })
    }

    var providerConfiguration: [String: Any] {
        [
            "dc_ip": dcIP,
            "verbose": verboseLogging
        ]
    }

    static func fromProviderConfiguration(_ dictionary: [String: Any]?) -> ProxyConfiguration {
        guard let dictionary else {
            return .defaults
        }
        let dcIP = dictionary["dc_ip"] as? [String] ?? defaults.dcIP
        let verbose = dictionary["verbose"] as? Bool ?? defaults.verboseLogging
        return ProxyConfiguration(uncheckedDCIP: dcIP, verboseLogging: verbose)
    }

    private init(uncheckedDCIP: [String], verboseLogging: Bool) {
        self.dcIP = uncheckedDCIP
        self.verboseLogging = verboseLogging
    }

    private static func isValidMapping(_ line: String) -> Bool {
        let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, Int(parts[0]) != nil else {
            return false
        }
        return isIPv4(parts[1])
    }

    private static func isIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".")
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { octet in
            guard let number = Int(octet), String(number) == octet else {
                return false
            }
            return (0...255).contains(number)
        }
    }
}
