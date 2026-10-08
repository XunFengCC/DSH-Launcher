// Feedback-module checks: routing configuration, the strict GitHub URL shape,
// the shared report (description kept verbatim), the two channel values and the
// local report file.
//
// Pure Foundation — this compiles with `swiftc` alone, needs no app bundle and
// touches no network and no real user data: every fixture below is fictional.
//
//   xcrun swiftc -O Sources/FeedbackCore.swift tests/feedback/main.swift \
//     -o /tmp/dsh-feedback-tests && /tmp/dsh-feedback-tests

import Foundation

// Release integration may supply the actual packaged plist, rather than only
// testing hand-written configuration fixtures.
if CommandLine.arguments.count > 1 {
    let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    let info = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as! [String: Any]
    let config = FeedbackConfiguration.resolve(environment: [:], settings: [:], infoPlist: info)
    precondition(config.githubIssuesURL == URL(string: "https://github.com/XunFengCC/DSH-Launcher/issues/new"))
}

var failures: [String] = []

func check(_ condition: Bool, _ label: String) {
    if condition {
        print("  ok   \(label)")
    } else {
        failures.append(label)
        print("  FAIL \(label)")
    }
}

func checkEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    check(actual == expected, label)
}

let environment = FeedbackEnvironment(
    appName: "DSH Launcher",
    appVersion: "1.0.0-rc.1",
    buildNumber: "12",
    macOSVersion: "Version 14.6.1 (Build 23G93)",
    architecture: "arm64",
    generatedAt: Date(timeIntervalSince1970: 1_789_000_000)
)

// Fictional private data: a documentation IP (TEST-NET-1), an example.com
// mailbox, a throwaway account name and made-up credential-shaped strings.
// The module keeps the description verbatim (2026-09-16 correction: an
// account, mailbox or IP the user typed on purpose is often what makes the
// report reproducible), so every one of these must survive into the report.
// Split the synthetic key in source so generic secret scanners do not mistake
// this deliberately fictional round-trip fixture for a committed credential.
let fictionalKey = "sk-" + "test-EXAMPLE1234567890"
let fictionalDescription = """
启动失败：无法连接 https://192.0.2.77:8443（示例），错误 EACCES
联系我：feedback.user@example.com
家目录 /Users/example-user/Projects/demo，账号 example-user
api_key=\(fictionalKey)
Authorization: Bearer ZXhhbXBsZS10b2tlbg==
版本 1.0.0-rc.1 时间 12:30:45 重试 3 次
"""

print("configuration")
let defaultConfiguration = FeedbackConfiguration.resolve(infoPlist: [
    "DSHFeedbackEmail": "fengyin.apps@icloud.com",
    "DSHFeedbackName": "风吟",
    "DSHFeedbackGitHubIssuesURL": "",
])
check(defaultConfiguration.hasEmailChannel, "默认配置启用邮件入口")
checkEqual(defaultConfiguration.email, "fengyin.apps@icloud.com", "默认收件人")
checkEqual(defaultConfiguration.emailName, "风吟", "默认显示名")
check(!defaultConfiguration.hasGitHubChannel, "未配置 GitHub 时渠道不可用")
check(defaultConfiguration.githubIssuesURL == nil, "未配置时不产生任何 GitHub URL")
checkEqual(
    defaultConfiguration.githubChannelNote,
    "GitHub 仓库开放后启用；现在可以用邮件反馈。",
    "未配置只说明仓库开放后启用、现在可走邮件"
)
check(defaultConfiguration.emailChannelNote.contains("fengyin.apps@icloud.com"), "面板显示收件地址")

for note in [defaultConfiguration.emailChannelNote, defaultConfiguration.githubChannelNote] {
    check(!note.contains("DSH_") && !note.lowercased().contains("feedback_email"),
          "面板文案不暴露配置键名：\(note)")
    check(!note.contains("上游"), "面板文案不谈内部猜测理由")
}

let overridden = FeedbackConfiguration.resolve(
    environment: ["DSH_FEEDBACK_EMAIL": "env@example.invalid"],
    settings: [
        "feedback_email": "settings@example.invalid",
        "feedback_github_issues_url": "https://github.com/example-org/example-repo/issues/new",
    ],
    infoPlist: ["DSHFeedbackEmail": "plist@example.invalid"]
)
checkEqual(overridden.email, "env@example.invalid", "环境变量优先于 settings.json 与 Info.plist")
checkEqual(
    overridden.githubIssuesURL?.absoluteString,
    "https://github.com/example-org/example-repo/issues/new",
    "settings.json 可配置 GitHub issues/new 地址"
)

let badEmail = FeedbackConfiguration.resolve(environment: ["DSH_FEEDBACK_EMAIL": "not an address"])
check(!badEmail.hasEmailChannel, "无效邮箱配置不启用邮件入口")
checkEqual(badEmail.emailChannelNote, "反馈邮箱地址无效。", "无效邮箱只给一句说明")

let badGitHub = FeedbackConfiguration.resolve(
    environment: ["DSH_FEEDBACK_GITHUB_ISSUES_URL": "http://github.com/example-org/example-repo/issues/new"]
)
check(!badGitHub.hasGitHubChannel, "非 HTTPS 地址不启用 GitHub 渠道")
checkEqual(badGitHub.githubChannelNote, "GitHub 地址无效；现在可以用邮件反馈。", "无效地址只给一句说明")

print("github url validation")
let githubURL = FeedbackConfiguration.githubIssuesURL(from:)
check(
    githubURL("https://github.com/example-org/example-repo/issues/new") != nil,
    "合法 HTTPS github.com/<owner>/<repo>/issues/new 被接受"
)
check(
    githubURL("  https://github.com/example-org/example-repo/issues/new  ") != nil,
    "首尾空白不影响判定"
)
check(githubURL("http://github.com/example-org/example-repo/issues/new") == nil, "http 被拒绝")
check(githubURL("https://gitlab.com/example-org/example-repo/issues/new") == nil, "非 github.com 主机被拒绝")
check(githubURL("https://github.com:8443/example-org/example-repo/issues/new") == nil, "显式端口被拒绝")
check(githubURL("https://user@github.com/example-org/example-repo/issues/new") == nil, "userinfo 被拒绝")
check(githubURL("https://user:pass@github.com/example-org/example-repo/issues/new") == nil, "用户名口令被拒绝")
check(githubURL("https://github.com/example-org/example-repo/issues/new?template=x") == nil, "query 被拒绝")
check(githubURL("https://github.com/example-org/example-repo/issues/new#top") == nil, "fragment 被拒绝")
check(githubURL("https://github.com/deepseek-ai/deepseek-harness") == nil, "仓库根地址被拒绝（含上游仓库）")
check(
    githubURL("https://github.com/deepseek-ai/deepseek-harness/issues") == nil,
    "issues 列表地址被拒绝"
)
check(
    githubURL("https://github.com/example-org/example-repo/sub/issues/new") == nil,
    "owner/repo 之外的多段路由被拒绝"
)
check(
    githubURL("https://github.com/example-org/example%2Frepo/issues/new") == nil,
    "被转义的多段路由也被拒绝"
)
check(githubURL("https://github.com/example-org/../example-repo/issues/new") == nil, "路径穿越被拒绝")
check(githubURL("https://github.com//example-repo/issues/new") == nil, "空 owner 被拒绝")
check(githubURL("   ") == nil, "空值不产生渠道")

print("report keeps the description verbatim")
let report = FeedbackReport.text(description: fictionalDescription, environment: environment)
check(report.contains(fictionalDescription), "描述整段原文进入报告")
check(report.contains("feedback.user@example.com"), "邮箱原文保留")
check(report.contains("192.0.2.77:8443"), "IP 原文保留")
check(report.contains("/Users/example-user/Projects/demo"), "家目录原文保留")
check(report.contains("example-user"), "账号原文保留")
check(report.contains(fictionalKey), "密钥形状文本原文保留")
check(report.contains("ZXhhbXBsZS10b2tlbg=="), "Bearer 形态文本原文保留")
check(!report.contains("隐去"), "报告不再声称自动隐去内容")
check(report.contains("1.0.0-rc.1 (build 12)"), "报告含版本与 build")
check(report.contains("Version 14.6.1 (Build 23G93)"), "报告含 macOS 版本")
check(report.contains("arm64"), "报告含架构")
check(report.contains("生成时间："), "报告含发送时间")
check(
    FeedbackReport.text(description: "  \n ", environment: environment).contains("（未填写描述）"),
    "空描述有占位说明"
)
check(
    FeedbackReport.text(description: "  第一行  \n\n正文  \n", environment: environment)
        .contains("  第一行  \n\n正文  \n"),
    "保留描述的缩进和换行"
)

let subject = FeedbackReport.subject(description: fictionalDescription, environment: environment)
check(subject.hasPrefix("DSH Launcher 反馈：启动失败"), "标题取自描述首行")
check(!subject.contains("\n"), "标题只有一行")
checkEqual(
    FeedbackReport.subject(description: "", environment: environment),
    "DSH Launcher 反馈（1.0.0-rc.1）",
    "无描述时的标题回退"
)

print("mail draft")
let attachment = URL(fileURLWithPath: "/tmp/DSH-Launcher-feedback-test.txt")
let draft = FeedbackChannels.mailDraft(
    configuration: defaultConfiguration, subject: subject, body: report, attachment: attachment
)
check(draft != nil, "可用邮件入口")
checkEqual(draft?.recipient, "fengyin.apps@icloud.com", "草稿收件人正确")
checkEqual(draft?.subject, subject, "草稿标题正确")
checkEqual(draft?.body, report, "草稿正文是完整报告，不做 mailto 截断")
checkEqual(draft?.attachment.path, attachment.path, "草稿要求附上完整报告文件")
check(
    FeedbackChannels.mailDraft(
        configuration: badEmail, subject: subject, body: report, attachment: attachment
    ) == nil,
    "无效邮箱不产生草稿"
)

// 风吟's correction: no length limit anywhere. A report that drops its tail is
// a report that loses the reproduction detail.
let longDescription = String(repeating: "描述很长。", count: 400)
let longReport = FeedbackReport.text(description: longDescription, environment: environment)
check(longReport.contains(longDescription), "超长描述不截断")
checkEqual(
    FeedbackChannels.mailDraft(
        configuration: defaultConfiguration, subject: subject, body: longReport, attachment: attachment
    )?.body,
    longReport,
    "超长报告全文进入草稿"
)

print("github draft")
let githubConfiguration = FeedbackConfiguration.resolve(infoPlist: [
    "DSHFeedbackGitHubIssuesURL": "https://github.com/example-org/example-repo/issues/new",
])
check(githubConfiguration.hasGitHubChannel, "配置后启用 GitHub 渠道")
let issueURL = FeedbackChannels.githubIssueDraft(
    configuration: githubConfiguration, title: subject, body: report
)
check(
    issueURL?.absoluteString
        .hasPrefix("https://github.com/example-org/example-repo/issues/new?") == true,
    "Issue 链接指向配置的仓库"
)
let issueQuery = issueURL
    .flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
    .queryItems ?? []
checkEqual(issueQuery.first(where: { $0.name == "title" })?.value, subject, "Issue 标题正确")
checkEqual(issueQuery.first(where: { $0.name == "body" })?.value, report, "Issue 正文等于本地报告")
check(
    FeedbackChannels.githubIssueDraft(
        configuration: defaultConfiguration, title: subject, body: report
    ) == nil,
    "未配置时不产生 Issue 链接"
)

print("local report file")
let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("dsh-feedback-tests-\(UUID().uuidString)", isDirectory: true)
check(
    FeedbackReportFile.defaultDirectory().path.hasSuffix("DSH Launcher/Feedback"),
    "默认目录为 Application Support/DSH Launcher/Feedback"
)
do {
    let first = try FeedbackReportFile.write(report, at: environment.generatedAt, to: directory)
    let second = try FeedbackReportFile.write(report, at: environment.generatedAt, to: directory)
    check(first != second, "同一秒内两次写入不互相覆盖（UUID 后缀）")
    check(first.lastPathComponent.hasPrefix("DSH-Launcher-feedback-"), "文件名前缀可辨认")
    check(
        first.lastPathComponent.contains(FeedbackReport.stamp(environment.generatedAt)),
        "文件名带时间戳"
    )
    checkEqual(first.pathExtension, "txt", "报告是纯文本附件")

    let written = try String(contentsOf: first, encoding: .utf8)
    checkEqual(written, report, "写入内容等于报告")
    check(written.contains("feedback.user@example.com"), "写出的文件同样保留描述原文")

    let fileAttributes = try FileManager.default.attributesOfItem(atPath: first.path)
    let fileMode = (fileAttributes[.posixPermissions] as? NSNumber)?.intValue
    check(fileMode == 0o600, "报告文件权限 0600（得到 \(fileMode.map { String($0, radix: 8) } ?? "nil")）")
    let directoryMode = (try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions]
        as? NSNumber)?.intValue
    check(directoryMode == 0o700, "报告目录权限 0700（得到 \(directoryMode.map { String($0, radix: 8) } ?? "nil")）")
} catch {
    check(false, "报告写入失败：\(error)")
}
try? FileManager.default.removeItem(at: directory)

if failures.isEmpty {
    print("feedback: all checks passed")
    exit(0)
} else {
    print("feedback: \(failures.count) failed check(s):")
    for failure in failures { print("  - \(failure)") }
    exit(1)
}
