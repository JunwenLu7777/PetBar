# ThreadHelm macOS

ThreadHelm 是一个独立运行的 macOS App。当前发行版本为 **1.1.0**，输出文件名为：

```text
ThreadHelm-macOS-arm64-1.1.0.zip
```

该发行只面向 macOS 12.3+ 的 Apple 芯片（arm64），暂不支持 Intel Mac。包内包含 `ThreadHelm.app`、LaunchAgent 模板、三个安装检查命令、本机事务脚本、License、隐私说明和资产说明。

## 官方仓库

ThreadHelm 的源码与发布只以 [JunwenLu7777/PetBar](https://github.com/JunwenLu7777/PetBar) 为准。

## 功能

- 独立 App：安装位置为 `~/Applications/ThreadHelm.app`，可从 Finder、Dock、LaunchAgent 或安装脚本启动。
- 独立身份：Executable 为 `ThreadHelm`，Bundle ID 和 LaunchAgent label 均使用 `dev.threadhelm.app`。
- 独立 App Icon：使用 `ThreadHelm.icns`，在 Dock 与应用切换器中显示 ThreadHelm 自己的图标。
- 灵动岛是唯一展示方式：胶囊可点击展开，展开态包含任务、确认与额度工作区。
- 确认工作区可直接回答 Claude Code 的权限、问题与计划请求，也可直接批准 Codex 与 ZCode 的工具授权；队列会标出每条请求来自哪个 Agent。
- Codex 侧需在 Codex 里信任一次 ThreadHelm 写入的 `~/.codex/hooks.json`，未信任时 Codex 会静默跳过 hook、闸门不生效；且只有 Codex 自己发起审批（`approval_policy` 不为 `never`）时才会触发。面板未启动或裁决超时时不会放行，而是交回 Codex 自己的批准界面。
- ZCode 侧不需要额外授信，但 `yolo` 模式不请求批准、闸门不会触发。ZCode 在 hook 失败时会直接执行工具，所以闸门够不着面板时由 ThreadHelm 主动返回拒绝兜底，而不是放行。
- 检测到独立 Claude Code CLI 或 Claude Desktop 内置 CLI 时，可显示 Claude Code 的 5h、周额度与 Fable 周额度；均未安装时只显示 Codex 来源。已安装但未登录或读取失败时保留 Claude Code 状态提示；不显示 Token、Credits 或行情模块。
- 任务控制台统一显示本机 Codex、Claude Code（包括 Claude Desktop 本地 Agent 会话）、Cursor、ZCode 和 OMP；Desktop 会话只读显示，不把应用聚焦、目录 fallback 或终端恢复冒充为精确会话返回。
- Agents 页面同时显示本机检测版本、真值夹具测试版本、支持能力和已知限制。
- 只有本机发现到的所有固定版本分量完全匹配时才显示 `validated`：Codex `0.150.1`、Claude Code `2.1.226`、Cursor Desktop `3.15.19` + Agent CLI `2026.04.15-dccdccd`、ZCode `3.9.1` + build `3.9.1.5853`、OMP `17.3.2`。缺版本、只匹配一部分或版本漂移都会显示 `unvalidated`，不会沿用旧版本的能力结论，也不会安装或修复该 Agent 的受管集成；卸载仍可只移除 ThreadHelm 自己的条目。
- 运行中任务会显示开始时间与持续时间；已完成/失败任务的持续时间会固定，不继续增长。
- 运行中任务预览只显示公开助手输出，新内容会及时替换，同时保留可滚动的完整输出；不展示 thinking、工具参数或原始工具输出。
- 本机读取 Codex app-server，以及已安装 Claude CLI 的 `/usage`、`agents --json`、CLI 会话公开输出和 Claude Desktop 本地 Agent transcript；不会发起远程第三方行情请求。
- 若用户已经授予辅助功能权限，ThreadHelm 会通过 Codex 暴露的固定辅助功能标签隐藏/静音 Codex 原生任务气泡；未授权时仍可使用额度、任务和灵动岛。
- ThreadHelm 不修改 `ChatGPT.app`、`Codex.app`、`app.asar` 或应用签名。

## 安装

1. 完整解压 `ThreadHelm-macOS-arm64-1.1.0.zip`。
2. 双击 `安装ThreadHelm.command`。
3. 如果 macOS 提示无法验证开发者，点“完成”，不要移到废纸篓。
4. 打开“系统设置”里的“隐私与安全”，选择“仍要打开”或 “Open Anyway”，输入 Mac 登录密码确认。
5. 重新双击 `安装ThreadHelm.command`。
6. 安装完成后会复制到 `~/Applications/ThreadHelm.app`，并启动 `dev.threadhelm.app`。
7. 若希望当前 Codex 运行中新建任务的原生气泡也自动静音，可在“系统设置 → 隐私与安全 → 辅助功能”中为“ThreadHelm”开启权限；未开启不影响核心功能。

安装会处理版本为 `validated` 的 Codex、Claude Code、Cursor、ZCode 和 OMP 受管本机集成；其他版本会跳过。ZCode 配置原本不存在时会直接创建并启用受管 Hook，已有配置的 `hooks.enabled` 仍原样保留；用户自己已注册的 `PermissionRequest` 处理器会与 ThreadHelm 的并存（ZCode 按「任一拒绝即拒绝」合并裁决）。新版本启动失败时会恢复旧 App、LaunchAgent 和受管配置。恢复点及手工处理方式见[本机运维说明](docs/threadhelm-local-operations.md)。

检查安装状态：

```bash
./检查ThreadHelm.command
```

卸载：

```bash
./卸载ThreadHelm.command
```

卸载器会先移除 Codex、Claude Code、Cursor、ZCode 和 OMP 的 ThreadHelm 受管条目，再移除 `~/Applications/ThreadHelm.app`、LaunchAgent、日志和健康缓存，并只移除 ThreadHelm 记录过的 Codex 原生气泡静音值。卸载前请先完全退出 Codex；若 Codex 仍在运行，卸载器会停止且保留当前安装与恢复文件。

## 发布构建

macOS 需要 Xcode Command Line Tools：

```bash
./scripts/build-macos-release.sh
```

只读校验：

```bash
./scripts/build-macos-release.sh --verify-only
```

开发构建可直接把 81 条脱敏真值夹具送进生产 Swift 归一化和真实 reducer：

```bash
BIN="macos/ThreadHelm/build/ThreadHelm.app/Contents/MacOS/ThreadHelm"
"$BIN" --verify-agent-truth macos/ThreadHelm/Tests/Fixtures/Agents
```

输出里的 miss、false alert、duplicate 和 exact return 只描述这 81 条固定夹具窗口，不代表实际使用指标。OMP 的精确返回能力在该基线中是 `unsupported`，实际打开结果只能是 `unavailable`。发布校验会执行同一回放；夹具比旧 ZIP 更新时，旧 ZIP 会被判为 stale。

构建成功后会生成 `dist/ThreadHelm-macOS-arm64-1.1.0.zip`，并在 staging 目录内生成 `CHECKSUMS-SHA256.txt`。

## 源码目录

- `macos/ThreadHelm`：ThreadHelm macOS App 源码与资源。
- `scripts/build-macos-release.sh`：macOS 发布脚本。

仓库布局校验会检查 tracked 文件，确保旧产品发布包、其他平台源码和非 ThreadHelm 素材不会再次进入主线：

```bash
python3 scripts/validate-repository-layout.py
```

## 许可与声明

原创代码使用 MIT License。ThreadHelm 视觉资产、图像和预览文件的授权边界见 [ASSET-NOTICE.md](ASSET-NOTICE.md)，本机数据处理边界见 [PRIVACY.md](PRIVACY.md)。
