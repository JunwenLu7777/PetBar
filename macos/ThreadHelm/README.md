# ThreadHelm macOS App

独立运行的 macOS AppKit 应用，提供灵动岛、额度和任务状态功能。源码目录为 `macos/ThreadHelm`，产品名称、Bundle、Executable 和安装产物均为 ThreadHelm。

- 左侧可在 Codex 与 Claude Code 间切换：Codex 显示周额度，Claude Code 同时显示 5h、周额度与 Fable 周额度。
- 不显示 Token、Credits 或行情区域。
- 启动时立即读取额度，之后每分钟自动更新，也可点击刷新图标手动更新。
- 点击“收起”会隐藏窗口；点击菜单栏 “ThreadHelm” 或使用全局快捷键可恢复显示。
- 灵动岛模式使用 404×58 pt 单行胶囊，依次显示状态点、状态、任务标题、耗时和展开箭头；整颗胶囊可点击且不抢焦点，也可拖到其他屏幕后释放并吸附到该屏幕顶部中央。
- 灵动岛展开态包含完整的任务、确认和额度工作区，右上角分别提供刷新、收起和隐藏：收起只返回胶囊，隐藏会让灵动岛完全消失且不响应后续任务刷新；从菜单栏选择“显示”可恢复胶囊。隐藏待确认请求不会同意、拒绝或丢弃该请求。
- Codex 未运行时会立即静音已有本地任务；若 Codex 正在运行，ThreadHelm 会在 Codex 完全退出且状态落盘稳定后自动同步，避免下次打开时旧气泡恢复。
- 已授予辅助功能权限时，ThreadHelm 约每 2 秒把带有 `Show activity, N item(s)` / `显示活动，N 项` 按钮的 Codex 计数角标窗口移到所有活动显示器之外，并继续通过 Codex 自带的“静音任务”菜单关闭新任务气泡；同名的任务列表窗口不会移动。该过程不会移动鼠标或发送按键，只匹配固定辅助功能标签，其他字符串不保留、不记录、不上传。未授权时仍可手动静音，退出后会加入下次启动使用的静音列表。
- 任务状态约每 2 秒读取本机 Codex 与 Claude Code 会话状态，显示执行中、等待确认、已完成和执行失败；点击任务行可打开 Codex 任务或在 Terminal 恢复 Claude 会话。
- 运行中任务显示开始时间与持续时间；已完成/失败任务的持续时间固定，不继续增长。
- 运行中任务悬停预览只显示助手公开输出，并以固定三行字符滑窗持续替换旧内容；详情区提供滚动条查看完整公开输出；不展示 thinking、工具参数或原始工具输出。
- 启动后写入不含个人数据的运行状态文件，供安装器确认进程确实已启动。
- Codex 额度通过本机 `codex app-server` 的 `account/rateLimits/read` 读取；Claude 额度通过已登录 Claude CLI 的只读 `/usage` PTY 读取。
- Claude 任务通过 `claude agents --json` 与顶层会话 transcript 读取；任务名称、公开输出和已读状态只在本机显示，不写入日志，也不上传。
- 不发起远程第三方行情请求。
- 不修改 Codex 应用本体，Codex 更新不会覆盖 ThreadHelm。

## 安装

```bash
./scripts/install.sh
```

安装后会把 App 安装到 `~/Applications/ThreadHelm.app`，注册当前用户的 `dev.threadhelm.app` LaunchAgent，并从安装路径启动。用户主动退出后会保持关闭，不会被自动重新拉起。

安装器会统一处理 Claude Code、Cursor、ZCode 和 Pi 的受管本机集成；Codex 集成明确为 `notManaged`，不会由该入口改写配置。更新前会备份旧 App、LaunchAgent 和受管配置，启动或健康检查失败会自动回滚。具体文件和恢复方法见[本机运维说明](../../docs/threadhelm-local-operations.md)。

ThreadHelm 不包含桌面宠物素材，也不再复制或选择 Codex Pet，不写入 `selected-avatar-id`；如果旧配置仍选择已停用的 Codex Pet，安装器会先备份再移除该选择。

额度与任务功能本身不需要 macOS 辅助功能授权。若用户已经授权，ThreadHelm 只会把精确匹配计数按钮的透明窗口移到活动显示器之外，并调用 Codex 自带的“静音任务”菜单动作来关闭新任务气泡；未授权时不会主动弹出授权请求。

Codex 完全退出后，ThreadHelm 会短暂等待全局状态与任务索引稳定，再合并静音任务 ID；如果 Codex 在等待期间重新启动，本次同步会取消并留到下次退出后执行。

当前开发构建位置：`./build/ThreadHelm.app`
安装位置：`~/Applications/ThreadHelm.app`

## 数据自检

```bash
./build/ThreadHelm.app/Contents/MacOS/ThreadHelm --print-quota
./build/ThreadHelm.app/Contents/MacOS/ThreadHelm --print-claude-quota
./build/ThreadHelm.app/Contents/MacOS/ThreadHelm --print-task-progress
./build/ThreadHelm.app/Contents/MacOS/ThreadHelm --print-panel-location
./build/ThreadHelm.app/Contents/MacOS/ThreadHelm --print-saved-panel-location
./build/ThreadHelm.app/Contents/MacOS/ThreadHelm --print-attention-feedback
./build/ThreadHelm.app/Contents/MacOS/ThreadHelm --agent-integrations status --root /tmp/threadhelm-isolated-root
./build/ThreadHelm.app/Contents/MacOS/ThreadHelm --self-test-placement
./build/ThreadHelm.app/Contents/MacOS/ThreadHelm --self-test-lifecycle
./build/ThreadHelm.app/Contents/MacOS/ThreadHelm --self-test-native-notification-state
./build/ThreadHelm.app/Contents/MacOS/ThreadHelm --self-test-task-progress
./build/ThreadHelm.app/Contents/MacOS/ThreadHelm --self-test-weekly-quota
./build/ThreadHelm.app/Contents/MacOS/ThreadHelm --self-test-claude-quota
./build/ThreadHelm.app/Contents/MacOS/ThreadHelm --self-test-threadhelm-edition
./build/ThreadHelm.app/Contents/MacOS/ThreadHelm --self-test-dynamic-island
```

注意力评价只接受五个固定 Agent ID（`codex`、`claudeCode`、`cursor`、
`zcode`、`pi`）和四个固定分类，不接收标题、路径或 session ID：

```bash
./build/ThreadHelm.app/Contents/MacOS/ThreadHelm \
  --record-attention-feedback cursor useful
./build/ThreadHelm.app/Contents/MacOS/ThreadHelm \
  --record-attention-feedback zcode unnecessary
./build/ThreadHelm.app/Contents/MacOS/ThreadHelm \
  --record-attention-feedback claudeCode wrongState
./build/ThreadHelm.app/Contents/MacOS/ThreadHelm \
  --record-attention-feedback codex wrongSession
```

未满 20 次真实评价时只显示原始计数和“样本不足”，不会给出看似可靠的
百分比。

灵动岛确定性预览：

```bash
./build/ThreadHelm.app/Contents/MacOS/ThreadHelm \
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
quota-refreshing
quota-loading
quota-stale
quota-first-failure
quota-unavailable
```

本地完整验证序列：

```bash
./macos/ThreadHelm/scripts/build.sh
BIN="macos/ThreadHelm/build/ThreadHelm.app/Contents/MacOS/ThreadHelm"
"$BIN" --self-test-placement
"$BIN" --self-test-lifecycle
"$BIN" --self-test-native-notification-state
"$BIN" --self-test-task-progress
"$BIN" --self-test-weekly-quota
"$BIN" --self-test-claude-quota
"$BIN" --self-test-claude-hook
"$BIN" --self-test-client-contract
"$BIN" --self-test-threadhelm-edition
"$BIN" --self-test-dynamic-island
OUT="output/audit/dynamic-island-implementation/previews"
mkdir -p "$OUT"
for STATE in \
  capsule-confirmation capsule-running capsule-waiting capsule-completed \
  capsule-failed capsule-idle capsule-codex-exited \
  tasks confirm-tool confirm-question confirm-plan \
  quota-codex quota-claude quota-refreshing quota-loading quota-stale \
  quota-first-failure quota-unavailable
do
  "$BIN" --render-dynamic-island-preview "$STATE" "$OUT/$STATE.png"
done
```

## 卸载

```bash
./scripts/uninstall.sh
```

卸载前必须完全退出 Codex；若仍在运行，脚本会停止且不会移除 App 或原生气泡恢复文件。卸载器会先移除 Claude Code、Cursor、ZCode 和 Pi 的 ThreadHelm 受管条目，再移除 `~/Applications/ThreadHelm.app`、`dev.threadhelm.app` LaunchAgent、ThreadHelm 日志和健康缓存，并只恢复本项目记录过的 Codex 原生气泡设置。其他厂商配置不会被删除。
