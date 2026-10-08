# DSH Launcher

想用 DeepSeek Harness CLI，但不想每次都打开终端。

这是一个非官方的原生 macOS 启动器：把官方网页放进独立窗口，处理启动、关闭、安装和更新。

**你继续用 CLI，只是多了一个可以点开的 App。**

[下载 1.0.0](https://github.com/XunFengCC/DSH-Launcher/releases/tag/v1.0.0) · [English](README.en.md)

## 为什么又做一个启动器？

也许你需要 CLI，但不想装官方桌面版；也许你已经在用 CLI，只想更方便地打开；也许你装了官方 App，仍想保留一个可自行选版本、单独使用的 CLI。

如果没有，官方 App 大概已经够了。我们也不是很确定世界还需要多少个壳子。但终端都打开这么多次了，还是搓了一个。

## 它做什么

- **点开即用。** 启动本机服务并打开窗口；退出前检查活动任务，避免直接打断正在运行的会话。
- **第一次少折腾一点。** 没装 CLI 时自动安装官方 npm 的最新版本；已有 CLI 就沿用，不在首次打开时擅自升级。缺少需要的运行环境时自动校验并准备到用户目录。
- **更新由你决定。** 启动器和 CLI 分别检查更新；CLI 更新前备份代码与数据，失败时按同一个恢复点还原。
- **用 API key，也可以用账号。** API key 在官方网页设置；DeepSeek 账号从原生菜单登录，登录后同一项变为退出。授权取消留在登录窗口中。
- **中英文一起切。** 原生菜单默认随系统，与支持语言协议的官方网页双向同步。“关于”同时显示 App 和实际使用的 CLI 版本。

单独使用这个 App，**不意味着自动隔离已有 CLI 的数据**。启动器默认沿用检测到的安装和用户数据；如果需要独立环境，可以按开发材料配置。

## 下载和使用

当前提供 **Apple Silicon Mac** 安装包，最低编译目标为 **macOS 14**。实际验证环境及兼容性边界见[发行验证](docs/diagnostics/20261004ReleasePreparation.md)。

1. 从 [GitHub Release](https://github.com/XunFengCC/DSH-Launcher/releases/tag/v1.0.0) 下载 `DSH-Launcher-1.0.0-macOS-arm64.dmg`。
2. 打开 DMG，把 **DSH Launcher.app** 拖入 Applications，然后打开。
3. 等待首次准备完成，在网页设置 API key，或从顶部 **DSH Launcher → 登录 DeepSeek 账号** 登录。

App 和 DMG 经过 Developer ID 签名与 Apple 公证。首次准备需要联网；已有 CLI 不会自动更新。账号与语言桥接已在官方 CLI `0.2.0-rc.2` 验证，旧 CLI 缺少相应能力时会提示手动检查更新。

## 从哪里来

Swift、AppKit 和 WebKit 做原生窗口，Python 做我们自己写的控制器。CLI、网页界面、协议和 favicon 来自 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)；按需准备的运行环境来自 Node.js、Python 和 Python Build Standalone。感谢这些上游项目，具体来源与许可见[第三方说明](THIRD_PARTY_NOTICES.md)。

风吟与 AI 伙伴砚衡一起做了这个小工具。它与 DeepSeek 官方没有隶属或背书关系。

## 问题和开发材料

遇到问题可以用 App 的“问题反馈…”菜单，或到 [Issues](https://github.com/XunFengCC/DSH-Launcher/issues)。提交前请检查描述，不要附上密钥、凭据或私有会话内容。

[配置、构建与恢复](docs/usage-and-build.zh.md) · [工程验证与排错记录](docs/diagnostics/20261004ReleasePreparation.md) · [变更记录](CHANGELOG.md)

自写代码采用 **GPL-3.0-only**，见 [LICENSE](LICENSE)。第三方组件保持各自许可。
