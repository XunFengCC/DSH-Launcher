import AppKit
import Foundation

/// Native feedback panel — stock AppKit only (labels, text view, buttons,
/// `NSAlert`, `NSSavePanel`), no web view and no custom drawing.
///
/// The panel never *sends*: it opens a mail draft in the user's mail client
/// (through `NSSharingService`, the only stock API that attaches a file), or a
/// pre-filled `issues/new` page in the browser, and it keeps a local copy of
/// the report so the user can attach it or send it later by hand. That
/// division is the whole point of the module — see the README "Feedback"
/// section for the implementation boundary.
@MainActor
final class FeedbackPanelController: NSObject {
    private let configuration: FeedbackConfiguration
    private let environment: FeedbackEnvironment

    private var window: NSWindow?
    private var descriptionTextView: NSTextView!
    private var statusLabel: NSTextField!
    private var mailService: NSSharingService?

    init(configuration: FeedbackConfiguration, environment: FeedbackEnvironment) {
        self.configuration = configuration
        self.environment = environment
        super.init()
    }

    func show() {
        if window == nil { buildWindow() }
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Land in the description field: this panel is only ever opened to
        // write something down.
        window.makeFirstResponder(descriptionTextView)
    }

    // MARK: - Window

    private func buildWindow() {
        let title = NSTextField(labelWithString: "问题反馈")
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        let intro = NSTextField(wrappingLabelWithString:
            "描述遇到的问题即可，写多长都行。App 不会自动发送或上传："
            + "邮件在你的邮件客户端里生成草稿，由你自己点发送；GitHub 则在浏览器里打开新建 Issue 页面。")
        intro.font = .systemFont(ofSize: 12)
        intro.textColor = .secondaryLabelColor

        let descriptionCaption = NSTextField(labelWithString: "问题描述")
        descriptionCaption.font = .systemFont(ofSize: 12, weight: .medium)

        descriptionTextView = NSTextView(frame: NSRect(x: 0, y: 0, width: 560, height: 180))
        descriptionTextView.isRichText = false
        descriptionTextView.font = .systemFont(ofSize: 13)
        descriptionTextView.isAutomaticQuoteSubstitutionEnabled = false
        descriptionTextView.isHorizontallyResizable = false
        descriptionTextView.isVerticallyResizable = true
        descriptionTextView.autoresizingMask = [.width]
        descriptionTextView.textContainer?.widthTracksTextView = true
        descriptionTextView.textContainerInset = NSSize(width: 4, height: 6)

        let descriptionScroll = NSScrollView()
        descriptionScroll.translatesAutoresizingMaskIntoConstraints = false
        descriptionScroll.hasVerticalScroller = true
        descriptionScroll.autohidesScrollers = true
        descriptionScroll.borderType = .bezelBorder
        descriptionScroll.documentView = descriptionTextView
        descriptionScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 170).isActive = true

        // Exactly what gets attached, spelled out before anything is clicked.
        let attachedLabel = NSTextField(wrappingLabelWithString:
            "附带信息：\(environment.appName) \(environment.appVersion) (build \(environment.buildNumber))"
            + " · \(environment.macOSVersion) · \(environment.architecture)")
        attachedLabel.font = .systemFont(ofSize: 11)
        attachedLabel.textColor = .secondaryLabelColor

        let boundaryLabel = NSTextField(wrappingLabelWithString:
            "报告只含以上版本信息和你写的描述（原文保留，便于复现）与发送时间；"
            + "不读取会话、日志、API 密钥或设置。")
        boundaryLabel.font = .systemFont(ofSize: 11)
        boundaryLabel.textColor = .secondaryLabelColor

        let mailButton = NSButton(
            title: "通过邮件反馈…", target: self, action: #selector(sendByEmail)
        )
        mailButton.bezelStyle = .rounded
        mailButton.isEnabled = configuration.hasEmailChannel
        mailButton.toolTip = configuration.emailChannelNote

        let githubButton = NSButton(
            title: "在 GitHub 新建 Issue…", target: self, action: #selector(openGitHubIssue)
        )
        githubButton.bezelStyle = .rounded
        githubButton.isEnabled = configuration.hasGitHubChannel
        githubButton.toolTip = configuration.githubChannelNote

        let previewButton = NSButton(
            title: "预览报告…", target: self, action: #selector(previewReport)
        )
        previewButton.bezelStyle = .rounded

        let saveButton = NSButton(
            title: "存储报告文件…", target: self, action: #selector(saveReportFile)
        )
        saveButton.bezelStyle = .rounded

        let buttonRow = NSStackView(views: [mailButton, githubButton, previewButton, saveButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.alignment = .centerY

        // Channel status: the mail address is always visible so the fallback
        // path needs no extra click, and an unconfigured GitHub channel says
        // why instead of offering a dead button.
        let channelLabel = NSTextField(wrappingLabelWithString:
            [configuration.emailChannelNote, configuration.githubChannelNote]
                .joined(separator: "\n"))
        channelLabel.font = .systemFont(ofSize: 11)
        channelLabel.textColor = .secondaryLabelColor
        channelLabel.isSelectable = true

        statusLabel = NSTextField(wrappingLabelWithString: "提示：每个发送入口都会把报告存到本机，便于作附件或以后再用。")
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .tertiaryLabelColor
        statusLabel.isSelectable = true
        statusLabel.maximumNumberOfLines = 4

        let stack = NSStackView(views: [
            title, intro, descriptionCaption, descriptionScroll,
            attachedLabel, boundaryLabel, buttonRow, channelLabel, statusLabel,
        ])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        // Vertical stacks should align controls to the leading edge. Using
        // the width attribute here right-aligned intrinsic-width labels.
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(6, after: title)
        stack.setCustomSpacing(14, after: intro)
        stack.setCustomSpacing(6, after: descriptionCaption)
        stack.setCustomSpacing(14, after: descriptionScroll)
        stack.setCustomSpacing(14, after: boundaryLabel)

        let content = NSView(frame: .zero)
        content.addSubview(stack)
        let fullWidthViews: [NSView] = [intro, descriptionScroll, attachedLabel, boundaryLabel, channelLabel, statusLabel]
        for view in fullWidthViews {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "问题反馈"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 560, height: 480)
        window.contentView = content
        window.center()
        window.setFrameAutosaveName("DSHFeedbackWindow")
        self.window = window
    }

    // MARK: - Channels

    @objc private func sendByEmail() {
        let report = currentReport()
        guard let reportURL = saveLocalCopy(of: report) else {
            presentMailFallback(reportURL: nil, reason: "报告未能写入本地文件。")
            return
        }
        guard let draft = FeedbackChannels.mailDraft(
            configuration: configuration,
            subject: FeedbackReport.subject(description: descriptionTextView.string, environment: environment),
            body: report,
            attachment: reportURL
        ) else {
            presentMailFallback(reportURL: reportURL, reason: "未配置可用的反馈邮箱。")
            return
        }

        // `NSSharingService`'s compose-email draft is a native way to
        // hand the mail client both the full body *and* the report as an
        // attachment. A `mailto:` draft cannot attach anything and long bodies
        // get truncated by the URL itself, which is exactly how a report
        // arrives incomplete — so the mailto route is not offered at all.
        let items: [Any] = [draft.body, draft.attachment]
        if let service = NSSharingService(named: .composeEmail),
           service.canPerform(withItems: items) {
            mailService = service
            service.recipients = [draft.recipient]
            service.subject = draft.subject
            service.perform(withItems: items)
            showStatus(
                "已请求打开邮件草稿（收件人 \(configuration.emailName) <\(configuration.email)>）。"
                + "请在邮件 App 中检查正文和报告附件，然后发送。"
                + reportPathSuffix(reportURL)
            )
        } else {
            presentMailFallback(reportURL: reportURL, reason: nil)
        }
    }

    @objc private func openGitHubIssue() {
        guard let issuesURL = configuration.githubIssuesURL else {
            showStatus(configuration.githubChannelNote)
            return
        }

        // Public-by-default is the one thing a user must know *before* the
        // browser opens, so this is a confirmation, not a footnote.
        let confirmation = NSAlert()
        confirmation.alertStyle = .warning
        confirmation.messageText = "在浏览器中新建 GitHub Issue？"
        confirmation.informativeText =
            "将打开 \(issuesURL.absoluteString) 并预填标题与报告正文。\n\n"
            + "注意：GitHub Issue 是公开的，任何拿到链接的人都能读到内容（包括你写的描述）。"
            + "请先确认描述里没有不该公开的信息。"
        confirmation.addButton(withTitle: "取消")
        confirmation.addButton(withTitle: "打开 Issue 页面")
        guard confirmation.runModal() == .alertSecondButtonReturn else { return }

        let report = currentReport()
        let savedURL = saveLocalCopy(of: report)
        guard let issueURL = FeedbackChannels.githubIssueDraft(
            configuration: configuration,
            title: FeedbackReport.subject(description: descriptionTextView.string, environment: environment),
            body: report
        ) else {
            presentSimpleAlert(title: "无法生成 Issue 链接", text: configuration.githubChannelNote)
            return
        }
        if NSWorkspace.shared.open(issueURL) {
            showStatus(
                "已打开 GitHub 新建 Issue 页面；提交前请再次确认内容公开可见。"
                + reportPathSuffix(savedURL)
            )
        } else {
            presentSimpleAlert(
                title: "无法打开浏览器",
                text: "请手动访问：\n\(issueURL.absoluteString)\n\n报告已保存为：\n\(savedURL?.path ?? "（未能写入本地文件）")"
            )
        }
    }

    // MARK: - Preview & local file

    @objc private func previewReport() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "报告预览（发送前检查）"
        alert.informativeText = "以下是将随反馈发出的全部内容（你的描述保留原文）。"
            + (configuration.hasGitHubChannel ? "\nGitHub 渠道的 Issue 页面公开可见。" : "")
        alert.accessoryView = reportPreviewView(currentReport())
        alert.addButton(withTitle: "关闭")
        alert.runModal()
    }

    @objc private func saveReportFile() {
        let directory = FeedbackReportFile.defaultDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let panel = NSSavePanel()
        panel.title = "存储反馈报告"
        panel.nameFieldStringValue = FeedbackReportFile.fileName(for: Date())
        panel.directoryURL = directory
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try currentReport().write(to: url, atomically: true, encoding: .utf8)
            FeedbackReportFile.restrictPermissions(at: url)
            showStatus("报告已存储：\(url.path)")
        } catch {
            presentSimpleAlert(title: "无法写入报告文件", text: error.localizedDescription)
        }
    }

    private func reportPreviewView(_ report: String) -> NSView {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 460, height: 260))
        textView.string = report
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 260))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = textView
        return scroll
    }

    // MARK: - Helpers

    private func currentReport() -> String {
        FeedbackReport.text(
            description: descriptionTextView.string,
            environment: environment.refreshed()
        )
    }

    private func saveLocalCopy(of report: String) -> URL? {
        do {
            return try FeedbackReportFile.write(
                report, at: Date(), to: FeedbackReportFile.defaultDirectory()
            )
        } catch {
            return nil
        }
    }

    private func reportPathSuffix(_ url: URL?) -> String {
        url.map { "报告副本：\($0.path)" } ?? "（报告未能写入本地文件。）"
    }

    private func showStatus(_ text: String) {
        statusLabel.stringValue = text
    }

    private func presentSimpleAlert(title: String, text: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    /// No mail client (or a badly configured address): the user still gets the
    /// address and the file, which is all a manual send needs — the mail is
    /// then composed by hand, with the report attached.
    private func presentMailFallback(reportURL: URL?, reason: String?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "无法自动打开邮件草稿"
        var text = reason.map { $0 + "\n\n" } ?? "这台 Mac 上没有可用的邮件客户端。\n\n"
        if configuration.hasEmailChannel {
            text += "请手动把反馈发送到：\(configuration.emailName) <\(configuration.email)>"
            text += reportURL.map { "\n\n请把报告文件作为附件：\n\($0.path)" } ?? ""
            text += "\n\n（可以用下面的按钮拷贝收件地址或在 Finder 里定位报告。）"
        } else {
            text += configuration.emailChannelNote
        }
        alert.informativeText = text

        // Buttons are conditional, so the response is matched by index instead
        // of assuming which one landed first.
        var buttonIndexes: [String: Int] = [:]
        var buttonCount = 0
        if configuration.hasEmailChannel {
            alert.addButton(withTitle: "拷贝收件地址")
            buttonIndexes["copy"] = buttonCount
            buttonCount += 1
        }
        if reportURL != nil {
            alert.addButton(withTitle: "在 Finder 中显示报告")
            buttonIndexes["reveal"] = buttonCount
            buttonCount += 1
        }
        alert.addButton(withTitle: "好")
        buttonIndexes["dismiss"] = buttonCount

        let clicked = Int(alert.runModal().rawValue)
            - Int(NSApplication.ModalResponse.alertFirstButtonReturn.rawValue)
        if clicked == buttonIndexes["copy"] {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(configuration.email, forType: .string)
        } else if clicked == buttonIndexes["reveal"], let reportURL {
            NSWorkspace.shared.activateFileViewerSelecting([reportURL])
        }
    }
}
