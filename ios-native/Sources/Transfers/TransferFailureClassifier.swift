import Foundation
import IlyichPlatform
import Photos

/// Why an executor stopped a job for a condition rather than a failure.
enum TransferDeferral: Error, Equatable, Sendable {
    /// Charging, temperature or Low Power Mode, as the backup settings require.
    case deviceConditions
    /// An iCloud original or a video that may move only on Wi-Fi.
    case unmeteredNetwork
}

/// Failures that concern one item and nothing else.
enum TransferItemFailure: Error, Equatable, Sendable, LocalizedError {
    /// The server's bulk upload check refused the file, not as a duplicate.
    case rejected(String?)
    /// The server holds this file, in its trash.
    case trashedDuplicate
    /// A Live Photo's still and video do not belong together on the server.
    case livePairConflict
    /// A staged file is missing or unreadable.
    case unreadableFile
    /// The server holds this photo already, but not from this attempt's own upload, so its XMP
    /// sidecar would not reach the server.
    case sidecarDuplicate

    var errorDescription: String? {
        switch self {
        case .rejected(let reason): reason ?? "The server refused this file."
        case .trashedDuplicate: "This photo is in the server’s trash. Restore it there to back it up again."
        case .livePairConflict: "This Live Photo’s still and video don’t match on the server."
        case .unreadableFile: "This photo’s file could not be read."
        case .sidecarDuplicate: "This photo already exists. Its XMP cannot be updated by uploading a duplicate; your source files were kept."
        }
    }
}

/// Section 5 of the architecture: what a failure means for the job and the engine. It is pure;
/// the engine supplies the job's history in the context.
///
/// - item: only the user retries;
/// - waiting: a condition, for the job or the whole engine, that any condition event clears;
/// - transient: retried by itself with backoff (30 s x 2^n, 20 % jitter, at most an hour);
///   errors it doesn't know are transient for five attempts, then item;
/// - account: the whole engine stops until the user acts.
///
/// Error text is shown, never parsed: the device locale writes it.
enum TransferFailureClassifier {
    struct Context: Hashable, Sendable {
        /// How many times this job has failed before.
        var retryCount = 0
        /// Server errors (5xx) in a row before this one, across jobs.
        var consecutiveServerErrors = 0
        /// Whether backup may download originals from iCloud.
        var downloadCloudOriginals = true
    }

    /// Failures of an unknown kind retried before one counts as the item's own.
    static let unknownAttempts = 5
    /// Server errors in a row that make the whole engine back off.
    static let serverErrorsBeforeBackoff = 3

    static func classify(_ error: any Error, context: Context = Context()) -> FailureClass {
        switch error {
        case let deferral as TransferDeferral:
            return switch deferral {
            case .deviceConditions: .waiting(.deviceConditions, jobScoped: false)
            case .unmeteredNetwork: .waiting(.unmeteredNetwork, jobScoped: true)
            }
        case let deferral as BackupDeferral:
            return switch deferral {
            case .waitingForDevice: .waiting(.deviceConditions, jobScoped: false)
            case .waitingForWiFi: .waiting(.unmeteredNetwork, jobScoped: true)
            }
        case let failure as TransferItemFailure:
            return .item(failure.localizedDescription)
        case let failure as UploadOutcomeFailure:
            // An outcome file, judged by its receipt, status and error code only.
            return switch failure {
            case .failed(let record): classify(outcome: record, context: context) ?? .transient(retryAfter: nil)
            case .unrecorded: .transient(retryAfter: nil)
            }
        case BackupError.item(let message):
            return .item(message)
        case let failure as ServerFailure:
            return classify(failure, context: context)
        case let failure as TransportFailure:
            return switch failure {
            case .unreachable(let code): classify(URLError(code), context: context)
            case .endpointChanged, .allEndpointsUnavailable, .systemCancelled: .transient(retryAfter: nil)
            }
        case APIError.signedOut:
            return .account(.signedOut)
        case is ReadOnlyPolicy.ReadOnlyError:
            // Read-only mode refused the request: the engine pauses, as BackupCoordinator does,
            // and the photo is not blamed. (A WriteFenced request never reaches here: the engine
            // gives its lease back and runs it again under the new write generation.)
            return .account(.readOnly)
        case APIError.invalidResponse:
            return .transient(retryAfter: nil)
        case is CancellationError:
            // The work was stopped, not refused: it runs again.
            return .transient(retryAfter: nil)
        case let failure as URLError:
            return classify(urlCode: failure.code, error: failure, context: context)
        default:
            break
        }
        let details = error as NSError
        switch details.domain {
        case NSURLErrorDomain:
            return classify(urlCode: URLError.Code(rawValue: details.code), error: error, context: context)
        case PHPhotosErrorDomain:
            switch PHPhotosError.Code(rawValue: details.code) {
            case .identifierNotFound, .invalidResource, .missingResource, .requestNotSupportedForAsset:
                return .item(error.localizedDescription)
            case .networkAccessRequired:
                // The original is in iCloud. With downloads off it can never be read.
                return context.downloadCloudOriginals ? .waiting(.unmeteredNetwork, jobScoped: true)
                    : .item("The original is in iCloud, and downloading originals is off.")
            case .networkError:
                return .waiting(.connectivity, jobScoped: false)
            case .accessUserDenied, .accessRestricted:
                return .account(.photosAccess)
            case .notEnoughSpace:
                return .account(.deviceStorage)
            default:
                return unknown(error, context: context)
            }
        case NSCocoaErrorDomain:
            switch CocoaError.Code(rawValue: details.code) {
            case .fileNoSuchFile, .fileReadNoSuchFile, .fileReadCorruptFile:
                return .item(error.localizedDescription)
            case .fileWriteOutOfSpace:
                return .account(.deviceStorage)
            default:
                return unknown(error, context: context)
            }
        case NSPOSIXErrorDomain where details.code == Int(ENOSPC):
            return .account(.deviceStorage)
        default:
            return unknown(error, context: context)
        }
    }

    /// An outcome file's verdict, or nil when it is a success. Only the receipt and the status
    /// count, and a version 2 file's error domain and code; never the message. An error without
    /// either is an interrupted attempt, checked again by checksum or sent again from its body.
    static func classify(outcome: OutcomeRecord, context: Context = Context()) -> FailureClass? {
        if outcome.receipt != nil { return nil }
        if let status = outcome.httpStatus { return classify(status: status, message: nil, context: context) }
        if outcome.cancelReason != nil { return .transient(retryAfter: nil) }
        if let domain = outcome.errorDomain, let code = outcome.errorCode {
            return classify(NSError(domain: domain, code: code), context: context)
        }
        return .transient(retryAfter: nil)
    }

    /// An HTTP status alone, as an outcome file records it, without the body that tells Immich's
    /// own refusals from a proxy's.
    static func classify(status: Int, message: String?, context: Context = Context()) -> FailureClass {
        switch status {
        case 200..<300: return .transient(retryAfter: nil)
        case 401: return .account(.sessionExpired)
        case 407: return .account(.proxyRejected)
        case 400, 413, 415, 422:
            return .item(message ?? "The server refused this file (HTTP \(status)).")
        case 408, 425, 429: return .transient(retryAfter: nil)
        case 500, 502, 503, 504: return server(context: context)
        default:
            return status >= 500 ? server(context: context, otherwise: unknownStatus(status, context: context))
                : unknownStatus(status, context: context)
        }
    }

    /// Whether the failure is a server error (5xx), which counts toward backing off.
    static func isServerError(_ error: any Error) -> Bool {
        if case ServerFailure.http(let status, _) = error { return status >= 500 }
        if case UploadOutcomeFailure.failed(let record) = error { return isServerError(outcome: record) }
        return false
    }

    static func isServerError(outcome: OutcomeRecord) -> Bool {
        outcome.receipt == nil && (outcome.httpStatus ?? 0) >= 500
    }

    /// The wait before retry number `retryCount + 1`: 30 s doubled per earlier failure, at most
    /// an hour, spread by 20 % either way. `random` is in 0..<1.
    static func backoff(retryCount: Int, random: Double) -> Duration {
        let base = min(30.0 * pow(2.0, Double(min(retryCount, 16))), 3_600)
        let spread = 0.8 + 0.4 * min(max(random, 0), 1)
        return .milliseconds(Int64((min(base * spread, 3_600) * 1_000).rounded()))
    }

    // MARK: -

    private static func classify(_ failure: ServerFailure, context: Context) -> FailureClass {
        switch failure {
        case .sessionExpired, .credentialsRejected: .account(.sessionExpired)
        case .proxyRejected: .account(.proxyRejected)
        case .readOnly: .account(.readOnly)
        case .passwordChangeRequired: .account(.passwordChange)
        case .http(let status, let message): classify(status: status, message: message, context: context)
        case .undecodable: .transient(retryAfter: nil)
        case .forbidden, .notFound: unknown(failure, context: context)
        }
    }

    private static func classify(urlCode code: URLError.Code, error: any Error, context: Context) -> FailureClass {
        switch code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff, .callIsActive:
            return .waiting(.connectivity, jobScoped: false)
        case .timedOut, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed,
             .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot,
             .clientCertificateRejected, .clientCertificateRequired, .badServerResponse, .cannotParseResponse, .cancelled,
             .backgroundSessionWasDisconnected, .backgroundSessionInUseByAnotherProcess:
            return .transient(retryAfter: nil)
        default:
            return unknown(error, context: context)
        }
    }

    private static func server(context: Context, otherwise: FailureClass = .transient(retryAfter: nil)) -> FailureClass {
        context.consecutiveServerErrors + 1 >= serverErrorsBeforeBackoff ? .waiting(.serverBackoff, jobScoped: false) : otherwise
    }

    private static func unknownStatus(_ status: Int, context: Context) -> FailureClass {
        context.retryCount < unknownAttempts ? .transient(retryAfter: nil) : .item("The server could not take this file (HTTP \(status)).")
    }

    private static func unknown(_ error: any Error, context: Context) -> FailureClass {
        context.retryCount < unknownAttempts ? .transient(retryAfter: nil) : .item(error.localizedDescription)
    }
}
