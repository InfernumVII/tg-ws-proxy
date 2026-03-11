import Foundation
import NetworkExtension

@MainActor
final class AppModel: ObservableObject {
    @Published var dcIPText: String = ProxyConfiguration.defaults.dcIP.joined(separator: "\n")
    @Published var verboseLogging = false
    @Published var statusMessage = "Preparing configuration…"
    @Published var debugMessage = ""
    @Published var isBusy = false
    @Published var isRunning = false

    private var manager: NETunnelProviderManager?
    private let providerBundleIdentifier = "org.flowseal.TgWsProxyIOS.TgWsProxyTunnel"

    var tunnelStateText: String {
        guard let session = manager?.connection else {
            return "not installed"
        }
        switch session.status {
        case .connected:
            return "connected"
        case .connecting:
            return "connecting"
        case .disconnected:
            return "disconnected"
        case .disconnecting:
            return "disconnecting"
        case .invalid:
            return "invalid"
        case .reasserting:
            return "reasserting"
        @unknown default:
            return "unknown"
        }
    }

    func load() async {
        let defaults = UserDefaults.standard
        if let savedText = defaults.string(forKey: "dcIPText") {
            dcIPText = savedText
        }
        verboseLogging = defaults.bool(forKey: "verboseLogging")
        await refreshManager()
        statusMessage = "Edit the mapping, install the profile, then start the tunnel."
    }

    func saveConfiguration() async {
        guard parseCurrentConfiguration() != nil else {
            statusMessage = "Invalid DC:IP lines. Use one mapping per line, for example 2:149.154.167.220"
            return
        }
        let defaults = UserDefaults.standard
        defaults.set(dcIPText, forKey: "dcIPText")
        defaults.set(verboseLogging, forKey: "verboseLogging")
        statusMessage = "Configuration saved locally."
    }

    func installProfile() async {
        guard let configuration = parseCurrentConfiguration() else {
            statusMessage = "Cannot install profile: invalid DC mapping."
            return
        }

        isBusy = true
        defer { isBusy = false }

        do {
            let manager = try await obtainManager()
            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = providerBundleIdentifier
            proto.serverAddress = "TG WS Proxy"
            proto.providerConfiguration = configuration.providerConfiguration

            manager.localizedDescription = "TG WS Proxy"
            manager.protocolConfiguration = proto
            manager.isEnabled = true

            try await save(manager: manager)
            try await loadFromPreferences(manager: manager)

            self.manager = manager
            statusMessage = "VPN/App Proxy profile installed. The system may ask for confirmation."
            debugMessage = managerSummary(manager, stage: "install-success")
        } catch {
            let details = errorDetails(error)
            statusMessage = "Failed to install profile: \(details)"
            debugMessage = managerSummary(manager, stage: "install-failed")
        }
    }

    func startTunnel() async {
        if manager == nil {
            await refreshManager()
        }
        guard let manager else {
            statusMessage = "Install the profile first."
            return
        }

        isBusy = true
        defer { isBusy = false }

        do {
            if manager.protocolConfiguration == nil {
                await installProfile()
            }
            try manager.connection.startVPNTunnel()
            isRunning = true
            statusMessage = "Tunnel start requested. Check iOS VPN status if it does not connect."
            debugMessage = managerSummary(manager, stage: "start-requested")
        } catch {
            let details = errorDetails(error)
            statusMessage = "Failed to start tunnel: \(details)"
            debugMessage = managerSummary(manager, stage: "start-failed")
        }
    }

    func stopTunnel() async {
        manager?.connection.stopVPNTunnel()
        isRunning = false
        statusMessage = "Tunnel stop requested."
    }

    func refreshManager() async {
        do {
            manager = try await loadExistingManager()
            isRunning = manager?.connection.status == .connected || manager?.connection.status == .connecting
            debugMessage = managerSummary(manager, stage: "refresh")
        } catch {
            let details = errorDetails(error)
            statusMessage = "Failed to load existing profile: \(details)"
            debugMessage = "refresh failed"
        }
    }

    private func parseCurrentConfiguration() -> ProxyConfiguration? {
        ProxyConfiguration(dcIP: dcIPText.split(separator: "\n").map { String($0) }, verboseLogging: verboseLogging)
    }

    private func obtainManager() async throws -> NETunnelProviderManager {
        if let manager {
            return manager
        }
        let loaded = try await loadExistingManager() ?? NETunnelProviderManager()
        self.manager = loaded
        return loaded
    }

    private func loadExistingManager() async throws -> NETunnelProviderManager? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NETunnelProviderManager?, Error>) in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: managers?.first)
            }
        }
    }

    private func save(manager: NETunnelProviderManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.saveToPreferences { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func loadFromPreferences(manager: NETunnelProviderManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.loadFromPreferences { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func errorDetails(_ error: Error) -> String {
        let nsError = error as NSError
        var parts: [String] = []
        parts.append(nsError.localizedDescription)
        parts.append("domain=\(nsError.domain)")
        parts.append("code=\(nsError.code)")
        if let reason = nsError.userInfo[NSLocalizedFailureReasonErrorKey] as? String, !reason.isEmpty {
            parts.append("reason=\(reason)")
        }
        if !nsError.userInfo.isEmpty {
            parts.append("userInfo=\(nsError.userInfo)")
        }
        return parts.joined(separator: " | ")
    }

    private func managerSummary(_ manager: NETunnelProviderManager?, stage: String) -> String {
        guard let manager else {
            return "[\(stage)] manager=nil"
        }

        let status = manager.connection.status
        if let proto = manager.protocolConfiguration as? NETunnelProviderProtocol {
            return "[\(stage)] enabled=\(manager.isEnabled) status=\(status.rawValue) providerBundleId=\(proto.providerBundleIdentifier ?? "nil") serverAddress=\(proto.serverAddress ?? "nil")"
        }
        return "[\(stage)] enabled=\(manager.isEnabled) status=\(status.rawValue) protocol=\(String(describing: manager.protocolConfiguration))"
    }

}
