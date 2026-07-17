//
//  GrokBuildAuthManager.swift
//  Grok for Mac
//
//  Handles detection and import of existing Grok Build CLI sessions
//  for seamless "Grok Build family" authentication (Super Heavy support).
//

import AppKit
import Foundation

struct GrokBuildSession: Equatable {
    let email: String?
    let tier: Int?
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?
    
    var isSuperHeavy: Bool {
        tier == 5
    }
    
    var isValid: Bool {
        // Refreshable sessions stay usable even if access JWT looks expired.
        if let refreshToken, !refreshToken.isEmpty { return true }
        if let expiresAt {
            return Date() < expiresAt.addingTimeInterval(-60) // 60s skew
        }
        return true
    }
}

enum GrokBuildAuthError: LocalizedError {
    case missingRefreshToken
    case refreshFailed(statusCode: Int, message: String)
    case noSession
    
    var errorDescription: String? {
        switch self {
        case .missingRefreshToken:
            return "Grok Build session expired. Run `grok login` in Terminal, then click Continue with Grok Build."
        case .refreshFailed(let code, let message):
            return "Token refresh failed (HTTP \(code)): \(message)"
        case .noSession:
            return "Not signed in to Grok Build."
        }
    }
}

final class GrokBuildAuthManager: ObservableObject {
    static let shared = GrokBuildAuthManager()
    
    static let cliClientID = "b1a00492-073a-47ea-816f-4c329264a828"
    static let tokenEndpoint = "https://auth.x.ai/oauth2/token"
    
    private let cliAuthPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".grok/auth.json")
    
    private let keychain = KeychainHelper.shared
    
    private let accessTokenKey = "grok_build_access_token"
    private let refreshTokenKey = "grok_build_refresh_token"
    private let emailKey = "grok_build_email"
    private let tierKey = "grok_build_tier"
    private let expiresAtKey = "grok_build_expires_at"
    
    private var refreshInFlight = false
    
    @Published var currentSession: GrokBuildSession?
    @Published var isUsingGrokBuildSession = false
    @Published var lastAuthError: String?
    
    private init() {
        loadStoredSession()
        bootstrapFromCLIIfNeeded()
    }
    
    // MARK: - Detection (same logic as VS Code / Grok CLI)
    
    func detectGrokBuildCLISession() -> GrokBuildSession? {
        guard let data = try? Data(contentsOf: cliAuthPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        
        // Prefer canonical CLI client entry; fall back to any auth.x.ai entry with a token.
        let entryKey = json.keys.first(where: { $0.contains(Self.cliClientID) })
            ?? json.keys.first(where: { $0.contains("auth.x.ai") })
        
        guard let entryKey,
              let entry = json[entryKey] as? [String: Any],
              let accessToken = entry["key"] as? String,
              !accessToken.isEmpty else {
            return nil
        }
        
        let refreshToken = entry["refresh_token"] as? String
        let email = entry["email"] as? String
        
        var tier: Int?
        var expiresAt: Date?
        
        if let payload = decodeJWTPayload(accessToken) {
            if let t = payload["tier"] as? Int {
                tier = t
            } else if let t = payload["tier"] as? NSNumber {
                tier = t.intValue
            }
            if let exp = Self.jwtNumericDate(payload["exp"]) {
                expiresAt = Date(timeIntervalSince1970: exp)
            }
        }
        
        if let expiresAtString = entry["expires_at"] as? String,
           let date = ISO8601DateFormatter().date(from: expiresAtString) {
            expiresAt = date
        }
        
        return GrokBuildSession(
            email: email,
            tier: tier,
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt
        )
    }
    
    var hasCLISessionOnDisk: Bool {
        detectGrokBuildCLISession() != nil
    }
    
    // MARK: - Import / bootstrap
    
    /// One-click import from ~/.grok/auth.json (same file Grok CLI / VS Code use).
    @discardableResult
    func importFromGrokBuildCLI() -> Bool {
        guard let session = detectGrokBuildCLISession() else {
            lastAuthError = "No Grok CLI login found. Run `grok login` in Terminal first."
            return false
        }
        
        persistSession(session)
        lastAuthError = nil
        return true
    }
    
    /// On launch: auto-import a valid CLI session so Build works without an extra click.
    func bootstrapFromCLIIfNeeded() {
        guard !isUsingGrokBuildSession else {
            syncFromCLIIfNewer()
            return
        }
        
        if let detected = detectGrokBuildCLISession(), detected.isValid {
            _ = importFromGrokBuildCLI()
        }
    }
    
    /// If the user re-authenticates via CLI while the app is open, pick up fresh tokens.
    func syncFromCLIIfNewer() {
        guard let cliSession = detectGrokBuildCLISession() else { return }
        
        if let current = currentSession,
           current.accessToken == cliSession.accessToken {
            return
        }
        
        _ = importFromGrokBuildCLI()
    }
    
    // MARK: - Token Access (for API calls)
    
    /// Prefers Grok Build OAuth; falls back to console.x.ai API key.
    func resolvedAuthToken(fallbackApiKey: String? = nil) -> String? {
        if isUsingGrokBuildSession, let token = getCurrentAccessToken(), !token.isEmpty {
            return token
        }
        
        if let fallbackApiKey, !fallbackApiKey.isEmpty {
            return fallbackApiKey
        }
        
        return keychain.getAPIKey()
    }
    
    func getCurrentAccessToken() -> String? {
        keychain.getString(forKey: accessTokenKey)
    }
    
    func isAuthenticated(fallbackApiKey: String? = nil) -> Bool {
        resolvedAuthToken(fallbackApiKey: fallbackApiKey) != nil
    }
    
    /// Refresh OAuth access token when near expiry (matches VS Code / Hermes xai-oauth flow).
    func refreshAccessTokenIfNeeded(completion: @escaping (Result<String, Error>) -> Void) {
        guard isUsingGrokBuildSession else {
            if let token = resolvedAuthToken() {
                completion(.success(token))
            } else {
                completion(.failure(GrokBuildAuthError.noSession))
            }
            return
        }
        
        guard let session = currentSession else {
            completion(.failure(GrokBuildAuthError.noSession))
            return
        }
        
        if session.isValid, let token = getCurrentAccessToken() {
            completion(.success(token))
            return
        }
        
        guard let refreshToken = session.refreshToken ?? keychain.getString(forKey: refreshTokenKey),
              !refreshToken.isEmpty else {
            lastAuthError = GrokBuildAuthError.missingRefreshToken.localizedDescription
            completion(.failure(GrokBuildAuthError.missingRefreshToken))
            return
        }
        
        if refreshInFlight {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                if let token = self?.getCurrentAccessToken(), self?.currentSession?.isValid == true {
                    completion(.success(token))
                } else {
                    self?.refreshAccessTokenIfNeeded(completion: completion)
                }
            }
            return
        }
        
        refreshInFlight = true
        
        var request = URLRequest(url: URL(string: Self.tokenEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        let body = [
            "grant_type=refresh_token",
            "client_id=\(Self.cliClientID)",
            "refresh_token=\(refreshToken)"
        ].joined(separator: "&")
        request.httpBody = body.data(using: .utf8)
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            defer { self?.refreshInFlight = false }
            
            if let error = error {
                DispatchQueue.main.async {
                    self?.lastAuthError = error.localizedDescription
                    completion(.failure(error))
                }
                return
            }
            
            guard let http = response as? HTTPURLResponse else {
                DispatchQueue.main.async {
                    completion(.failure(GrokBuildAuthError.refreshFailed(statusCode: -1, message: "Invalid response")))
                }
                return
            }
            
            let detail = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            
            guard http.statusCode == 200,
                  let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let newAccess = json["access_token"] as? String,
                  !newAccess.isEmpty else {
                DispatchQueue.main.async {
                    let message = detail.isEmpty ? "Unknown error" : detail
                    self?.lastAuthError = GrokBuildAuthError.refreshFailed(statusCode: http.statusCode, message: message).localizedDescription
                    completion(.failure(GrokBuildAuthError.refreshFailed(statusCode: http.statusCode, message: message)))
                }
                return
            }
            
            let newRefresh = (json["refresh_token"] as? String) ?? refreshToken
            var tier: Int?
            var expiresAt: Date?
            if let payload = self?.decodeJWTPayload(newAccess) {
                tier = payload["tier"] as? Int
                if let exp = Self.jwtNumericDate(payload["exp"]) {
                    expiresAt = Date(timeIntervalSince1970: exp)
                }
            }
            
            let refreshed = GrokBuildSession(
                email: self?.currentSession?.email,
                tier: tier ?? self?.currentSession?.tier,
                accessToken: newAccess,
                refreshToken: newRefresh,
                expiresAt: expiresAt
            )
            
            DispatchQueue.main.async {
                self?.persistSession(refreshed)
                self?.lastAuthError = nil
                completion(.success(newAccess))
            }
        }.resume()
    }
    
    // MARK: - Sign out
    
    func signOut() {
        _ = keychain.delete(forKey: accessTokenKey)
        _ = keychain.delete(forKey: refreshTokenKey)
        _ = keychain.delete(forKey: emailKey)
        _ = keychain.delete(forKey: tierKey)
        _ = keychain.delete(forKey: expiresAtKey)
        
        currentSession = nil
        isUsingGrokBuildSession = false
        lastAuthError = nil
    }
    
    // MARK: - CLI login helper
    
    /// Opens Terminal and runs `grok login` (same flow as Grok CLI / VS Code extension).
    @discardableResult
    func launchCLILogin() -> Bool {
        let grok = GrokCLIResolver.resolveExecutable() ?? "grok"
        let command = "'\(grok.replacingOccurrences(of: "'", with: "'\\''"))' login"
        let script = """
        tell application "Terminal"
            activate
            do script "\(command)"
        end tell
        """
        
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            if error == nil { return true }
        }
        
        // Fallback: open Terminal at home if AppleScript fails
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
        return false
    }

    /// Poll `~/.grok/auth.json` after login until a session appears (or timeout).
    /// Completion always runs on the main queue.
    func waitUntilCLISessionAvailable(
        timeout: TimeInterval = 180,
        pollInterval: TimeInterval = 1.5,
        completion: @escaping (Bool) -> Void
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        func tick() {
            if detectGrokBuildCLISession() != nil {
                DispatchQueue.main.async {
                    _ = self.importFromGrokBuildCLI()
                    completion(true)
                }
                return
            }
            if isUsingGrokBuildSession, currentSession?.isValid == true {
                DispatchQueue.main.async { completion(true) }
                return
            }
            if Date() >= deadline {
                DispatchQueue.main.async { completion(false) }
                return
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + pollInterval) {
                tick()
            }
        }
        DispatchQueue.global(qos: .utility).async { tick() }
    }

    private static func jwtNumericDate(_ value: Any?) -> TimeInterval? {
        if let n = value as? TimeInterval { return n }
        if let n = value as? Double { return n }
        if let n = value as? Int { return TimeInterval(n) }
        if let n = value as? NSNumber { return n.doubleValue }
        return nil
    }
    
    // MARK: - Private Helpers
    
    private func persistSession(_ session: GrokBuildSession) {
        _ = keychain.save(session.accessToken, forKey: accessTokenKey)
        if let refresh = session.refreshToken {
            _ = keychain.save(refresh, forKey: refreshTokenKey)
        }
        if let email = session.email {
            _ = keychain.save(email, forKey: emailKey)
        }
        if let tier = session.tier {
            _ = keychain.save(String(tier), forKey: tierKey)
        }
        if let expiresAt = session.expiresAt {
            _ = keychain.save(ISO8601DateFormatter().string(from: expiresAt), forKey: expiresAtKey)
        }
        
        currentSession = session
        isUsingGrokBuildSession = true
        // Keep any console API key — Chat/Grok modes may still use it.
    }
    
    private func loadStoredSession() {
        guard let accessToken = keychain.getString(forKey: accessTokenKey) else {
            isUsingGrokBuildSession = false
            return
        }
        
        let refreshToken = keychain.getString(forKey: refreshTokenKey)
        let email = keychain.getString(forKey: emailKey)
        let tier = Int(keychain.getString(forKey: tierKey) ?? "")
        
        var expiresAt: Date?
        if let expiresString = keychain.getString(forKey: expiresAtKey) {
            expiresAt = ISO8601DateFormatter().date(from: expiresString)
        }
        if expiresAt == nil, let payload = decodeJWTPayload(accessToken),
           let exp = Self.jwtNumericDate(payload["exp"]) {
            expiresAt = Date(timeIntervalSince1970: exp)
        }
        
        currentSession = GrokBuildSession(
            email: email,
            tier: tier,
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt
        )
        isUsingGrokBuildSession = true
    }
    
    private func decodeJWTPayload(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return nil }
        
        let payloadSegment = String(parts[1])
        let padded = payloadSegment
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            .padding(toLength: ((payloadSegment.count + 3) / 4) * 4, withPad: "=", startingAt: 0)
        
        guard let data = Data(base64Encoded: padded),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }
}
