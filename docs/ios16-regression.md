# iOS 16 真机回归清单

> v1.0 · 2026-09-22 · 配套 `docs/ios16-compat.md`（兼容层边界与门控清单）
>
> **为什么需要这张表**：CI（`.github/workflows/build-unsigned-ipa.yml`）只做
> `xcodebuild build` + 打无签名 IPA —— **没有 UI 测试**，而且 Xcode 26 **没有 iOS 16
> 模拟器**。也就是说：编译能过 ≠ 在 iOS 16 上能跑。运行时正确性**只能靠真机点一遍**。
> 下面每一条都是这个分支上**真实坏过**的，且都已修好；它们是"别改回去"的护栏。

## 用法

- 改动碰到哪一块，就重点回归哪一条（表里标了"涉及"）
- 出包前（或装上新包后）过一遍全表
- 新修好一个 bug，就补一行：**复现路径 / 期望 / 曾经的故障**

## 清单

| # | 复现路径 | 期望 | 曾经的故障 |
|---|---|---|---|
| 1 | 打开一个很长的会话 | 直接停在**最底部** | 停在**最顶部**（吸底状态被自己的几何变化关掉）；或短一截 / 空白 |
| 2 | 发送消息 / 点"跳到底部" / 唤键盘 | 不闪退，且一次就到最底 | `ScrollViewProxy.scrollTo` 在 SwiftUI 内 trap → 闪退；证据：`logs/*.ips`（4 份，faulting thread 全在 `TranscriptView.scrollToBottom`）。另：点一次到不了底，要点三四次 |
| 3 | 唤起输入法键盘 | 输入框与两侧按钮**跟键盘同步**升降 | 有延迟才出现；按钮漂移到上方；位置被键盘遮住 |
| 4 | 唤起键盘 → 点 `+` | 面板**完整显示在输入框上方**，且**上方内容不动** | 面板被键盘挡住只剩两行；内容区向上抬 8pt；面板通栏占满宽度 |
| 5 | 键盘开着 → 点 `+`（原生 `Menu` 时期） | **不出现空白** | 转写可用高度 499 → 306，键盘收起后仍残留 ~340pt；根因是原生 `Menu` 的 UIKit 呈现让 SwiftUI 键盘避让卡死。**所以 `+` 必须自绘**，见 `docs/ios16-compat.md` |
| 6 | 长会话滚动 + 流式输出 | 不卡顿 | 每个 flush 全量重解析 markdown（O(n²)）；VStack 全量渲染 |
| 7 | 用 `deepseek harness` / `qorder` / `Google Antigravity` 等 agent | 显示各自图标与名称，**能发出消息** | 全被解码成 Claude（图标/名称错），且请求里回传 `claude_code` → 服务端对不上 → **发不出消息** |
| 8 | 向上滑看历史 | 停得住、不被拉回；滑回底部后恢复跟随 | 每次流式都被强行拽到底；或滑上去后不再跟随 |
| 9 | 进任意带 alert / 确认框的页面（设置各页、服务器编辑、MCP、技能、专家…） | 正常打开、不卡死 | 见下方"更新期间写入"一条 |

## 头号护栏：视图更新期间不要写状态

这个分支上**反复复发**的卡死（`bug_type 509`，主线程烧掉几十秒 CPU 后被
scene-update watchdog 杀掉）几乎都是同一个根因，只是每次出现在不同页面：

> 上游 iOS 17 用 `@Observable`（**按属性**追踪，body 没读的属性被写也不失效）；
> 降到 iOS 16 只能改成 `ObservableObject` / `@Published`（**对象级**失效）。
> 于是"在 SwiftUI 自己的更新过程里写一下状态"从无害变成了**自激循环**：
> body 每帧重入、永不提交、主线程再没回到 run loop。

已经踩过并修好的四种形态（别改回去）：

1. `@Published` 挂在**私有标志位**上（上游是普通 `private var`）——共 71 处，已全部还原为 `private var`。
2. `navigationDestination(item:)`（iOS 17+）的降级替身 `navigationDestination(isPresented:)`
   写在"本身就是 settings 栈 destination"的视图里 → iOS 16 每帧重注册导航。
   **改用普通 `NavigationLink { destination }`**。
3. 用 `Binding(get: { x != nil }, set: { if !$0 { x = nil } })` 给 `isPresented:` 桥接可选值。
   SwiftUI 会在自己的更新里写 `false`，而 setter 把 `nil` 写回一个**本来就是 nil** 的值 —— 值永远不变，循环永远不收敛。
   **统一改用 `Binding.presenting(_:)`**（`CodegiOS/DesignSystem/Binding+Presenting.swift`）。
   全仓 23 处已收敛；**新增任何 alert / confirmationDialog / sheet 的可选桥接都必须用它**。
4. 视图 body / destination 闭包里做**同步阻塞 I/O**：`ServerStore.client(for:)` → `SecItemCopyMatching`。
   现在 token 走 `ServerStore` 的内存缓存，body 里不再碰 Keychain。
5. **绑定了 path 的 `NavigationStack` + 任意 `NavigationLink { destination }` 跳转。**
   iOS 16 的导航权威会不停尝试把"绑定的 path"和"实际栈"对齐，而 destination 式跳转
   **没有值可以放进 path**，这个同步永远不成功：它每帧重试、每帧重跑该栈的
   `navigationDestination` 闭包（闭包重建屏幕 → 屏幕 body 重算 → 永不提交帧）。
   Settings 栈因此**不绑定 path**（`RootView.settingsTab`），见那里的长注释。
   > 仍待处理：`FolderCommitsView` / `FolderFilesView` / `FolderChangesView` /
   > `AgentOptionsButton` 里的 destination 式跳转位于**绑定 path 的 `Route` 栈**内，
   > 是同一形态。要修的话，得让这些跳转也走值（`Route` 加 case），不能只改一处。
6. **save-on-change 的 `Binding(get:set:)` 没有同值 guard**（Toggle / Picker /
   TextField / `Set.insert` / 按钮写 `@Published`）。
   SwiftUI 会在自己的更新过程里回写绑定；`@State` / `@Published` 是**对象级**失效，
   同值写入也 invalidate → update pass 自激、永不提交帧 → watchdog 10s 杀进程。
   **统一改用 `Binding.changes(get:set:)`**（同上 helper），或在 setter 开头
   `guard newValue != current`；`Set` 成员资格写入、`Button` 点当前行写 store
   也要在**写之前**比一次。仅 `didSet { guard oldValue != x }` **不够**——
   `@Published` 在 willSet 就发通知。真机 freeze 档案里 `SettingsView.body` /
   `EditorSection.body` / `ChatChannelEditorSheet` / `GroupedRow` 的 AttributeGraph
   自激与 89a76f0 修完后仍残留的 8 条 episode 都落在这一形态。

排查新卡死时的顺序：先看主线程栈落在哪个 body，再检查那条路径上有没有
`@Published` / `@State` 在**绑定 setter** 或**视图更新**里被写，
最后看这个栈是不是"绑了 path 又有 destination 式跳转"。

> 反面教材：`HangProbe` 那套临时探针（body 里 `print` 到重定向文件、
> `queue.sync`、按秒全量读日志）本身就是"更新期间做主线程 I/O"，
> 在排查期间反而成了新的卡死来源，已随 build-61 删除。诊断代码同样要守上面的规矩。

## 相关

- `logs/Codeg-2026-09-21-*.ips`：iOS 16.1.2 上的 4 份崩溃日志，是第 2 条的**唯一证据**，
  保留在仓库里作为回归依据（不是构建产物）。
- 第 5 条的量化数据（`w 0..499` → `w 0..306`、`kb 367`）来自临时诊断面板，
  面板本身已随 build-38 删除；需要复测时再临时加回。
