# 2026-09-11：升级后窗口认证失败

## 问题与原因

Harness 升级至 `0.1.5-rc.1` 后，Launcher `2.3.0 build 11` 窗口停在
`localhost:3080/`，显示 `dsh web authentication required`。服务存活，
`activity` 返回空闲，状态文件里的认证地址有效。正常退出重开后原对话恢复。

根因：`restart --json` 先调用 `stop()` 往 stdout 打印中文状态，再由
`start()` 打印 JSON。Swift `webStartURL(from:)` 解码整个 stdout 失败，
退回不带认证的 localhost 地址。服务重启成功也会留下无法认证的窗口。
受控复现中首行“DeepSeek Harness 当前没有运行。”使 `json.loads` 在
第一字符报错。普通 `start --json` 没有此前缀，解释了退出重开的有效性。
服务/API 可用且历史对话恢复，是反对安装失败或会话损坏假设的证据。

## 修复与回退

仅在重启 JSON 模式把 `stop()` 的状态输出转到 stderr，stdout 保持
单个 StartResult；普通文本输出、活动检查与停止/启动异常行为保持原样。
修复同步源码与已装控制器，无需构建 App，未牵入未提交的公开发行准备。

回退本修复会重新引入 JSON 混合输出故障；回退代码本身不需要恢复或覆盖
用户数据。控制器现随 App 发布，旧版本手动安装控制器的操作不再适用于当前版本。

## 验证与边界

- `/usr/bin/python3 -m unittest discover -s tests -v`：4 项通过，覆盖停止时
  未运行/正常退出/超时终止、普通文本输出、活动拒绝与停止异常。
- 修复前通过真实 restart/stop 函数与模拟进程复现混合 stdout。
- 最小 PATH 下执行 `restart --json`：完整 JSON 可解码，认证地址存在，
  停止信息仅在 stderr；认证请求返回 HTTP 200 与 HTML。
- 活动状态查询及认证页面刷新通过；没有发送模型请求或发布会话内容。
- 源码与安装控制器 SHA256 一致。App 保持 `2.3.0 build 11`，Harness
  已是 `0.1.5-rc.1`。未再次下载升级或发送测试模型消息。
- 本次验收不替代既有公开发行审查、完整代码/数据回滚验证。
