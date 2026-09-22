# iOS 16 兼容层：边界与门控清单

> v1.0 · 2026-09-22 · 配套 `docs/ios16-regression.md`（真机回归清单）
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
| 新增文件 | `Compat.swift` / `Haptics.swift` / `ScrollMetrics.swift` / CI workflow / 测试脚本 | **无**（上游没有这些文件） |
| 一行 shim 调用 | 玻璃 18+26 处、触感 11、sheet 背景 3、滚动几何 2、zoom 转场 2、默认滚动锚点 1、高度变化 2 | 单行 |
| 一行 API 改名 | `.navigationBarTrailing` 21 处、`.navigationBarTitleDisplayMode` 3 处、`onChange(of:)` 单参形式 18 处 | 单行 |
| **结构性改动（不可避免）** | `@Observable` → `ObservableObject`：30 个类、257 个 `@Published`、23 个 `@StateObject`、4 个 `@EnvironmentObject`、3 个 `@ObservedObject` | **大**：这些文件与上游逐行冲突，合并时需人工过 |

规模：相对 `main` 共 91 个文件、+2432 / −846（含 `logs/` 与文档）；仅 `CodegiOS/` 为
84 个文件、+1474 / −844。

> Observation 那一项是降到 iOS 16 的**固有代价**（Observation 框架本身是 iOS 17+，
> 没有官方 backport）。唯一的替代是引入第三方反向移植（如 Point-Free 的 `Perception`），
> 代价是新增依赖 + 每个 view body 包一层 `WithPerceptionTracking`（漏包会静默不刷新），
> 冲突面并不会明显变小，因此保持现状。

---

## 2. 门控清单

### 已门控（iOS 17/18/26 保持上游行为）

| API | 原生版本 | shim | 调用点 |
|---|---|---|---|
| `GlassEffectContainer` / `.glassEffect` / `.buttonStyle(.glass*)` | 26 | `CodegGlassEffectContainer`、`.codegGlassEffect`、`.codegGlassButtonStyle` | 44 处 |
| `.presentationBackground` | 16.4 | `.codegPresentationBackground` | 3 处 |
| `.onGeometryChange` | 18 | `.codegOnHeightChange` | 2 处 |
| `.sensoryFeedback` | 17 | `.codegSensoryFeedback` | 11 处 |
| `.defaultScrollAnchor(.bottom)` | 17 | `.codegDefaultScrollAnchorBottom` | 1 处（TranscriptView） |
| `matchedTransitionSource` / `navigationTransition(.zoom)` | 18 | `.codegZoomSource` / `.codegZoomTransition` | 2 处（SessionListView） |

### 未门控（附原因）

| API | 原生版本 | 现状 | 为什么不门控 |
|---|---|---|---|
| `Tab(value:)` 构造器 | 18 | 全局 `.tabItem` + `.tag` | `Tab` 是 `TabContent` 不是 `View`，无法用 `@ViewBuilder` 抽象；门控要在 `TabView` 里写**两份**全部 5 个 tab（源文件改动翻倍）。而 `.tabItem` 在 iOS 26 上仍是系统玻璃 tab bar，收益不足以抵消冲突面 |
| `onScrollGeometryChange` | 18 | 全局 UIScrollView introspection | 调用点需要用 `UIScrollView` 直接驱动 `contentOffset`（iOS 16 的 `ScrollViewProxy.scrollTo` 会崩，见回归清单 #2），而原生 API 不提供 scroll view；门控要重构整个调用点 |
| `UITraitDefinition` 自定义 trait | 17 | 全局 `codegCurrentAccentPalette`（`Theme.swift`） | 替换后**全版本一套机制**、调用点不变；门控反而要维护两套 |
| `scrollBounceBehavior` / `scrollClipDisabled` | 16.4 / 17 | 移除 | 影响面小，且相关布局已被重写 |
| `onChange(of:)` 双参 + `initial:` | 17 | 单参形式（+ 需要时的 `onAppear`） | 单参形式在所有版本可用（17+ 只是 deprecation 警告），保持一行改动优于门控 18 处 |

---

## 3. 新增兼容改动时的检查表

1. 能放进 compat 层吗？能，就放那里，别动业务视图。
2. 调用点是不是只有一行 shim 调用？如果超过一行，先想清楚是否值得。
3. 是"门控"还是"替换"？只有"替换后全版本一致且调用点不变"才允许替换（并在上表登记）。
4. 是否**动过键盘避让 / 滚动 inset**？不要动。iOS 16 上 SwiftUI 的键盘 inset 施加在
   比详情页更高的层级，任何"自己算一份"都会**叠加**在上面（build-35/36 的教训）。
5. 改完跑一遍 `docs/ios16-regression.md`。
