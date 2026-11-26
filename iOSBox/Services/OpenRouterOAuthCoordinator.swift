import AuthenticationServices
import CryptoKit
import Foundation
import Security
import UIKit

enum OpenRouterOAuthError: LocalizedError {
    case cancelled
    case missingCallbackCode
    case exchangeFailed(String)
    case invalidKeyResponse

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return nil
        case .missingCallbackCode:
            return String(localized: "未从授权回调中获取到有效授权码，请重试。")
        case .exchangeFailed(let detail):
            return detail.isEmpty
                ? String(localized: "向 OpenRouter 换取 API Key 失败，请稍后重试。")
                : String(localized: "授权换取 Key 失败：\(detail)")
        case .invalidKeyResponse:
            return String(localized: "OpenRouter 未返回有效的 API Key。")
        }
    }
}

@MainActor
final class OpenRouterOAuthCoordinator: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = OpenRouterOAuthCoordinator()
    static let callbackScheme = "iosbox"
    static let callbackURLString = "iosbox://openrouter-oauth"

    private var activeSession: ASWebAuthenticationSession?

    struct PKCEPair: Sendable, Equatable {
        let verifier: String
        let challenge: String
    }

    nonisolated static func generatePKCEPair() -> PKCEPair {
        var randomBytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
        let seedData: Data
        if status == errSecSuccess {
            seedData = Data(randomBytes)
        } else {
            seedData = Data((UUID().uuidString + UUID().uuidString).utf8)
        }
        let verifier = base64URLEncode(seedData)
        let digest = SHA256.hash(data: Data(verifier.utf8))
        let challenge = base64URLEncode(Data(digest))
        return PKCEPair(verifier: verifier, challenge: challenge)
    }

    nonisolated static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    nonisolated static func buildAuthorizationURL(challenge: String, callbackURL: String = callbackURLString) -> URL? {
        var components = URLComponents(string: "https://openrouter.ai/auth")
        components?.queryItems = [
            URLQueryItem(name: "callback_url", value: callbackURL),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        return components?.url
    }

    nonisolated static func extractAuthorizationCode(from callbackURL: URL) -> String? {
        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else { return nil }
        let code = components.queryItems?.first(where: { $0.name == "code" })?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let code, !code.isEmpty else { return nil }
        return code
    }

    nonisolated static func parseKeyExchangeResponse(_ data: Data) throws -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenRouterOAuthError.invalidKeyResponse
        }
        let keyCandidate = (obj["key"] as? String)
            ?? ((obj["data"] as? [String: Any])?["key"] as? String)
        let cleaned = LLMClient.sanitizedAPIKey(keyCandidate ?? "")
        guard !cleaned.isEmpty else {
            throw OpenRouterOAuthError.invalidKeyResponse
        }
        return cleaned
    }

    func authorize() async throws -> String {
        let pkce = Self.generatePKCEPair()
        guard let authURL = Self.buildAuthorizationURL(challenge: pkce.challenge) else {
            throw OpenRouterOAuthError.invalidKeyResponse
        }

        let callbackURL: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: Self.callbackScheme
            ) { [weak self] url, error in
                Task { @MainActor in
                    self?.activeSession = nil
                    if let authErr = error as? ASWebAuthenticationSessionError,
                       authErr.code == .canceledLogin {
                        continuation.resume(throwing: OpenRouterOAuthError.cancelled)
                        return
                    }
                    if let error {
                        continuation.resume(throwing: OpenRouterOAuthError.exchangeFailed(error.localizedDescription))
                        return
                    }
                    guard let url else {
                        continuation.resume(throwing: OpenRouterOAuthError.missingCallbackCode)
                        return
                    }
                    continuation.resume(returning: url)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.activeSession = session
            if !session.start() {
                self.activeSession = nil
                continuation.resume(throwing: OpenRouterOAuthError.exchangeFailed(""))
            }
        }

        guard let code = Self.extractAuthorizationCode(from: callbackURL) else {
            throw OpenRouterOAuthError.missingCallbackCode
        }
        return try await Self.exchangeCodeForAPIKey(code: code, verifier: pkce.verifier)
    }

    nonisolated static func exchangeCodeForAPIKey(
        code: String,
        verifier: String,
        session: URLSession = .shared
    ) async throws -> String {
        var req = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/auth/keys")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let payload: [String: String] = [
            "code": code,
            "code_verifier": verifier,
            "code_challenge_method": "S256"
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw OpenRouterOAuthError.exchangeFailed("")
        }
        guard (200...299).contains(http.statusCode) else {
            var detail = "HTTP \(http.statusCode)"
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let err = obj["error"] as? [String: Any],
               let msg = err["message"] as? String, !msg.isEmpty {
                detail = msg
            }
            throw OpenRouterOAuthError.exchangeFailed(detail)
        }
        return try parseKeyExchangeResponse(data)
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let activeWindow = scenes
            .first(where: { $0.activationState == .foregroundActive })?
            .windows
            .first(where: { $0.isKeyWindow }) {
            return activeWindow
        }
        if let anyWindow = scenes.flatMap(\.windows).first {
            return anyWindow
        }
        return ASPresentationAnchor()
    }
}
