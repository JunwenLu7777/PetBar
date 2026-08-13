# ThreadHelm 本机运维说明

ThreadHelm 只供这台 Mac 的当前用户使用。集成管理没有云端、账号同步或网络遥测。安装、修复和卸载会先在本机保存恢复点；测试只操作临时目录，不会拿真实厂商配置做夹具。

## 会改哪些文件

| Agent | ThreadHelm 的行为 | 受管位置 |
|---|---|---|
| Codex | 集成状态固定为 `notManaged`，集成安装/修复/卸载绝不写 Codex 配置。原生任务气泡静音是另一项已有功能，有自己的增量恢复文件。 | 不存在 Agent Hook 配置；气泡恢复文件为 `~/.codex/threadhelm-native-notification-backup.json` |
| Claude Code | 只管理自己拥有的 `PermissionRequest` HTTP Hook；其他 Hook、环境变量和设置保留。 | `~/.claude/settings.json` |
| Cursor | 只管理带 `threadhelmOwner` / `threadhelmAgent` 标记的生命周期 Hook；其他 Hook 和禁用选择保留。 | `~/.cursor/hooks.json` |
| ZCode | 只管理状态观察事件中的 ThreadHelm process Hook；不注册 `PermissionRequest`，并保留其他键、事件顺序和 `hooks.enabled`。变更只对新启动的 ZCode 会话生效。 | `~/.zcode/cli/config.json` |
| Pi | 只管理一个带所有权文件的 state-only 扩展；不做审批、发消息、取消、导航或会话修改。 | `~/.pi/agent/extensions/threadhelm-state-observer/` |

App 本身安装到 `~/Applications/ThreadHelm.app`，登录启动项是 `~/Library/LaunchAgents/dev.threadhelm.app.plist`。运行日志在 `~/Library/Logs/ThreadHelm.log`，健康文件在 `~/Library/Caches/dev.threadhelm.app/`。

## 低噪声提醒和本地评价

ThreadHelm 只把权限、问题、计划确认、已经验证的阻塞和任务级失败列为可打断原因。同一 Agent、同一原生会话、同一原因在未解决期间只提醒一次；原因短暂消失后 60 秒内再次出现仍合并。普通工具失败、进程抖动和完成/可查看状态只更新胶囊，不触发新的打断。当前构建没有开启完成通知。

当灵动岛已经展开到同一个任务，或 Claude 确认面板正在处理当前请求时，对应提醒会在内存中标记为已经处理。这个合并状态不写磁盘。

如需评价提醒是否有用，只能使用固定 Agent ID 和固定分类：

```bash
BIN="$HOME/Applications/ThreadHelm.app/Contents/MacOS/ThreadHelm"

"$BIN" --record-attention-feedback cursor useful
"$BIN" --record-attention-feedback cursor unnecessary
"$BIN" --record-attention-feedback cursor wrongState
"$BIN" --record-attention-feedback cursor wrongSession
"$BIN" --print-attention-feedback
```

计数保存在 `~/Library/Application Support/ThreadHelm/attention-feedback-v1.json`，文件权限为 `0600`。文件只含 Agent ID、四种固定分类和非负整数；不含标题、提示词、命令、路径、session ID、时间戳或时间线，也不会发送网络遥测。少于 20 次真实评价时，诊断只显示原始计数，不计算百分比。

如果遇到重复提醒，也归到 `unnecessary`；这样统计口径始终只有上述四类，不会为了备注而写入自由文本。

## 固定版本和 81 场景真值回放

Agents 页面里的 `validated` 不是“看起来能用”，而是本机发现到的所有版本分量都与固定真值版本逐项相等：

- Codex `0.145.0`
- Claude Code `2.1.226`
- Cursor Desktop `3.15.6` 和 Agent CLI `2026.04.14-ee4b43a`
- ZCode `3.7.6` 和 build `3.7.6.4691`
- Pi `0.84.1`

只要版本没读到、少一个分量或有任意漂移，就显示 `unvalidated`，并隐藏只在固定版本上验证过的能力文案。例如本机 Cursor Desktop 即使只是升级到 `3.15.19`，也不能沿用 `3.15.6` 的验证结论。发现过程只读，不会安装集成或修改厂商配置。

在源码目录构建后，可以运行生产回放器：

```bash
./macos/ThreadHelm/scripts/build.sh
BIN="macos/ThreadHelm/build/ThreadHelm.app/Contents/MacOS/ThreadHelm"
"$BIN" --verify-agent-truth macos/ThreadHelm/Tests/Fixtures/Agents
```

这会读取 81 条脱敏场景，经生产 Swift 归一化和真实 `AgentEventReducer` 比较 7 个 expected 字段。duplicate 和 out-of-order 场景也走真实 reducer。输出的 miss、false alert、duplicate、exact return 分子分母只说明这 81 条固定夹具，没有测量你的实际使用、延迟或主观体验；夹具回放也不会增加个人真实会话计数。

该基线里 Codex 精确返回仍是 `unknown`；Claude Code 只有同时匹配会话、活进程和 process-start identity 才可能是 exact，否则降为 `unknown`；Cursor 与 ZCode 不宣称 exact；Pi 的精确返回能力是 `unsupported`，打开结果只能是 `unavailable`。发布脚本会执行同一回放，并把真值夹具纳入 release 输入时间；夹具更新后旧 ZIP 会被判为 stale。

## 个人真实会话与主人复核

Agents 页面会分别展示本机检测版本、当前真值夹具的测试版本、已支持能力、已知限制，以及个人真实会话计数。当前五个 Agent 一律从：

```text
experimental · 真实会话 0/10
```

开始。81 条自动化真值场景、App 启动、轮询、Hook 事件和自测都不会增加这个数字。只有你确实用 ThreadHelm 陪跑完一条真实本机会话，并手工确认这次端到端体验有效后，才执行一次对应命令：

```bash
BIN="$HOME/Applications/ThreadHelm.app/Contents/MacOS/ThreadHelm"

"$BIN" --record-personal-session codex
"$BIN" --record-personal-session claudeCode
"$BIN" --record-personal-session cursor
"$BIN" --record-personal-session zcode
"$BIN" --record-personal-session pi
"$BIN" --print-personal-session-evidence
```

一条命令只增加对应 Agent 的一个整数，不接收备注、路径或 session ID。计数保存在 `~/Library/Application Support/ThreadHelm/personal-session-evidence-v1.json`；目录权限为 `0700`，JSON 顶层只有五个固定 Agent ID，值只能是非负整数。JSON 和相邻的零字节 `.lock` 文件权限都为 `0600`；锁文件只负责串行化多个本机命令，不保存任何会话信息。App 运行时会重新读取这个小文件，因此不需要为了刷新计数而重启。

10 次只是允许主人复核的最低样本量，不会仅凭数字自动显示 `personal-ready`。达到 10 次但尚未复核时仍显示 `experimental · 真实会话 10/10 · 待主人复核`。你逐个确认该 Agent 的 10 次实际体验后，再显式执行：

```bash
"$BIN" --confirm-personal-readiness codex
"$BIN" --confirm-personal-readiness claudeCode
"$BIN" --confirm-personal-readiness cursor
"$BIN" --confirm-personal-readiness zcode
"$BIN" --confirm-personal-readiness pi
```

未满 10 次的 Agent 会被拒绝。误确认时可单独撤销，例如：

```bash
"$BIN" --revoke-personal-readiness cursor
```

`--print-personal-session-evidence` 会同时显示计数和主人复核结果。复核状态保存在 `~/Library/Application Support/ThreadHelm/personal-readiness-review-v1.json`，文件恰好只有五个固定 Agent ID 及五个布尔值；不保存时间、备注、任务、路径或 session ID。JSON 与相邻空锁文件权限为 `0600`，目录为 `0700`；损坏、不完整、多余键、非布尔值或符号链接状态会整体按“未复核”处理。App 运行时会重新读取计数和复核文件，无需重启。ThreadHelm 不会伪造个人会话、评分、延迟、miss rate 或精确返回成功率。

## 检查、安装、修复和卸载集成

以下命令必须明确写 `--live` 才能接触真实主目录。没有 `--live` 时命令会拒绝执行；自动化测试使用 `--root` 加临时目录。

```bash
BIN="$HOME/Applications/ThreadHelm.app/Contents/MacOS/ThreadHelm"

"$BIN" --agent-integrations status --live
"$BIN" --agent-integrations install --live
"$BIN" --agent-integrations repair --live
"$BIN" --agent-integrations uninstall --live
```

每次有写操作时，输出里的 `backupID` 都对应一个本机恢复点。Codex 应显示 `notManaged`；Agent 没安装时，相关适配器不会为它凭空创建配置。

## 备份和恢复

恢复点位于：

```text
~/Library/Application Support/ThreadHelm/Integration Backups/<backupID>/
```

目录权限为 `0700`，清单和新写入的配置文件为 `0600`。恢复点是原配置的本机副本，可能包含厂商配置中原本就有的私密值，因此不要上传或分享。

恢复一份备份：

```bash
"$BIN" --agent-integrations restore <backupID> --live
```

恢复动作自己也会先创建一个安全备份；如果恢复中途失败，会尽量回到恢复前的状态。

如果 App 二进制无法启动，可用当前源码构建出的二进制或完整安装包里的 `ThreadHelm.app/Contents/MacOS/ThreadHelm` 执行同一条恢复命令。最后的手工办法是打开对应 `manifest.json`，按其中的 `relativePath` 把 `payload/` 下的条目复制回主目录；标为 `missing` 的目标表示备份时原本不存在，应移除 ThreadHelm 后来创建的对应受管文件。

## 更新失败时会怎样

安装器在停止旧版本前，会临时保存旧 App、LaunchAgent、健康文件、Codex 气泡状态和恢复文件。随后才复制新 App、安装四个受管集成并启动自检。

任何一步失败时，安装器会：

1. 停止失败的新 LaunchAgent；
2. 用 `backupID` 恢复 Claude、Cursor、ZCode 和 Pi 配置；
3. 恢复旧 App、旧 LaunchAgent 和 Codex 气泡状态；
4. 重新启动原来的 LaunchAgent。

只有新 App 通过 `codesign --verify --deep --strict` 且健康检查成功，安装事务才会提交。旧产品清理发生在提交之后，不参与新版本启动判定。

如果自动回滚本身仍有一步失败，脚本不会删除本次事务快照，而会打印保留目录。快照位于 `~/Library/Application Support/ThreadHelm/Install Transactions/`，里面保存旧 App、LaunchAgent、健康文件和 Codex 本机状态的隔离副本；完成手工恢复前不要删除该目录。

## 完整卸载

运行安装包里的“卸载ThreadHelm.command”或源码脚本：

```bash
./macos/ThreadHelm/scripts/uninstall.sh
```

卸载器先语义化移除四个 ThreadHelm 受管集成，再恢复 Codex 气泡设置，最后删除 App 和 LaunchAgent。非 ThreadHelm 配置会保留；移除 App 后，五个 Agent 都继续按自己的原生行为运行。

## 快速核验

```bash
/usr/bin/codesign --verify --deep --strict \
  "$HOME/Applications/ThreadHelm.app"

"$BIN" --agent-integrations status --live
```

安装包的“检查ThreadHelm.command”也会执行签名检查并打印五 Agent 集成状态。
