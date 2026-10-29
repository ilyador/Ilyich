import Foundation
import IlyichPlatform
import os
import Synchronization

/// The background URLSession configuration, the app's only call to
/// URLSessionConfiguration.background(withIdentifier:). Only BackgroundTransport's live session
/// builds a session from it, and scripts/check-single-engine.sh fails the build if a second call
/// site or a second builder appears.
///
/// iOS allows one session per identifier in a process: a second one with the same identifier gets
/// undefined event delivery. Each identifier's configurations are counted, and a repeat is logged
/// as a fault: TransferHost starts the engine's sessions once in a process.
enum TransferSessionConfiguration {
    /// Uploads may take a week: iOS retries them across network changes and relaunches.
    static let resourceTimeout: TimeInterval = 7 * 24 * 3600
    static let connectionsPerHost = 2

    static func make(identifier: String) -> URLSessionConfiguration {
        let count = counts.withLock { counts in
            counts[identifier, default: 0] += 1
            return counts[identifier, default: 0]
        }
        if count > 1 { logger.fault("A second background URLSession was configured for \(identifier, privacy: .public)") }
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.sharedContainerIdentifier = try? AppGroup.identifier
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.httpMaximumConnectionsPerHost = connectionsPerHost
        configuration.timeoutIntervalForResource = resourceTimeout
        return configuration
    }

    /// How many times this process has configured a session for an identifier. More than one is a bug.
    static func configurations(of identifier: String) -> Int { counts.withLock { $0[identifier] ?? 0 } }

    private static let counts = Mutex<[String: Int]>([:])
    private static let logger = Logger(subsystem: "app.ilyich.native", category: "Transfers")
}
