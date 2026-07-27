# 隐私说明

## 仓库与发布包不包含

- 作者或测试者的本机用户名、邮箱、主目录和绝对路径；
- GitHub 访问凭据、API Key、Cookie、密码或其他访问凭据；
- Codex 聊天内容、账号缓存、真实额度百分比或重置时间；
- 安装测试产生的日志、健康状态文件和诊断报告。

## 运行时数据

- ChatBird 额度面板读取本机 Codex app-server 提供的周额度，并通过已安装的 Claude CLI `/usage` 读取 Claude Code 的 5h、周额度与 Fable 周额度。
- Claude 额度探针禁用工具、使用固定隔离会话和独立缓存目录，并清理探针自己生成的 transcript；面板不记录或展示探针原始终端输出。
- 任务状态在本机读取 Codex 会话状态，以及 Claude CLI `agents --json` 与 `~/.claude/projects` 下的顶层会话 transcript，用于显示执行中、等待确认、已完成和执行失败。
- Claude 任务只提取公开的 assistant `text` 作为悬停预览；不读取或展示 thinking、工具参数和原始工具输出，也会排除 subagent 与 ChatBird 额度探针 transcript。
- 任务名称、任务文字、已读状态、额度百分比和重置时间不写入面板日志，也不上传。
- 为关闭原生气泡，ChatBird 只把不含内容的本地任务 ID 写入 Codex 已有的 `avatar-overlay-muted-notification-ids-v1` 状态，并把 ChatBird 新增值记录到 `~/.codex/chatbird-native-notification-backup.json`。检测到 Codex 正在运行时不会改写该状态；完全退出且文件稳定后才会同步，写入失败会回滚本次备份变更，卸载时只移除已经记录的新增值。
- 卸载器检测到 Codex 仍在运行时会停止，不会移除 ChatBird 或恢复文件；完全退出 Codex 后才会恢复原生气泡设置。
- 若用户已经授予辅助功能权限，运行中的面板会查找 Codex 暴露的固定辅助功能标签“显示活动，N 项 / Show activity, N item(s)”“打开通知 / Open notification”和“静音任务 / Mute task”。它只把同时具有固定窗口标题和计数按钮的透明角标窗口移到所有活动显示器之外，并调用 Codex 自带的菜单动作关闭新任务气泡；同名的任务列表窗口不会移动。读取到的其他辅助功能字符串不保留、不记录、不上传；面板不生成鼠标或键盘事件，也不会主动弹出授权请求。未授权时只检查授权状态，不访问 Codex 的辅助功能树、不移动窗口、不执行菜单动作，仍在 Codex 完全退出后同步任务 ID。
- 面板不会修改 `ChatGPT.app`、`Codex.app`、`app.asar` 或应用签名。
- 宠物像素探针只在用户已经授予屏幕录制权限时工作；面板不会为定位主动弹出屏幕录制授权。截图像素只在内存中用于计算宠物边界，不落盘、不上传。
- 面板不显示 Token、Credits 或行情模块，也不发起远程第三方行情请求。
- Claude 额度读取由用户已登录的 Claude CLI 完成，CLI 可能像正常使用 Claude Code 一样连接 Anthropic；ChatBird 不读取 Claude 凭据，也不直接调用 Anthropic OAuth API。
- Mac 日志位于当前用户的 `~/Library/Logs/ChatBird额度面板.log`。

## macOS 权限

- 辅助功能：可选，只用于永久隐藏宠物旁的任务计数角标，并在当前 Codex 进程中自动执行其自带的“静音任务”菜单动作；未授权时额度、任务面板和退出后的气泡静音同步仍正常工作。
- 屏幕录制：可选，只用于提高宠物可见边界的定位精度；未授权时优先使用 Codex 独立宠物窗口的几何位置，旧版 Codex 才回退到已保存的位置。

## 发布前审计

维护者应运行：

```bash
./scripts/privacy-audit.sh
```

发布包还应在全新临时目录中解压并重新执行校验，避免把本机缓存、日志或绝对路径带入压缩包。
