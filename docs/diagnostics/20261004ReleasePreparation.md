# DSH Launcher 1.0.0 发行工程记录（2026-10-04 至 2026-10-08）

## 背景与当前结论

DSH Launcher 是官方 `dsh web` 的 macOS 原生窗口，不修改上游 CLI。首发工作将此前未发布的实现整理成可供外部维护的发行工程。旧版本存在新用户缺控制器、最低系统声明漂移、更新失败未完整恢复及回滚代码/数据错配；这些问题不能由“开发机已安装”或单次编译通过掩盖。

1.0.0 于 2026-10-08 作为首个正式版本发行。已修复路径通过隔离回归。Node/Python 自动补齐已经实现；账号登录作为用户主动选择的 App 菜单入口，不触发首次认证向导。本文记录实现依据、已验证结果及剩余平台边界。

## 已修复的故障与取舍

### 包内控制器与兼容目标

控制器以前默认位于维护者用户目录，App 只有 Swift 主程序和图标；普通下载者无法从 App 完成安装。现在控制器及许可证进入签名的 Resources，并从 bundle 默认读取。显式 `DSH_CONTROLLER` 仍供开发/隔离使用。

旧构建依赖 SDK 默认部署目标，曾导致 plist 声明 14.0 而 Mach-O 最低为 27.0。构建现在显式指定 `arm64` 或 `x86_64` 与 macOS 14.0；arm64 成品 `vtool -show-build` 验证为 `minos 14.0 / sdk 27.0`。Intel typecheck 通过，但尚无 Intel 实机运行验收；macOS 14 实机运行也未验证。

### 首次安装与认证

已有 CLI 时直接使用原版本，不自动升级；只有缺 CLI 才自动安装官方 npm `latest`。不存在 CLI 的新用户使用私有 prefix，避免向系统 npm 目录写入并要求管理员密码。已有全局 CLI 保持原目标。显式隔离 prefix 不得回退日常 CLI。

缺旧 Keychain API key 不再阻止服务启动，官方 Web 的 Settings → Models 可以配置 key。协议检查必须将上游“bundled UI 的可用范围”和“host 协议的可调用范围”分开：

- [官方 providers 指南](https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/user/guide/providers.md)说明 API-key 流程。
- 必须区分 bundled UI 的入口限制与 Host 的 RPC 能力。只因 UI 显示 Desktop-only 就推断 Host 协议不能由本启动器调用，是过宽的结论；上游 `0.2.0-rc.2` 的公开 Host 接口与隔离 RPC 验证表明，受支持的 Web consumer 可以使用相应能力。

精确验证版本为 npm `0.2.0-rc.2`，源码 tag `dsh-v0.2.0-rc.2`，commit `639ed015397290b3745d163aafe02ffee4aa3f84`：

- [account-controller](https://github.com/deepseek-ai/deepseek-harness/blob/dsh-v0.2.0-rc.2/packages/api/account-controller/src/index.ts)公开 account Remote：getState/watch/startSignIn/cancelSignIn/signOut；callbackOrigin为实际回环origin，loginSource支持web。Host负责state、S256 PKCE、oauth/callback、exchange与凭据提交，返回的AccountView不含token/verifier。
- [Web RPC](https://github.com/deepseek-ai/deepseek-harness/blob/dsh-v0.2.0-rc.2/packages/client/connection/src/client/rpc.ts)使用已认证浏览器cookie发送POST `/api/account/startSignIn`。最初把业务参数序列化为数组，实测得到上游 `Remote payload must contain exactly one plain-object args field`；[Gateway 的 `remoteRequest`](https://github.com/deepseek-ai/deepseek-harness/blob/dsh-v0.2.0-rc.2/packages/api/gateway/src/index.ts#L1114)证实唯一合法外壳是`payload:{args:{...}}`，而[account-controller](https://github.com/deepseek-ai/deepseek-harness/blob/dsh-v0.2.0-rc.2/packages/api/account-controller/src/index.ts#L68)的三个具名参数分别是`client`、`callbackOrigin`、`loginSource`，取消则需要`attemptId`。修正后通过npm `0.2.0-rc.2`隔离Host验证：同源`getState`返回signed-out，`startSignIn`先返回initializing、随后得到waiting-browser，`cancelSignIn({attemptId})`结束为cancelled且状态仍signed-out；未打开授权页、未登录账号。
- RPC用当前WK页面上下文和same-origin credentials调用；Host的浏览器cookie绑定host与port，所以它必须从认证后的页面实际origin发起。一次用`localhost`代替当前`127.0.0.1`的隔离检查收到401，反证“loopback等价即可”：现在每次RPC前复核WebView仍位于配置端口的精确loopback origin，并使用绝对同源根路径`/api/...`；`callbackOrigin`也只由该authority构成，页面route/query/hash不会混入回调地址。页面fetch设15秒AbortController超时，避免认证页面请求挂起时菜单永久等待。Swift只收到页面校验并裁剪后的安全AccountView（status/links/attempt），不读取cookie或Host返回的token/PKCE，也不记录授权URL。
- 每个Web RPC最多等待15秒；用户可在等待期间停止本机流程，迟到结果不会打开浏览器。若上游尚未返回attemptId，客户端没有足够信息发送远端cancelSignIn，因此UI明确说明无法确认远端立即取消；上游未完成尝试依其有效期结束。收到attemptId后才调用带该ID的cancelSignIn。返回非空但不符合官方HTTPS授权地址白名单的authorizeUrl会立即失败，不进入等待或浏览器打开路径。
- [Account UI插件](https://github.com/deepseek-ai/deepseek-harness/blob/dsh-v0.2.0-rc.2/packages/client/ui-settings-account/src/client/index.ts)在不存在`globalThis.dshDesktop`时直接退出；因此Web不注册`settings.models.sign-in`插槽，Models官方引导回退API key编辑器。
- [Models store](https://github.com/deepseek-ai/deepseek-harness/blob/dsh-v0.2.0-rc.2/packages/client/ui-settings-models/src/client/store.ts)的预置`deepseek-account`是独立模型路由（llm-deepseek-account namespace、catalog非空才显示、无key字段），该目录项自身不注册账号登录。

单纯供应商/Host配置不能打开该官方网页登录按钮；伪装desktop会改变官方引导行为，因此不使用。启动器以“登录 DeepSeek 账号…”菜单提供按需原生入口：它调用上游既有Web RPC，再由系统浏览器打开经过严格校验的`https://platform.deepseek.com/dsh/authorize`页面；官方Web页面不做修改，也不在首次启动弹登录选择。HTTP 404，或 gateway typed error `gateway/method-unavailable`、`gateway/definition-unavailable`、`gateway/invocation-unavailable`表示已安装CLI没有此入口，提示用户手动检查CLI更新，不自动升级已安装版本。`gateway/service-unavailable`及参数/协议错误仍作为一般错误处理，避免把临时故障误报为旧版本。

认证地址使用 URL parser 校验精确协议、host、port、userinfo 与 token 参数，日志及状态两条读取路径均验证。旧“字符串含 localhost 即允许”的实现可接受外部 host 携带回环 query，故退出。加载界面不显示认证 token。

### 自动运行时与下载信任

启动器优先探测符合版本要求的现有 Node/npm 配对和 Python；macOS 的 `/usr/bin/python3` 开发工具 stub不自动触发安装提示。缺失的一侧才自动准备，版本与SHA-256固定在签名App的 `RuntimeBootstrap.swift`，网络可变的checksum不是独立信任来源。

当前固定 Node 24.21.0（Node.js 官方发行）和 Python 3.14.8+20261003（Astral python-build-standalone 官方发行）。arm64 归档分别约 53 MB 与 27 MB，展开约 199 MiB 与 69 MiB。Node Mach-O 最低系统为 13.5，Python 归档中 Mach-O 最高最低系统为 11.0。Node 有 Developer ID 签名，Python 使用 ad-hoc 签名；两者代码完整性检查与直接运行通过。单二进制 `spctl` 执行分类拒绝不能代替签名 App 子进程实际验证。

下载限定官方HTTPS源/官方资产跳转、最大尺寸及整体超时，完成后强制SHA检查；tar路径/链接检查后在独立staging展开，再验证可执行文件和版本、发布到用户版本目录。跨进程锁避免两个首次启动相互挪动目录，旧树保留恢复点。默认不改系统PATH或npm目录。坏hash、越界链接、半装缓存和下载失败允许重试。

上游归档中的许可文件完整保留：Node/npm与其依赖各自声明，Python `lib/python3.14/LICENSE.txt`及pip依赖许可证。PBS构建仓库许可不等同全部二进制依赖许可。本App不重新打包或更改这些第三方运行时；按需从固定上游发行下载。来源：[Node固定目录](https://nodejs.org/dist/v24.21.0/)、[PBS固定发行](https://github.com/astral-sh/python-build-standalone/releases/tag/20261003)。

### 更新与恢复

运行服务可能读取安装树中的依赖；npm 替换活跃目录会造成新旧混合文件。现在更新守卫在所有写入前执行，服务停止后才建立一致数据备份和代码快照。代码快照清单绑定版本与数据路径，回滚只接受完整的本地配对恢复点；没有配对就拒绝，不用在线 npm 和任意最近备份拼接。

恢复先完整 staging，再移动当前树、切换准备好的树；当前数据与代码保留为 sidecar，失败时尽力恢复。快照准备失败不运行 npm，并恢复原服务状态；安装失败、版本错误、新服务启动失败或活动 API 冒烟失败都会恢复旧配对。恢复自身失败时如实保留路径和状态，只有停止成功才宣称服务已停止。多步文件切换不是跨目录数据库事务；突然断电仍需要依据备份/sidecar恢复，不宣称已覆盖硬断电。

CLI 只采用官方 `latest` dist-tag；官方开发者预览可将 rc 指向 latest，因此接受该版本，但不自动选择 `next` 或 `alpha`。

启动器查询自身 GitHub Release 源，不借用上游仓库；未发布状态与网络错误分别显示，有新版则打开下载页面供用户安装。查询在后台并设有超时，不阻塞主线程。首次启动不因发现新版本自动更新。

## 验证记录

- Python 隔离回归覆盖首次安装、现有 CLI 保留、无 Node 可读错误、认证地址拒绝、活动守卫、配对回滚、npm失败、版本错误、启动/冒烟失败、准备快照失败和 JSON 输出契约。
- Foundation 反馈测试通过：原文描述、完整邮件正文/附件、URL验证及 owner-only 文件；版本比较测试8项通过。
- 账号登录协议隔离测试覆盖同源origin提取、授权地址拒绝、具名RPC envelope/cancel参数、缺失account能力错误码、rpcId不匹配、超时及等待态无效授权地址。
- Swift arm64/macOS14 与 x86_64/macOS14 类型检查通过；plist lint、shell syntax、Python编译与 diff检查通过。
- 在临时 prefix 安装官方 `@deepseek-ai/dsh` **0.2.0-rc.2** 并验证启动、就绪探测和停止成功。该验证未发送模型请求，也未收集或发布用户数据。
- 图标完整构建成功，历史 `sips` SVG 失败本轮未重现。保留旧反馈记录的失败事实，不据此继续把已成功的构建当作当前阻塞。
- 自动运行时5组fixture检查通过，涵盖缓存复用、只补缺失依赖、hash拒绝与链接拒绝；真实两份官方arm64归档完成SHA、结构、解包、执行全链路。实际URLSession联网下载Python也通过HTTPS/哈希/解包/启动，优先沿用现有Node未下载另一侧。不能用仅curl下载成功替代App下载实现验收。
- Developer ID已公证、带下载quarantine的Dev App实际冷启动通过：隔离目录缺两种运行时及CLI，固定归档校验后自动准备Node/Python，npm安装latest，成功加载官方新用户页面；正常退出后测试端口关闭、状态清除。没有重新签名下载的第三方运行时。该测试验证当前macOS27.2上的子进程行为，不替代macOS14或Intel实机验证。
- 原生按需登录菜单的状态与取消路径通过隔离回归；另用独立 HTTP 404 fixture 验证旧 CLI 能力缺失提示，避免在兼容性错误时自动降级或升级。页面桥 JavaScript 模拟覆盖安全投影、401/404、rpcId 错误、缺少方法、坏状态和 15 秒超时。
- 账号流程的验证只记录状态、错误分类和界面行为；公开工程记录不包含账户标识、授权内容或密钥。验证不代表已发送模型请求或验证模型推理。
- 原生菜单验收发现AppKit自动验证会重新启用空闲的“取消登录”，现以NSMenuItemValidation按当前尝试状态决定可用性；复测空闲项禁用、登录项可用。此问题影响菜单状态，取消动作本身已有活动尝试守卫。

最终 App、DMG、ZIP 的签名、公证、staple与校验摘要按精确源码revision记录在候选同目录的验收报告和ACCEPTANCE.json中。CI仅产出开发工件，显式ad-hoc，不冒充公证发行包。

发行过程中曾遇到公证配置暂时不可读取，随后使用同一配置完成公证，没有更改凭据。这个结果不足以判断凭据是否失效。遇到同类错误时，应先区分凭据访问故障和产物问题，保留已签名产物，避免无新证据地重复提交或另建凭据。

发行打包要求工作树为干净checkpoint，确保写入App的`DSHSourceRevision`对应实际封包源码；普通开发构建允许dirty状态。打包守卫拒绝未提交变更时不改动源码、构建产物或凭据。

## 发行与剩余边界

### 2026-10-05：账号状态、语言和实际CLI版本

账号菜单此前只表达“开始一次授权”，即使 Host 已保存凭据仍显示登录，且常驻取消项混淆授权取消与账号退出。现在菜单只保留一个状态项，启动后、菜单展开与每 3 秒通过安全 AccountView 刷新：`signed-out` 显示登录，`credential-stored` 显示退出；后者调用 `account/signOut`，具名 args 为 `{client:{version,locale,timezoneOffsetSeconds}}`，并返回同一 AccountView。官方协议没有 `signed-in` 状态；`credential-stored` 只表示本机存在 grant，不保证服务端仍接受它。进行中的取消仍用 `attemptId` 留在授权窗口，绝不以 `cancelSignIn` 代替退出。旧 CLI 缺能力时提示用户手动检查更新，不自动升级已安装版本。隔离状态测试确认登录与退出菜单映射，不包含账户标识或授权数据。

语言采用上游 CLI `0.2.0-rc.2` 的 `@deepseek-ai/dsh-client-locale` 契约 `globalThis.__DSH_LOCALE__`：document-start preload 的 read 返回系统 languages 与 null preference；Host 持久偏好接管后，onChange 上报实际 active 的 zh/en，仅接收可信主框架本机来源。原生选择通过 `settings/describe` 在页面内定位 locale namespace/revision，再以 expectedRevision 调用 settings/update 修改 preference；“跟随系统”用 settings/mutate unset 该字段。只有最小成功/失败结果和 active 语言进入 Swift，其他配置不跨出页面；不写配置文件、不抓 DOM、不伪装 dshDesktop。冲突/失败不盲目重试，提示使用官方设置重选。旧 CLI 未调用此桥时仍按系统本地化并允许原生菜单切换，网页保持原样。隔离验证覆盖原生到网页、网页到原生和恢复系统偏好。此原生契约是上游明确扩展点，不将此前“Web UI 保持原样”解释为禁止使用其桥接协议。

关于窗口异步调用同一 controller 的 `version --json`，沿用启动/更新使用的 `_dsh_bin` 与 `NODE_BIN`，不联网、不扫描其他副本。仅接受单行可识别版本，分别返回 `installed`、`not-installed`、`unavailable`；不将任意 stdout/stderr 当作版本显示。界面列出 App 版本/build 与 CLI 版本，缺失/读取失败会明确说明。隔离路径归属/缺失/失败回归通过；发行验证用隔离 prefix 核对 CLI 归属。日常替换仍先核活动状态，并保留用户数据与语言偏好。

### 2026-10-05：安装成功却显示更新失败

一次更新回归中，CLI 安装成功，但原生窗口无法解析返回结果，新版 Host 已正常启动。故障在控制器协议边界：初始 stop 已重定向诊断，但后续 start 与失败恢复仍可能先打印生命周期文本，再输出最终 JSON，Swift 整体解码因此失败。不能将解析错误等同 npm 安装失败或自动再次安装。

现在 `update --json` 与 `rollback --json` 将整个事务的诊断输出送入 stderr，stdout 只保留最终一个 JSON 对象；普通文本模式不变。隔离命令回归覆盖成功、恢复成功、恢复失败及回滚。另在隔离数据目录和端口上确认真实 Host 生命周期文字仍能与单一 JSON 结果分离。上游 settings importer 可能将旧 `settings.yaml` 改名为 `settings.yaml.imported` 并迁入 profile，因此文件名变化不能单独作为数据丢失证据。公开报告不含用户配置或会话内容。

登录入口是macOS顶部“DSH Launcher → 登录 DeepSeek 账号…”，而非官方Web Settings；旧App没有该菜单。排障先核对运行App路径、版本和source revision，避免用新源码验收结论解释仍在运行的旧二进制。

启动器以 SPDX 标识 `GPL-3.0-only` 发布。官方 CLI、下载运行时及其依赖仍保留各自许可。公开源码与工程记录不包含本机日志、凭据、会话内容或私人快照。

麦克风、摄像头和 AppleEvents 没有本启动器当前已实现的原生功能路径；不为假想功能申请额外权限。反馈使用系统 NSSharingService，由用户发出。若以后增加捕获或自动化，须按实际功能补授权声明和运行验证。本版不能宣称这些未实现能力已经验收。

恢复入口为更新前配对快照和旁路保留目录；代码发布可回退版本 checkpoint。日常安装 App 与服务不由发行准备脚本替换。
