import Foundation
import IlyichPlatform

/// A server's saved network settings and client certificate. Reading and writing them touches the
/// Keychain, and importing a certificate decodes PKCS#12, so the work runs here, off the main
/// actor, and the settings screen only shows and sends.
actor NetworkConfigurationService {
    struct Saved: Sendable {
        let configuration: NetworkConfiguration
        let hasCertificate: Bool
    }

    /// The settings in use: the signed-in client's when there is one, or else those saved for
    /// `server`.
    func load(server: URL, client: APIClient?) async throws -> Saved {
        let configuration: NetworkConfiguration
        if let client { configuration = await client.networkConfiguration() }
        else { configuration = try NetworkConfigurationStore.load(server: server) }
        return Saved(configuration: configuration, hasCertificate: try ClientCertificateStore.hasCertificate(server: server))
    }

    /// Saves `configuration` for `server`, and the signed-in client takes it up at once.
    func save(_ configuration: NetworkConfiguration, server: URL, client: APIClient?) async throws {
        if let client { try await client.updateNetworkConfiguration(configuration) }
        else { try NetworkConfigurationStore.save(configuration, server: server) }
    }

    func importCertificate(data: Data, password: String, server: URL) throws {
        try ClientCertificateStore.importCertificate(data: data, password: password, server: server)
    }

    func removeCertificate(server: URL) throws {
        try ClientCertificateStore.remove(server: server)
    }
}
