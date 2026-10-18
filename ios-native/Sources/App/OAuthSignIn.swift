import AuthenticationServices
import CryptoKit
import Security
import UIKit

@MainActor final class OAuthSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func signIn(api: APIClient) async throws -> LoginResponse {
        let state = try Self.randomToken()
        let verifier = try Self.randomToken()
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        struct Start: Encodable, Sendable { let redirectUri: String; let state: String; let codeChallenge: String }
        struct Authorization: Decodable, Sendable { let url: URL }
        let authorization: Authorization = try await api.request(.post, path: "oauth/authorize",
            body: Start(redirectUri: "app.immich:///oauth-callback", state: state, codeChallenge: challenge))
        guard ["https", "http"].contains(authorization.url.scheme?.lowercased() ?? "") else { throw APIError.invalidResponse("The sign-in provider returned an invalid address.") }
        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let flow = ASWebAuthenticationSession(url: authorization.url, callbackURLScheme: "app.immich") { [weak self] url, error in
                Task { @MainActor in self?.session = nil }
                if let error { continuation.resume(throwing: error) }
                else if let url { continuation.resume(returning: url) }
                else { continuation.resume(throwing: APIError.invalidResponse("Sign-in did not return a response.")) }
            }
            flow.presentationContextProvider = self
            session = flow
            guard flow.start() else {
                session = nil
                continuation.resume(throwing: APIError.invalidResponse("The sign-in window could not open. Try again.")); return
            }
        }
        guard callback.scheme == "app.immich", callback.path == "/oauth-callback",
              URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "state" })?.value == state else {
            throw APIError.invalidResponse("The sign-in response did not match this request. Please try again.")
        }
        struct Finish: Encodable, Sendable { let url: String; let state: String; let codeVerifier: String }
        let normalized = callback.absoluteString.replacingOccurrences(of: "app.immich:/oauth-callback", with: "app.immich:///oauth-callback")
        return try await api.request(.post, path: "oauth/callback", body: Finish(url: normalized, state: state, codeVerifier: verifier))
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
    private static func randomToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw APIError.invalidResponse("Couldn’t securely start sign-in. Try again.")
        }
        return base64URL(Data(bytes))
    }
    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
