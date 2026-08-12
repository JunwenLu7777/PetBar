# ChatBird macOS 版

## 安装

1. 完整解压 `ChatBird-macOS-arm64-1.1.0.zip`。
2. 双击 `安装ChatBird.command`。
3. 如果出现“Apple 无法验证”提示，点“完成”，不要点“移到废纸篓”。
4. 打开“系统设置”中的“隐私与安全”。
5. 点击“仍要打开”或 “Open Anyway”，输入 Mac 登录密码确认。
6. 重新双击 `安装ChatBird.command`。
7. 安装器会复制并启动 `~/Applications/ChatBird.app`，LaunchAgent label 为 `dev.chatbird.app`。
8. 若希望当前 Codex 运行中新建任务的原生气泡也自动静音，可在“系统设置 → 隐私与安全 → 辅助功能”中为“ChatBird”开启权限。

“仍要打开”按钮只会在尝试启动安装文件后出现，并会保留约一小时。
[查看 Apple 官方的允许步骤](https://support.apple.com/guide/mac-help/mh40616/mac)。

## 要求

- macOS 12.3+
- Apple 芯片（arm64）；暂不支持 Intel Mac
- 已安装并登录 Codex，用于读取本机额度与任务状态
- Claude Code 额度与任务兼容为可选功能；未安装时 ChatBird 自动隐藏相关入口和任务，使用时需安装并登录 Claude Code

## 包内容

- `ChatBird.app`：独立 macOS App，包含灵动岛、额度和任务状态功能。
- `dev.chatbird.app.plist.in`：当前用户 LaunchAgent 模板。
- `安装ChatBird.command`：安装 App 和 LaunchAgent。
- `检查ChatBird.command`：检查 App、arm64 架构、签名、LaunchAgent、运行状态、Codex 周额度、可选 Claude 三项额度和任务状态。
- `卸载ChatBird.command`：卸载 App 和 LaunchAgent，并恢复本项目记录过的 Codex 原生气泡静音值。
- `LICENSE`、`PRIVACY.md`、`ASSET-NOTICE.md`、`CHECKSUMS-SHA256.txt`。

## 功能

- ChatBird 是独立 App，不包含桌面宠物，也不再向 `$CODEX_HOME/pets` 安装宠物或写入 Codex `selected-avatar-id`。
- 灵动岛默认是胶囊，点击后展开为功能面板；胶囊可拖到其他屏幕并吸附到该屏幕顶部中央。
- 检测到 Claude Code CLI 时可切换额度来源：Codex 显示周额度，Claude Code 同时显示 5h、周额度与 Fable 周额度；不显示 Token、Credits 或任何行情模块。
- 任务状态约每 2 秒读取本机 Codex 与可用的 Claude Code 会话状态，并显示执行中、等待确认、已完成和执行失败；未安装 Claude Code 时不显示其残留会话。
- 运行中任务显示开始时间与持续时间；运行中最新一条会交替替换展示，详情区可滚动查看完整公开输出。
- 点击 Codex 任务会通过官方深链打开，点击 Claude 任务会在原工作目录通过 Terminal 恢复会话。
- 本机读取 Codex app-server，以及已安装 Claude CLI 的 `/usage`、`agents --json` 和会话公开输出；不会发起远程第三方行情请求。
- 任务名称、已读状态、额度百分比和重置时间只在本机读取和显示，不写入发布包，也不上传。
- 不需要管理员权限或另行填写 API Key；辅助功能权限仅是当前运行中新任务气泡自动静音的可选增强。

## 检查与卸载

- `检查ChatBird.command`：检查 `~/Applications/ChatBird.app`、`dev.chatbird.app`、签名、进程、运行状态、Codex 周额度、可选 Claude 三项额度和任务状态。
- `卸载ChatBird.command`：完全退出 Codex 后，移除 `~/Applications/ChatBird.app` 与 `dev.chatbird.app` LaunchAgent，并只恢复本项目添加的 Codex 原生气泡设置；Codex 仍运行时会停止卸载并保留恢复文件。
