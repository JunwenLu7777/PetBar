# ChatBird NT macOS

ChatBird NT 是一个原创 Codex 桌面宠物和本机额度面板发行包。当前发行版本为 **1.0.0**，输出文件名为：

```text
ChatBird-NT-macOS-arm64-1.0.0.zip
```

该发行只面向 macOS 12.3+ 的 Apple 芯片（arm64），暂不支持 Intel Mac。包内只包含 ChatBird NT 宠物、ChatBird 额度面板、LaunchAgent 模板、三个安装检查命令、预览/QA 文件、License、隐私说明和资产说明。

## 官方仓库

ChatBird NT 的源码与发布只以 [JunwenLu7777/PetBar](https://github.com/JunwenLu7777/PetBar) 为准。

## 功能

- ChatBird NT 宠物 ID：`chatbird-nt`。
- ChatBird 额度面板安装位置：`~/Applications/ChatBird 额度面板.app`。
- LaunchAgent label：`dev.chatbird.codex-quota-panel`。
- 检测到 Claude Code CLI 时，左侧可在 Codex 与 Claude Code 间切换：Codex 显示周额度，Claude Code 同时显示 5h、周额度与 Fable 周额度；未安装 Claude Code 时只显示 Codex。已安装但未登录或读取失败时保留 Claude Code 入口并显示对应状态；不显示 Token、Credits 或行情模块。
- 面板约 30 ms 跟随宠物窗口；即使 Codex 原生任务气泡短暂出现，也只识别宠物本体，箭头与面板中心不会被气泡带偏。
- 箭头尖端到宠物头顶保持 14 个逻辑像素，箭头中心严格对齐可见宠物中心。
- 点击面板“收起”后，单击宠物或点击菜单栏 “ChatBird” 即可恢复显示。
- Codex 未运行时会立即关闭已知任务的原生气泡；若安装时 Codex 正在运行，ChatBird 会在 Codex 完全退出且状态落盘稳定后自动同步，避免下次打开时旧气泡恢复。
- 若用户已经授予辅助功能权限，面板会约每 2 秒把带有 `Show activity, N item(s)` / `显示活动，N 项` 按钮的 Codex 计数角标窗口移到所有活动显示器之外，并继续通过 Codex 自带的“静音任务”菜单关闭新任务气泡；同名的任务列表窗口不会移动。该过程不会移动鼠标或发送按键，只匹配固定辅助功能标签，其他字符串不保留、不记录、不上传。未授权时仍使用退出后的磁盘同步，新任务首个气泡可手动静音。
- 横向 388×226 基准面板采用额度与任务列表左右分栏，默认实显不小于约 369×215；Codex 周额度下方显示本期重置时间与剩余时长。任务状态约每 2 秒从本机 Codex 与可用的 Claude Code 状态读取；未安装 Claude Code 时不显示其残留会话。点击任务行可返回对应 Codex 任务或在 Terminal 恢复 Claude 会话。
- 面板正文使用 14 pt 基准字号，并按宠物可见图像比例同步缩放。
- 本机读取 Codex app-server，以及已安装 Claude CLI 的 `/usage`、`agents --json` 和会话公开输出；不会展示 Claude thinking、工具参数或原始工具输出，也不会发起远程第三方行情请求。

## 安装

1. 完整解压 `ChatBird-NT-macOS-arm64-1.0.0.zip`。
2. 双击 `安装ChatBird.command`。
3. 如果 macOS 提示无法验证开发者，点“完成”，不要移到废纸篓。
4. 打开“系统设置”里的“隐私与安全”，选择“仍要打开”或 “Open Anyway”，输入 Mac 登录密码确认。
5. 重新双击 `安装ChatBird.command`。
6. 完全退出并重新打开 Codex；ChatBird 会在退出后自动完成原生任务气泡静音同步。
7. 额度与任务面板本身无需辅助功能权限。若希望永久隐藏宠物旁的任务计数角标，并自动静音当前这次 Codex 运行中新建任务的原生气泡，可在“系统设置 → 隐私与安全 → 辅助功能”中为“ChatBird 额度面板”开启权限；未开启不影响其他功能。

检查安装状态：

```bash
./检查ChatBird.command
```

卸载：

```bash
./卸载ChatBird.command
```

卸载器会只移除 ChatBird 添加的原生气泡静音值，并保留用户自己的 Codex 通知设置。
卸载前请先完全退出 Codex；若仍在运行，卸载器会停止且保留当前安装与恢复文件。

## 发布构建

macOS 需要 Xcode Command Line Tools：

```bash
./scripts/build-macos-release.sh
```

默认输入路径：

- 宠物：`shared/pet/chatbird-nt`
- 预览/QA：`shared/preview/chatbird-nt`

可通过环境变量覆盖：

```bash
CHATBIRD_PET_SOURCE=/path/to/chatbird-nt \
CHATBIRD_PREVIEW_QA_SOURCE=/path/to/preview-qa \
./scripts/build-macos-release.sh
```

只读校验：

```bash
./scripts/build-macos-release.sh --verify-only
```

构建成功后会生成 `dist/ChatBird-NT-macOS-arm64-1.0.0.zip`，并在 staging 目录内生成 `CHECKSUMS-SHA256.txt`。

## 源码目录

- `shared/pet/chatbird-nt`：ChatBird NT 宠物源文件。
- `shared/preview/chatbird-nt`：预览和 QA 文件。
- `macos/ChatBirdQuotaPanel`：ChatBird 额度面板源码与资源。
- `scripts/build-macos-release.sh`：macOS 发布脚本。

仓库布局校验会检查 tracked 文件，确保旧产品发布包、其他平台源码和非 ChatBird 素材不会再次进入主线：

```bash
python3 scripts/validate-repository-layout.py
```

## 许可与声明

原创代码使用 MIT License。ChatBird NT 视觉资产、图像和预览文件的授权边界见 [ASSET-NOTICE.md](ASSET-NOTICE.md)，本机数据处理边界见 [PRIVACY.md](PRIVACY.md)。
