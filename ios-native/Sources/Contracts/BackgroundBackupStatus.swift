import Foundation

/// Device policy and scheduler refusals are separate from failures to upload a file.
enum BackgroundBackupIssue: Hashable, Sendable {
    case refreshDisabled
    case restricted
    case lowPower
    case unavailable
    case requestLimit
    case notPermitted
    case purchaseRequired
    case temporarilyUnavailable

    var title: String {
        switch self {
        case .refreshDisabled: "iOS background refresh is off"
        case .restricted: "Background backup is restricted"
        case .lowPower: "Low Power Mode limits background backup"
        default: "Background backup is unavailable"
        }
    }

    var message: String {
        switch self {
        case .refreshDisabled:
            "In iOS Settings, check General → Background App Refresh, then allow Ilyich. The app’s switch may look on when the global setting is off. You can still back up while Ilyich is open."
        case .restricted:
            "iOS restrictions prevent background backup. You can still back up while Ilyich is open."
        case .lowPower:
            "Background backup can resume after Low Power Mode is turned off. You can still back up while Ilyich is open."
        case .unavailable:
            "iOS is not accepting background work. Check Background App Refresh in Settings; you can still back up while Ilyich is open."
        case .requestLimit, .temporarilyUnavailable:
            "iOS could not schedule background work. Ilyich will try again when you reopen it. You can still use Back up now."
        case .notPermitted:
            "iOS did not permit background backup. Check Background App Refresh in Settings, and update Ilyich if this continues. You can still use Back up now."
        case .purchaseRequired:
            "Restore app access to schedule new backups. Your existing backups are kept."
        }
    }

    var canOpenSettings: Bool { self == .refreshDisabled || self == .unavailable || self == .notPermitted }
}

enum BackgroundBackupAvailability: Sendable {
    case available, denied, restricted, lowPower

    var issue: BackgroundBackupIssue? {
        switch self {
        case .available: nil
        case .denied: .refreshDisabled
        case .restricted: .restricted
        case .lowPower: .lowPower
        }
    }
}

/// A scheduler error crosses the seam as a reason, never a localized platform error string.
enum BackgroundSchedulingFailure: Hashable, Sendable {
    case unavailable, requestLimit, notPermitted, purchaseRequired, other

    var issue: BackgroundBackupIssue {
        switch self {
        case .unavailable: .unavailable
        case .requestLimit: .requestLimit
        case .notPermitted: .notPermitted
        case .purchaseRequired: .purchaseRequired
        case .other: .temporarilyUnavailable
        }
    }
}
