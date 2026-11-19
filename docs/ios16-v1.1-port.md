# v1.1.0 → iOS 16 移植记录

> 分支 `ios16-v1.1-compat`，基线 `origin/main` v1.1.0（2026-11-15）。
> 部署目标从 **iOS 26.0 降到 16.0**；上游功能全量保留，另回填了本 fork 独有的五项。

## 一、为什么要单独开分支

上游 v1.1.0 把部署目标定在 iOS 26，`ios16-compat` 分支（v1.0.44）则是
从更早的 `e2d75f9` 独立演进出来的，两边各有 248 / 114 个提交。
直接合并会产生 68 个重叠文件的语义冲突，所以改为「以上游为基 + 降级」。

## 二、降级的四个层次

### 2.1 可观察性：`@Observable` → `ObservableObject`

**这是最大的一块，也是唯一有性能代价的。**

| | 上游 | 本分支 |
|---|---|---|
| 标记 | `@Observable` | `ObservableObject` + `@Published` |
| 类数 | 39 | 39（全部改写） |
| 属性忽略 | `@ObservationIgnored`（48 处） | 去掉标记，普通存储属性 |
| 视图持有 | `@State` / `@Bindable` | `@StateObject` / `@ObservedObject` |
| 注入 | `.environment(obj)` | `.environmentObject(obj)` |
| 读取 | `@Environment(T.self)` | `@EnvironmentObject` |

**代价**：`@Observable` 只在视图读到某个属性时才重绘；`ObservableObject`
任何 `@Published` 变更都通知整个对象。长会话滚动时可能比上游多触发重绘。

**连带损失**：上游用 `withObservationTracking`（iOS 17+）写的两组测试
（`DisclosureStoreTests` 的 3 个用例、`QuietTabSwitchTests` 整份）
无法在本分支表达，已删除。它们守护的正是「重绘粒度」这件事。

### 2.2 视觉：Liquid Glass

`.glassEffect` 28 处、`.buttonStyle(.glass/.glassProminent)` 32 处，
统一收敛到 `DesignSystem/GlassComponents.swift` 的两个方法：

- `codegGlassEffect(tint:in:)` — iOS 26 用原生 glass，更早版本用平铺填充
- `codegGlassButtonStyle(prominent:)` — iOS 26 用 `.glass`，更早用 `.bordered*`

### 2.3 交互 API

| API | 版本 | 处理 |
|---|---|---|
| `TextField(text:selection:)` | iOS 18 | 新建 `ComposerTextView`（`UITextView` 包装），读 `selectedRange` |
| `onChange(of:initial:_:)` | iOS 17 | 改单参数签名，原 `initial: true` 的补 `onAppear` |
| `onScrollGeometryChange` | iOS 18 | `ScrollMetrics.swift` 直读 `UIScrollView` |
| `onGeometryChange` | iOS 18 | `codegOnWidthChange` / `codegOnHeightChange` |
| `sensoryFeedback` | iOS 17 | 自定义 `CodegHaptic` + `UIFeedbackGenerator` |
| `navigationDestination(item:)` | iOS 17 | `isPresented` + 状态解包 |
| `Tab(value:)` builder | iOS 18 | `.tabItem` + `.tag` |
| `MagnifyGesture` | iOS 17 | `MagnificationGesture`（回调值语义不同，已改） |
| `UITraitBridgedEnvironmentKey` | iOS 17 | accent 改用进程全局 + trait 刷新 |
| `presentationBackground` 等 | iOS 16.4 | `Compat.swift` 的可用性分支 |

### 2.4 iOS 16 导航纪律（真 bug 修复）

上游按 iOS 26 写，**6 个视图在同一层挂了 2–5 个 `.sheet`**。iOS 16 只认
最后一个，其余静默失效——与 v1.0.40 事故同源。已全部改为单一 `enum` 路由：

| 视图 | sheet 数 |
|---|---|
| `SessionDetailView` | 5（详情/消息导航/标签/移动/pi 信任） |
| `SessionRowSheets` | 2（标签/移动） |
| `SessionListView` | 2（标签筛选/批量移动） |
| `ProjectListView` | 2（浏览/克隆） |
| `ProjectDetailView` | 2（提交/凭据） |
| `ChatChannelDetailView` | 2（编辑/二维码） |

## 三、回填的本 fork 独有功能

上游没有这五项，从 `ios16-compat` 移植：

| 功能 | 文件 |
|---|---|
| Office 文档 QuickLook 预览 | `FolderFilesView` + `FolderPaths.isOfficePreviewable` |
| 智能体安装日志流 | `AgentInstallMonitor`（订阅 `app://agent-install`） |
| 引用选择器（4 组） | `MentionReference` / `MentionInsertModel` / `MentionInsertSheet` |
| Automations 设置页 | `AutomationsSettingsView` + `CodegClient+Automations` |
| Token Usage 设置页 | `TokenUsageSettingsView` + `CodegClient+TokenUsage` |

另补 `FolderVisibility`（`ActivityModel` 一直在引用但合并时缺失）
和 `FolderDetail.alias` 字段。

## 四、验证

| 项 | 结果 |
|---|---|
| 构建（CI dev 通道） | ✅ IPA 12.8 MB |
| 单元测试 | ✅ 1393 个 / 205 suite |
| 真机 | ❌ **未验证** |

### 必须在真机上确认的

构建和单元测试绿了**不代表功能正确**，以下几处必须实机点一遍：

1. **多 sheet 改造**（最高风险）：会话详情的详情/消息导航/标签/移动、
   列表的标签筛选与批量移动、项目的浏览/克隆、提交与凭据弹窗——逐个打开一次。
2. **`@Observable` 改造**：任何界面是否还随数据更新（尤其流式回复、
   安装进度、活动列表）。
3. **Office 预览**：打开一个 .docx / .xlsx / .pptx。
4. **安装日志**：在 Agents 页执行一次安装，看是否出现日志行。
5. **引用选择器**：`+` → References，四个标签的计数与插入。
6. **长会话滚动**：确认没有明显卡顿（`ObservableObject` 的代价）。
7. **accent 换色**：设置里切换配色，确认立即生效（trait 刷新路径）。
