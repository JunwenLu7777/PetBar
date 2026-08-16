# ThreadHelm 本机运维说明

ThreadHelm 只供这台 Mac 的当前用户使用。集成管理没有云端、账号同步或网络遥测。安装、修复和卸载会先在本机保存恢复点；测试只操作临时目录，不会拿真实厂商配置做夹具。

## 会改哪些文件

| Agent | ThreadHelm 的行为 | 受管位置 |
|---|---|---|
| Codex | 集成状态固定为 `notManaged`，集成安装/修复/卸载绝不写 Codex 配置。原生任务气泡静音是另一项已有功能，有自己的增量恢复文件。 | 不存在 Agent Hook 配置；气泡恢复文件为 `~/.codex/threadhelm-native-notification-backup.json` |
| Claude Code | 只管理自己拥有的 `PermissionRequest` HTTP Hook；其他 Hook、环境变量和设置保留。 | `~/.claude/settings.json` |
| Cursor | 只管理带 `threadhelmOwner` / `threadhelmAgent` 标记的生命周期 Hook；其他 Hook 和禁用选择保留。 | `~/.cursor/hooks.json` |
| ZCode | 只管理状态观察事件中的 ThreadHelm process Hook；不注册 `PermissionRequest`，并保留已有配置的其他键、事件顺序和 `hooks.enabled`。配置文件原本不存在时会新建并启用 Hook，同时写入独立所有权标记，卸载时据此恢复到“文件不存在”；旧版 ThreadHelm 单独创建且尚未启用的纯受管配置会安全迁移。变更只对新启动的 ZCode 会话生效。 | `~/.zcode/cli/config.json`、`~/.zcode/cli/.threadhelm-config-owner` |
| OMP | 只管理一个带所有权文件的 state-only 扩展；不做审批、发消息、取消、导航或会话修改。 | `~/.omp/agent/extensions/threadhelm-state-observer/` |

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
- Cursor Desktop `3.15.19` 和 Agent CLI `2026.04.15-dccdccd`
- ZCode `3.7.6` 和 build `3.7.6.4691`
- OMP `17.3.2`

只要版本没读到、少一个分量或有任意漂移，就显示 `unvalidated`，并隐藏只在固定版本上验证过的能力文案。例如本机 Cursor Desktop 即使再升到 `3.16.0`，也不能沿用 `3.15.19` 的验证结论。发现过程只读；`unvalidated` Agent 的安装和修复会跳过，不会改厂商配置，卸载仍可只移除已确认属于 ThreadHelm 的条目。

在源码目录构建后，可以运行生产回放器：

```bash
./macos/ThreadHelm/scripts/build.sh
BIN="macos/ThreadHelm/build/ThreadHelm.app/Contents/MacOS/ThreadHelm"
"$BIN" --verify-agent-truth macos/ThreadHelm/Tests/Fixtures/Agents
```

这会读取 81 条脱敏场景，经生产 Swift 归一化和真实 `AgentEventReducer` 比较 7 个 expected 字段。duplicate 和 out-of-order 场景也走真实 reducer。输出的 miss、false alert、duplicate、exact return 分子分母只说明这 81 条固定夹具，没有测量实际使用、延迟或主观体验；回放过程不写持久化用户状态。

该基线里 Codex 精确返回仍是 `unknown`；Claude Code 只有同时匹配会话、活进程和 process-start identity 才可能是 exact，否则降为 `unknown`；Cursor 与 ZCode 不宣称 exact；OMP 的精确返回能力是 `unsupported`，打开结果只能是 `unavailable`。发布脚本会执行同一回放，并把真值夹具纳入 release 输入时间；夹具更新后旧 ZIP 会被判为 stale。

受管集成的逻辑契约可以单独验证，不受其他适配器自测影响：

```bash
"$BIN" --self-test-agent-integration-manager
```

它覆盖安装、修复、卸载生命周期、备份与恢复、失败回滚、单 Agent 定向作用域与定向回滚、固定版本门禁和命令行边界。同一批断言也会在 `--self-test-task-progress` 中运行，但那条链会先跑一批与集成无关的适配器自测，任何一条失败都会在集成自测之前退出。

## 检查、安装、修复和卸载集成

用户可在 ThreadHelm 的 **Agents 详情页** 直接点击对应已验证 Agent 的 `[ 一键安装 ]` 或 `[ 立即修复 ]` 按钮触发受管集成安装；也可在页面顶部开启 `[ 自动集成 ]` 开关（默认关闭）。首次开启需要点击两次——第一次进入待确认态并说明会写入哪些厂商配置，第二次才真正生效；确认只需一次，8 秒内未确认自动撤销。

开启后 ThreadHelm 每 5 分钟在后台探测一次本机 Agent，发现新安装且版本已验证、且尚未集成时自动配置受管集成。同一 Agent 与版本的两次自动尝试之间有 5 分钟最小间隔（无论上一次成败），连续失败另有 5m→15m→60m 指数退避。发现结果缓存 TTL 为 240 秒，必须短于刷新周期，否则定时器唤醒时缓存尚未过期，实际探测间隔会退化成两个周期。亦可通过终端命令行进行批量运维。

以下命令必须明确写 `--live` 才能接触真实主目录。没有 `--live` 时命令会拒绝执行；自动化测试使用 `--root` 加临时目录。

```bash
BIN="$HOME/Applications/ThreadHelm.app/Contents/MacOS/ThreadHelm"

"$BIN" --agent-integrations status --live
"$BIN" --agent-integrations install --live
"$BIN" --agent-integrations repair --live
"$BIN" --agent-integrations uninstall --live
```

每次有写操作时，输出里的 `backupID` 都对应一个本机恢复点。Codex 应显示 `notManaged`；Agent 没安装或版本为 `unvalidated` 时，安装和修复不会为它创建或改写配置。卸载不受版本门禁影响，但仍只删除 ThreadHelm 自己拥有的受管条目。

ZCode 的“完整安装”不会要求额外确认：如果 `~/.zcode/cli/config.json` 原本不存在，ThreadHelm 会创建可直接工作的启用配置；如果文件已经存在，则显式的 `hooks.enabled=false` 和缺省状态都保持不变。只有内容完全由旧版 ThreadHelm Hook 组成的缺省配置会被识别为可迁移并启用。

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
2. 用 `backupID` 恢复 Claude、Cursor、ZCode 和 OMP 配置；
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
