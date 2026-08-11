# ChatBird macOS 灵动岛技术评审

日期：2026-08-10
阶段：设计评审完成，Gate A/B 已确认，等待选择实施方式
代码状态：本评审未修改产品源码

## 1. 结论

方案可以实现，建议进入实现，但必须把它作为与现有宠物面板并列的第二套展示模式，而不是在 `QuotaPanelView` 上继续堆叠条件分支。

推荐架构是：

- 保留现有宠物面板的窗口、定位、绘制和交互行为。
- 新增独立的顶部居中 `NSPanel`，负责胶囊与展开工作台两阶段展示。
- 两套展示共享同一份任务、额度和 Claude 确认状态，任一时刻只显示用户选择的主展示模式。
- 灵动岛使用独立的中性深色视觉系统，不复用当前宠物面板的蓝色渐变、发光边框、指针气泡和像素宠物语言。
- 不显示没有真实数据来源的 `3/5`；默认胶囊改为 404×58pt 单行“状态点、状态、任务标题、耗时、展开箭头”。公开活动与来源仍保留在共享模型、无障碍值和展开工作台中。
- V1 的“最近事件”只显示最多三条经过安全过滤的公开事件，不做无限历史归档。

评审结果为 **GO**：技术结构可行，第 13 节的两个用户可见 Gate 已由用户确认并关闭。

## 2. 评审范围和证据

### 2.1 已选视觉目标

- `output/imagegen/petbar-dynamic-island-interactions-01-task-workspace.png`
- `output/imagegen/petbar-dynamic-island-interactions-02-confirmation-workflows.png`
- `output/imagegen/petbar-dynamic-island-interactions-03-quota-system-states.png`

### 2.2 当前产品快照

本轮从当前构建产物重新离屏渲染并检查：

- `output/audit/dynamic-island-review/01-current-panel.png`
- `output/audit/dynamic-island-review/02-current-confirm-tool.png`
- `output/audit/dynamic-island-review/03-current-confirm-question.png`
- `output/audit/dynamic-island-review/04-current-confirm-plan.png`

### 2.3 当前实现证据

- 主窗口是 `borderless + nonactivatingPanel` 的 AppKit `NSPanel`，并已具备跨 Space、全屏辅助窗口和状态栏层级基础：`AppDelegate.swift:153-210`。
- 当前窗口依赖宠物定位并以约 30ms 高频跟随：`AppDelegate.swift:447-605`、`PanelPlacement.swift:15-58`。
- 任务、额度和选择状态目前直接存放在 `QuotaPanelView`：`QuotaPanelView.swift:16-83`。
- Codex/Claude 任务模型已有状态、时间、公开活动、线程/会话和工作目录字段：`TaskProgressModels.swift:15-128`。
- 当前任务在数据进入 UI 前已经投影为最多五项：`TaskProgressModels.swift:272-325`、`CodexTaskProgress.swift:47-103`、`ClaudeTaskProgress.swift:827-845`。
- Claude 确认队列、自动收起、终端回退和三类决策目前与独立窗口控制器耦合：`ClaudePermissionPanel.swift:13-199`。
- 三类 Claude 交互协议已经存在：工具授权、分页问答和计划审批：`ClaudeHookSupport.swift:18-62`、`ClaudeHookSupport.swift:90-215`。
- 额度已有 Codex 周额度、重置额度、Claude 5 小时/周/Fable、缓存和错误文案：`QuotaModels.swift:15-239`、`QuotaClients.swift:49-139`、`AppDelegate.swift:610-783`。
- 构建目标是纯 AppKit、Swift 5、macOS 12.3，不适合改用 macOS 15+ SwiftUI 窗口 API：`scripts/build.sh:19-32`、`Resources/Info.plist`。

## 3. 产品边界

### 3.1 两套展示模式

```text
展示模式
├── 现有宠物面板
│   ├── 继续跟随宠物
│   ├── 保持当前尺寸、视觉与点击行为
│   └── Claude 确认继续使用现有独立弹窗
└── macOS 灵动岛
    ├── 顶部居中胶囊
    ├── 点击后向下展开为功能工作台
    ├── Claude 确认内联到工作台
    └── 不依赖宠物坐标，Codex 退出时仍可显示系统状态
```

### 3.2 模式切换

- 新增 `PresentationMode.petPanel` 和 `PresentationMode.dynamicIsland`。
- 使用 `UserDefaults` 保存选择。
- 现有用户默认仍使用宠物面板，避免升级后突然改变窗口位置和交互。
- 通过状态栏菜单切换模式；菜单同时提供“显示/隐藏”“移到当前显示器”和“退出”。
- 切换时先隐藏旧模式，再显示新模式；任务、额度和待确认队列不重读、不丢失。

### 3.3 明确不做

- 不修改 Codex/Claude 应用本体。
- 不新增远程服务、埋点或第三方依赖。
- 不读取或展示 thinking、工具参数、原始工具输出或凭据。
- 不把灵动岛做成现有蓝色宠物面板的缩放版。
- 不承诺没有可靠来源的精确步骤百分比或 `3/5`。
- V1 不做无限任务历史、全文搜索或跨设备同步。

## 4. 顶部窗口与尺寸

### 4.1 推荐尺寸

| 状态 | 基准尺寸 | 说明 |
|---|---:|---|
| 默认胶囊 | 404×58pt | 单行状态点、状态、任务标题、耗时和展开箭头；整颗可点击 |
| 任务工作台 | 820×560pt | 左侧任务队列，右侧任务详情 |
| 待确认工作台 | 820×600pt | 覆盖最多五题问答和长计划滚动区 |
| 额度工作台 | 820×470pt | 左侧 Provider，右侧额度与状态 |

尺寸不是用户自由缩放窗口；窗口根据内容状态在上述尺寸间切换，并在小屏幕上按可见区域收敛内容高度。不能整体缩小字体来“塞进去”。

### 4.2 刘海和菜单栏

本轮机器实测：内屏硬件刘海左右安全区域之间只有约 185pt，而目标胶囊宽约 404pt，因此不能把胶囊放进真实菜单栏刘海区域。

定位规则：

1. 胶囊水平居中于目标显示器。
2. 胶囊顶部位于 `visibleFrame.maxY - 6pt`，即菜单栏下方。
3. 展开时保持窗口顶部锚点不变，窗口向下增长。
4. 使用 `safeAreaInsets` 和 `auxiliaryTopLeftArea` / `auxiliaryTopRightArea` 判断刘海，但不覆盖系统菜单项。
5. 外接屏没有刘海时仍使用相同“顶部下方”规则。
6. 目标显示器断开后迁移到主屏；窗口不跟随鼠标在显示器之间跳动。

### 4.3 窗口属性

- 新建独立 `DynamicIslandPanel: NSPanel`，不复用现有 `panel` 实例。
- `styleMask`: `.borderless + .nonactivatingPanel`；只有确认表单输入时临时允许成为 key window，普通浏览不激活 ChatBird。
- `collectionBehavior`: `.canJoinAllSpaces`, `.fullScreenAuxiliary`, `.stationary`。
- 默认层级使用现有 `statusBar` 层级；不得永久使用更高层级覆盖系统确认窗口。
- 与 Codex 原生活动窗口相交时可复用现有动态 `statusBar + 1` 层级策略，离开交叠后必须恢复默认层级。
- 普通胶囊永不成为 key window；展开工作台可在不激活应用的前提下接收 Tab/Escape，待确认文本输入时才显式激活 ChatBird 并成为 first responder。
- 用本地和全局鼠标监听共同实现点击外部收起；监听只判断坐标，不注入鼠标或键盘事件。

### 4.4 动画

- 胶囊到面板：建议 220ms，顶部锚点固定，尺寸与圆角同步变化。
- 面板到胶囊：建议 180ms，先收起详细内容，再缩放外框。
- 动画中锁定重复点击，避免 frame 动画和内容切换重入。
- 开启“减少动态效果”时取消形变动画，改为短淡入淡出。
- 开启“降低透明度”时使用不透明近黑背景和清晰边框。

## 5. 状态机

```text
hidden
  └─ 用户显示/模式切换 ─> capsule

capsule
  ├─ 点击主状态 ─> expanded(preferredTab)
  ├─ 新 Claude 确认 ─> expanded(confirmation)
  └─ 用户隐藏 ─> hidden

expanded(tasks | confirmation | quota)
  ├─ 切换页签 ─> expanded(otherTab)
  ├─ 点击外部 / Escape / 收起 ─> capsule
  ├─ 切换展示模式 ─> hidden，并交给另一展示模式
  └─ 用户隐藏 ─> hidden
```

约束：

- 点击外部只收起界面，不取消待确认请求。
- 待确认队列不为空时，胶囊必须持续显示黄色状态点与“待确认”；队列数量保留在无障碍值和展开确认页。
- 当前确认完成后，有下一条则留在确认页并自动切换；没有下一条则回到之前页签。
- 用户在终端中完成回答后，沿用当前“先观察到 waiting，再观察到离开 waiting”的安全收起条件。
- Codex 退出时，未完成的 Claude 确认按当前逻辑安全回退终端；灵动岛显示“Codex 已退出”，而不是留下一张失效表单。

## 6. 胶囊内容和优先级

胶囊只显示一项主状态，优先级固定，避免每次刷新跳来跳去：

| 优先级 | 条件 | 胶囊内容 | 主动作 |
|---:|---|---|---|
| 1 | Claude 确认队列非空 | 黄色状态点、待确认、任务名、耗时 | 展开确认页 |
| 2 | 有等待输入任务 | 黄色状态点、等待中、任务名、耗时 | 展开并选中任务 |
| 3 | 有运行中任务 | 绿色状态点、执行中、最近更新的任务名、耗时 | 展开并选中任务 |
| 4 | 有未读失败任务 | 任务名、失败状态、完成时间 | 展开查看详情 |
| 5 | 有未读完成任务 | 任务名、完成状态、完成时间 | 展开查看详情 |
| 6 | 无任务 | 当前 Provider 额度摘要或空闲状态 | 展开额度页 |
| 7 | Codex 已退出 | 状态说明；Claude Provider 仍按可用性展示 | 展开系统状态 |

胶囊的“进度”定义：

- 运行中：绿色静态状态点，不显示数字分数。
- 等待确认：黄色静态状态点。
- 完成：绿色完成态。
- 失败：红色失败态。
- 如果未来出现可靠的 `completedStepCount/totalStepCount` 来源，再单独增加确定进度，不从文本猜测。

## 7. 展开工作台

### 7.1 公共顶部栏

- 产品名。
- `任务 / 待确认 / 额度` 三个页签及真实计数。
- `全部 / Codex / Claude` Provider 筛选。
- 手动刷新按钮：同时请求任务和额度刷新；刷新中旋转且不接受重复点击。
- 收起按钮。

### 7.2 任务页

左栏：

- 状态筛选：全部、运行中、等待输入、已完成、失败。
- Provider 筛选与状态筛选组合使用。
- 任务列表保留完整的“当前可见集合”，不是现有五行投影。
- 选中任务刷新后仍存在则保持选中；消失时按胶囊优先级选择下一项。
- 运行中任务悬停显示最多三行安全活动预览，不改变当前选中项。

右栏：

- Provider、项目/工作目录、标题、状态和耗时。
- 当前活动摘要。
- 最近三条安全事件。
- `打开 Codex` 或 `回到终端`。
- `复制路径`，仅在存在绝对工作目录时启用；完成后短暂显示“已复制”。
- 缩短后的 Thread/Session ID，用于辨认，不作为主要信息。

### 7.3 待确认页

- 左栏显示 FIFO 队列和到达时间。
- 右栏根据类型切换：工具授权、分页问答、计划审批。
- 复用现有协议解析、限制、答案验证和决策语义；重新实现中性深色视图，不直接嵌入当前蓝色宠物样式。
- 工具授权保留：权限详情、拒绝、允许一次、长期权限建议、回到终端。
- 问答保留：1–5 题、单选/多选/自由输入、上一题/下一题、未回答定位和批量提交。
- 计划保留：可滚动计划、修改意见、让 Claude 修改、批准并继续、回到终端。

### 7.4 额度页

- Provider 列表与快速预览。
- Codex：周额度、重置时间、可用重置额度与到期时间。
- Claude：5 小时、周额度、Fable。
- 状态覆盖：首次读取、刷新中、成功、使用缓存的失败、首次失败、未安装、未登录。
- 刷新失败时保留最后成功的额度行和 Codex 重置额度；当前代码会在 Codex 刷新失败时清空重置额度，这里需要修正。

## 8. 数据和动作映射

| 设计能力 | 当前基础 | 评审结论 |
|---|---|---|
| 任务状态、标题、开始/更新时间 | 已有 | 直接复用 |
| 状态耗时 | 已有时间，可派生 | 新增统一格式化 |
| 当前公开活动 | 已有 `activityText` | 直接复用并保持隐私过滤 |
| 最近三条事件 | 当前只有合并文本 | 新增有界 `TaskActivityEvent` |
| `3/5` 精确步骤 | 无来源 | V1 删除数字，禁止猜测 |
| 完整任务筛选和计数 | 当前先裁成最多五条 | 新增 collection，再为旧面板投影五条 |
| Codex 工作目录 | rollout `session_meta.cwd` 有数据，当前未进入 item | 扩展 Codex 解析器 |
| Claude 工作目录 | 已有 | 直接复用 |
| 打开 Codex Thread | 已有 | 直接复用 |
| 恢复 Claude Terminal/Session | 已有 | 直接复用 |
| 复制工作目录 | 数据部分已有 | 新增剪贴板动作 |
| Claude 确认队列和三类交互 | 已有但与窗口耦合 | 拆分 coordinator 与 presenter |
| Codex 周额度和重置额度 | 已有 | 直接复用并修正失败缓存 |
| Claude 三类额度 | 已有 | 直接复用 |
| Provider 可用性和选择 | 已有 | 提升为共享状态 |
| 手动刷新 | 当前只刷新选中额度 | 新增任务+额度联合刷新命令 |
| 顶部定位、多屏和刘海 | 当前只支持宠物锚点 | 新增独立 placement 逻辑 |

## 9. 推荐代码边界

### 9.1 共享状态

新增轻量 `ActivityDashboardStore`，由 `AppDelegate` 在主线程持有：

- `taskCollection`
- `quotaStates`
- `availableProviders`
- `selectedQuotaProvider`
- `permissionQueue`
- `acknowledgedTerminalTaskKeys`（按任务身份、终态和终态更新时间区分，仅当前进程内）
- `isTaskRefreshing` 与每个 Provider 的 `isRefreshing`
- 订阅/解绑接口

现有 `QuotaPanelView` 和新 `DynamicIslandWindowController` 都只消费快照并发送动作，不能互相读取对方的 view 属性作为数据源。

### 9.2 Claude 确认拆分

把当前 `ClaudePermissionPanelController` 拆为：

- `ClaudePermissionCoordinator`：队列、当前请求、完成回调、过期、终端回答自动收起。
- `ClaudePermissionPanelPresenter`：只服务现有宠物面板模式。
- `DynamicIslandConfirmationPresenter`：只服务灵动岛模式。

同一 coordinator 任一时刻只绑定一个 presenter，避免重复回答同一请求。

### 9.3 任务集合

新增 `TaskProgressCollectionSnapshot`：

- 保存经过去重和隐私过滤的当前可见任务集合。
- 提供 Provider/状态筛选、计数和选中恢复。
- 提供 `compactProjection(limit: 5)` 给现有宠物面板。
- Codex 仍限制候选 rollout 数量和新鲜度；Claude 仍只保留活跃及短期结束任务。这里的“完整”指完整可见集合，不是永久档案。

### 9.4 建议新增文件

- `ActivityDashboardModels.swift`
- `DynamicIslandWindowController.swift`
- `DynamicIslandPlacement.swift`
- `DynamicIslandView.swift`
- `DynamicIslandSelfTest.swift`

现有文件的职责调整：

- `AppDelegate.swift`：刷新编排、模式选择和两套 presenter 生命周期。
- `TaskProgressModels.swift`：集合、事件和投影模型。
- `CodexTaskProgress.swift` / `ClaudeTaskProgress.swift`：返回集合并生成安全事件。
- `ClaudePermissionPanel.swift`：拆分队列协调与旧窗口展示。
- `QuotaClients.swift`：保留现有客户端；失败状态不得丢弃最后成功数据。
- `main.swift`：增加灵动岛自测与离屏预览入口。

不新增第三方依赖，不把项目迁移到 SwiftUI，不重命名全部 `ChatBird*` 内部符号。

## 10. V1 交付范围

V1 应一次交付以下真实功能：

1. 两种展示模式及持久化切换。
2. 404×58pt 默认胶囊和三种展开工作台。
3. 顶部居中定位、刘海/菜单栏安全区、多显示器和屏幕断开恢复。
4. 任务 Provider/状态筛选、真实计数、选择联动、公开活动和最近三条安全事件。
5. Codex Thread 打开、Claude Terminal/Session 恢复、工作目录复制。
6. Claude 工具授权、分页问答、计划审批的完整内联流程。
7. Codex/Claude 额度、重置额度、手动/自动刷新和完整错误状态。
8. 待确认优先级、Codex 退出、无任务、Provider 不可用等系统状态。
9. 点击外部收起、Escape、减少动态效果、降低透明度、键盘导航和 VoiceOver 标签。
10. 旧宠物面板的回归验证。

V1 不包含：精确步骤分数、永久任务历史、历史搜索、云同步、远程通知。

## 11. 验收与测试规格

### 11.1 状态和数据自测

- 胶囊优先级覆盖确认、等待、运行、失败、完成、空闲和退出。
- 状态机不允许动画重入或重复提交确认。
- Provider 与状态筛选计数来自 collection，不来自五行视图投影。
- 刷新后选中任务保持；任务消失时选择确定且稳定。
- 最近事件最多三条，只包含公开 commentary、公开 assistant 文本和通用工具活动。
- thinking、工具参数、命令正文、原始工具输出、凭据永不进入事件或胶囊。
- Codex/Claude 去重、活跃排序和旧面板五行投影保持当前行为。
- 额度刷新 single-flight；失败保留最后额度和重置额度。
- Claude 确认每个请求只完成一次，过期/回退/终端回答继续安全工作。

### 11.2 窗口和定位自测

- 有刘海内屏、无刘海外屏、负坐标屏幕、Dock 在不同边、菜单栏自动隐藏。
- 胶囊和展开态共享相同顶部锚点。
- 小屏幕内容不越出 `visibleFrame`，不通过缩小字体规避。
- 目标显示器断开后移到主屏；重连不自动跳回。
- 普通胶囊不抢焦点；问答/意见输入能正确成为 first responder。
- 点击外部、Escape、收起按钮行为一致，待确认请求不被取消。
- 全屏 Space 中可见性和层级通过真实 `.app` 手动验证，不能只依赖离屏截图。

### 11.3 交互验收

- 胶囊点击按当前主状态展开到对应页签，并在任务态选中对应任务。
- 任务点击更新右侧；悬停只显示预览，不改变选择。
- `打开 Codex`、`回到终端` 和 `复制路径` 命中正确目标。
- 联合刷新期间按钮旋转、禁止重复，完成后显示成功或缓存失败状态。
- 三类 Claude 确认覆盖允许、拒绝、长期建议、答案验证、计划反馈和队列推进。
- 在终端完成回答后，内联确认自动关闭且不会打开错误会话。

### 11.4 无障碍验收

- 所有可点击区域使用真实 AppKit control 或完整的 NSAccessibility 元素，不只依赖自绘命中区。
- VoiceOver 能读出胶囊主状态、页签计数、任务状态、额度值和按钮用途。
- Tab 顺序与视觉顺序一致；Return 只触发当前安全主动作；拒绝不绑定容易误触的默认键。
- 状态不只靠颜色表达，必须同时有符号和文本。
- 细节文字不低于 12pt，主要正文不低于 13pt。
- Reduce Motion / Reduce Transparency 有明确降级。

### 11.5 视觉验收

- 离屏渲染胶囊的运行、等待、完成、失败、空闲五种状态。
- 离屏渲染任务、三类确认、两种 Provider 额度、加载和失败状态。
- 每个实现截图与对应设计稿在同一输入中比较尺寸、间距、层级、圆角、字体和颜色。
- 旧面板截图与基线比较，不允许因共享状态重构产生视觉漂移。

## 12. 当前基线验证

本评审运行了当前构建产物的九组自测，均为退出码 0：

- placement
- lifecycle
- native notification state
- task progress
- weekly quota
- Claude quota
- Claude hook
- client contract
- ChatBird edition

这些结果证明现有能力可以复用，但不等于灵动岛已经实现或运行时窗口行为已验证。

## 13. 实现前用户可见决策

### Gate A：品牌文案

当前应用、Bundle 和代码中的用户可见名称是“ChatBird 额度面板”，选中的灵动岛设计稿使用“PetBar”。实现时不能混用两个品牌。

推荐默认：本次只实现功能，灵动岛沿用当前发布名称 `ChatBird`；如果要统一改为 `PetBar`，作为单独的品牌迁移范围处理。

**已确认（2026-08-10）：本次使用 `ChatBird` 品牌；不在灵动岛范围内执行 `PetBar` 品牌迁移。**

### Gate B：进度表达

设计稿中的 `3/5` 没有可靠数据来源。

推荐默认：V1 使用状态点 + 状态 + 耗时，不显示数字步骤；未来只有在 Provider 提供结构化步骤后才恢复确定进度。

**已确认（2026-08-10）：V1 不显示 `3/5`、猜测百分比或推断步骤数，只显示真实状态和耗时。2026-08-11 胶囊视觉修订进一步将进度表达收敛为状态色圆点。**

## 14. 建议实施顺序

两个 Gate 已确认。逐文件实施计划已记录在 `docs/superpowers/plans/2026-08-10-chatbird-dynamic-island.md`，执行顺序为：

1. 建立共享状态模型、Store 和模式偏好。
2. 扩展完整任务 collection、Codex cwd 和安全事件，同时保留旧面板紧凑投影。
3. 把额度状态迁入 Store，并锁定失败时的额度行/重置额度缓存。
4. 拆分 Claude 确认 coordinator，不改变现有窗口表现。
5. 实现顶部 placement 和两阶段窗口状态机。
6. 实现胶囊及独立的展开工作台框架。
7. 接入完整任务工作台。
8. 接入三类内联 Claude 确认。
9. 接入完整额度工作台和联合刷新。
10. 完成模式切换、状态栏菜单和运行时生命周期。
11. 完成多屏、全屏、键盘、VoiceOver、视觉比较、隐私审计和发布前验证。

只有第 1–4 步验证通过后，才让灵动岛接管真实确认请求；这样不会因新 UI 的中间状态影响正在运行的 Claude 会话。
