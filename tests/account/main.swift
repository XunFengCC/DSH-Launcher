import Foundation

private func decodeView(_ status: String, phase: String? = nil, authorizeURL: String? = nil) throws -> AccountLoginView {
    var attempt: Any = NSNull()
    if let phase {
        var value: [String: Any] = ["id": "fixture-attempt", "phase": phase]
        if let authorizeURL { value["authorizeUrl"] = authorizeURL }
        attempt = value
    }
    let value: [String: Any] = [
        "status": status,
        "links": ["usageUrl": "https://platform.deepseek.com/usage", "topUpUrl": "https://platform.deepseek.com/top_up"],
        "attempt": attempt,
    ]
    return try JSONDecoder().decode(AccountLoginView.self, from: JSONSerialization.data(withJSONObject: value))
}

precondition(AccountLoginProtocol.callbackOrigin(for: URL(string: "http://localhost:3080/")!, port: 3080) == "http://localhost:3080")
precondition(AccountLoginProtocol.callbackOrigin(for: URL(string: "http://127.0.0.1:3080/")!, port: 3080) == "http://127.0.0.1:3080")
precondition(AccountLoginProtocol.callbackOrigin(for: URL(string: "http://127.0.0.1:3080/settings/models?tab=deepseek#account")!, port: 3080) == "http://127.0.0.1:3080")
precondition(AccountLoginProtocol.callbackOrigin(for: URL(string: "http://localhost:3080/")!, port: 0) == nil)
precondition(AccountLoginProtocol.callbackOrigin(for: URL(string: "http://localhost:3080/")!, port: 65_536) == nil)
precondition(AccountLoginProtocol.callbackOrigin(for: URL(string: "http://localhost:3081/")!, port: 3080) == nil)
precondition(AccountLoginProtocol.callbackOrigin(for: URL(string: "http://localhost/")!, port: 3080) == nil)
precondition(AccountLoginProtocol.callbackOrigin(for: URL(string: "http://user@localhost:3080/")!, port: 3080) == nil)
precondition(AccountLoginProtocol.callbackOrigin(for: URL(string: "http://user:secret@localhost:3080/")!, port: 3080) == nil)
precondition(AccountLoginProtocol.callbackOrigin(for: URL(string: "https://localhost:3080/")!, port: 3080) == nil)
precondition(AccountLoginProtocol.callbackOrigin(for: URL(string: "http://attacker.example:3080/")!, port: 3080) == nil)

let acceptedAuthorizationURLs = [
    "https://platform.deepseek.com/dsh/authorize?state=opaque&next=%2F",
    "https://PLATFORM.DEEPSEEK.COM:443/dsh/authorize?state=opaque",
]
for value in acceptedAuthorizationURLs {
    precondition(AccountLoginProtocol.authorizationURL(value) != nil, "rejected official URL: \(value)")
}
let rejectedAuthorizationURLs = [
    "http://platform.deepseek.com/dsh/authorize?state=x",
    "https://platform.deepseek.com.attacker.example/dsh/authorize?state=x",
    "https://attacker.example/dsh/authorize?state=x",
    "https://user@platform.deepseek.com/dsh/authorize?state=x",
    "https://platform.deepseek.com:444/dsh/authorize?state=x",
    "https://platform.deepseek.com/other?state=x",
    "https://platform.deepseek.com/dsh/authorize?state=x#fragment",
]
for value in rejectedAuthorizationURLs {
    precondition(AccountLoginProtocol.authorizationURL(value) == nil, "accepted unsafe URL: \(value)")
}

let requestData = try AccountLoginProtocol.requestData(
    method: AccountLoginProtocol.startMethod,
    rpcID: "fixture-rpc-id",
    args: ["client": ["version": "fixture", "locale": "zh-CN", "timezoneOffsetSeconds": 28_800],
           "callbackOrigin": "http://127.0.0.1:3080", "loginSource": "web"]
)
let request = try JSONSerialization.jsonObject(with: requestData) as! [String: Any]
precondition(request["type"] as? String == "client-request")
precondition(request["rpcId"] as? String == "fixture-rpc-id")
precondition(request["method"] as? String == "account/startSignIn")
let payload = request["payload"] as! [String: Any]
let args = payload["args"] as! [String: Any]
precondition(payload.count == 1)
precondition(args["callbackOrigin"] as? String == "http://127.0.0.1:3080")
precondition(args["loginSource"] as? String == "web")
precondition(args["client"] != nil)
precondition(!String(decoding: requestData, as: UTF8.self).contains("cookie"))
precondition(!String(decoding: requestData, as: UTF8.self).contains("token"))

do {
    _ = try AccountLoginProtocol.requestData(method: "account/unknown", rpcID: "fixture", args: [:])
    preconditionFailure("unexpected methods must not be serializable")
} catch AccountLoginRequestError.invalidRequest {
    // Expected: only the explicit account state/sign-in/sign-out methods.
}
let cancelData = try AccountLoginProtocol.requestData(
    method: AccountLoginProtocol.cancelMethod,
    rpcID: "cancel-rpc-id",
    args: ["attemptId": "fixture-attempt"]
)
let cancelEnvelope = try JSONSerialization.jsonObject(with: cancelData) as! [String: Any]
let cancelPayload = cancelEnvelope["payload"] as! [String: Any]
let cancelArgs = cancelPayload["args"] as! [String: Any]
precondition(cancelArgs.count == 1 && cancelArgs["attemptId"] as? String == "fixture-attempt")

let waiting = try decodeView(
    "signed-out", phase: "waiting-browser",
    authorizeURL: "https://platform.deepseek.com/dsh/authorize?state=opaque"
)
if case .authorize(let url) = AccountLoginProtocol.transition(for: waiting) {
    precondition(url.host == "platform.deepseek.com")
} else {
    preconditionFailure("waiting-browser state should authorize only the validated Platform URL")
}
let initializing = try decodeView("signed-out", phase: "initializing")
let invalidAuthorize = try decodeView("signed-out", phase: "waiting-browser", authorizeURL: "https://attacker.example/steal")
let failed = try decodeView("signed-out", phase: "failed")
let cancelled = try decodeView("signed-out", phase: "cancelled")
let alreadyStored = try decodeView("credential-stored")
let stored = try decodeView("credential-stored", phase: "succeeded")
precondition(AccountLoginProtocol.transition(for: initializing) == .pending)
precondition(AccountLoginProtocol.transition(for: invalidAuthorize) == .invalidAuthorization)
precondition(AccountLoginProtocol.transition(for: failed) == .failed)
precondition(AccountLoginProtocol.transition(for: cancelled) == .cancelled)
precondition(AccountLoginProtocol.transition(for: alreadyStored) == .alreadyStored)
precondition(AccountLoginProtocol.transition(for: stored) == .succeeded)

let unsupported = Data(#"{"kind":"httpFailure","status":404}"#.utf8)
if case .unsupportedCLI = AccountLoginProtocol.decodePageReply(unsupported) {} else {
    preconditionFailure("HTTP 404 should identify a CLI without the account RPC route")
}
let missingRemoteMethod = Data(#"{"kind":"remoteFailure","code":"gateway/method-unavailable"}"#.utf8)
if case .unsupportedCLI = AccountLoginProtocol.decodePageReply(missingRemoteMethod) {} else {
    preconditionFailure("an unavailable account Remote should identify a CLI without this capability")
}
let unavailableGateway = Data(#"{"kind":"remoteFailure","code":"gateway/service-unavailable"}"#.utf8)
if case .remoteFailure = AccountLoginProtocol.decodePageReply(unavailableGateway) {} else {
    preconditionFailure("a temporarily unavailable gateway must not be reported as an old CLI")
}
for code in ["gateway/definition-unavailable", "gateway/invocation-unavailable"] {
    let missingDefinition = Data(#"{"kind":"remoteFailure","code":"\#(code)"}"#.utf8)
    if case .unsupportedCLI = AccountLoginProtocol.decodePageReply(missingDefinition) {} else {
        preconditionFailure("\(code) should identify a CLI without this account capability")
    }
}
let timedOut = Data(#"{"kind":"timeout"}"#.utf8)
if case .requestTimeout = AccountLoginProtocol.decodePageReply(timedOut) {} else {
    preconditionFailure("a hung page RPC must be reported as a bounded timeout")
}
let transportFailure = Data(#"{"kind":"transportFailure"}"#.utf8)
if case .transportFailure = AccountLoginProtocol.decodePageReply(transportFailure) {} else {
    preconditionFailure("network failures should remain distinct from invalid RPC envelopes")
}
let mismatchedRPC = Data(#"{"kind":"rpcMismatch"}"#.utf8)
if case .protocolFailure = AccountLoginProtocol.decodePageReply(mismatchedRPC) {} else {
    preconditionFailure("mismatched rpcId must fail closed")
}
precondition(AccountLoginProtocol.acceptsResponse(generation: 4, currentGeneration: 4, active: true))
precondition(!AccountLoginProtocol.acceptsResponse(generation: 4, currentGeneration: 5, active: true))
precondition(!AccountLoginProtocol.acceptsResponse(generation: 4, currentGeneration: 4, active: false))
let deadline = Date(timeIntervalSince1970: 100)
precondition(!AccountLoginProtocol.deadlineExpired(deadline, now: Date(timeIntervalSince1970: 99)))
precondition(AccountLoginProtocol.deadlineExpired(deadline, now: deadline))

let signOutData = try AccountLoginProtocol.requestData(method: AccountLoginProtocol.signOutMethod, rpcID: "signout-test", args: ["client": ["version": "1.0.0-rc.1", "locale": "en", "timezoneOffsetSeconds": 0]])
let signOut = try AccountLoginProtocol.messageObject(from: signOutData)
precondition(signOut["method"] as? String == "account/signOut")
precondition(LauncherLocalization.language(for: ["zh-Hans-CN", "en"]) == "zh")
precondition(LauncherLocalization.language(for: ["en-US", "zh"]) == "en")
precondition(LauncherLocalization.menu("退出 DeepSeek 账号", language: "en") == "Sign Out of DeepSeek")
precondition(LauncherLocalization.menu("登录 DeepSeek 账号", language: "zh") == "登录 DeepSeek 账号")
print("AccountLogin and localization protocol checks passed")
