# iOS 16 兼容层：边界与门控清单

> v1.2 · 2026-09-28 · 配套 `docs/ios16-regression.md`（真机回归清单）
>
> 上游 `xintaofei/codeg-ios` 的目标是 iOS 26，本分支（`ios16-compat`）把它降到
> iOS 16.0，以便在 iOS 16.1.2 的设备上通过 TrollStore 安装。本文说明**兼容改动放在哪、
> 为什么这么放**，以及每个降级 API 是"门控"还是"替换"。

---

## 0. 三条原则

1. **兼容逻辑集中在 compat 层**，不散落到业务视图里。
   新增文件（对上游**零冲突**）：
   - `CodegiOS/DesignSystem/Compat.swift` —— `#available` 门控 shim（sheet 背景、几何、滚动锚点、zoom 转场）
   - `CodegiOS/DesignSystem/Haptics.swift` —— 触感（iOS 17+ 走原生 `.sensoryFeedback`）
   - `CodegiOS/DesignSystem/ScrollMetrics.swift` —— `onScrollGeometryChange` 的 iOS 16 替代（UIScrollView introspection）
   - `CodegiOS/DesignSystem/GlassComponents.swift` —— 玻璃层（iOS 26 原生 / 其余平铺填充）
   - `.github/workflows/build-unsigned-ipa.yml`、`scripts/test_agent_type_wire.py`

2. **调用点最多一行 shim**。调用点与上游的差异应当是一行、可预测、易合并的；
   绝不为兼容而**分叉整个视图**。

3. **新 API 用 `#available` 门控，而不是删除或全局替换**。
   即"iOS 17/18/26 保持上游行为，只有 iOS 16 走回退"。这一条是对最初做法的纠正：
   最初 `5c904a8` 是把不支持的 API **直接删掉/全局替换**（`.defaultScrollAnchor(.bottom)`、
   `Tab(value:)`、`sensoryFeedback`、zoom 转场……），导致 iOS 26 用户也一起降级，
   并且让"route 1 保留 iOS 26 体验"只兑现了玻璃那一半。

---

## 1. 兼容面（与上游的冲突面）

| 类型 | 位置 | 与上游冲突面 |
|---|---|---|
| 新增文件 | `Compat.swift` / `Haptics.swift` / `ScrollMetrics.swift` / `MentionInsertModel.swift` / `MentionInsertSheet.swift` / `ReferenceChipsView.swift` / `MentionReference.swift` / CI workflow / 测试脚本 | **无**（上游没有这些文件） |
| 一行 shim 调用 | 玻璃 39 处（effect 15 + button 24）、触感 9、sheet 背景 3、滚动几何 1、zoom 转场 2、高度变化 1 | 单行 |
| 一行 API 改名 | `.topBarTrailing`→`.navigationBarTrailing` 22 处（上游 21 处）、`onChange(of:)` 单参形式 17 处 | 单行 |
| 订阅包装 | `@ObservedObject var` 取代裸 `let`/`var` 接收模型（见下方「订阅缺口」），现共 21 个调用点 | 单行，但合并上游时必须还原成裸 `let` |
| **结构性改动（不可避免）** | `@Observable` → `ObservableObject`：29 个类、267 个 `@Published`、23 个 `@StateObject`、4 个 `@EnvironmentObject`、21 个订阅包装 | **大**：这些文件与上游逐行冲突，合并时需人工过 |

> **订阅缺口（迁移最容易漏的一类）**：上游是 `@Observable`，在 `body` 里读一个裸
> `let model` 的属性会自动建立依赖；换成 `ObservableObject` 之后必须显式包
> `@ObservedObject`，否则视图永远停在首帧渲染出来的内容上。典型症状是**转圈/loading
> 不消失**或**列表空白**——而模型其实早就加载好了，所以看起来像网络或连接故障。
>
> `9be8b11` 修了 `AgentOptionsSheet` 一处并留了排查记录；本分支随后补齐
> `FolderTerminalView`（终端 tab 两个「Starting terminal…」不消失）与后续新页面。
> 截至 v1.2 共 **21 个 `@ObservedObject` 调用点**（另有 4 处出现在注释里）：
> `ActivityView`、`ProjectListView`、`ProjectDetailView`（×2）、`FolderDetailContent`
> （`ProjectDetailView.swift` 内）、`FolderChangesView`、`FolderCommitsView`（×2）、
> `GitStatusStrip`、`FolderTerminalView`、`ServerListView`、`ComposeInsertSheet`、
> `SessionActionsMenu`（`SessionDetailView:374`）、`MentionInsertSheet`、
> `LiveTextRun`×2（`TimelineNodeBody`，流式文本/推理叶节点）、`SettingsView`、
> `AboutView`、`AgentDetailView`、`AgentRow`、`ChannelRow`、`AppModel`（`RootView:406`）。
> 新增页面（如 @ 菜单 `MentionInsertSheet`）从第一天起就是 `@ObservedObject`，不再欠账。
>
> 判断标准是**该视图的 `body` 是否读了模型的 `@Published` 状态**。只在 action 里用
> （调用方法、写属性）的裸 `let` **不需要**包装，例如 `CommitSheet`、
> `AgentConfigKimiView`、`AgentConfigPiView`、`TranscriptView`（有意不订阅）。
> 合并上游时这些 `@ObservedObject` 都要还原成裸 `let`——`@Observable` 类型不满足
> `ObservableObject`，编译器会直接报错把位置全部列出来。

规模：相对 `main` 共 108 个文件、+4400 / −1036（含 `logs/` 与文档）；仅 `CodegiOS/` 为
97 个文件、+3080 / −1034。

> Observation 那一项是降到 iOS 16 的**固有代价**（Observation 框架本身是 iOS 17+，
> 没有官方 backport）。唯一的替代是引入第三方反向移植（如 Point-Free 的 `Perception`），
> 代价是新增依赖 + 每个 view body 包一层 `WithPerceptionTracking`（漏包会静默不刷新），
> 冲突面并不会明显变小，因此保持现状。

---

## 2. 门控清单

### 已门控（iOS 17/18/26 保持上游行为）

| API | 原生版本 | shim | 调用点 |
|---|---|---|---|
| `.glassEffect` / `.buttonStyle(.glass*)` | 26 | `.codegGlassEffect`、`.codegGlassButtonStyle` | 39 处（15 + 24） |
| `.presentationBackground` | 16.4 | `.codegPresentationBackground` | 3 处 |
| `.onGeometryChange` | 18 | `.codegOnHeightChange` | 1 处 |
| `.sensoryFeedback` | 17 | `.codegSensoryFeedback` | 9 处 |
| `matchedTransitionSource` / `navigationTransition(.zoom)` | 18 | `.codegZoomSource` / `.codegZoomTransition` | 2 处（SessionListView） |
| `onScrollGeometryChange` | 18 | `.codegOnScrollMetricsChange` | 1 处（TranscriptView） |

> 已移除的两个门控（不要再引入）：
> `CodegGlassEffectContainer`（`GlassComponents.swift`，iOS 26 的 `GlassEffectContainer` 包装）
> 与 `.codegDefaultScrollAnchorBottom`（`Compat.swift`，`.defaultScrollAnchor(.bottom)` 包装）——
> 两者都是**零调用**的死代码，倒置重构后 transcript 不再需要默认滚动锚点，
> 而玻璃容器在本项目里从来没有调用点。

### 未门控（附原因）

| API | 原生版本 | 现状 | 为什么不门控 |
|---|---|---|---|
| `Tab(value:)` 构造器 | 18 | 全局 `.tabItem` + `.tag` | `Tab` 是 `TabContent` 不是 `View`，无法用 `@ViewBuilder` 抽象；门控要在 `TabView` 里写**两份**全部 5 个 tab（源文件改动翻倍）。而 `.tabItem` 在 iOS 26 上仍是系统玻璃 tab bar，收益不足以抵消冲突面 |
| `onScrollGeometryChange` | 18 | 全局 UIScrollView introspection | 调用点需要用 `UIScrollView` 直接驱动 `contentOffset`（iOS 16 的 `ScrollViewProxy.scrollTo` 会崩，见回归清单 #2），而原生 API 不提供 scroll view；门控要重构整个调用点 |
| `UITraitDefinition` 自定义 trait | 17 | 全局 `codegCurrentAccentPalette`（`Theme.swift`） | 替换后**全版本一套机制**、调用点不变；门控反而要维护两套 |
| `scrollBounceBehavior` / `scrollClipDisabled` | 16.4 / 17 | 移除 | 影响面小，且相关布局已被重写 |
| `onChange(of:)` 双参 + `initial:` | 17 | 单参形式（+ 需要时的 `onAppear`） | 单参形式在所有版本可用（17+ 只是 deprecation 警告），保持一行改动优于门控 17 处 |

> `.navigationBarTitleDisplayMode`（iOS 14+，不涉及门控）现全分支 36 处：上游 0 处。
> 其中 1 处在 `screenTitle` 修饰符内部，其余 35 处是本分支新增的设置/表单页自带
> 的「compact 大标题」修饰——不是上游改名，是新增调用，合并时零冲突。

---

## 3. 新增兼容改动时的检查表

1. 能放进 compat 层吗？能，就放那里，别动业务视图。
2. 调用点是不是只有一行 shim 调用？如果超过一行，先想清楚是否值得。
3. 是"门控"还是"替换"？只有"替换后全版本一致且调用点不变"才允许替换（并在上表登记）。
4. 是否**动过键盘避让 / 滚动 inset**？不要动。iOS 16 上 SwiftUI 的键盘 inset 施加在
   比详情页更高的层级，任何"自己算一份"都会**叠加**在上面（build-35/36 的教训）。
5. 是否**动过导航 / 弹层机制**？iOS 16.0–16.3 的雷区，不要踩：
   - 同一视图**不要同时挂 `.sheet` 与 `navigationDestination(...)`**：destination 在 16.4 之前
     不可靠，会被同视图的 sheet 挤坏 —— **点击当场卡死、页面不出现**。两种健康形状：
     全用 sheet（Experts / Skills / MCP），或零 sheet 全 push（Agents、Chat Channels）。
   - 同一视图**不要挂多个 `.sheet`**：多个弹层用一个 `.sheet(item:)` + `Identifiable` 枚举路由。
   - 在 Settings stack 里 push `SettingsLeaf` 以外的值（如 `ChatChannelsRoute`）时，
     `AppModel.settingsPath` 必须是 **`NavigationPath`**：强类型 path 会**静默丢弃**外来值，
     症状是「点击毫无反应」（不报错、不跳转）。
   - 跨层级共存是可以的：`RootView` / `SettingsSheet` 的 sheet 在外、destination 在其内容的
     stack 内，一直正常。
   - 见回归清单 #12（含 7 步试错链，别再走回头路）。
6. 改完跑一遍 `docs/ios16-regression.md`。

---

## 4. 逐文件标注：合并上游时谁会挡路

按 diff 内容自动分类（`git diff origin/main...HEAD -- CodegiOS/`，**98 文件**）：

| 类别 | 文件数 | 行数 | 合并上游时的行为 |
|---|---|---|---|
| **A 新增文件** | 7 | +1018 | **零冲突** —— 上游没有这些文件，`git merge` 碰不到 |
| **C1 Observation 迁移** | 29 | +767 / −572 | **逐行冲突** —— 上游 30 个 `@Observable` 文件里 29 个被迁移（`TimelineNode.swift` 未动，其 `@Observable` 只在注释里） |
| **C2 单行 shim / 改名** | 43 | 约 +8 / −10 净改 | 单行冲突，形状可预测（`.glassEffect` → `.codegGlassEffect`、`topBarTrailing`、`onChange(of:)` 单参、`@StateObject`…） |
| **B 功能 / 结构改动** | 19 | 约 +1500 / −450 | **需人工** —— 与 iOS 16 无关，是功能修复与重构 |

### B 类清单（合并时真正花时间的 19 个文件，随分支演进，以 `git diff --numstat` 为准）

```
+270 -121  Features/SessionDetail/TranscriptView.swift       倒置列表重构 + 间距
+161  -48  Features/SessionDetail/ComposeBar.swift            "+" 面板自绘
+140   -0  Resources/Localizable.xcstrings                    本地化目录（新增词条）
+113  -45  Models/AgentType.swift                             agent 类型解码
+110  -84  Features/Settings/ChatChannels/ChatChannelsSettingsView.swift  零 sheet、纯 push（#12）
 +60  -10  Features/Settings/Mcp/McpSettingsView.swift        MCP 页解码/布局
 +58   -2  Features/SessionDetail/ContentBlockView.swift
 +44  -28  Features/Settings/ChatChannels/ChatChannelEditorSheet.swift    可 push（embedsNavigationStack）
 +41  -43  App/RootView.swift                                 + settingsPath 类型改 NavigationPath
 +41   -1  Features/Projects/Terminal/FolderTerminalView.swift 断网重连横幅
 +33   -8  Features/SessionDetail/ComposeInsertSheet.swift
 +28   -0  Models/McpModels.swift                             mcp_scan_local 对象/数组兼容
 +23   -5  DesignSystem/AgentIcon.swift
 +20   -0  Models/DirectoryEntry.swift
 +17   -8  Features/Settings/Agents/AgentsSettingsView.swift
 +17   -8  Networking/CodegClient.swift
  +8   -0  Networking/CodegClient+Folders.swift
  +6  -10  Features/Activity/ActivityView.swift
  +2   -2  Networking/WireRequests.swift
```

> `App/AppModel.swift`（`settingsPath: [SettingsLeaf]` → `NavigationPath`）也属 B 类：
> 上游是强类型 path，合并时必须保留 `NavigationPath`，否则 Chat Channels 的 push 会静默失效
> （回归清单 #12 的②）。

注：`SessionDetailViewModel`（+230/−97）、`LiveTurn`（+37/−27）等同时属于 C1 与 B——
它们既做了 Observation 迁移也承载了快照去重 / reattach 等功能修复，合并时按 C1 流程
（先取上游版本再机械迁移）走完后，还需对照本清单核对功能修复是否丢掉。

### 合并上游的顺序

1. **先合并，再跑机械迁移。** C1 那 29 个文件的冲突形状几乎完全一样（上游新增的
   `@Observable` 类与属性要变成 `ObservableObject` + `@Published`）。解冲突时**直接采用上游
   版本**，然后在合并结果上统一迁移一遍，比在冲突里逐个手改快得多。
2. **C2 那 43 个文件**的冲突通常是"上游改了同一行"，按一行 shim 的规则处理即可。
3. **B 那 19 个文件逐个看。** 这些是功能修复，上游很可能也需要 —— **优先反向提交给上游**，
   让分歧消失，而不是每次合并都人工过一遍。其中 `TranscriptView` 的倒置重构是最大的一笔
   （+261/−118），它和 iOS 16 无关，纯粹是滚动方案的替换。
