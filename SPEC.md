# PR Desk — 规格 v0.1

macOS 原生的 vLLM PR / Issue 工作台，高密度、键盘驱动。Clean room 实现，不参考任何既有工具的源码。

## 1. 范围

- 仓库：仅 `vllm-project/vllm`
- 条目：PR 与 Issue
- 用户：当前 `gh` 登录用户（BugenZhao），所有 "me / you" 语义都以它为准
- 分诊结果的 source of truth：GitHub Project **Bugen's Board**（`vllm-project` 的 #56），见 §3.1
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

- **跟踪集合**：`repo:vllm-project/vllm` 下满足任一条件
  - `involves:@me`（作者 / assignee / 被 @ / 评论过）
  - `review-requested:@me`、`reviewed-by:@me`
  - `label:rust`
  - 在 board 上（包括在网页上手动加的）
  - 首次同步回溯 90 天；closed/merged 的保留 14 天后淡出
- **手动**：`+ Add`（粘贴编号或 URL）把条目加到 board 上（不设 Status），之后就一直跟踪
- **增量**：每 60s 用 `updated:>=上次同步时间` 拉增量；选中条目时实时拉详情；窗口激活时立即同步一次
- **限流**：顶栏显示 GraphQL 剩余额度；低于 500 时自动降低轮询频率
- **Board**：每次同步都拉 board 的全部条目（Status、Priority、Comment）；board 上不在本地的条目按 id 补拉
- **Inbox**：GitHub Notifications（仅本仓库、仅 participating，不含 watching），未读数显示在 tab、Dock 和菜单栏上；打开条目或按 `n` 即在 GitHub 上标记已读

## 3.1 分诊（Bugen's Board）

分诊是手动的决定，写在 board 上；条目的实时状态（Turn、approve、CI、冲突、merged/closed）由 API 算出，不手动维护。app 从不自动改 Status。

| Status | 意思 | GitHub 订阅 |
|---|---|---|
| （不在 board 上，或没有 Status） | 未分诊 | 不变 |
| **Working** | 现在要管 | 不变 |
| **Backlog** | 想管，但以后再说（包括停滞了、暂时不想关心的） | 不变 |
| **Skipped** | 质量不高或优先级不高，暂时忽略 | UNSUBSCRIBED（只在参与或被 @ 时通知） |
| **Muted** | 彻底不管，相当于友好的 close | UNSUBSCRIBED，并把已有的通知线程设为 ignored（完全不通知）；GitHub 不支持对单个 PR / issue 设 IGNORED，所以还没有通知线程的条目之后被 @ 仍会通知。Inbox 和未读数不计 Muted 条目的通知 |
| **Done** | 已合并或关闭；由 board 自带的 workflow 设置，app 不写 | 不变 |

- 名字只描述"我做了什么"，不评价 PR 本身，因为 org 里的人可能看得到 board
- 从 Skipped / Muted 改成别的状态时，订阅恢复为 SUBSCRIBED（Muted 的通知线程也取消 ignored）
- 改订阅需要 token 有 `notifications` scope（`gh auth refresh -h github.com -s notifications`）
- **Priority**：board 上的单选字段，High / Medium / Low
- **Comment**：board 上的文本字段，作为这条的备注（通常是下一步要做什么）
- **其他 Status**：`Python Parity Backlog` 属于另一个 tracker，app 完全忽略这些条目（不显示，也不改）。旧的 `Good`、`Pending` 当作 Working，`Stale` 当作 Backlog；open 的条目上出现 Done（比如重新打开了）当作未分诊
- **被唤醒**：Skipped 的条目在设为 Skipped 之后若有人直接找我，会回到 Triage，带一个原因标签，Status 本身不变。"直接找我"指：
  - 被 @
  - 被人手动请求 review（不是作者在打开、转 ready 或 push 时发出的自动请求）
  - 我参与过的条目上，他人在我最后一次活动之后评论或 review
- 写操作立即在本地生效，再写到 GitHub；同步时以 board 为准

## 4. 主界面

```
┌ 顶栏：Dashboard | Inbox (n) | + Add                          BugenZhao · vllm-project/vllm · synced 12s · api 4821 ⟳ ┐
├ 列表 ─────────────────────────────────────────────┬ 详情 ──────────────────────────────────────────────┤
│ Filter (/)          643 items   快捷键提示        │ #56492 [Core] Extensible KV cache                  │
│ ▾ Recently viewed 8                               │ by njhill ◆◆  draft  CI ● 16 failed  conflicts     │
│ ▾ Pinned 2                                        │ [Triage Working Backlog Skipped Muted] [H M L –]   │
│ ▾ Working 9                                       │ [Pin] [Open ↗]   Comment: ...                      │
│ ▾ Good 1                                          │ Conversation | Checks | Files                      │
│ ▾ Triage 180                                      │ ...时间线...                                       │
│ ▸ Backlog 31                                      │                                                    │
│                                                   │ ┌ 评论框 ──────────────── Comment / Approve … ┐   │
└───────────────────────────────────────────────────┴────────────────────────────────────────────────────┘
```

### 4.1 分组

从上到下：

- **Recently viewed**：最近查看的 8 条（本地）
- **Pinned**：`p` 置顶的条目（本地）
- **Working**：Status = Working 的 open 条目，approve 了的 PR 除外；Turn = me 的排在前面
- **Good**：Status = Working、已 approve 的 open PR
- **Triage**：未分诊的 open 条目，加上被唤醒的 Skipped 条目；downvote 过的作者的条目沉到底部
- **Backlog**：Status = Backlog 的 open 条目，默认折叠
- **Recently closed**：最近 14 天 merged / closed 的条目，默认折叠
- **Skipped**、**Muted**：对应 Status 的 open 条目，默认折叠

除 Recently viewed 和 Pinned 外，每个条目只出现在一个组里。组的折叠状态持久化。过滤时显示所有匹配项，忽略折叠。

### 4.2 列

| 列 | 内容 |
|---|---|
| (标记) | `•` 有未读的他人动态（相对我上次查看） |
| P | 优先级 `H` / `M` / `L` 徽章（来自 board） |
| # | 编号；PR / Issue 用不同的小图标区分 |
| Title | 状态图标 + 标题（开头的 `[..]` / `xx:` 标签变淡），再接灰色的最新事件摘要（如 `@xx commented 2h`、`you reviewed 2d`）；被唤醒的条目带原因标签；有 board Comment 时在最后显示备注 |
| Author | 用户名 + 组织徽章（见 §5） |
| Review | 绿色 ✓ + approve 总数（含我）；我 approve 过时 ✓ 变成实心圆；我 request changes 时后面多一个红 ✗。和 CI 列同样的结构：小标记 + 数字，固定位置 |
| Turn | `review`（请求我 review 且未完成）/ `me` / `them` / 空（已关闭） |
| CI | 色点：绿 通过 / 红 失败 / 黄 运行中 / 灰 被取消；带 `ready` label 时实心，否则空心；后面固定位置显示失败数 |
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
- 支持 token：`is:pr` `is:issue` `is:draft` `is:open` `is:unread` `is:pinned` `is:first` `is:regular` `status:triage|working|backlog|skipped|muted` `turn:me` `author:x` `label:x` `ci:fail` `p:h` `org:redhat` `vote:down` `merged:>=10`；前面加 `-` 取反

### 4.5 快捷键

| 键 | 作用 |
|---|---|
| `j` / `k`，`↑` / `↓` | 移动 |
| `/` | 聚焦过滤框 |
| `w` / `b` / `s` / `m` | Status 设为 Working / Backlog / Skipped / Muted；再按一次同一个键清除 Status（回到未分诊） |
| `1` / `2` / `3` / `0` | Priority 设为 H / M / L / 清除 |
| `p` | 置顶 / 取消置顶 |
| `n` | 标为已读 |
| `o` | 在浏览器打开 |
| `+` / `-` | upvote / downvote 作者 |
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

## 5.1 对人投票

- 每个人可以是 upvote / 默认 / downvote，只存在本地
- 作者名后显示 👍 / 👎 小图标（列表、详情头部、时间线）
- downvote 的作者：他的条目在 Triage 里沉到底部，其余分组不受影响；不会自动改 Status
- upvote 目前只显示图标，没有其他效果
- 操作：选中行按 `+` / `-`（再按一次取消），右键行或右键人名，设置 → Votes 管理
- 过滤：`vote:up` / `vote:down` / `vote:none`

## 5.2 贡献者标记

- 统计每个作者在 vllm 合并过的 PR 数（GitHub search，每批 40 人，每周刷新；为 0 的每天刷新）
- 合并数 ≥ 阈值（默认 10，设置 → Affiliations 可改）：作者名后显示绿色描边 seal 图标；已有组织徽章的作者不显示
- 合并数 = 0：显示灰色 "1st"
- 悬停显示具体数字；列表、详情头部、时间线都显示
- 过滤：`merged:N`、`merged:>=N`（也支持 `>`、`<`、`<=`）、`is:regular`、`is:first`
- 只存本地，不写 board，也不影响分组

## 6. 详情面板

- **头部**：标题、作者和徽章、状态（draft / open / merged / closed）、CI 汇总、mergeable / conflicts、labels、创建和更新时间
- **操作**：Status（Triage / Working / Backlog / Skipped / Muted）、Priority（H / M / L / –）、Pin、Open ↗
- **Comment**：board 的 Comment 字段，可直接编辑，回车或失焦时保存
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
- `item_state`：pinned、viewed_at、seen_at（只存本地）
- `board_item`：board 条目的缓存（item id、Status 及其设置时间、Priority、Comment）
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

- 有待我完成的 review request（PR 不是 draft）→ `me`
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
