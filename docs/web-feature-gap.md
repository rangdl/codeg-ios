# Web 端 vs iOS 端功能差距清单

> 2026-09-29 · 对比基准：web/桌面端 [xintaofei/codeg](https://github.com/xintaofei/codeg)（本地参考副本
> `/data/workspace/test/reference/codeg`）vs 本仓库 `ios16-compat` 分支。
>
> 对比方法：web 端 `src/` 共调用 **470** 个服务端端点（`getTransport().call("…")`），
> iOS 端 `CodegClient*` 共实现 **139** 个，差集 **334** 个；再按功能域归并、剔除
> 桌面专属与 agent 内部工具后整理成下面的清单。排序为**移动端实用性**。

## 一、高实用性（移动端可做、价值明显）

| # | 功能 | Web 端 | iOS 现状 |
|---|---|---|---|
| 1 | **Git 分支 / 暂存 / 合并管理** | `git_merge`、`git_rebase`、stash 全套（push/pop/list/apply/drop/clear/show）、删分支、删远程分支、`git_reset`、`git_init`、remote 增删改、`git_diff_with_branch`、`git_show_file`（历史版本）、`git_commit_files`/`git_commit_branches`、`git_search_authors` | 只有 commit / push / pull / fetch / checkout / new-branch。冲突**检测**有，但现有代码把**解决**推给桌面（`FolderGitModel.swift`："resolve them on desktop or via an agent"）——冲突解决不建议移动端做；stash、分支删除、remote 管理、分支对比很适合 |
| 2 | **Tasks 任务看板** | `work_task_*` 共 **31 个端点** + 看板列/卡片/完成/取消/验收/交付 PR/合并/重试/模板/设置，与 worktree 绑定 | **完全没有**。若用 codeg 管任务流，这是最大缺口（也相当于其余各项之和的工作量） |
| 3 | **Forge 集成**（GitLab/GitHub） | `forge_*` 共 **21 个端点**：issue 列表/详情/新建/评论/labels、merge change、设置 | **完全没有**。移动端看/回 issue 很自然 |
| 4 | **Automations 定时任务** | cron 调度、模板库、启停、调用弹窗（`automation_*` 11 个端点） | **完全没有**。移动端「看状态 / 手动触发 / 暂停」即够用 |
| 5 | **会话 fork（分叉）** | `acp_fork`：从某条历史消息另开会话 | **没有**。重试/改方向时高频；改动小、收益大 |

## 二、中等实用性

| # | 功能 | 说明 |
|---|---|---|
| 6 | **Token 用量统计** | web 有独立页面（token-usage）；iOS 只有消息级字段，无汇总页 |
| 7 | **自定义 agent**（新建/编辑/删除） | `acp_save_custom_agent` / `delete` / `list_custom_agents`；iOS 的 Agents 页只能列表、排序、开关、看配置，**不能创建** |
| 8 | **导入会话** | `import-sessions` 页：从 Claude Code / Codex 等迁移历史会话（一次性，迁移时关键） |
| 9 | **连接管理** | `acp_list_connections` / `disconnect` / `touch` / `get_agent_status` |
| 10 | **日志查看** | logs 设置页（排查问题用） |
| 11 | **备份与恢复** | backup 设置 |
| 12 | **数据 / 配置同步** | data-sync、config-sync |
| 13 | **Science / Office 技能包** | skill-packs 中心的两个 tab（iOS 已有 Experts + Skills 两个等价物） |
| 14 | **Agent 诊断** | `acp_env_diagnostics` + 诊断弹窗 |
| 15 | **停止异步任务 / goal control** | `acp_stop_async_task`、`acp_goal_control` |
| 16 | **清理泄露临时文件** | `acp_scan_leaked_temp` / `acp_reclaim_leaked_temp` |
| 17 | **Web service 设置** | 服务端对外服务配置 |

## 三、低实用性 / 桌面专属（不建议移动端做）

Canvas 画布（拖拽看板）、Pet 桌宠（`pet_*` 21 个端点）、浏览器自动化与设置（Playwright）、快捷键、工作区背景市场（`background_market_*`）、自定义 CSS / 字体、桌面通知与通知声音、关闭行为设置。

## 四、iOS 已覆盖的部分（不要重复做）

会话与流式输出、plan / question / permission 交互、References 与 @ 提及、
终端、文件树、diff、commit、push/pull/fetch、分支切换、Agents 配置（含
Cursor/Kimi/Pi/Hermes/OpenCode/DeepSeek 面板）、Experts、Skills、快捷消息、
Chat Channels、MCP、Model Providers、版本控制、外观、系统、delegation 协作、
feedback/question 开关、文件夹别名。

## 备注

- 若在 Settings stack 里 push `SettingsLeaf` 以外的路由值，`AppModel.settingsPath`
  需改为 `NavigationPath`（强类型 path 会静默丢弃外来值，见回归清单 #12 ⑥）。
- 排序含义：第一梯队为「移动端可做且价值明显」；第二梯队为「可做但收益/频次
  中等或属于一次性场景」；第三梯队依赖桌面交互或本机环境，不建议在 iOS 做。
