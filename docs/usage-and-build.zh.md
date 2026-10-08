# DSH Launcher 使用与构建

官方 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) CLI 的原生 macOS 启动器。打开 App 启动本机 Web 服务，关闭时检查活动会话并停止；不设置登录自启。

## 安装与首次使用

当前公开发行版为 **1.0.0 / Apple Silicon**，编译最低目标 macOS 14。发行验证与平台边界见[发行工程记录](diagnostics/20261004ReleasePreparation.md)。Intel 可从源码指定架构构建；当前没有 Intel 成品与实机验收。

1. 将 DMG 中的 **DSH Launcher.app** 拖入 Applications，打开 App。控制器已经内置，无需手工复制脚本。macOS 首次询问是否打开时，确认 App 名称和 Developer ID 签名后打开。
2. 启动器优先沿用符合要求的 Node/npm 与 Python；缺少时自动从固定官方来源下载、校验并准备到用户目录，无需管理员密码或开发工具。两者都缺失时下载约 80 MB，显示准备进度。
3. 未安装 CLI 时自动从官方 npm 源安装最新版本，显示安装进度；新安装使用用户私有目录，无需管理员密码。已有全局 CLI 保持其原有安装目标。
4. 在官方网页的 **Settings → Models** 配置 DeepSeek API key，或从顶部 **DSH Launcher → 登录 DeepSeek 账号** 使用官方账号授权。登录后同一个菜单项变为 **退出 DeepSeek 账号**，通过官方服务退出；进行中的登录可在授权窗口取消。可从 [DeepSeek API 平台](https://platform.deepseek.com/)取得 API key。旧版本使用的钥匙串凭据仍可兼容读取，缺凭据不会阻止打开网页。

官方网页保持上游原样，由 Harness 管理账号凭据。账号登录只在用户从 App 菜单发起时打开 DeepSeek 官方授权页；本机 RPC 在当前 WebView 的同源认证会话中调用，账号凭据由 Harness 保存在自己的凭据存储中。已有旧版 CLI 若不支持该入口，启动器会提示用户手动检查更新，不会为登录自动升级。启动器不额外弹出首次认证向导。运行时按需联网准备，当前发行形态是小体积 App。

## 更新与恢复

原生菜单默认跟随系统语言；支持官方语言协议的CLI（已验0.2.0-rc.2）会与网页 **Settings → General → Language** 双向同步。原生 **DSH Launcher → 语言** 可选中文、English或跟随系统，偏好由官方Host保存。旧CLI没有该协议时只切换原生菜单，不修改网页或本地配置文件。**关于 DSH Launcher** 同时显示App版本/build和实际所用CLI版本；未安装或无法读取会明确标示。

菜单「检查更新…」（⌘U）分别显示启动器和 CLI 状态：

- 启动器查询自身 GitHub Release，出现更新时打开版本下载页，由用户安装签名 App。未发布时显示暂无公开版本，查询失败会明确显示；这些状态不阻断 CLI 功能。
- CLI 查询官方 npm，安装前检查活动状态，备份旧代码和数据。失败恢复使用同一恢复点，避免把某版本代码和其他时间的数据拼接。详细事务边界和隔离故障测试见发行验证。
- 正在执行任务或无法确认状态时拒绝修改，需用户明确处理活动工作。数据恢复前保留当前状态，不静默丢弃升级后的会话。

服务仅监听 `127.0.0.1`。网页一次性认证 token 存入权限受限的本地状态，不显示在加载文字里。反馈面板仅准备邮件草稿或报告，发送由用户完成。

## 源码构建与发行

构建另需 Xcode Command Line Tools；当前图标来自已安装的官方 CLI favicon，也可用 `DSH_LAUNCHER_FAVICON` 指定源 SVG。以下命令在仓库根目录运行。

```sh
zsh buildApp.sh
DSH_BUILD_ARCH=x86_64 DSH_SIGNING_MODE=adhoc zsh buildApp.sh
```

`DSH_BUILD_NUMBER` 可覆盖默认 Git 提交计数，必须为正整数；公开的 1.0.0
成品使用 build 23。精确源码 revision 和签名、公证结果由候选目录内的发行回执记录。

`buildApp.sh` 默认有 Developer ID 证书则使用 Hardened Runtime、安全时间戳签名，否则 ad-hoc；指定签名身份不可用则失败，不静默降级。公开发行必须 Developer ID 签名、公证并 staple。

```sh
DSH_NOTARY_PROFILE=profile-name zsh scripts/packageRelease.sh
```

此脚本构建并公证 App、准备 ZIP/DMG、公证 DMG 与生成 SHA256SUMS，不安装或公开上传。凭据只在钥匙串；不在命令行填写秘密。输出目录已有产物则拒绝覆盖。

## 配置

环境变量（均可选；括号为默认）：

| 变量 | 默认 | 作用域 |
|---|---|---|
| `DSH_HOME` | `~/.dsh` | Harness 数据目录（控制器） |
| `DSH_PORT` | `3080` | Web 端口（控制器 + 壳子） |
| `DSH_NODE_BIN` | 探测 `/opt/homebrew/bin/node`、`/usr/local/bin/node`、`PATH` | node 路径 |
| `DSH_BIN` | `<安装 prefix>/bin/dsh` | dsh 入口 |
| `DSH_INSTALL_PREFIX` | 已有全局 CLI 的 prefix；新用户为私有 runtime | CLI 安装目标 |
| `DSH_PYTHON_BIN` | 优先已有 Python，缺失时自动准备 | 控制器 Python |
| `DSH_RUNTIME_ROOT` | `~/Library/Application Support/DSH Launcher/Runtimes`（Dev 使用 `DSH Launcher Dev`） | 自动运行时缓存 |
| `DSH_WORKSPACE` | `~/DeepSeekHarnessWorkspace` | 默认工作区 cwd |
| `DSH_BACKUP_DIR` | `~/.local/share/deepseek-harness/backups` | 升级前备份 + 部署快照 |
| `DSH_KEYCHAIN_SERVICE` | `deepseek-harness/deepseek-api` | 钥匙串 service |
| `DSH_KEYCHAIN_ACCOUNT` | `deepseek-api` | 钥匙串 account |
| `DSH_CONTROLLER` | App 内置控制器 | 控制器路径（壳子） |
| `DSH_LOG` | `$DSH_HOME/launcher/web.log` | 服务日志路径（壳子） |
| `DSH_LAUNCHER_FAVICON` | 探测 npm 全局树 | favicon 覆盖（仅构建） |
| `DSH_SETTINGS` | `~/.config/deepseek-harness-launcher/settings.json` | 设置文件路径 |
| `DSH_FEEDBACK_EMAIL` | 发行配置提供 | 反馈收件邮箱（壳子） |
| `DSH_FEEDBACK_NAME` | 发行配置提供 | 收件人显示名（壳子） |
| `DSH_FEEDBACK_GITHUB_ISSUES_URL` | `https://github.com/XunFengCC/DSH-Launcher/issues/new` | 反馈用 GitHub 地址，须恰为 `https://github.com/<owner>/<repo>/issues/new`（壳子） |

**settings.json**（`DSH_SETTINGS` 路径；控制器与壳子都会读）：可选 JSON
对象，键名与上表 snake_case 一致，例如
`{"dsh_home": "/path/to/dsh-data", "port": "8080"}`。优先级：
环境变量 → settings.json → 默认值。

**干净测试** —— 所有路径都可覆盖，临时环境一条命令即可（无需卸载）：

```sh
DSH_HOME=/tmp/dsh-test DSH_WORKSPACE=/tmp/dsh-work \
DSH_BACKUP_DIR=/tmp/dsh-backups DSH_PORT=3081 \
python3 controller/deepseekHarness.py start
```

## 安全模型

- 服务只监听字面回环 `127.0.0.1`——Harness 对特权方法本身就拒绝非字面
  回环 Host。
- 一次性认证 token 从启动日志解析后写入 owner-only 状态文件（`0600`），
  从不打印到命令输出。
- API key 运行时从钥匙串读取，只注入 Harness 子进程环境（不进 argv、
  不进文件）。
- 仓库内没有任何秘密，只引用钥匙串条目的**名字**。

## 问题反馈

从「DSH Launcher ▸ 问题反馈…」或帮助菜单打开原生面板，填写描述后可以预览、保存或选择反馈渠道：

- **邮件**：使用发行配置中的收件地址。系统邮件草稿包含完整报告正文和同一份文本附件，由用户检查并发送；没有可用客户端时提供手动处理说明，并在 Finder 中定位报告。
- **GitHub**：打开预填的 Issue 页面，由用户检查并提交。Issue 内容公开可见；请移除不应公开的描述后再提交。
- **报告**：包含 App 版本/build、macOS、架构、生成时间及手写描述。描述保留原文，包括有意提供的复现信息；自动采集不包含会话、日志、API 密钥或控制器状态。

报告默认保存在 `~/Library/Application Support/DSH Launcher/Feedback/`，采用时间戳与 UUID 文件名避免覆盖，目录/文件权限为 `0700`/`0600`；也可以通过「存储报告文件…」另存。

维护配置沿用环境变量 → settings → Info.plist 的优先级。三个字段分别为：
`DSH_FEEDBACK_EMAIL` / `feedback_email` / `DSHFeedbackEmail`；
`DSH_FEEDBACK_NAME` / `feedback_name` / `DSHFeedbackName`；
`DSH_FEEDBACK_GITHUB_ISSUES_URL` / `feedback_github_issues_url` / `DSHFeedbackGitHubIssuesURL`。

GitHub 地址须为 `https://github.com/<owner>/<repo>/issues/new`，不带端口、凭据、查询串或片段。若维护自己的构建，可用 `DSH_FEEDBACK_GITHUB_ISSUES_URL`、settings.json 或 `DSHFeedbackGitHubIssuesURL` 覆盖发行默认值。邮件使用系统分享服务是为了完整附带报告；不依赖有长度限制、无法携带附件的 mailto 链接。配置内容不进入反馈报告。

反馈模块的隔离验证（使用虚构输入）：

```sh
xcrun swiftc -O Sources/FeedbackCore.swift tests/feedback/main.swift \
  -o /tmp/dsh-feedback-tests && /tmp/dsh-feedback-tests
```

## 干净环境测试

发布构建在真正干净的环境里验证——见 `.github/workflows/build.yml`：
首发尚未启用 GitHub Actions：发布账户现有授权不允许上传自动 workflow。可选配置保留在 [`ci/build.yml`](ci/build.yml)，维护者可在具有 workflow 权限后移入 `.github/workflows/`。该配置只产出开发包，不能替代正式签名公证。每次 CI 运行都在全新的 macOS runner 上（新用户、新磁盘）。

本地不必每次卸载重来：
- **临时 HOME 运行**（上面示例）用全新 `DSH_HOME` 跑完整控制器路径，不碰
  真实数据；
- **临时 macOS 用户或虚拟机**（Tart/UTM/OrbStack，或 `macos-14` GitHub
  runner）最接近全新机器；
- 正是参数化让这些成为可能——没有任何东西硬编码到个人布局。

## 限制

- 本次兼容性验证使用的上游 CLI `0.2.0-rc.2` 属于 Developer Preview；内部接口会漂移
  （`0.1.2-rc.1` 的 token 认证与端点变化就是实例），非交互升级前先检查兼容性。
- 构建产物默认优先用现有 Developer ID 证书签名；没有证书时是 ad-hoc，Gatekeeper
  首次打开可能需要右键「打开」，或改用你自己的证书重签。Developer ID 签名后仍需
  公证才能在别人机器上免警告打开。
- 钥匙串 service/account 可按部署环境覆盖。
- 品牌素材与上游 CLI 的界面可能随版本调整。

## 许可

GNU GPL-3.0-only —— 见[根目录许可证](../LICENSE)。注意：拉取的
`@deepseek-ai/dsh` 包仍遵循其自身 MIT 许可，favicon 来自官方
`dsh-web-frontend` 包（© DeepSeek）。「DeepSeek Harness」与鲸鱼标识归
其所有者；本项目为非官方、无关联作品。第三方运行时和依赖仍以各自许可文件为准。

## 历史

见[变更记录](../CHANGELOG.md)。
