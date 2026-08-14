# 隐私说明

## 当前产品源码与发布包不包含

- 作者或测试者的本机用户名、邮箱、主目录和绝对路径；
- GitHub 访问凭据、API Key、Cookie、密码或其他访问凭据；
- Codex 聊天内容、账号缓存、真实额度百分比或重置时间；
- 安装测试产生的日志、健康状态文件和诊断报告。

## 运行时数据

- ThreadHelm 读取本机 Codex app-server 提供的周额度，以及 `rateLimitResetCredits` 中的可用重置次数与到期时间；并通过已安装的 Claude CLI `/usage` 读取 Claude Code 的 5h、周额度与 Fable 周额度。
- 本机集成管理只支持 Codex、Claude Code、Cursor、ZCode 和 OMP。Codex 集成固定为 `notManaged`，其 install/repair/uninstall 路径不会写 Codex 配置；Claude、Cursor、ZCode 或 OMP 未安装时，不会为该 Agent 凭空创建受管配置。
- Claude Code 只在 `~/.claude/settings.json` 管理自己的 `PermissionRequest` Hook；Cursor 只在 `~/.cursor/hooks.json` 管理带所有权标记的生命周期 Hook；ZCode 只在 `~/.zcode/cli/config.json` 管理状态观察 Hook；OMP 只管理 `~/.omp/agent/extensions/threadhelm-state-observer/`。所有非 ThreadHelm 条目和显式禁用设置都会保留。
- Claude 额度探针禁用工具、使用固定隔离会话和独立缓存目录，并清理探针自己生成的 transcript；ThreadHelm 不记录或展示探针原始终端输出。
- 启用 Claude Code 权限确认 Hook 时，ThreadHelm 会在 `~/.claude/settings.json` 的 ThreadHelm HTTP Hook 条目中写入一个随机安装 token，并要求本机 `127.0.0.1:27841/threadhelm/claude/permission` 请求携带 `X-ThreadHelm-Hook-Token` header。该 token 只用于本机 Hook 请求鉴权，不写入 ThreadHelm 日志、不上传，也不会包含在返回给 Claude 的 Hook 响应中。Hook 服务只监听 `127.0.0.1`，单次请求正文上限为 256 KiB，待处理请求队列上限为 16 个。
- 任务状态在本机读取 Codex 会话状态，以及 Claude CLI `agents --json` 与 `~/.claude/projects` 下的顶层会话 transcript，用于显示执行中、等待确认、已完成和执行失败。
- Claude 任务只提取公开的 assistant `text` 作为悬停预览；不读取或展示 thinking、工具参数和原始工具输出，也会排除 subagent 与 ThreadHelm 额度探针 transcript。
- 任务名称、任务文字、已读状态、额度百分比和重置时间不写入 ThreadHelm 日志，也不上传。
- 用户主动打开任务时，ThreadHelm 会在 `~/Library/Application Support/ThreadHelm/open-measurements-v1.json` 记录仅由 Agent 类型、打开结果类型和数字组成的本地汇总计数，用于区分精确返回、应用聚焦、目录 fallback、未知和不可用。该文件权限为当前用户只读写（`0600`），不含标题、提示词、命令、路径、session/thread ID、时间线或时间戳，也不上传。
- 安装、修复、卸载或手工恢复受管集成前，ThreadHelm 会在 `~/Library/Application Support/ThreadHelm/Integration Backups/` 保存本机恢复点。更新期间还会在 `~/Library/Application Support/ThreadHelm/Install Transactions/` 临时保存旧 App、LaunchAgent、健康文件和 Codex 本机状态；成功或完整回滚后删除，回滚不完整时保留并打印路径供手工恢复。备份和事务目录权限为 `0700`，清单为 `0600`；其中可能包含原厂商配置或 Codex 本机状态中已有的私密值，只留在本机，不写日志、不上传。
- 为关闭原生气泡，ThreadHelm 只把不含内容的本地任务 ID 写入 Codex 已有的 `avatar-overlay-muted-notification-ids-v1` 状态，并把 ThreadHelm 新增值记录到 `~/.codex/threadhelm-native-notification-backup.json`。检测到 Codex 正在运行时不会改写该状态；完全退出且文件稳定后才会同步，写入失败会回滚本次备份变更，卸载时只移除已经记录的新增值。
- 卸载器检测到 Codex 仍在运行时会停止，不会移除 ThreadHelm 或恢复文件；完全退出 Codex 后才会恢复原生气泡设置。
- 卸载器只移除 ThreadHelm 拥有的 Claude、Cursor、ZCode 和 OMP 条目，保留其他配置；测试使用临时隔离 root，不读取或写入真实厂商配置。
- 若用户已经授予辅助功能权限，运行中的 ThreadHelm 会查找 Codex 暴露的固定辅助功能标签“显示活动，N 项 / Show activity, N item(s)”“打开通知 / Open notification”和“静音任务 / Mute task”。它只把同时具有固定窗口标题和计数按钮的透明角标窗口移到所有活动显示器之外，并调用 Codex 自带的菜单动作关闭新任务气泡；同名的任务列表窗口不会移动。读取到的其他辅助功能字符串不保留、不记录、不上传；ThreadHelm 不生成鼠标或键盘事件，也不会主动弹出授权请求。未授权时只检查授权状态，不访问 Codex 的辅助功能树、不移动窗口、不执行菜单动作，仍在 Codex 完全退出后同步任务 ID。
- ThreadHelm 不包含桌面宠物或对应素材，不依赖或安装 Codex Pet，不写入 `selected-avatar-id`，也不选择 `custom:chatbird-nt`。
- ThreadHelm 不会修改 `ChatGPT.app`、`Codex.app`、`app.asar` 或应用签名。
- ThreadHelm 不显示 Token 或行情模块，也不发起远程第三方行情请求；只展示 Codex app-server 返回的重置额度次数与到期时间，不直接读取登录凭据。
- Claude 额度读取与 Claude Hook 请求由用户已登录的 Claude CLI 完成，CLI 可能像正常使用 Claude Code 一样连接 Anthropic；ThreadHelm 不读取 Claude 凭据，也不直接调用 Anthropic OAuth API。
- Mac 日志位于当前用户的 `~/Library/Logs/ThreadHelm.log`。

## macOS 权限

- 辅助功能：可选，只用于隐藏 Codex 原生任务计数角标，并在当前 Codex 进程中自动执行其自带的“静音任务”菜单动作；未授权时额度、任务、灵动岛和退出后的气泡静音同步仍正常工作。

## 发布前审计

维护者应运行：

```bash
./scripts/privacy-audit.sh
```

发布包还应在全新临时目录中解压并重新执行校验，避免把本机缓存、日志或绝对路径带入压缩包。
