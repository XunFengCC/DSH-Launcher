import Foundation

// MARK: - Routing configuration

/// Feedback routing configuration, resolved the same way as every other
/// launcher setting: environment variable → settings.json → Info.plist →
/// built-in default.
///
/// Why the default recipient lives in Info.plist (`DSHFeedbackEmail`): the
/// address is release metadata, not logic, so a rebuild can change it without
/// touching Swift code.
///
/// Why the GitHub channel has **no** default: this shell has no confirmed
/// public repository yet, and the upstream `deepseek-ai` project is not its
/// issue tracker. An unset value therefore stays unset — the launcher never
/// invents a URL, and the panel says so in one short user-facing line instead
/// of offering a dead entry.
struct FeedbackConfiguration {
    static let defaultEmail = "FengYinYH@icloud.com"
    static let defaultEmailName = "风吟"

    let email: String
    let emailName: String
    /// Raw configured value, kept so the panel can explain *why* a channel is
    /// unavailable (unset vs. malformed) without re-reading any file.
    let githubIssuesValue: String
    let githubIssuesURL: URL?

    var hasEmailChannel: Bool { Self.isDeliverableEmail(email) }
    var hasGitHubChannel: Bool { githubIssuesURL != nil }

    /// Ready-to-display one-liner; also carries the address when the channel is
    /// usable, so the panel can always show where feedback goes.
    ///
    /// Deliberately free of configuration key names and of the routing
    /// rationale: the panel is read by users, not by whoever deploys the
    /// launcher, so an unavailable channel just says so and points at the
    /// channel that works. The keys are documented in the README instead.
    var emailChannelNote: String {
        if email.isEmpty {
            return "未配置反馈邮箱。"
        }
        if !hasEmailChannel {
            return "反馈邮箱地址无效。"
        }
        return "反馈邮箱：\(emailName) <\(email)>"
    }

    var githubChannelNote: String {
        if githubIssuesValue.isEmpty {
            return "GitHub 仓库开放后启用；现在可以用邮件反馈。"
        }
        if githubIssuesURL == nil {
            return "GitHub 地址无效；现在可以用邮件反馈。"
        }
        return "GitHub Issue 渠道：\(githubIssuesURL?.absoluteString ?? "")（内容公开可见）"
    }

    static func resolve(
        environment: [String: String] = [:],
        settings: [String: String] = [:],
        infoPlist: [String: Any] = [:]
    ) -> FeedbackConfiguration {
        let email = firstNonEmpty(
            environment["DSH_FEEDBACK_EMAIL"],
            settings["feedback_email"],
            infoPlist["DSHFeedbackEmail"] as? String,
            defaultEmail
        ) ?? ""
        let emailName = firstNonEmpty(
            environment["DSH_FEEDBACK_NAME"],
            settings["feedback_name"],
            infoPlist["DSHFeedbackName"] as? String,
            defaultEmailName
        ) ?? defaultEmailName
        let githubValue = firstNonEmpty(
            environment["DSH_FEEDBACK_GITHUB_ISSUES_URL"],
            settings["feedback_github_issues_url"],
            infoPlist["DSHFeedbackGitHubIssuesURL"] as? String
        ) ?? ""
        return FeedbackConfiguration(
            email: email,
            emailName: emailName,
            githubIssuesValue: githubValue,
            githubIssuesURL: githubIssuesURL(from: githubValue)
        )
    }

    /// Accepts one exact shape and nothing else:
    /// `https://github.com/<owner>/<repo>/issues/new`.
    ///
    /// Everything else fails closed — a different host, `http`, an explicit
    /// port, embedded credentials, a query or fragment, a repository root, an
    /// issues list, and extra path segments (`/<owner>/<repo>/x/issues/new`,
    /// including one hidden behind `%2F`) are rejected instead of being
    /// normalised, repaired or forwarded. A typo therefore degrades to "channel
    /// unavailable" rather than sending the user to a page nobody reviewed, and
    /// the query that carries the report is always rebuilt by the app.
    static func githubIssuesURL(from rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "github.com",
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.query == nil,
              components.fragment == nil
        else { return nil }
        // `URLComponents.path` is percent-decoded, so a `%2F` shows up as a
        // real separator below and cannot smuggle a longer route through.
        let segments = components.path.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.count == 5, segments[0].isEmpty,
              segments[3] == "issues", segments[4] == "new",
              isGitHubNameSegment(String(segments[1])),
              isGitHubNameSegment(String(segments[2]))
        else { return nil }
        return components.url
    }

    /// GitHub owners and repositories are `[A-Za-z0-9._-]` and never just
    /// `.`/`..`; requiring that keeps empty segments and path traversal out.
    private static func isGitHubNameSegment(_ value: String) -> Bool {
        guard !value.isEmpty, value != ".", value != ".." else { return false }
        return value.range(
            of: "^[A-Za-z0-9][A-Za-z0-9._-]*$",
            options: [.regularExpression]
        ) != nil
    }

    /// Deliberately stricter than RFC 5322: a malformed address must not become
    /// the recipient of a mail draft that the user then sends.
    static func isDeliverableEmail(_ value: String) -> Bool {
        guard !value.isEmpty, !value.contains(where: { $0.isWhitespace }) else { return false }
        return value.range(
            of: "^[A-Za-z0-9._%+\\-]+@[A-Za-z0-9.\\-]+\\.[A-Za-z]{2,}$",
            options: [.regularExpression]
        ) != nil
    }

    private static func firstNonEmpty(_ candidates: String?...) -> String? {
        for candidate in candidates {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }
}

// MARK: - Report environment

/// Everything a report may contain besides the user's own words. Kept as a
/// value type for two reasons: the panel can show exactly these fields before
/// anything leaves the machine, and tests can pin them.
///
/// These fields are the *entire* collection: version, build, macOS,
/// architecture and a timestamp. DSH's feedback module collects no log, so
/// there is nothing else to gather — and, by the same token, no account name,
/// home directory or machine identity to strip later (see `FeedbackReport`).
struct FeedbackEnvironment {
    let appName: String
    let appVersion: String
    let buildNumber: String
    let macOSVersion: String
    let architecture: String
    let generatedAt: Date

    static func current(appName: String, appVersion: String, buildNumber: String) -> FeedbackEnvironment {
        FeedbackEnvironment(
            appName: appName,
            appVersion: appVersion,
            buildNumber: buildNumber,
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: architectureName,
            generatedAt: Date()
        )
    }

    /// A fresh timestamp for a fresh report; the other fields never change
    /// while the panel is open.
    func refreshed(at date: Date = Date()) -> FeedbackEnvironment {
        FeedbackEnvironment(
            appName: appName,
            appVersion: appVersion,
            buildNumber: buildNumber,
            macOSVersion: macOSVersion,
            architecture: Self.architectureName,
            generatedAt: date
        )
    }

    /// The architecture of this binary — that is the datum a build report
    /// needs — and it costs no sysctl call or subprocess.
    static var architectureName: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "未知"
        #endif
    }
}

// MARK: - Shared report

/// The single artifact both channels use: version / build / macOS /
/// architecture / timestamp plus the user's description.
///
/// The description is kept **verbatim** — only the subject takes its first
/// line. This module runs no redaction pass over it, by explicit correction
/// (2026-09-16): a mailbox, an account name or an IP address the user typed on
/// purpose is often exactly what makes a report reproducible, and silently
/// stripping them (or the keys, paths and addresses around them) can destroy
/// the one clue the report had. The module's answer is therefore to collect
/// nothing else — no logs, no sessions, no settings — to let the user preview
/// the exact text, and to warn that GitHub issues are public.
enum FeedbackReport {
    static func text(description: String, environment: FeedbackEnvironment) -> String {
        // Preserve indentation and newlines too: a reproduction may contain
        // whitespace-sensitive source/configuration examples.
        let body = description
        var lines: [String] = []
        lines.append("\(environment.appName) 问题反馈报告")
        lines.append("生成时间：\(timestamp(environment.generatedAt))")
        lines.append("App 版本：\(environment.appVersion) (build \(environment.buildNumber))")
        lines.append("macOS：\(environment.macOSVersion)")
        lines.append("架构：\(environment.architecture)")
        lines.append("")
        lines.append("── 问题描述 ──")
        lines.append(body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "（未填写描述）" : body)
        lines.append("")
        lines.append("── 报告边界 ──")
        lines.append("本报告只含以上版本信息与问题描述，描述按原文保留、未作改动。")
        lines.append("不会自动收集会话、日志、API 密钥或设置；发送和提交由你完成。")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Mail subject and GitHub issue title: the first non-empty line of the
    /// description, because that is what makes a report findable. Capped
    /// because a title is a label, not a body — the full text stays in the
    /// report.
    static func subject(description: String, environment: FeedbackEnvironment) -> String {
        let firstLine = description
            .split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty }) ?? ""
        let summary = firstLine.count > 60 ? String(firstLine.prefix(60)) + "…" : firstLine
        return summary.isEmpty
            ? "\(environment.appName) 反馈（\(environment.appVersion)）"
            : "\(environment.appName) 反馈：\(summary)"
    }

    static func timestamp(_ date: Date) -> String {
        format(date, "yyyy-MM-dd HH:mm:ss Z")
    }

    static func stamp(_ date: Date) -> String {
        format(date, "yyyyMMdd-HHmmss")
    }

    private static func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}

/// Local copy of the report. Both channels save one before they open a mail
/// draft or a browser page: it is the attachment for the mail channel, the
/// paste-able body for GitHub, and the fallback when neither app opens.
enum FeedbackReportFile {
    /// Owner-only, directory and file alike: a report is the user's
    /// correspondence, not shared state, so no other account on this Mac needs
    /// to read it — and a report may legitimately quote addresses or keys.
    static let directoryPermissions: Int = 0o700
    static let filePermissions: Int = 0o600

    /// The timestamp keeps reports sortable and greppable by date; the UUID
    /// suffix keeps two reports written within the same second (a retry, or two
    /// windows) from overwriting each other.
    static func fileName(
        for date: Date,
        uniqueSuffix: String = String(UUID().uuidString.prefix(8))
    ) -> String {
        "DSH-Launcher-feedback-\(FeedbackReport.stamp(date))-\(uniqueSuffix).txt"
    }

    static func defaultDirectory(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base.appendingPathComponent("DSH Launcher/Feedback", isDirectory: true)
    }

    @discardableResult
    static func write(
        _ report: String,
        at date: Date,
        to directory: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: directoryPermissions]
        )
        // `createDirectory` leaves an existing directory's mode alone, so 0700
        // is re-applied (best effort) on every write.
        try? fileManager.setAttributes(
            [.posixPermissions: directoryPermissions], ofItemAtPath: directory.path
        )
        let url = directory.appendingPathComponent(fileName(for: date))
        // `createFile` applies the mode at creation, so the report never sits
        // on disk as a world-readable 0644 file — not even for the instant that
        // an atomic write would leave it that way.
        guard fileManager.createFile(
            atPath: url.path,
            contents: Data(report.utf8),
            attributes: [.posixPermissions: filePermissions]
        ) else {
            throw WriteError.cannotCreateFile(url.path)
        }
        restrictPermissions(at: url, fileManager: fileManager)
        return url
    }

    /// Used for the *save panel* path as well: the user picked the location,
    /// but the file is still owner-only by default.
    static func restrictPermissions(at url: URL, fileManager: FileManager = .default) {
        try? fileManager.setAttributes(
            [.posixPermissions: filePermissions], ofItemAtPath: url.path
        )
    }

    enum WriteError: LocalizedError {
        case cannotCreateFile(String)

        var errorDescription: String? {
            switch self {
            case .cannotCreateFile(let path):
                return "无法创建报告文件：\(path)"
            }
        }
    }
}

// MARK: - Delivery channels

/// The channels as pure values. Nothing here performs I/O: the panel hands the
/// mail draft to `NSSharingService` and the GitHub URL to `NSWorkspace`, both
/// of which belong to the *user* — only the user can actually send or submit.
///
/// Why the mail channel is not a `mailto:` URL: `mailto:` cannot carry an
/// attachment, and long bodies get truncated by the URL itself, so a report
/// sent that way could silently arrive incomplete. The mail channel is
/// therefore built around attaching the report file, and falls back to "here is
/// the address and the file" when no mail client can compose.
enum FeedbackChannels {
    /// A mail draft as data, so the AppKit layer stays thin and this stays
    /// testable: recipient, subject, the full report as the body, and the
    /// report file to attach.
    struct MailDraft: Equatable {
        let recipient: String
        let subject: String
        let body: String
        let attachment: URL
    }

    static func mailDraft(
        configuration: FeedbackConfiguration,
        subject: String,
        body: String,
        attachment: URL
    ) -> MailDraft? {
        guard configuration.hasEmailChannel else { return nil }
        return MailDraft(
            recipient: configuration.email,
            subject: subject,
            body: body,
            attachment: attachment
        )
    }

    static func githubIssueDraft(
        configuration: FeedbackConfiguration,
        title: String,
        body: String
    ) -> URL? {
        guard let base = configuration.githubIssuesURL,
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        else { return nil }
        components.queryItems = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "body", value: body),
        ]
        return components.url
    }
}
