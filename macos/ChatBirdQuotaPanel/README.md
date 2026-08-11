# ChatBird 额度面板

跟随 Codex 宠物窗口的 macOS 原生额度与任务状态面板。

![ChatBird 额度面板预览](docs/chatbird-panel-preview.png)

- 左侧可在 Codex 与 Claude Code 间切换：Codex 显示周额度，Claude Code 同时显示 5h、周额度与 Fable 周额度。
- 不显示 Token、Credits 或行情区域。
- 启动时立即读取额度，之后每分钟自动更新，也可点击刷新图标手动更新。
- 高频跟随宠物窗口，约 30 ms 更新一次；箭头对齐可见宠物中心，尖端到头顶固定 14 个逻辑像素。
- 像素探针使用连通区域识别宠物本体，不会把 Codex 原生任务气泡计入宠物边界。
- Codex 未运行时会立即静音已有本地任务；若 Codex 正在运行，面板会在 Codex 完全退出且状态落盘稳定后自动同步，避免下次打开时旧气泡恢复。
- 已授予辅助功能权限时，面板约每 2 秒把带有 `Show activity, N item(s)` / `显示活动，N 项` 按钮的 Codex 计数角标窗口移到所有活动显示器之外，并继续通过 Codex 自带的“静音任务”菜单关闭新任务气泡；同名的任务列表窗口不会移动。该过程不会移动鼠标或发送按键，只匹配固定辅助功能标签，其他字符串不保留、不记录、不上传。未授权时仍可手动静音，退出后会加入下次启动使用的静音列表。
- 面板使用 388×226 横向基准画布，默认实显不小于约 369×215，将额度与任务列表左右分栏；Codex 周额度标题位于半圆额度条上方，下方重置卡显示本期到期时间与剩余时长。正文使用 14 pt 基准字号，任务状态徽章使用 8 pt 级别的紧凑尺寸。
- Claude Code 提问弹层使用 620 pt 高度；多问题一次只显示一张回答卡，通过“上一题 / 下一题”左右切换，提交时会自动定位首个未回答问题。
- 任务状态约每 2 秒读取本机 Codex 与 Claude Code 会话状态，显示执行中、等待确认、已完成和执行失败；点击任务行可打开 Codex 任务或在 Terminal 恢复 Claude 会话。
- 运行中任务悬停预览只显示助手公开输出，并以固定三行字符滑窗持续替换旧内容；不展示 thinking、工具参数或原始工具输出。
- 点击“收起”会隐藏窗口；单击宠物或点击菜单栏 “ChatBird” 都可恢复显示。
- 菜单栏可在“宠物面板”和“灵动岛”模式之间切换；默认使用宠物面板，选择会写入本机 `presentation-mode` 并在下次启动恢复。
- 灵动岛模式使用 404×58 pt 单行胶囊，依次显示状态点、状态、任务标题、耗时和展开箭头；整颗胶囊可点击且不抢焦点，也可拖到其他屏幕后释放并吸附到该屏幕顶部中央，展开后仍使用完整的任务、确认和额度工作区。
- 灵动岛展开态右上角分别提供刷新、收起和隐藏：收起只返回胶囊，隐藏会让灵动岛完全消失且不响应后续任务刷新；从菜单栏选择“显示”可恢复胶囊。隐藏待确认请求不会同意、拒绝或丢弃该请求。
- 灵动岛最近事件只显示本机公开任务输出，不展示 thinking、工具参数、原始工具输出或推断式数字步骤进度。
- 启动后写入不含个人数据的运行状态文件，供安装器确认进程确实已启动。
- Codex 额度通过本机 `codex app-server` 的 `account/rateLimits/read` 读取；Claude 额度通过已登录 Claude CLI 的只读 `/usage` PTY 读取。
- Claude 任务通过 `claude agents --json` 与顶层会话 transcript 读取；任务名称、公开输出和已读状态只在本机显示，不写入面板日志，也不上传。
- 不发起远程第三方行情请求。
- 不修改 Codex 应用本体，Codex 更新不会覆盖面板。

## 安装

```bash
./scripts/install.sh
```

安装后会注册当前用户的 LaunchAgent，并在登录时启动一次；用户主动退出后会保持关闭，不会被自动重新拉起。开发安装只运行当前项目的构建产物，不再复制第二份应用；同时在 `~/Applications` 创建一个指向项目构建产物的快捷入口，方便从 Finder 启动。
额度与任务面板本身不需要 macOS 辅助功能授权。若用户已经授权，面板只会把精确匹配计数按钮的透明窗口移到活动显示器之外，并调用 Codex 自带的“静音任务”菜单动作来关闭新任务气泡；未授权时不会主动弹出授权请求。
Codex 完全退出后，面板会短暂等待全局状态与任务索引稳定，再合并静音任务 ID；如果 Codex 在等待期间重新启动，本次同步会取消并留到下次退出后执行。

当前开发安装位置：`./build/ChatBird 额度面板.app`
Finder 快捷入口：`~/Applications/ChatBird 额度面板.app`

## 数据自检

```bash
./build/ChatBird\ 额度面板.app/Contents/MacOS/ChatBirdQuotaPanel --print-quota
./build/ChatBird\ 额度面板.app/Contents/MacOS/ChatBirdQuotaPanel --print-claude-quota
./build/ChatBird\ 额度面板.app/Contents/MacOS/ChatBirdQuotaPanel --print-task-progress
./build/ChatBird\ 额度面板.app/Contents/MacOS/ChatBirdQuotaPanel --print-panel-location
./build/ChatBird\ 额度面板.app/Contents/MacOS/ChatBirdQuotaPanel --print-saved-panel-location
./build/ChatBird\ 额度面板.app/Contents/MacOS/ChatBirdQuotaPanel --self-test-placement
./build/ChatBird\ 额度面板.app/Contents/MacOS/ChatBirdQuotaPanel --self-test-lifecycle
./build/ChatBird\ 额度面板.app/Contents/MacOS/ChatBirdQuotaPanel --self-test-native-notification-state
./build/ChatBird\ 额度面板.app/Contents/MacOS/ChatBirdQuotaPanel --self-test-task-progress
./build/ChatBird\ 额度面板.app/Contents/MacOS/ChatBirdQuotaPanel --self-test-weekly-quota
./build/ChatBird\ 额度面板.app/Contents/MacOS/ChatBirdQuotaPanel --self-test-claude-quota
./build/ChatBird\ 额度面板.app/Contents/MacOS/ChatBirdQuotaPanel --self-test-chatbird-edition
./build/ChatBird\ 额度面板.app/Contents/MacOS/ChatBirdQuotaPanel --self-test-dynamic-island
```

灵动岛确定性预览：

```bash
./build/ChatBird\ 额度面板.app/Contents/MacOS/ChatBirdQuotaPanel \
  --render-dynamic-island-preview <state> <path>
```

支持的 `state` 固定为：

```text
capsule-confirmation
capsule-running
capsule-waiting
capsule-completed
capsule-failed
capsule-idle
capsule-codex-exited
tasks
confirm-tool
confirm-question
confirm-plan
quota-codex
quota-claude
quota-loading
quota-stale
quota-first-failure
quota-unavailable
```

本地完整验证序列：

```bash
./macos/ChatBirdQuotaPanel/scripts/build.sh
BIN="macos/ChatBirdQuotaPanel/build/ChatBird 额度面板.app/Contents/MacOS/ChatBirdQuotaPanel"
"$BIN" --self-test-placement
"$BIN" --self-test-lifecycle
"$BIN" --self-test-native-notification-state
"$BIN" --self-test-task-progress
"$BIN" --self-test-weekly-quota
"$BIN" --self-test-claude-quota
"$BIN" --self-test-claude-hook
"$BIN" --self-test-client-contract
"$BIN" --self-test-chatbird-edition
"$BIN" --self-test-dynamic-island
OUT="output/audit/dynamic-island-implementation/previews"
mkdir -p "$OUT"
for STATE in \
  capsule-confirmation capsule-running capsule-waiting capsule-completed \
  capsule-failed capsule-idle capsule-codex-exited \
  tasks confirm-tool confirm-question confirm-plan \
  quota-codex quota-claude quota-loading quota-stale \
  quota-first-failure quota-unavailable
do
  "$BIN" --render-dynamic-island-preview "$STATE" "$OUT/$STATE.png"
done
```

## 卸载

```bash
./scripts/uninstall.sh
```

卸载前必须完全退出 Codex；若仍在运行，脚本会停止且不会移除面板或原生气泡恢复文件。
