import Foundation
import IlyichPlatform

// The widget's Swift 5 sources, including those under mobile/ios, still use the names they had
// before IlyichPlatform. These forward to the package until the widget is rewritten on it.

typealias SavedSession = StoredCredential
typealias ServerConnection = IlyichPlatform.ServerConnection
typealias SameOriginRedirectDelegate = IlyichPlatform.SameOriginRedirectDelegate

enum SessionKeychain {
  static var appGroup: String {
    get throws { try AppGroup.identifier }
  }

  static func read() throws -> SavedSession? {
    try KeychainCredentialStore().load()
  }
}

extension IlyichPlatform.ServerConnection {
  /// Connects with the network settings saved for the server, as the app does.
  init(server: URL) throws {
    let primary = try ServerAddress.normalized(server)
    try self.init(
      server: primary,
      configuration: NetworkConfigurationStore.connectionSettings(server: primary),
      wifiName: SystemWiFiName()
    )
  }
}
