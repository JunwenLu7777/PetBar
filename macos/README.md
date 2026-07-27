# ChatBird NT macOS 版

## 安装

1. 完整解压 `ChatBird-NT-macOS-Universal-1.0.0.zip`。
2. 双击 `安装ChatBird.command`。
3. 如果出现“Apple 无法验证”提示，点“完成”，不要点“移到废纸篓”。
4. 打开“系统设置”中的“隐私与安全”。
5. 点击“仍要打开”或 “Open Anyway”，输入 Mac 登录密码确认。
6. 重新双击 `安装ChatBird.command`。
7. 完全退出并重新打开 Codex；ChatBird 会在退出后自动完成原生任务气泡静音同步。
8. 额度与任务面板本身无需辅助功能权限。若希望当前这次 Codex 运行中新建任务的原生气泡也自动静音，可在“系统设置 → 隐私与安全 → 辅助功能”中为“ChatBird 额度面板”开启权限。

“仍要打开”按钮只会在尝试启动安装文件后出现，并会保留约一小时。
[查看 Apple 官方的允许步骤](https://support.apple.com/guide/mac-help/mh40616/mac)。

## 要求

- macOS 12.3+
- Apple 芯片或 Intel Mac
- 已安装并登录 Codex
- Claude Code 额度与任务兼容为可选功能；未安装时面板自动隐藏相关入口和任务，使用时需安装并登录 Claude Code

## 包内容

- `pet/chatbird-nt`：ChatBird NT 宠物。
- `quota-panel/ChatBird 额度面板.app`：原生 AppKit 面板。
- `quota-panel/dev.chatbird.codex-quota-panel.plist.in`：当前用户 LaunchAgent 模板。
- `安装ChatBird.command`：安装宠物、面板和 LaunchAgent。
- `检查ChatBird.command`：检查宠物、面板、LaunchAgent、额度读取和任务状态读取。
- `卸载ChatBird.command`：卸载宠物、面板和 LaunchAgent。
- `preview-qa/`：预览和 QA 文件。
- `LICENSE`、`PRIVACY.md`、`ASSET-NOTICE.md`、`CHECKSUMS-SHA256.txt`。

## 功能

- 安装 `chatbird-nt` 宠物，并自动写入 Codex `selected-avatar-id = "custom:chatbird-nt"`。
- 原生 AppKit 面板约 30 ms 跟随宠物窗口，箭头对齐可见宠物中心，尖端到头顶固定为 14 个逻辑像素。
- 点击面板“收起”后，单击宠物或点击菜单栏 “ChatBird” 即可恢复显示。
- 像素定位会分离 Codex 原生任务气泡与宠物本体，因此气泡不会再把面板拉到一侧。
- Codex 未运行时，安装器会立即把已有本地任务加入官方任务静音列表；若 Codex 正在运行，面板会在 Codex 完全退出且状态落盘稳定后自动同步，避免下次打开时旧气泡恢复。
- 已授予辅助功能权限时，面板约每 2 秒通过 Codex 自带的“静音任务”菜单关闭当前运行中新出现的原生气泡；不会移动鼠标或发送按键，只匹配固定辅助功能标签，其他字符串不保留、不记录、不上传。未授权时仍可手动静音，退出后会加入下次启动使用的静音列表。
- 面板使用 388×226 横向基准画布，默认实显不小于约 369×215，将额度与任务列表左右分栏；Codex 周额度下方显示本期重置时间与剩余时长，正文使用 14 pt 基准字号，任务状态徽章使用 8 pt 级别的紧凑尺寸。
- 检测到 Claude Code CLI 时，左侧可切换额度来源：Codex 显示周额度，Claude Code 同时显示 5h、周额度与 Fable 周额度；未安装时只显示 Codex，已安装但未登录或读取失败时保留 Claude Code 入口并显示对应状态；不显示 Token、Credits 或任何行情模块。
- 任务状态约每 2 秒读取本机 Codex 与可用的 Claude Code 会话状态，并显示执行中、等待确认、已完成和执行失败；未安装 Claude Code 时不显示其残留会话。点击 Codex 任务会通过官方深链打开，点击 Claude 任务会在原工作目录通过 Terminal 恢复会话。
- 运行中任务悬停预览只显示助手公开输出，使用固定三行字符滑窗持续替换旧内容；不展示 thinking、工具参数或原始工具输出。
- 任务名称、已读状态、额度百分比和重置时间只在本机读取和显示，不写入发布包，也不上传。
- 本机读取 Codex app-server，以及已安装 Claude CLI 的 `/usage`、`agents --json` 和会话公开输出；不会发起远程第三方行情请求。
- 不需要管理员权限或另行填写 API Key；辅助功能权限仅是当前运行中新任务气泡自动静音的可选增强。

## 检查与卸载

- `检查ChatBird.command`：检查宠物、Universal 2 架构、签名、面板进程、运行状态、Codex 周额度、可选 Claude 三项额度和任务状态。
- `卸载ChatBird.command`：完全退出 Codex 后，移除 ChatBird NT 宠物和本项目面板，并只恢复本项目添加的 Codex 原生气泡设置；Codex 仍运行时会停止卸载并保留恢复文件。
