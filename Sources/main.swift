import AppKit
import Foundation
import WebKit

private enum LauncherConfig {
    static let isDev = (Bundle.main.bundleIdentifier ?? "").hasSuffix("-dev")
    static let title = isDev ? "DSH Launcher Dev" : "DSH Launcher"
    static let releaseVersion = Bundle.main.object(forInfoDictionaryKey: "DSHReleaseVersion") as? String
        ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        ?? "?"
    static let env = ProcessInfo.processInfo.environment

    /// settings.json (release) / settings-dev.json (dev build); the dev build
    /// uses its own port + data dir so both flavors can run in parallel.
    private static func loadSettings() -> [String: String] {
        let path = env["DSH_SETTINGS"]
            ?? (NSHomeDirectory() + "/.config/deepseek-harness-launcher/\(isDev ? "settings-dev.json" : "settings.json")")
        let expanded = (path as NSString).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: expanded),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return [:] }
        return object
    }

    static let settingsPath: String = {
        if let override = env["DSH_SETTINGS"] { return (override as NSString).expandingTildeInPath }
        return (NSHomeDirectory() + "/.config/deepseek-harness-launcher/\(isDev ? "settings-dev.json" : "settings.json")" as NSString).expandingTildeInPath
    }()

    static let settings = loadSettings()

    private static func cfg(_ settingKey: String, _ envKey: String, _ defaultValue: String) -> String {
        if let value = env[envKey], !value.isEmpty { return value }
        if let value = settings[settingKey], !value.isEmpty { return value }
        return defaultValue
    }

    static let dshHome = cfg("dsh_home", "DSH_HOME", NSHomeDirectory() + (isDev ? "/.dsh-launcher-dev" : "/.dsh"))
    static let webPort = Int(cfg("port", "DSH_PORT", isDev ? "3082" : "3080")) ?? (isDev ? 3082 : 3080)
    static let webURL = URL(string: "http://localhost:\(webPort)/")!
    static let webHost = "localhost"
    static let controllerPath = cfg(
        "controller_path", "DSH_CONTROLLER",
        Bundle.main.resourceURL?.appendingPathComponent("deepseekHarness.py").path
            ?? NSHomeDirectory() + "/.local/share/deepseek-harness/deepseekHarness.py"
    )
    static let logPath = cfg(
        "log_path", "DSH_LOG", dshHome + "/launcher/web.log"
    )

    /// True only for the harness's own loopback web entry
    /// (localhost/127.0.0.1 on port 3080). Other loopback URLs on other
    /// ports (e.g. a local SSH tunnel to Cockpit) must open in the system
    /// browser instead of being swallowed by the WKWebView.
    static func isInternalWebURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http", url.user == nil, url.password == nil else { return false }
        guard let host = url.host?.lowercased() else { return false }
        guard host == "localhost" || host == "127.0.0.1" else { return false }
        return (url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)) == webPort
    }
}

/// Transparent drag zone spanning the whole titlebar band. Page controls in
/// the band (e.g. the session-log save button) are reported from JS
/// (`dragExclusions`) as content-coordinate rects; the zone returns nil from
/// hitTest there so the page keeps priority, while everything around stays
/// draggable / double-click-zoomable.
private final class DragRegionView: NSView {
    var excludedRects: [NSRect] = []

    override func hitTest(_ point: NSPoint) -> NSView? {
        for rect in excludedRects where rect.contains(point) {
            return nil
        }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            window?.performZoom(nil)
        } else {
            window?.performDrag(with: event)
        }
    }
}

private struct CommandResult: Sendable {
    let terminationStatus: Int32
    let standardOutput: String
    let standardError: String

    var message: String {
        let error = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        if !error.isEmpty { return error }
        let output = standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? "控制器没有返回错误详情。" : output
    }
}

private struct HarnessActivity: Decodable, Sendable {
    let serviceRunning: Bool
    let busy: Bool
    let runningSessionIDs: [String]
    let childProcessIDs: [Int]

    enum CodingKeys: String, CodingKey {
        case serviceRunning = "service_running"
        case busy
        case runningSessionIDs = "running_session_ids"
        case childProcessIDs = "child_process_ids"
    }
}

private struct DistTagEntry: Decodable, Sendable {
    let version: String
    let published: String
}

private struct UpdateRecommended: Decodable, Sendable {
    let tag: String
    let version: String
    let published: String
}

private struct UpdateInfo: Decodable, Sendable {
    let localVersion: String?
    let registry: [String: DistTagEntry]?
    let updateAvailable: Bool
    let recommended: UpdateRecommended?

    enum CodingKeys: String, CodingKey {
        case localVersion = "local_version"
        case registry
        case updateAvailable = "update_available"
        case recommended
    }
}

private struct UpdateResult: Decodable, Sendable {
    let status: String
    let message: String
    let backup: String?
    let from: String?
    let to: String?
}

private struct StartResult: Decodable, Sendable {
    let status: String
    let pid: Int?
    let url: String?
    let authUrl: String?

    enum CodingKeys: String, CodingKey {
        case status
        case pid
        case url
        case authUrl = "auth_url"
    }
}

private enum ControllerError: LocalizedError {
    case couldNotLaunch(String)
    case commandFailed(CommandResult)
    case invalidActivity(String)

    var errorDescription: String? {
        switch self {
        case .couldNotLaunch(let detail):
            return "无法运行本机控制器：\(detail)"
        case .commandFailed(let result):
            return result.message
        case .invalidActivity(let detail):
            return "无法确认 Harness 是否空闲：\(detail)"
        }
    }
}

private final class HarnessController: @unchecked Sendable {
    // run() is called only from controllerQueue. Caching avoids re-probing
    // runtimes for every controller command while keeping bootstrap off the UI.
    private var runtimePaths: RuntimeBootstrap.Paths?

    func run(_ arguments: [String]) throws -> CommandResult {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        var environment = ProcessInfo.processInfo.environment
        environment["DSH_SETTINGS"] = LauncherConfig.settingsPath
        environment["DSH_HOME"] = LauncherConfig.dshHome
        environment["DSH_PORT"] = String(LauncherConfig.webPort)
        if LauncherConfig.isDev {
            // A dev bundle must be safe even when launched by Finder without
            // test overrides: data, service port and writable CLI are separate.
            let root = NSHomeDirectory() + "/.local/share/deepseek-harness-dev"
            let defaults = [("workspace", "DSH_WORKSPACE", root + "/workspace"),
                            ("backup_dir", "DSH_BACKUP_DIR", root + "/backups"),
                            ("install_prefix", "DSH_INSTALL_PREFIX", root + "/runtime")]
            for (setting, key, fallback) in defaults where environment[key] == nil {
                environment[key] = LauncherConfig.settings[setting] ?? fallback
            }
        }
        if runtimePaths == nil {
            do {
                runtimePaths = try RuntimeBootstrap.resolve(
                    root: RuntimeBootstrap.defaultRoot(environment: environment),
                    architecture: Self.machineArchitecture,
                    environment: environment,
                    settings: LauncherConfig.settings
                )
            } catch {
                throw ControllerError.couldNotLaunch("自动配置本机运行环境失败。\(error.localizedDescription)")
            }
        }
        guard let runtimePaths else {
            throw ControllerError.couldNotLaunch("没有可用的本机运行环境。")
        }
        let pythonPath = runtimePaths.python
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [LauncherConfig.controllerPath] + arguments
        // Pin the settings file so the dev build can never read the release
        // config (and vice versa), even if defaults shift later.
        environment["DSH_PYTHON_BIN"] = runtimePaths.python
        environment["DSH_NODE_BIN"] = runtimePaths.node
        let inheritedPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = URL(fileURLWithPath: runtimePaths.node).deletingLastPathComponent().path + ":" + inheritedPath
        process.environment = environment
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw ControllerError.couldNotLaunch(error.localizedDescription)
        }
        process.waitUntilExit()
        let output = String(
            data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let error = String(
            data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        return CommandResult(
            terminationStatus: process.terminationStatus,
            standardOutput: output,
            standardError: error
        )
    }

    private static var machineArchitecture: String {
        var system = utsname()
        uname(&system)
        let machine = withUnsafeBytes(of: system.machine) { bytes in
            String(cString: bytes.bindMemory(to: CChar.self).baseAddress!)
        }
        return machine == "arm64" ? "arm64" : machine == "x86_64" ? "x86_64" : machine
    }

    func activity() throws -> HarnessActivity {
        let result = try run(["activity"])
        guard result.terminationStatus == 0 else {
            throw ControllerError.commandFailed(result)
        }
        guard let data = result.standardOutput.data(using: .utf8) else {
            throw ControllerError.invalidActivity("返回内容不是 UTF-8。")
        }
        do {
            return try JSONDecoder().decode(HarnessActivity.self, from: data)
        } catch {
            throw ControllerError.invalidActivity(error.localizedDescription)
        }
    }
}

/// Bridges the launcher's private configuration into the feedback module:
/// `FeedbackCore`/`FeedbackWindow` receive resolved values and never read
/// settings, the keychain, the state file or any log themselves.
private enum FeedbackSetup {
    static func configuration() -> FeedbackConfiguration {
        FeedbackConfiguration.resolve(
            environment: LauncherConfig.env,
            settings: LauncherConfig.settings,
            infoPlist: Bundle.main.infoDictionary ?? [:]
        )
    }

    static func environment() -> FeedbackEnvironment {
        FeedbackEnvironment.current(
            appName: LauncherConfig.title,
            appVersion: LauncherConfig.releaseVersion,
            buildNumber: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        )
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, NSMenuItemValidation, NSMenuDelegate {
    private let controller = HarnessController()
    private let controllerQueue = DispatchQueue(
        label: "dev.fengyin.deepseek-harness-launcher.controller",
        qos: .userInitiated
    )
    private var window: NSWindow!
    private var webView: WKWebView!
    private var dragRegion: DragRegionView?
    private var overlay: NSVisualEffectView!
    private var spinner: NSProgressIndicator!
    private var statusLabel: NSTextField!
    private var detailLabel: NSTextField!
    private var retryButton: NSButton!
    private var logButton: NSButton!
    private var startupGeneration = 0
    private var terminationInFlight = false
    private var allowWindowClose = false
    // An update changes the on-disk dsh tree before the running service is
    // restarted. Keep this small in-memory handoff so the App can distinguish
    // a normal page load from the update's final WebView/auth refresh and give
    // the user a visible completion result.
    private var pendingHarnessUpdateSummary: String?
    private var pendingUpdateCompletionMessage: String?
    private var runtimeProgressObserver: NSObjectProtocol?
    private var accountLoginMenuItem: NSMenuItem?
    private var accountCredentialStored = false
    private var accountStateTimer: Timer?
    private var accountStateReadInFlight = false
    private var nativeLanguage = LauncherLocalization.language(for: Locale.preferredLanguages)
    private var localeBridgeSeen = false
    private var localeWriteInFlight = false
    private var aboutAlert: NSAlert?
    private var accountLoginAlert: NSAlert?
    private var accountLoginTimer: Timer?
    private var accountLoginDeadline: Date?
    private var accountLoginAttemptID: String?
    private var accountLoginGeneration = 0
    private var accountLoginOrigin: String?
    private var accountLoginCallInFlight = false
    private var accountLoginCancelInFlight = false
    private var accountAuthorizationOpened = false
    /// Feedback panel (Sources/FeedbackWindow.swift). Created lazily so the
    /// feedback configuration is resolved from the same settings/env the rest
    /// of the launcher uses, and only when the user opens the panel.
    private lazy var feedbackPanel = FeedbackPanelController(
        configuration: FeedbackSetup.configuration(),
        environment: FeedbackSetup.environment()
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMainMenu()
        buildWindow()
        runtimeProgressObserver = NotificationCenter.default.addObserver(
            forName: RuntimeBootstrap.downloadProgressNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let kind = notification.userInfo?["kind"] as? String,
                  let received = notification.userInfo?["received"] as? Int64 else { return }
            let expected = notification.userInfo?["expected"] as? Int64 ?? -1
            Task { @MainActor [weak self] in
                self?.setRuntimeDownloadDetail(kind: kind, received: received, expected: expected)
            }
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startHarness()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard window != nil else { return }
        showWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if allowWindowClose { return true }
        NSApp.terminate(nil)
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationInFlight else { return .terminateLater }
        terminationInFlight = true
        showOverlay(title: "正在检查任务状态…", detail: "确认可以安全停止 DeepSeek Harness。", spinning: true)

        let harnessController = controller
        controllerQueue.async { [weak self, harnessController] in
            let result = Result { try harnessController.activity() }
            DispatchQueue.main.async { [weak self] in
                self?.decideTermination(using: result, application: NSApp)
            }
        }
        return .terminateLater
    }

    @objc private func reloadPage() {
        // A plain reload can repeat an unauthenticated localhost page. Ask the
        // controller for the current (or newly started) auth URL instead.
        startHarness()
    }

    @objc private func retryStart() {
        startHarness()
    }

    @objc private func loginDeepSeekAccount() {
        guard !accountLoginCallInFlight, accountLoginTimer == nil else {
            showAccountLoginMessage("DeepSeek 账号登录已在等待中。")
            return
        }
        guard let pageURL = webView?.url, LauncherConfig.isInternalWebURL(pageURL) else {
            showAccountLoginMessage("请先等待 Harness 网页加载完成，再开始账号登录。")
            return
        }
        guard let callbackOrigin = AccountLoginProtocol.callbackOrigin(for: pageURL, port: LauncherConfig.webPort) else {
            showAccountLoginMessage("当前 Harness 页面不是预期的本机登录来源，已阻止账号登录。请从“显示 → 重新载入”后重试。")
            return
        }

        accountLoginGeneration += 1
        let generation = accountLoginGeneration
        accountLoginOrigin = callbackOrigin
        accountLoginCallInFlight = true
        accountLoginAttemptID = nil
        accountAuthorizationOpened = false
        updateAccountLoginMenu()
        accountLoginPreflightAlert()
        callAccountRPC(method: AccountLoginProtocol.stateMethod, args: [:], generation: generation) { [weak self] result in
            guard let self,
                  AccountLoginProtocol.acceptsResponse(
                    generation: generation,
                    currentGeneration: self.accountLoginGeneration,
                    active: self.accountLoginAlert != nil
                  ) else { return }
            self.accountLoginCallInFlight = false
            switch result {
            case .success(let view) where view.status == .credentialStored:
                self.accountCredentialStored = true
                self.finishAccountLogin(generation: generation)
            case .success:
                self.dismissAccountLoginSheet()
                self.beginAccountSignIn(callbackOrigin: callbackOrigin, generation: generation)
            case .unsupportedCLI:
                self.finishAccountLogin(generation: generation)
                self.showAccountCLIUnsupported()
            case .sessionUnavailable:
                self.finishAccountLogin(generation: generation)
                self.showAccountLoginMessage("Launcher 与 Harness 的本机认证连接已失效，请从“显示 → 重新载入”刷新后再试。")
            case .transportFailure, .requestTimeout, .remoteFailure, .protocolFailure:
                self.finishAccountLogin(generation: generation)
                self.showAccountLoginMessage("暂时无法读取 DeepSeek 账号状态。请确认 Harness 正在运行后重试。")
            }
        }
    }

    @objc private func cancelDeepSeekAccountLogin() {
        guard !accountLoginCancelInFlight, accountLoginAlert != nil else { return }
        guard let attemptID = accountLoginAttemptID else {
            let generation = accountLoginGeneration
            finishAccountLogin(generation: generation)
            showAccountLoginMessage("已停止等待账号登录。上游请求尚未返回尝试编号，Launcher 无法确认远端已取消；不会打开授权页，未完成的上游尝试会按其自身有效期结束。")
            return
        }
        accountLoginCancelInFlight = true
        accountLoginCallInFlight = true
        updateAccountLoginSheet("正在取消账号登录…", cancellable: false)
        updateAccountLoginMenu()
        let generation = accountLoginGeneration
        callAccountRPC(
            method: AccountLoginProtocol.cancelMethod,
            args: ["attemptId": attemptID],
            generation: generation
        ) { [weak self] result in
            guard let self,
                  AccountLoginProtocol.acceptsResponse(
                    generation: generation,
                    currentGeneration: self.accountLoginGeneration,
                    active: self.accountLoginAlert != nil
                  ) else { return }
            self.accountLoginCallInFlight = false
            self.accountLoginCancelInFlight = false
            switch result {
            case .success(let view):
                if view.attempt?.phase == .cancelled {
                    self.finishAccountLogin(generation: generation)
                    self.showAccountLoginMessage("DeepSeek 账号登录已取消；现有账号凭据保持不变。")
                } else {
                    self.updateAccountLoginSheet("账号登录仍在处理中，请稍候或稍后重试取消。", cancellable: true)
                    self.scheduleAccountLoginPoll(generation: generation)
                }
            default:
                self.updateAccountLoginSheet("暂时无法确认取消状态；Launcher 会继续观察当前登录尝试。", cancellable: true)
                self.scheduleAccountLoginPoll(generation: generation)
            }
        }
    }

    private func accountLoginPreflightAlert() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "正在检查 DeepSeek 账号登录支持…"
        alert.informativeText = "登录状态只通过当前 WebView 的认证连接读取。"
        alert.addButton(withTitle: "取消")
        accountLoginAlert = alert
        alert.beginSheetModal(for: window) { [weak self, weak alert] response in
            guard response == .alertFirstButtonReturn,
                  let self,
                  self.accountLoginAlert === alert,
                  self.accountLoginAttemptID == nil else { return }
            self.finishAccountLogin(generation: self.accountLoginGeneration)
        }
    }

    private func beginAccountSignIn(callbackOrigin: String, generation: Int) {
        guard accountLoginGeneration == generation else { return }
        accountLoginCallInFlight = true
        presentAccountLoginSheet()
        let metadata: [String: Any] = [
            "version": LauncherConfig.releaseVersion,
            "locale": Locale.current.identifier,
            "timezoneOffsetSeconds": TimeZone.current.secondsFromGMT(),
        ]
        callAccountRPC(
            method: AccountLoginProtocol.startMethod,
            args: ["client": metadata, "callbackOrigin": callbackOrigin, "loginSource": "web"],
            generation: generation
        ) { [weak self] result in
            guard let self,
                  AccountLoginProtocol.acceptsResponse(
                    generation: generation,
                    currentGeneration: self.accountLoginGeneration,
                    active: self.accountLoginAlert != nil
                  ) else { return }
            self.accountLoginCallInFlight = false
            switch result {
            case .success(let view):
                self.observeAccountLogin(view, generation: generation)
            case .unsupportedCLI:
                self.finishAccountLogin(generation: generation)
                self.showAccountCLIUnsupported()
            case .sessionUnavailable:
                self.finishAccountLogin(generation: generation)
                self.showAccountLoginMessage("Launcher 与 Harness 的本机认证连接已失效，请从“显示 → 重新载入”刷新后再试。")
            case .transportFailure, .requestTimeout, .remoteFailure, .protocolFailure:
                self.finishAccountLogin(generation: generation)
                self.showAccountLoginMessage("当前 Harness 无法开始 DeepSeek 账号登录。可在 Settings → Models 配置 API key。")
            }
        }
    }

    private func callAccountRPC(
        method: String,
        args: [String: Any],
        generation: Int,
        completion: @escaping (AccountLoginCallResult) -> Void
    ) {
        guard accountLoginGeneration == generation,
              let pageURL = webView?.url,
              LauncherConfig.isInternalWebURL(pageURL),
              AccountLoginProtocol.callbackOrigin(for: pageURL, port: LauncherConfig.webPort) == accountLoginOrigin else {
            completion(.sessionUnavailable)
            return
        }
        let rpcID = UUID().uuidString.lowercased()
        guard let requestData = try? AccountLoginProtocol.requestData(method: method, rpcID: rpcID, args: args),
              let message = try? AccountLoginProtocol.messageObject(from: requestData) else {
            completion(.protocolFailure)
            return
        }
        let script = """
        const controller = new AbortController();
        const timeout = setTimeout(() => controller.abort(), 15000);
        try {
          const response = await fetch(new URL(`/api/${message.method}`, window.location.origin), {
            method: 'POST',
            credentials: 'same-origin',
            signal: controller.signal,
            headers: { 'content-type': 'application/json' },
            body: JSON.stringify(message)
          });
          if (!response.ok) return { kind: 'httpFailure', status: response.status };
          const envelope = await response.json();
          if (envelope?.type !== 'server-response') return { kind: 'invalidResponse' };
          if (envelope.rpcId !== message.rpcId) return { kind: 'rpcMismatch' };
          if (envelope.result?.ok !== true) {
            return { kind: 'remoteFailure', code: typeof envelope.result?.error?.code === 'string' ? envelope.result.error.code : '' };
          }
          const source = envelope.result.value;
          const statuses = ['signed-out', 'credential-stored'];
          const phases = ['initializing', 'waiting-browser', 'exchanging', 'committing', 'succeeded', 'cancelled', 'expired', 'failed'];
          if (!source || !statuses.includes(source.status) || !source.links
              || typeof source.links.usageUrl !== 'string' || typeof source.links.topUpUrl !== 'string') {
            return { kind: 'invalidResponse' };
          }
          let attempt = null;
          if (source.attempt !== null) {
            const input = source.attempt;
            if (!input || typeof input.id !== 'string' || !phases.includes(input.phase)
                || (input.authorizeUrl !== undefined && typeof input.authorizeUrl !== 'string')
                || (input.expiresAt !== undefined && (!Number.isFinite(input.expiresAt) || typeof input.expiresAt !== 'number'))
                || (input.errorCode !== undefined && !['network', 'protocol', 'expired', 'storage'].includes(input.errorCode))) {
              return { kind: 'invalidResponse' };
            }
            attempt = { id: input.id, phase: input.phase };
            if (typeof input.authorizeUrl === 'string') attempt.authorizeUrl = input.authorizeUrl;
            if (typeof input.expiresAt === 'number') attempt.expiresAt = input.expiresAt;
            if (typeof input.errorCode === 'string') attempt.errorCode = input.errorCode;
          }
          return { kind: 'success', view: {
            status: source.status,
            links: { usageUrl: source.links.usageUrl, topUpUrl: source.links.topUpUrl },
            attempt
          } };
        } catch (_) {
          if (_?.name === 'AbortError') return { kind: 'timeout' };
          return { kind: 'transportFailure' };
        } finally {
          clearTimeout(timeout);
        }
        """
        webView.callAsyncJavaScript(
            script,
            arguments: ["message": message],
            in: nil,
            in: .page
        ) { [weak self] result in
            guard let self else { return }
            guard self.accountLoginGeneration == generation else {
                completion(.sessionUnavailable)
                return
            }
            guard case .success(let value) = result,
                  JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value) else {
                completion(.transportFailure)
                return
            }
            let reply = AccountLoginProtocol.decodePageReply(data)
            completion(reply)
        }
    }

    private func observeAccountLogin(_ view: AccountLoginView, generation: Int) {
        accountCredentialStored = view.status == .credentialStored
        guard AccountLoginProtocol.acceptsResponse(
            generation: generation, currentGeneration: accountLoginGeneration, active: accountLoginAlert != nil
        ) else { return }
        if let attempt = view.attempt {
            accountLoginAttemptID = attempt.id
            let now = Date()
            let expiry = attempt.expiresAt.map { Date(timeIntervalSince1970: $0 / 1_000) }
            let candidate = min(expiry ?? now.addingTimeInterval(600), now.addingTimeInterval(600))
            accountLoginDeadline = min(accountLoginDeadline ?? candidate, candidate)
        } else if accountLoginAttemptID == nil {
            finishAccountLogin(generation: generation)
            showAccountLoginMessage("Harness 没有返回账号登录尝试状态。请从 App 菜单手动检查更新，或配置 API key。")
            return
        }
        updateAccountLoginMenu()

        switch AccountLoginProtocol.transition(for: view) {
        case .alreadyStored:
            finishAccountLogin(generation: generation)
            showAccountLoginMessage("当前账号已登录。")
        case .authorize(let url):
            if !accountAuthorizationOpened {
                guard AccountLoginProtocol.authorizationURL(url.absoluteString) == url,
                      NSWorkspace.shared.open(url) else {
                    finishAccountLogin(generation: generation)
                    showAccountLoginMessage("DeepSeek 返回的授权地址未通过校验，Launcher 已阻止打开。")
                    return
                }
                accountAuthorizationOpened = true
                updateAccountLoginSheet("已在系统浏览器打开 DeepSeek 官方授权页。完成登录后会自动返回。", cancellable: true)
            }
            scheduleAccountLoginPoll(generation: generation)
        case .invalidAuthorization:
            finishAccountLogin(generation: generation)
            showAccountLoginMessage("DeepSeek 返回的授权地址未通过校验，Launcher 已阻止打开。")
        case .pending:
            updateAccountLoginSheet("正在准备 DeepSeek 官方账号授权…", cancellable: true)
            scheduleAccountLoginPoll(generation: generation)
        case .succeeded:
            finishAccountLogin(generation: generation)
            showAccountLoginMessage("DeepSeek 账号登录成功，正在刷新 Harness 页面。")
            startHarness()
        case .cancelled:
            finishAccountLogin(generation: generation)
            showAccountLoginMessage("DeepSeek 账号登录已取消；现有账号凭据保持不变。")
        case .failed:
            finishAccountLogin(generation: generation)
            showAccountLoginMessage("DeepSeek 账号登录未完成或已过期。请从 App 菜单重新登录，或在 Settings → Models 配置 API key。")
        case .idle:
            finishAccountLogin(generation: generation)
            showAccountLoginMessage("Harness 当前没有活动的账号登录尝试。")
        }
    }

    private func scheduleAccountLoginPoll(generation: Int) {
        guard accountLoginGeneration == generation, accountLoginTimer == nil else { return }
        accountLoginTimer = Timer.scheduledTimer(
            timeInterval: 2,
            target: self,
            selector: #selector(pollAccountLogin(_:)),
            userInfo: generation,
            repeats: true
        )
    }

    @objc private func pollAccountLogin(_ timer: Timer) {
        guard let generation = timer.userInfo as? Int,
              AccountLoginProtocol.acceptsResponse(
                generation: generation,
                currentGeneration: accountLoginGeneration,
                active: accountLoginAlert != nil
              ) else { return }
        guard !AccountLoginProtocol.deadlineExpired(accountLoginDeadline ?? .distantFuture, now: Date()) else {
            timeOutAccountLogin(generation: generation)
            return
        }
        guard !accountLoginCallInFlight else { return }
        accountLoginCallInFlight = true
        callAccountRPC(method: AccountLoginProtocol.stateMethod, args: [:], generation: generation) { [weak self] result in
            guard let self,
                  AccountLoginProtocol.acceptsResponse(
                    generation: generation,
                    currentGeneration: self.accountLoginGeneration,
                    active: self.accountLoginAlert != nil
                  ) else { return }
            self.accountLoginCallInFlight = false
            switch result {
            case .success(let view): self.observeAccountLogin(view, generation: generation)
            case .unsupportedCLI:
                self.finishAccountLogin(generation: generation)
                self.showAccountCLIUnsupported()
            case .sessionUnavailable, .transportFailure, .requestTimeout, .remoteFailure, .protocolFailure:
                self.finishAccountLogin(generation: generation)
                self.showAccountLoginMessage("无法继续确认账号登录状态。请重新载入 Harness 页面后检查账号，必要时从 App 菜单手动检查 CLI 更新。")
            }
        }
    }

    private func timeOutAccountLogin(generation: Int) {
        guard accountLoginGeneration == generation else { return }
        if let attemptID = accountLoginAttemptID {
            // Best effort cancellation only settles this sign-in attempt; it
            // never signs out or removes a previously stored account.
            callAccountRPC(method: AccountLoginProtocol.cancelMethod, args: ["attemptId": attemptID], generation: generation) { _ in }
        }
        finishAccountLogin(generation: generation)
        showAccountLoginMessage("DeepSeek 账号登录等待超时。现有账号凭据保持不变，您可以稍后重新尝试。")
    }

    private func presentAccountLoginSheet() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "正在连接 DeepSeek 官方账号服务…"
        alert.informativeText = "Launcher 不接收账号密码或 OAuth 凭据。"
        alert.addButton(withTitle: "取消登录")
        accountLoginAlert = alert
        alert.beginSheetModal(for: window) { [weak self, weak alert] response in
            guard response == .alertFirstButtonReturn,
                  let self,
                  self.accountLoginAlert === alert else { return }
            self.cancelDeepSeekAccountLogin()
        }
        updateAccountLoginMenu()
    }

    private func updateAccountLoginSheet(_ text: String, cancellable: Bool) {
        accountLoginAlert?.informativeText = text
        accountLoginAlert?.buttons.first?.isEnabled = cancellable && !accountLoginCancelInFlight
    }

    private func finishAccountLogin(generation: Int) {
        guard accountLoginGeneration == generation else { return }
        accountLoginGeneration += 1
        accountLoginTimer?.invalidate()
        accountLoginTimer = nil
        accountLoginDeadline = nil
        accountLoginAttemptID = nil
        accountLoginOrigin = nil
        accountLoginCallInFlight = false
        accountLoginCancelInFlight = false
        accountAuthorizationOpened = false
        dismissAccountLoginSheet()
        updateAccountLoginMenu()
    }

    private func dismissAccountLoginSheet() {
        guard let alert = accountLoginAlert else { return }
        accountLoginAlert = nil
        if let parent = alert.window.sheetParent {
            parent.endSheet(alert.window, returnCode: .cancel)
        } else {
            alert.window.close()
        }
    }

    private func showAccountLoginMessage(_ text: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "DeepSeek 账号登录"
        alert.informativeText = text
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private func showAccountCLIUnsupported() {
        showAccountLoginMessage("当前已安装的 DeepSeek Harness CLI 不支持官方账号登录入口。请从 App 菜单选择“检查更新…”手动检查 CLI 更新；Launcher 不会为账号登录自动升级现有 CLI。也可以在 Settings → Models 配置 DeepSeek API key。")
    }

    private func updateAccountLoginMenu() {
        accountLoginMenuItem?.title = localized(accountCredentialStored ? "退出 DeepSeek 账号" : "登录 DeepSeek 账号")
        accountLoginMenuItem?.isEnabled = webView?.url.map(LauncherConfig.isInternalWebURL) == true
            && accountLoginAlert == nil && !accountLoginCallInFlight
    }

    @objc private func accountMenuAction() {
        guard accountCredentialStored else { loginDeepSeekAccount(); return }
        guard let url = webView?.url,
              let origin = AccountLoginProtocol.callbackOrigin(for: url, port: LauncherConfig.webPort) else { return }
        accountLoginGeneration += 1
        let generation = accountLoginGeneration
        accountLoginOrigin = origin
        accountLoginCallInFlight = true
        updateAccountLoginMenu()
        let client: [String: Any] = ["version": LauncherConfig.releaseVersion,
                                   "locale": nativeLanguage,
                                   "timezoneOffsetSeconds": TimeZone.current.secondsFromGMT()]
        callAccountRPC(method: AccountLoginProtocol.signOutMethod, args: ["client": client], generation: generation) { [weak self] result in
            guard let self, self.accountLoginGeneration == generation else { return }
            self.accountLoginCallInFlight = false
            if case .success(let view) = result {
                self.accountCredentialStored = view.status == .credentialStored
            } else {
                self.showAccountLoginMessage("暂时无法退出 DeepSeek 账号，请确认服务连接后重试。")
            }
            self.updateAccountLoginMenu()
            self.refreshAccountState()
        }
    }

    // Safe AccountView only; never cache credentials. Polling also reflects
    // sign-in/sign-out performed outside this menu without modifying Web UI.
    private func refreshAccountState() {
        guard !accountStateReadInFlight, !accountLoginCallInFlight, accountLoginAlert == nil,
              let url = webView?.url,
              let origin = AccountLoginProtocol.callbackOrigin(for: url, port: LauncherConfig.webPort) else { return }
        accountLoginOrigin = origin
        accountStateReadInFlight = true
        let generation = accountLoginGeneration
        callAccountRPC(method: AccountLoginProtocol.stateMethod, args: [:], generation: generation) { [weak self] result in
            guard let self else { return }
            self.accountStateReadInFlight = false
            guard generation == self.accountLoginGeneration else { return }
            if case .success(let view) = result {
                self.accountCredentialStored = view.status == .credentialStored
                self.updateAccountLoginMenu()
            }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshAccountState()
        updateAccountLoginMenu()
    }

    // AppKit's automatic menu validation otherwise re-enables a selector merely
    // because this delegate implements it, overriding the idle Cancel state.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(accountMenuAction) {
            return webView?.url.map(LauncherConfig.isInternalWebURL) == true
                && accountLoginAlert == nil && !accountLoginCallInFlight
        }
        return true
    }

    @objc private func resetZoom() {
        webView.setMagnification(1, centeredAt: NSPoint(x: webView.bounds.midX, y: webView.bounds.midY))
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: LauncherConfig.logPath))
    }

    private var checkingPanel: NSPanel?

    @objc private func checkForUpdates() {
        // Respond instantly: a small spinner panel appears the moment the
        // menu item is clicked; the result dialog replaces it when done.
        showCheckingPanel()
        let harnessController = controller
        controllerQueue.async { [weak self, harnessController] in
            let harnessResult = Result { try harnessController.run(["check-update", "--json"]) }
            let launcherResult = LauncherUpdates.check(current: LauncherConfig.releaseVersion)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.checkingPanel?.close()
                self.checkingPanel = nil
                self.presentCombinedUpdateCheck(harnessResult, launcherResult: launcherResult)
            }
        }
    }

    private func showCheckingPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 96),
            styleMask: [.titled, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "检查更新"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        let spinner = NSProgressIndicator(frame: .zero)
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.startAnimation(nil)
        let label = NSTextField(labelWithString: "正在检查更新…")
        label.alignment = .center
        let stack = NSStackView(views: [spinner, label])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: panel.contentView!.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: panel.contentView!.centerYAnchor),
        ])
        panel.center()
        panel.orderFrontRegardless()
        checkingPanel = panel
    }

    private func presentCombinedUpdateCheck(_ harnessResult: Result<CommandResult, Error>, launcherResult: LauncherUpdateCheck) {
        var sections: [String] = []
        var buttons: [(String, () -> Void)] = []

        // ── DSH Launcher（本 App）────────────────────────────────────────
        let localApp = LauncherConfig.releaseVersion
            + " (build " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?") + ")"
        var appLine = "当前版本：\(localApp)"
        switch launcherResult {
        case .available(let latest, let pageURL):
            appLine += " · 最新版本：\(latest)"
            buttons.append(("下载启动器更新…", { NSWorkspace.shared.open(pageURL) }))
        case .current: appLine += " · 已是最新"
        case .unpublished: appLine += " · 暂无公开发行版本"
        case .failed(let reason): appLine += " · 查询失败：\(reason)"
        }
        sections.append("DSH Launcher（本 App）\n\(appLine)")

        // ── DeepSeek Harness（dsh CLI）───────────────────────────────────
        var harnessLine = "查询失败"
        switch harnessResult {
        case .success(let command) where command.terminationStatus == 0:
            guard let data = command.standardOutput.data(using: .utf8),
                  let info = try? JSONDecoder().decode(UpdateInfo.self, from: data) else {
                harnessLine = "返回内容无法解析"
                break
            }
            let local = info.localVersion ?? "未知"
            if info.updateAvailable, let recommended = info.recommended {
                harnessLine = "当前 \(local) · 最新 \(recommended.version)（\(recommended.tag)）"
                buttons.append(("更新 Harness…", { [weak self] in self?.performUpdate() }))
            } else {
                harnessLine = "当前 \(local) · 已是最新"
            }
        case .success(let command):
            harnessLine = command.message
        case .failure(let error):
            harnessLine = error.localizedDescription
        }
        sections.append("DeepSeek Harness（dsh CLI）\n\(harnessLine)")

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "检查更新"
        alert.informativeText = sections.joined(separator: "\n\n")
        buttons.append(("关闭", {}))
        for (title, _) in buttons {
            alert.addButton(withTitle: title)
        }
        let index = Int(alert.runModal().rawValue - 1000)
        if index >= 0 && index < buttons.count {
            buttons[index].1()
        }
    }

    private func performUpdate() {
        showOverlay(title: "正在更新 DeepSeek Harness…", detail: "备份设置与会话 → 通过 npm 升级，可能需要几分钟。", spinning: true)
        let harnessController = controller
        controllerQueue.async { [weak self, harnessController] in
            let result = Result { try harnessController.run(["update", "--restart", "--json"]) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch result {
                case .success(let command) where command.terminationStatus == 0:
                    self.presentUpdateSuccess(command.standardOutput)
                case .success(let command):
                    self.presentUpdateFailure(command.message)
                case .failure(let error):
                    self.presentUpdateFailure(error.localizedDescription)
                }
            }
        }
    }

    private func presentUpdateSuccess(_ json: String) {
        guard let data = json.data(using: .utf8),
              let result = try? JSONDecoder().decode(UpdateResult.self, from: data) else {
            presentUpdateFailure("无法解析更新结果。")
            return
        }
        if result.status == "rolled_back" {
            pendingHarnessUpdateSummary = nil
            presentUpdateFailure(result.message)
            startHarness()
            return
        }
        guard result.status == "installed_restarted" else {
            presentUpdateFailure("更新没有完成：\(result.message)")
            return
        }
        hideOverlay()
        pendingHarnessUpdateSummary = updateSummary(result)
        // The controller performs stop, install, smoke and automatic recovery
        // as one transaction. Reacquire the authenticated entry for this view.
        pendingUpdateCompletionMessage = result.message + "\n" + updateSummary(result)
        startHarness()
    }

    private func updateSummary(_ result: UpdateResult) -> String {
        if let from = result.from, let to = result.to {
            return "版本：\(from) → \(to)"
        }
        return "新版本已安装。"
    }

    private func confirmAndRestart() {
        showOverlay(title: "正在检查任务状态…", detail: "确认可以安全重启 DeepSeek Harness。", spinning: true)
        let harnessController = controller
        controllerQueue.async { [weak self, harnessController] in
            let result = Result { try harnessController.activity() }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch result {
                case .success(let activity) where activity.busy:
                    self.promptRestartWithBusy(activity)
                case .success:
                    self.restartHarness()
                case .failure:
                    self.promptRestartUnknown()
                }
            }
        }
    }

    private func promptRestartWithBusy(_ activity: HarnessActivity) {
        hideOverlay()
        let sessionCount = activity.runningSessionIDs.count
        let childCount = activity.childProcessIDs.count
        var details: [String] = []
        if sessionCount > 0 { details.append("\(sessionCount) 个 Agent 会话仍在执行") }
        if childCount > 0 { details.append("\(childCount) 个后台子进程仍在运行") }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "DeepSeek Harness 已安装更新，但当前还有活动线程"
        alert.informativeText = [
            pendingHarnessUpdateSummary ?? "新版本已安装。",
            details.joined(separator: "，") + "。重启会停止这些任务；已有会话记录仍会保留。",
        ].joined(separator: "\n")
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "确定重启")
        if alert.runModal() == .alertSecondButtonReturn {
            restartHarness(force: true)
        } else {
            presentUpdatePendingRestart("你选择暂不停止活动任务。")
        }
    }

    private func promptRestartUnknown() {
        presentUpdatePendingRestart("暂时无法确认 Harness 是否空闲。为避免误停任务，本次没有自动重启。")
    }

    private func presentUpdatePendingRestart(_ reason: String) {
        hideOverlay()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "DeepSeek Harness 已安装，但尚未切换"
        alert.informativeText = [
            pendingHarnessUpdateSummary ?? "新版本已安装。",
            reason,
            "当前窗口仍可能使用旧版本；可以稍后重试。",
        ].joined(separator: "\n")
        alert.addButton(withTitle: "稍后")
        alert.addButton(withTitle: "重试检查")
        if alert.runModal() == .alertSecondButtonReturn {
            confirmAndRestart()
        }
    }

    private func restartHarness(force: Bool = false) {
        showOverlay(title: "正在重启 DeepSeek Harness…", detail: "保存会话并切换到新版本。", spinning: true)
        let harnessController = controller
        controllerQueue.async { [weak self, harnessController] in
            var arguments = ["restart", "--json"]
            if force { arguments.insert("--yes", at: 1) }
            let result = Result { try harnessController.run(arguments) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch result {
                case .success(let command) where command.terminationStatus == 0:
                    guard let targetURL = self.webStartURL(from: command.standardOutput) else {
                        self.presentUpdateFailure(
                            "DeepSeek Harness 已重启，但 Launcher 没有收到新的认证地址，界面未刷新。"
                        )
                        return
                    }
                    if let summary = self.pendingHarnessUpdateSummary {
                        self.pendingUpdateCompletionMessage = "DeepSeek Harness 更新已完成。\n\(summary)"
                    }
                    // Keep the existing Launcher window; only replace the
                    // WebView request with the fresh one-time auth URL.
                    self.loadWebInterface(targetURL)
                case .success(let command):
                    self.presentUpdateFailure("更新已安装，但 DeepSeek Harness 重启失败：\(command.message)")
                case .failure(let error):
                    self.presentUpdateFailure("更新已安装，但 DeepSeek Harness 重启失败：\(error.localizedDescription)")
                }
            }
        }
    }

    private func presentUpdateFailure(_ message: String) {
        hideOverlay()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "DeepSeek Harness 更新失败"
        alert.informativeText = message
        let canRetry = pendingHarnessUpdateSummary != nil
        alert.addButton(withTitle: canRetry ? "稍后" : "好")
        if canRetry {
            alert.addButton(withTitle: "重试切换")
        }
        if canRetry && alert.runModal() == .alertSecondButtonReturn {
            confirmAndRestart()
        } else if !canRetry {
            alert.runModal()
        }
    }

    private func showWindow() {
        guard window != nil else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func startHarness() {
        startupGeneration += 1
        let generation = startupGeneration
        showOverlay(title: "正在启动 DeepSeek Harness…", detail: "服务只监听本机，关闭这个 App 时会一并停止。", spinning: true)

        let harnessController = controller
        controllerQueue.async { [weak self, harnessController] in
            let result = Result { try harnessController.run(["start", "--json"]) }
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.startupGeneration else { return }
                guard !self.terminationInFlight else { return }
                switch result {
                case .success(let command) where command.terminationStatus == 0:
                    guard let targetURL = self.webStartURL(from: command.standardOutput) else {
                        self.showStartFailure("Harness 已启动，但 Launcher 没有收到认证地址；请重试。")
                        return
                    }
                    self.loadWebInterface(targetURL)
                case .success(let command):
                    if command.message.contains("未检测到 DeepSeek Harness") {
                        // First run is unattended: the CLI itself comes from
                        // npm's current official latest tag. Auth setup follows
                        // in the upstream Web UI after the server starts.
                        self.performInstallDsh()
                    } else {
                        self.showStartFailure(command.message)
                    }
                case .failure(let error):
                    self.showStartFailure(error.localizedDescription)
                }
            }
        }
    }

    private var installProgressURL: URL?
    private var installProgressTimer: Timer?

    private func performInstallDsh() {
        showOverlay(title: "正在安装 DeepSeek Harness…", detail: "准备安装…", spinning: true)
        let progressPath = (LauncherConfig.dshHome as NSString)
            .appendingPathComponent("launcher/install.progress")
        installProgressURL = URL(fileURLWithPath: progressPath)
        installProgressTimer = Timer.scheduledTimer(
            timeInterval: 0.4,
            target: self,
            selector: #selector(pollInstallProgress),
            userInfo: nil,
            repeats: true
        )
        let harnessController = controller
        controllerQueue.async { [weak self, harnessController] in
            let result = Result {
                try harnessController.run(["install-dsh", "--json", "--progress-file", progressPath])
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.installProgressTimer?.invalidate()
                self.installProgressTimer = nil
                switch result {
                case .success(let command) where command.terminationStatus == 0:
                    self.startHarness()
                case .success(let command):
                    self.showStartFailure(command.message)
                case .failure(let error):
                    self.showStartFailure(error.localizedDescription)
                }
            }
        }
    }

    @objc private func pollInstallProgress() {
        guard overlayIsVisible, let url = installProgressURL else { return }
        guard let content = try? String(contentsOf: url, encoding: .utf8),
              let line = content.split(separator: "\n").last,
              let data = line.data(using: .utf8),
              let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let stage = state["stage"] as? String ?? ""
        let bytes = (state["received_bytes"] as? NSNumber)?.intValue ?? 0
        let detail: String
        if stage == "downloading" && bytes > 0 {
            detail = String(format: "正在下载… 已下载 %.1f MB", Double(bytes) / 1_000_000)
        } else if stage == "installing" {
            detail = "正在安装（下载完成，编译原生依赖）…"
        } else if stage == "done" {
            detail = "安装完成，正在启动…"
        } else {
            detail = "准备安装…"
        }
        updateOverlayDetail(detail)
    }

    private func webStartURL(from output: String) -> URL? {
        guard let data = output.data(using: .utf8),
              let result = try? JSONDecoder().decode(StartResult.self, from: data),
              let authUrl = result.authUrl,
              let url = URL(string: authUrl) else {
            return nil
        }
        return url
    }

    private func loadWebInterface(_ targetURL: URL) {
        // Do not put the one-time auth token into the visible overlay or AX
        // tree. It is only needed by this request.
        showOverlay(title: "正在载入界面…", detail: "正在建立本机认证连接…", spinning: true)
        var request = URLRequest(url: targetURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        webView.load(request)
    }

    private func decideTermination(
        using result: Result<HarnessActivity, Error>,
        application: NSApplication
    ) {
        switch result {
        case .success(let activity) where !activity.serviceRunning:
            finishTermination(application)
        case .success(let activity) where activity.busy:
            let sessionCount = activity.runningSessionIDs.count
            let childCount = activity.childProcessIDs.count
            var details: [String] = []
            if sessionCount > 0 { details.append("\(sessionCount) 个 Agent 会话仍在执行") }
            if childCount > 0 { details.append("\(childCount) 个后台子进程仍在运行") }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "DeepSeek Harness 还有任务在运行"
            alert.informativeText = details.joined(separator: "，") + "。现在退出会停止这些任务；已有会话记录仍会保留。"
            alert.addButton(withTitle: "继续使用")
            alert.addButton(withTitle: "退出并停止")
            if alert.runModal() == .alertSecondButtonReturn {
                stopHarnessAndTerminate(application)
            } else {
                cancelTermination(application)
            }
        case .success:
            stopHarnessAndTerminate(application)
        case .failure(let error):
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "无法确认 Harness 是否空闲"
            alert.informativeText = "\(error.localizedDescription)\n\n为避免误停任务，默认保持 App 打开。"
            alert.addButton(withTitle: "保持打开")
            alert.addButton(withTitle: "仍然退出并停止")
            if alert.runModal() == .alertSecondButtonReturn {
                stopHarnessAndTerminate(application)
            } else {
                cancelTermination(application)
            }
        }
    }

    private func stopHarnessAndTerminate(_ application: NSApplication) {
        showOverlay(title: "正在安全停止 DeepSeek Harness…", detail: "正在保存会话并结束本机服务。", spinning: true)
        let harnessController = controller
        controllerQueue.async { [weak self, harnessController] in
            let result = Result { try harnessController.run(["stop"]) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch result {
                case .success(let command) where command.terminationStatus == 0:
                    self.finishTermination(application)
                case .success(let command):
                    self.showStopFailure(command.message, application: application)
                case .failure(let error):
                    self.showStopFailure(error.localizedDescription, application: application)
                }
            }
        }
    }

    private func finishTermination(_ application: NSApplication) {
        allowWindowClose = true
        application.reply(toApplicationShouldTerminate: true)
    }

    private func cancelTermination(_ application: NSApplication) {
        terminationInFlight = false
        hideOverlay()
        application.reply(toApplicationShouldTerminate: false)
    }

    private func showStopFailure(_ message: String, application: NSApplication) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "未能停止 DeepSeek Harness"
        alert.informativeText = message + "\n\nApp 将保持打开，避免留下不明确的后台服务。"
        alert.addButton(withTitle: "好")
        alert.runModal()
        cancelTermination(application)
    }

    private func buildWindow() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        // Official native locale contract (0.2.0-rc.2); not a desktop identity
        // shim. The Host owns durable preference and reports the active locale.
        let languagesJSON = String(data: try! JSONSerialization.data(withJSONObject: Locale.preferredLanguages), encoding: .utf8)!
        let localeScript = """
        globalThis.__DSH_LOCALE__ = Object.freeze({
          read: async () => ({ languages: \(languagesJSON), preference: null }),
          onChange: locale => { if (locale === 'zh' || locale === 'en')
            window.webkit.messageHandlers.launcherLocale.postMessage(locale); }
        });
        """
        configuration.userContentController.add(self, name: "launcherLocale")
        configuration.userContentController.addUserScript(WKUserScript(source: localeScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        // Keep the traffic lights clear of the page header: push the page
        // content down 20pt inside its own containers, so the sidebar's grey
        // band and the divider still run to the very top (class-hash-safe
        // partial attribute selectors, per the 0.1.x client CSS convention).
        let insetCSS = """
        [class*="sidebarCol"] { padding-top: 20px !important; }
        """
        let cssJS = "let s=document.createElement('style');s.textContent=\(insetCSS.debugDescription);document.head.appendChild(s);"
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: cssJS,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )
        // Report interactive page elements in the titlebar band so the drag
        // zone can yield to them (save-log button & friends keep priority).
        let exclusionsJS = """
        (() => {
          const send = () => {
            const els = [...document.querySelectorAll('button, a, [role="button"], [role="tab"], input')]
              .filter(e => { const r = e.getBoundingClientRect(); return r.top >= 0 && r.top < 60 && r.width > 0 && r.height > 0; })
              .map(e => { const r = e.getBoundingClientRect(); return { x: r.x, y: r.y, w: r.width, h: r.height }; });
            try { window.webkit.messageHandlers.dragExclusions.postMessage(els); } catch (e) {}
          };
          send();
          let pending = null;
          new MutationObserver(() => { clearTimeout(pending); pending = setTimeout(send, 120); })
            .observe(document.documentElement, { childList: true, subtree: true, attributes: true });
          window.addEventListener('resize', send);
          setInterval(send, 2000);
        })();
        """
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: exclusionsJS,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )
        configuration.userContentController.add(self, name: "dragExclusions")
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsMagnification = true

        let content = NSView(frame: .zero)
        content.addSubview(webView)
        // Full-size content: the web page's own sidebar band and its divider
        // run to the very top; the traffic lights float above the sidebar's
        // empty header area (probed: the brand row starts at y=24, the lights
        // end around y=20, so nothing is covered and no white band remains).
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            webView.topAnchor.constraint(equalTo: content.topAnchor),
            webView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        // Transparent drag zone spanning the whole titlebar band; page
        // controls reported via JS (dragExclusions) get hit-test priority,
        // everything else is draggable / double-click-zoomable.
        let dragRegion = DragRegionView(frame: .zero)
        dragRegion.translatesAutoresizingMaskIntoConstraints = false
        self.dragRegion = dragRegion
        content.addSubview(dragRegion, positioned: .above, relativeTo: webView)
        NSLayoutConstraint.activate([
            dragRegion.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            dragRegion.topAnchor.constraint(equalTo: content.topAnchor),
            dragRegion.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            dragRegion.heightAnchor.constraint(equalToConstant: 28),
        ])
        buildOverlay(in: content)

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = LauncherConfig.title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.minSize = NSSize(width: 900, height: 600)
        window.contentView = content
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("DeepSeekHarnessMainWindow")
    }

    private func buildOverlay(in content: NSView) {
        overlay = NSVisualEffectView(frame: .zero)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.material = .underWindowBackground
        overlay.blendingMode = .withinWindow
        overlay.state = .active

        spinner = NSProgressIndicator(frame: .zero)
        spinner.style = .spinning
        spinner.controlSize = .regular

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        statusLabel.alignment = .center

        detailLabel = NSTextField(wrappingLabelWithString: "")
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .center
        detailLabel.maximumNumberOfLines = 4

        retryButton = NSButton(title: "重试", target: self, action: #selector(retryStart))
        retryButton.bezelStyle = .rounded
        logButton = NSButton(title: "查看日志", target: self, action: #selector(openLog))
        logButton.bezelStyle = .rounded
        let buttonRow = NSStackView(views: [retryButton, logButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10
        buttonRow.alignment = .centerY

        let stack = NSStackView(views: [spinner, statusLabel, detailLabel, buttonRow])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.setCustomSpacing(18, after: detailLabel)

        overlay.addSubview(stack)
        content.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: content.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
            detailLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 540),
        ])
    }

    private func showOverlay(title: String, detail: String, spinning: Bool) {
        statusLabel.stringValue = title
        detailLabel.stringValue = detail
        retryButton.isHidden = spinning
        logButton.isHidden = spinning
        spinner.isHidden = !spinning
        if spinning { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        overlay.isHidden = false
    }

    private func setRuntimeDownloadDetail(kind: String, received: Int64, expected: Int64) {
        let label = kind == "python" ? "Python" : "Node.js"
        let receivedMB = Double(received) / 1_048_576
        if expected > 0 {
            let expectedMB = Double(expected) / 1_048_576
            detailLabel.stringValue = String(format: "正在下载 %@ 本机运行环境：%.0f / %.0f MB", label, receivedMB, expectedMB)
        } else {
            detailLabel.stringValue = String(format: "正在下载 %@ 本机运行环境：%.0f MB", label, receivedMB)
        }
    }

    private func hideOverlay() {
        spinner.stopAnimation(nil)
        overlay.isHidden = true
    }

    private var overlayIsVisible: Bool {
        !overlay.isHidden
    }

    private func updateOverlayDetail(_ text: String) {
        detailLabel.stringValue = text
    }

    private func showStartFailure(_ message: String) {
        showOverlay(title: "DeepSeek Harness 启动失败", detail: message, spinning: false)
    }

    @objc private func showAboutPanel() {
        let alert = NSAlert()
        alert.messageText = localized("关于") + " " + LauncherConfig.title
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let appLine = "\(LauncherConfig.title) \(LauncherConfig.releaseVersion) (build \(build))"
        alert.informativeText = appLine + "\n\nDeepSeek Harness CLI: " + (nativeLanguage == "zh" ? "正在读取…" : "Reading…")
        alert.addButton(withTitle: nativeLanguage == "zh" ? "好" : "OK")
        aboutAlert = alert
        alert.beginSheetModal(for: window) { [weak self, weak alert] _ in
            if self?.aboutAlert === alert { self?.aboutAlert = nil }
        }
        let harnessController = controller
        controllerQueue.async { [weak self, weak alert, harnessController] in
            let result = try? harnessController.run(["version", "--json"])
            DispatchQueue.main.async { [weak self, weak alert] in
                guard let self, let alert, self.aboutAlert === alert else { return }
                let value = result?.standardOutput.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                let text: String
                if let version = value?["version"] as? String, value?["status"] as? String == "installed" {
                    text = version
                } else if value?["status"] as? String == "not-installed" {
                    text = self.nativeLanguage == "zh" ? "未安装" : "Not installed"
                } else { text = self.nativeLanguage == "zh" ? "无法读取" : "Unavailable" }
                alert.informativeText = appLine + "\n\nDeepSeek Harness CLI: " + text
            }
        }
    }

    private func localized(_ value: String) -> String {
        LauncherLocalization.menu(value, language: nativeLanguage)
    }

    private func applyNativeLanguage(_ language: String) {
        guard ["zh", "en"].contains(language), nativeLanguage != language else { return }
        nativeLanguage = language
        buildMainMenu()
        updateAccountLoginMenu()
    }

    @objc private func selectLanguage(_ item: NSMenuItem) {
        guard !localeWriteInFlight else { return }
        let preference: String? = item.tag == 1 ? "zh" : item.tag == 2 ? "en" : nil
        let resolved = preference ?? LauncherLocalization.language(for: Locale.preferredLanguages)
        guard localeBridgeSeen, let url = webView?.url, LauncherConfig.isInternalWebURL(url) else {
            applyNativeLanguage(resolved)
            return
        }
        localeWriteInFlight = true
        let script = """
        const abort = new AbortController();
        const timer = setTimeout(() => abort.abort(), 15000);
        async function rpc(method, args) {
          const rpcId = crypto.randomUUID();
          const response = await fetch(new URL(`/api/${method}`, location.origin), {
            method: 'POST', credentials: 'same-origin', signal: abort.signal,
            headers: {'content-type':'application/json'},
            body: JSON.stringify({type:'client-request', rpcId, method, payload:{args}})
          });
          if (!response.ok) throw new Error('unavailable');
          const message = await response.json();
          if (message.type !== 'server-response' || message.rpcId !== rpcId || message.result?.ok !== true)
            throw new Error('write-rejected');
          return message.result.value;
        }
        try {
          const settings = await rpc('settings/describe', {});
          const locale = settings?.namespaces?.find(value => value.ns === 'locale');
          if (!settings.writable || !Number.isInteger(locale?.revision)) return {kind:'unsupported'};
          const args = {ns:'locale', expectedRevision:locale.revision};
          if (preference === null) {
            args.ops = [{op:'unset', path:['preference']}];
            await rpc('settings/mutate', args);
          } else {
            args.patch = {preference};
            await rpc('settings/update', args);
          }
          return {kind:'success'};
        } catch (_) { return {kind:'failed'}; }
        finally { clearTimeout(timer); }
        """
        webView.callAsyncJavaScript(script, arguments: ["preference": preference as Any? ?? NSNull()], in: nil, in: .page) { [weak self] result in
            guard let self else { return }
            self.localeWriteInFlight = false
            let value: [String: Any]?
            if case .success(let response) = result { value = response as? [String: Any] } else { value = nil }
            if value?["kind"] as? String == "success" {
                // The official onChange callback is authoritative. A later
                // concurrent Web choice may already have arrived; applying
                // our requested locale here would overwrite that newer state.
                return
            } else if value?["kind"] as? String == "unsupported" {
                self.applyNativeLanguage(resolved)
            } else {
                let alert = NSAlert()
                alert.messageText = self.nativeLanguage == "zh" ? "语言设置未保存" : "Language was not saved"
                alert.informativeText = self.nativeLanguage == "zh" ? "当前CLI未接受设置或设置已同时改变。请重试，或在网页设置中选择语言。" : "The CLI rejected the setting or it changed concurrently. Retry, or choose the language in Web Settings."
                alert.addButton(withTitle: self.nativeLanguage == "zh" ? "好" : "OK")
                alert.runModal()
            }
        }
    }

    @objc private func showFeedbackPanel() {
        feedbackPanel.show()
    }

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.delegate = self
        appItem.submenu = appMenu
        let aboutItem = appMenu.addItem(withTitle: localized("关于") + " " + LauncherConfig.title, action: #selector(showAboutPanel), keyEquivalent: "")
        aboutItem.target = self
        appMenu.addItem(withTitle: localized("检查更新…"), action: #selector(checkForUpdates), keyEquivalent: "u")
        let languageMenu = NSMenu(title: localized("语言"))
        let languageItem = NSMenuItem(title: localized("语言"), action: nil, keyEquivalent: "")
        languageItem.submenu = languageMenu
        appMenu.addItem(languageItem)
        for (tag, title) in [(0, localized("跟随系统")), (1, "中文"), (2, "English")] {
            let item = languageMenu.addItem(withTitle: title, action: #selector(selectLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.tag = tag
        }
        appMenu.addItem(NSMenuItem.separator())
        let accountLoginItem = appMenu.addItem(withTitle: localized("登录 DeepSeek 账号"), action: #selector(accountMenuAction), keyEquivalent: "")
        accountLoginItem.target = self
        self.accountLoginMenuItem = accountLoginItem
        let feedbackItem = appMenu.addItem(withTitle: localized("问题反馈…"), action: #selector(showFeedbackPanel), keyEquivalent: "")
        feedbackItem.target = self
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: localized("隐藏") + " " + LauncherConfig.title, action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: localized("退出") + " " + LauncherConfig.title, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: localized("编辑"))
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: localized("撤销"), action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: localized("重做"), action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: localized("剪切"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: localized("拷贝"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: localized("粘贴"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: localized("全选"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: localized("显示"))
        viewItem.submenu = viewMenu
        viewMenu.addItem(withTitle: localized("重新载入"), action: #selector(reloadPage), keyEquivalent: "r")
        viewMenu.addItem(NSMenuItem.separator())
        viewMenu.addItem(withTitle: localized("实际大小"), action: #selector(resetZoom), keyEquivalent: "0")

        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: localized("窗口"))
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: localized("最小化"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        let zoomItem = NSMenuItem(
            title: localized("缩放"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "m"
        )
        // ⌘⇧M: full-size content covers the titlebar, so the system
        // double-click-zoom gesture no longer fires; this is the equivalent.
        zoomItem.keyEquivalentModifierMask = [.command, .shift]
        windowMenu.addItem(zoomItem)

        // Feedback also lives in the Help menu: that is where users look for
        // "something went wrong", and the Help menu's search field finds it
        // without a key equivalent to memorise.
        let helpItem = NSMenuItem()
        mainMenu.addItem(helpItem)
        let helpMenu = NSMenu(title: localized("帮助"))
        helpItem.submenu = helpMenu
        let helpFeedbackItem = helpMenu.addItem(
            withTitle: localized("问题反馈…"), action: #selector(showFeedbackPanel), keyEquivalent: ""
        )
        helpFeedbackItem.target = self

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
        NSApp.helpMenu = helpMenu
    }

    // MARK: - WKScriptMessageHandler (drag-zone exclusions)

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        if message.name == "launcherLocale" {
            guard message.frameInfo.isMainFrame,
                  let url = message.frameInfo.request.url, LauncherConfig.isInternalWebURL(url),
                  let language = message.body as? String, ["zh", "en"].contains(language) else { return }
            localeBridgeSeen = true
            applyNativeLanguage(language)
            return
        }
        guard message.name == "dragExclusions",
              let items = message.body as? [[String: Any]] else { return }
        let height = webView?.frame.height ?? 0
        var rects: [NSRect] = []
        for item in items {
            guard let x = item["x"] as? NSNumber,
                  let y = item["y"] as? NSNumber,
                  let w = item["w"] as? NSNumber,
                  let h = item["h"] as? NSNumber else { continue }
            let cx = CGFloat(x.doubleValue)
            let cy = CGFloat(y.doubleValue)
            let cw = CGFloat(w.doubleValue)
            let ch = CGFloat(h.doubleValue)
            // Page coords are top-origin; contentView coords are bottom-origin.
            rects.append(NSRect(x: cx, y: height - cy - ch, width: cw, height: ch))
        }
        dragRegion?.excludedRects = rects
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        hideOverlay()
        refreshAccountState()
        if accountStateTimer == nil {
            accountStateTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refreshAccountState() }
            }
        }
        updateAccountLoginMenu()
        if let message = pendingUpdateCompletionMessage {
            pendingUpdateCompletionMessage = nil
            pendingHarnessUpdateSummary = nil
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "DeepSeek Harness 更新完成"
            alert.informativeText = message + "\n\n当前 Launcher 窗口已刷新认证连接。"
            alert.addButton(withTitle: "好")
            alert.runModal()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        updateAccountLoginMenu()
        if pendingUpdateCompletionMessage != nil {
            pendingUpdateCompletionMessage = nil
            presentUpdateFailure("DeepSeek Harness 已重启，但 Launcher 界面刷新失败：\(error.localizedDescription)")
        } else {
            showStartFailure("Web 界面载入失败：\(error.localizedDescription)")
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        if nsError.code == NSURLErrorCancelled { return }
        updateAccountLoginMenu()
        if pendingUpdateCompletionMessage != nil {
            pendingUpdateCompletionMessage = nil
            presentUpdateFailure("DeepSeek Harness 已重启，但 Launcher 界面刷新失败：\(error.localizedDescription)")
        } else {
            showStartFailure("Web 界面载入失败：\(error.localizedDescription)")
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url,
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              !LauncherConfig.isInternalWebURL(url) else {
            decisionHandler(.allow)
            return
        }
        NSWorkspace.shared.open(url)
        decisionHandler(.cancel)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url {
            if LauncherConfig.isInternalWebURL(url) {
                webView.load(URLRequest(url: url))
            } else {
                NSWorkspace.shared.open(url)
            }
        }
        return nil
    }
}

@main
@MainActor
private enum DeepSeekHarnessApplication {
    private static let delegate = AppDelegate()

    static func main() {
        let application = NSApplication.shared
        application.delegate = delegate
        application.run()
    }
}
