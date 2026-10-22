# PR Desk — 规格 v0.1

macOS 原生的 vLLM PR / Issue 工作台，高密度、键盘驱动。Clean room 实现，不参考任何既有工具的源码。

## 1. 范围

- 仓库：仅 `vllm-project/vllm`
- 条目：PR 与 Issue
- 用户：当前 `gh` 登录用户（BugenZhao），所有 "me / you" 语义都以它为准
- 不做：Claude / 终端面板、Task 类条目、Collection、Notes、IDE / worktree 集成

## 2. 技术栈

| 项 | 选择 |
|---|---|
| 系统 | macOS 26+，跟随系统深浅色 |
| 语言 | Swift 6（strict concurrency） |
| 工程 | Tuist（与 MNGA 一致） |
| UI | SwiftUI 搭外壳（窗口、分栏、详情、设置）；主列表用 AppKit `NSTableView`（经 `NSViewRepresentable`），保证几百行下的密度、性能和键盘手感 |
| 正文渲染 | 时间线骨架全部原生（SwiftUI：事件行、头像、作者徽章、折叠、时间、review 状态）。只有每条评论或 review 的**正文**用 `WKWebView` 渲染 GitHub 返回的 `bodyHTML`，配自带 CSS、跟随系统配色，保证代码块、表格、图片、`<details>` 显示正确。WebView 按需创建：折叠的条目不创建，按内容高度自适应，滚动由外层原生容器负责 |
| 存储 | SQLite（GRDB），位于 `~/Library/Application Support/PR Desk/` |
| 网络 | GitHub GraphQL 为主，REST 补充（通知、个别写操作） |
| 鉴权 | 设置里保存了 PAT（存 Keychain）就用它，否则用 `gh auth token` |

## 3. 数据同步

- **跟踪集合**（自动）：`repo:vllm-project/vllm` 下满足任一条件
  - `involves:@me`（作者 / assignee / 被 @ / 评论过）
  - `review-requested:@me`、`reviewed-by:@me`
  - 首次同步回溯 90 天；open 的全部保留，closed/merged 的保留 14 天后自动淡出
- **手动**：`+ Add`（粘贴编号或 URL）加入；`u` untrack 后不再自动加回，除非之后有新的 @me 或 review request
- **增量**：每 60s 用 `updated:>=上次同步时间` 拉增量；选中条目时实时拉详情；窗口激活时立即同步一次
- **限流**：顶栏显示 GraphQL 剩余额度；低于 500 时自动降低轮询频率
- **Inbox**：GitHub Notifications（仅本仓库、仅 participating，不含 watching），未读数显示在 tab、Dock 和菜单栏上；打开条目或按 `n` 即在 GitHub 上标记已读

## 4. 主界面

```
┌ 顶栏：Dashboard | Inbox (n) | + Add                          BugenZhao · vllm-project/vllm · synced 12s · api 4821 ⟳ ┐
├ 列表 ─────────────────────────────────────────────┬ 详情 ──────────────────────────────────────────────┤
│ Filter (/)          643 items   快捷键提示        │ #56492 [Core] Extensible KV cache                  │
│ ▾ Recently viewed 8                               │ by njhill ◆◆  draft  CI ● 16 failed  conflicts     │
│ ▾ Pinned 24                                       │ [H M L] [Pin] [Untrack] [Open ↗]                   │
│ ▾ Focus 20                                        │ Conversation | Checks | Files                      │
│ ▸ All tracked 591                                 │ ...时间线...                                       │
│                                                   │ ┌ 评论框 ──────────────── Comment / Approve … ┐   │
└───────────────────────────────────────────────────┴────────────────────────────────────────────────────┘
```

### 4.1 分组

- **Recently viewed**：最近查看的 8 条
- **Pinned**：`p` 置顶的条目
- **Focus**：open，且未被 `d` 移出（或移出后又有新动态），且满足任一条件：优先级 H；或 Turn = me。例外：自己的 PR 若 30 天没有任何人（不含 bot）的动静，且没标 H，则不进 Focus
- **Review requests**：自动的 review 请求（作者在 PR 打开、转 ready 或 push 前后发出的，基本是 CODEOWNERS），PR 已 ready、我从没参与过；14 天没动静的降到 All tracked。别人发起的、或在其他时间发起的请求视为手动请求，算 Turn = me
- **All tracked**：其余，默认折叠
- 同一条目可同时出现在多个组里；组的折叠状态持久化

### 4.2 列

| 列 | 内容 |
|---|---|
| (标记) | `•` 有未读的他人动态（相对我上次查看） |
| P | 优先级 `H` / `M` / `L` 徽章 |
| # | 编号；PR / Issue 用不同的小图标区分 |
| Title | 标题，后接状态标签（draft、merged、closed、new、on me、req），再接灰色的最新事件摘要，例如 `@xx commented 2h`、`CI passed 3h`、`you reviewed 2d` |
| Author | 用户名 + 组织徽章（见 §5） |
| Review | `✓n` approve 数；`✓ you` / `× you` 我的结论；`req` 请求我 review 且未完成 |
| Turn | `me` / `them` / 空（已关闭） |
| CI | 色点（绿 / 红 / 黄 运行中 / 灰 无）+ 失败数；PR 带 `ready` label 时显示 `rdy` |
| Size | `+add` 绿、`−del` 红（Issue 为空） |
| Age / Upd | 相对时间 |

- 所有列都可点击排序，默认按 Upd 降序；列宽、顺序、显隐都持久化
- 行高约 20pt，字号 11–12pt，数字列用等宽数字

### 4.3 颜色

- 行底色：H 为淡橙，M 为淡黄，L 和无优先级不着色
- Turn = me 用强调色；merged 和 closed 的行整体变淡
- 选中行用系统选中色；以上颜色在深色和浅色下各有一套

### 4.4 过滤

- 自由文本匹配标题、编号、作者
- 支持 token：`is:pr` `is:issue` `is:draft` `is:open` `turn:me` `author:x` `label:x` `ci:fail` `p:h` `org:redhat`

### 4.5 快捷键

| 键 | 作用 |
|---|---|
| `j` / `k`，`↑` / `↓` | 移动 |
| `/` | 聚焦过滤框 |
| `1` / `2` / `3` / `0` | 设为 H / M / L / 清除优先级 |
| `p` | 置顶 / 取消置顶 |
| `d` | 移出 Focus |
| `n` | 标为已读 |
| `o` | 在浏览器打开 |
| `u` | untrack |
| `c` | 聚焦评论框 |
| `⌘R` | 立即同步 |
| `⌘1` / `⌘2` | 切换 Dashboard / Inbox |

## 5. 组织徽章

显示四种：**vLLM committer**、**Inferact**、**Red Hat**、**NVIDIA**。图标用对应 GitHub 组织的头像（缓存到本地）。

判定来源按优先级从高到低，命中即生效，悬停显示命中来源：

1. 手动设置：设置页里的"用户 → 组织"表，可添加，也可强制排除
2. vLLM committer：解析仓库里的 `docs/governance/committers.md`，悬停时显示负责领域（如 "Rust frontend"）。不用 `author_association`，因为 vllm-project 的 MEMBER 范围太广
3. GitHub 组织成员：`Inferact`、`NVIDIA`、`RedHatOfficial` / `redhat-et` / `neuralmagic`（你所在的组织如 Inferact 能看到全部成员，其余只能看到公开成员）
4. 个人资料的 company 字段，例如 `@Inferact`、`Red Hat`、`NVIDIA`
5. 该用户 PR commit 的作者邮箱域名：`redhat.com`、`nvidia.com`、`inferact.ai`
6. 用户名后缀，例如 `-redhat`、`-nv`

用户信息缓存 7 天；committers.md 每天刷新一次。

## 6. 详情面板

- **头部**：标题、作者和徽章、状态（draft / open / merged / closed）、CI 汇总、mergeable / conflicts、labels、创建和更新时间
- **操作**：H / M / L、Pin、Untrack、Open ↗
- **Conversation**：
  - 时间线包括评论、review（含行内评论的摘要和 diff hunk）、push、label、状态变化
  - 可"显示 bot"，可全部展开 / 折叠
  - 自上次查看以来的新内容高亮，并自动滚到第一条新内容
- **Checks**：按状态分组列出 check runs 和 statuses，失败的置顶，点击打开日志 URL
- **Files**（v1 只读）：变更文件列表和 diff
- **写操作**：底部是 Markdown 评论框（支持预览，`⌘↩` 发送）
  - PR：Comment / Approve / Request changes，以带正文的整体 review 提交
  - Issue：仅 Comment
  - 行内代码评论放到 v2，届时在 Files 里实现

## 7. 本地状态（SQLite）

- `items`：PR / Issue 的快照字段 + 原始 JSON
- `item_state`：priority、pinned、focus_dismissed_at、last_viewed_at、tracked、manual
- `users`：login、头像、company、orgs、邮箱域名、committer 领域、来源、fetched_at
- `org_overrides`：手动设置的映射
- `timeline_cache`：详情缓存
- `sync_meta`：同步元数据

## 8. Turn 规则（`me` / `them`）

**我是 PR 作者**，以下任一成立时为 `me`，否则 `them`：

- 存在未处理的 changes requested
- 我上次活动之后，有他人的评论或 review
- CI 失败
- 有冲突

**我是 reviewer**：

- 有待我完成的 review request → `me`
- 我 review 过，且作者在我上次 review 之后 push 或评论了 → `me`
- 其他情况 → `them`

**Issue**：

- assign 给我或 @ 了我，且他人最新评论晚于我的最新评论 → `me`
- 其他情况 → `them`

已关闭的条目留空。

## 9. 里程碑

1. 工程骨架、鉴权、GraphQL 客户端、首次同步和增量同步、列表能显示
2. 分组、本地状态、快捷键、过滤、颜色、排序和列持久化
3. 组织徽章（自动来源 + 手动设置）
4. 详情：头部、Conversation（原生时间线 + WebView 正文）、Checks
5. 写操作：评论、review；Inbox
6. 打磨：Files diff、菜单栏和 Dock 未读数、性能
