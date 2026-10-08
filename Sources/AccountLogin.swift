import Foundation

enum LauncherLocalization {
    static func language(for languages: [String]) -> String {
        languages.first?.lowercased().hasPrefix("zh") == true ? "zh" : "en"
    }
    static func menu(_ text: String, language: String) -> String {
        guard language == "en" else { return text }
        return ["关于": "About", "检查更新…": "Check for Updates…",
                "登录 DeepSeek 账号": "Sign In to DeepSeek", "退出 DeepSeek 账号": "Sign Out of DeepSeek",
                "问题反馈…": "Send Feedback…", "隐藏": "Hide", "退出": "Quit",
                "编辑": "Edit", "撤销": "Undo", "重做": "Redo", "剪切": "Cut", "拷贝": "Copy",
                "粘贴": "Paste", "全选": "Select All", "显示": "View", "重新载入": "Reload",
                "实际大小": "Actual Size", "窗口": "Window", "最小化": "Minimize", "缩放": "Zoom",
                "帮助": "Help", "语言": "Language", "跟随系统": "System Default"][text] ?? text
    }
}

/// The account RPC contract used by the launcher is pinned to the official
/// `@deepseek-ai/dsh` 0.2.0-rc.2 protocol. Keep this small boundary explicit:
/// older installed CLIs may not publish these endpoints, and the launcher must
/// not silently upgrade an existing installation just to expose login.
enum AccountLoginProtocol {
    static let startMethod = "account/startSignIn"
    static let stateMethod = "account/getState"
    static let cancelMethod = "account/cancelSignIn"
    static let signOutMethod = "account/signOut"
    static let officialAuthorizationHost = "platform.deepseek.com"
    static let officialAuthorizationPath = "/dsh/authorize"

    static func callbackOrigin(for pageURL: URL, port: Int) -> String? {
        guard (1...65_535).contains(port),
              pageURL.scheme?.lowercased() == "http",
              pageURL.user == nil,
              pageURL.password == nil,
              pageURL.port == port,
              let host = pageURL.host?.lowercased(),
              ["localhost", "127.0.0.1"].contains(host) else { return nil }
        return "http://\(host):\(port)"
    }

    /// Only open the default official Platform authorization page. The Host
    /// already validates its response against platformOrigin; this second
    /// boundary protects the native browser launch from a compromised/mismatched
    /// local RPC response. Query parameters are Platform-owned OAuth state.
    static func authorizationURL(_ value: String) -> URL? {
        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == officialAuthorizationHost,
              components.port == nil || components.port == 443,
              components.user == nil,
              components.password == nil,
              components.path == officialAuthorizationPath,
              components.fragment == nil,
              let url = components.url else { return nil }
        return url
    }

    static func requestData(method: String, rpcID: String, args: [String: Any]) throws -> Data {
        guard [startMethod, stateMethod, cancelMethod, signOutMethod].contains(method),
              !rpcID.isEmpty else {
            throw AccountLoginRequestError.invalidRequest
        }
        let envelope: [String: Any] = [
            "type": "client-request",
            "rpcId": rpcID,
            "method": method,
            "payload": ["args": args],
        ]
        guard JSONSerialization.isValidJSONObject(envelope) else {
            throw AccountLoginRequestError.invalidRequest
        }
        return try JSONSerialization.data(withJSONObject: envelope)
    }

    static func messageObject(from data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AccountLoginRequestError.invalidRequest
        }
        return value
    }

    static func acceptsResponse(generation: Int, currentGeneration: Int, active: Bool) -> Bool {
        active && generation == currentGeneration
    }

    static func deadlineExpired(_ deadline: Date, now: Date) -> Bool {
        now >= deadline
    }

    static func transition(for view: AccountLoginView) -> AccountLoginTransition {
        guard let attempt = view.attempt else {
            return view.status == .credentialStored ? .alreadyStored : .idle
        }
        switch attempt.phase {
        case .initializing, .exchanging, .committing:
            return .pending
        case .waitingBrowser:
            if let raw = attempt.authorizeURL, let url = authorizationURL(raw) {
                return .authorize(url)
            }
            if attempt.authorizeURL != nil { return .invalidAuthorization }
            return .pending
        case .succeeded:
            return .succeeded
        case .cancelled:
            return .cancelled
        case .expired, .failed:
            return .failed
        }
    }

    static func decodePageReply(_ data: Data) -> AccountLoginCallResult {
        guard let reply = try? JSONDecoder().decode(AccountLoginPageReply.self, from: data) else {
            return .protocolFailure
        }
        switch reply.kind {
        case .success:
            guard let view = reply.view else { return .protocolFailure }
            return .success(view)
        case .httpFailure:
            if reply.status == 404 { return .unsupportedCLI }
            if reply.status == 401 || reply.status == 403 { return .sessionUnavailable }
            return .transportFailure
        case .timeout:
            return .requestTimeout
        case .transportFailure:
            return .transportFailure
        case .rpcMismatch, .invalidResponse:
            return .protocolFailure
        case .remoteFailure:
            if let code = reply.code,
               ["gateway/method-unavailable", "gateway/definition-unavailable", "gateway/invocation-unavailable"].contains(code) {
                return .unsupportedCLI
            }
            return .remoteFailure
        }
    }
}

enum AccountLoginRequestError: Error {
    case invalidRequest
}

enum AccountLoginCredentialStatus: String, Decodable {
    case signedOut = "signed-out"
    case credentialStored = "credential-stored"
}

enum AccountLoginAttemptPhase: String, Decodable {
    case initializing
    case waitingBrowser = "waiting-browser"
    case exchanging
    case committing
    case succeeded
    case cancelled
    case expired
    case failed
}

struct AccountLoginView: Decodable {
    let status: AccountLoginCredentialStatus
    let links: AccountLoginLinks
    let attempt: AccountLoginAttempt?
}

struct AccountLoginLinks: Decodable {
    let usageUrl: String
    let topUpUrl: String

    enum CodingKeys: String, CodingKey {
        case usageUrl
        case topUpUrl
    }
}

struct AccountLoginAttempt: Decodable {
    let id: String
    let phase: AccountLoginAttemptPhase
    let authorizeURL: String?
    let expiresAt: Double?

    enum CodingKeys: String, CodingKey {
        case id
        case phase
        case authorizeURL = "authorizeUrl"
        case expiresAt
    }
}

enum AccountLoginTransition: Equatable {
    case idle
    case alreadyStored
    case pending
    case authorize(URL)
    case invalidAuthorization
    case succeeded
    case cancelled
    case failed

    static func == (lhs: AccountLoginTransition, rhs: AccountLoginTransition) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.alreadyStored, .alreadyStored), (.pending, .pending), (.invalidAuthorization, .invalidAuthorization), (.succeeded, .succeeded),
             (.cancelled, .cancelled), (.failed, .failed):
            return true
        case let (.authorize(left), .authorize(right)):
            return left == right
        default:
            return false
        }
    }
}

enum AccountLoginPageReplyKind: String, Decodable {
    case success
    case httpFailure
    case timeout
    case transportFailure
    case remoteFailure
    case rpcMismatch
    case invalidResponse
}

struct AccountLoginPageReply: Decodable {
    let kind: AccountLoginPageReplyKind
    let status: Int?
    let code: String?
    let view: AccountLoginView?
}

enum AccountLoginCallResult {
    case success(AccountLoginView)
    case unsupportedCLI
    case sessionUnavailable
    case transportFailure
    case requestTimeout
    case remoteFailure
    case protocolFailure
}

struct AccountRPCFailure: Decodable {
    let code: String
    let message: String
}

struct AccountRPCResult: Decodable {
    let ok: Bool
    let value: AccountLoginView?
    let error: AccountRPCFailure?
}

struct AccountRPCEnvelope: Decodable {
    let type: String
    let rpcId: String
    let result: AccountRPCResult
}
