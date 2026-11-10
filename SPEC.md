# PR Desk — 规格 v0.1

macOS 原生的 vLLM PR / Issue 工作台，高密度、键盘驱动。Clean room 实现，不参考任何既有工具的源码。

## 1. 范围

- 仓库：`vllm-project/vllm`；另有 `BugenZhao/vllm` 上 parity agent 的 staging PR，只在 Parity tab 里出现（§3.2）
- 条目：PR 与 Issue
- 用户：当前 `gh` 登录用户（BugenZhao），所有 "me / you" 语义都以它为准
- 分诊结果的 source of truth：GitHub Project **Bugen's Board**（`vllm-project` 的 #56），见 §3.1
- 不做：Claude / 终端面板、Task 类条目、Collection、Notes、IDE / worktree 集成
- Grok Bot：只把条目派给 bot（§3.3），不运行 agent，也不读 bot 的对话或状态

## 2. 技术栈

| 项 | 选择 |
|---|---|
| 系统 | macOS 26+，跟随系统深浅色 |
| 语言 | Swift 6（strict concurrency） |
| 工程 | Tuist（与 MNGA 一致） |
| UI | SwiftUI 搭外壳（窗口、分栏、详情、设置）；主列表用 AppKit `NSTableView`（经 `NSViewRepresentable`），保证几百行下的密度、性能和键盘手感 |
| 正文渲染 | 整条时间线（事件行、头像、作者徽章、折叠、时间、review 状态和 GitHub 返回的 `bodyHTML` 正文）在**一个** `WKWebView` 页面里渲染，配自带 CSS、跟随系统配色，保证代码块、表格、图片、`<details>` 显示正确。页面常驻：切换条目时只发新数据，按条目 id 原地更新，滚动位置、展开状态和已加载的图片都保留；折叠的条目不生成正文。滚动、跨评论选择文字、查找（⌘F）都由 WebKit 负责 |
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
- **手动**：在 GitHub 上把条目加到 board（不设 Status 即为未分诊），下次同步就会跟踪
- **增量**：定时（默认每 5 分钟，设置 → General 可改，前后台一样）用一次 advanced search 拉增量：`(involves:@me OR review-requested:@me OR reviewed-by:@me OR label:rust) updated:>=上次同步时间`，增量每页 20 条（首次同步每页 50 条、分时间窗并行）；⌘R 立即同步
- **详情**：每次同步后在后台预取 Working、Good、Triage、Inbox、Pinned、Recently viewed 里条目的详情，只取缓存缺失或比条目旧的，并发 2；选中条目时先显示缓存，缓存比条目旧或超过 2 分钟再实时拉一次。一次详情是两个并行的 GraphQL 查询：正文和时间线一个，PR 的 checks 一个
- **限流**：底部状态栏显示 GraphQL 剩余额度；低于 500 时自动降低轮询频率
- **Board**：最多每 3 分钟拉一次 board 的全部条目（Status、Priority、Comment），⌘R 时必拉；board 上不在本地的条目按 id 补拉
- **Inbox**：GitHub Notifications（仅本仓库和 parity 的 fork、仅 participating，不含 watching），未读数显示在 tab、Dock 和菜单栏上；打开条目或按 `n` 即在 GitHub 上标记已读

## 3.1 分诊（Bugen's Board）

分诊是手动的决定，写在 board 上；条目的实时状态（Turn、approve、CI、冲突、merged/closed）由 API 算出，不手动维护。app 从不自动改 Status，唯一的例外是下面的 approve。

| Status | 意思 | GitHub 订阅 |
|---|---|---|
| （不在 board 上，或没有 Status） | 未分诊 | 不变 |
| **Working** | 现在要管 | 不变 |
| **Backlog** | 想管，但以后再说（包括停滞了、暂时不想关心的） | 不变 |
| **Skipped** | 质量不高或优先级不高，暂时忽略 | UNSUBSCRIBED（只在参与或被 @ 时通知） |
| **Muted** | 彻底不管，相当于友好的 close | UNSUBSCRIBED（和 Skipped 一样） |
| **Done** | 已合并或关闭；由 board 自带的 workflow 设置，app 不写 | 不变 |

- 名字只描述"我做了什么"，不评价 PR 本身，因为 org 里的人可能看得到 board
- 设成 Skipped / Muted 时先记下当时的订阅（SUBSCRIBED 或 UNSUBSCRIBED），改成别的状态时恢复成记下的那个；没有记录的（比如在加这条规则之前设的）恢复为 SUBSCRIBED。所以撤销一次 skip 会准确回到原来的订阅
- **Skipped 和 Muted 只在 app 里有区别**：GitHub 已经不能对单个 PR / issue 彻底屏蔽通知（GraphQL 的 `IGNORED` 和 REST 把通知线程设为 ignored 都不生效，后者只会删掉线程订阅），所以两者在 GitHub 上都只是 UNSUBSCRIBED：被 @ 或被请求 review 时仍会通知。app 里的区别是：
  - Skipped 会被唤醒（见下），Muted 不会，一直留在 Muted
  - Inbox 和未读数不计 Muted 条目的通知，Skipped 的照常计
- 改订阅需要 token 有 `notifications` scope（`gh auth refresh -h github.com -s notifications`）
- **我自己开的条目**：没有 Status 时当作 Working（显示和过滤都算），不进 Triage，因为没有什么要分诊的；这个默认不写到 board。按 `w` / `b` / `s` / `m` 照常写 Status；在详情里选 Triage 不清除这个默认
- **我 approve 的 PR**：board 自带的 "Code review approved" workflow 把 board 上的 PR 设成 `Good`（当作 Working，approved 的进 Good 分组）。不在 board 上（或已 archive）的 PR 它管不到，所以 app 把它加到 board 并设为 `Good`；已在 board 上的交给 workflow，app 不写。在 app 里 approve 的立即加；在别处（网页）approve 的，在读 board 的那次同步之后加：只看上次检查（减去 search 的 index 余量）之后的 approve，第一次检查只记下起点，所以加这条规则之前的 approve 不补。加上后又被拿下 board 的，同一个 approve 不再加回
- **Priority**：board 上的单选字段，High / Medium / Low
- **Comment**：board 上的文本字段，作为这条的备注（通常是下一步要做什么）；app 只读，在列表标题后显示
- **其他 Status**：`Python Parity Backlog` 属于另一个 tracker，app 完全忽略这些条目（不显示，也不改）。旧的 `Good`、`Pending` 当作 Working，`Stale` 当作 Backlog；open 的条目上出现 Done（比如重新打开了）当作未分诊
- **被唤醒**：Skipped 的条目在设为 Skipped 之后若有人直接找我，会回到 Triage，带一个原因标签，Status 本身不变。"直接找我"指：
  - 被 @
  - 被人手动请求 review（不是作者在打开、转 ready 或 push 时发出的自动请求）
  - 我参与过的条目上，他人在我最后一次活动之后评论或 review

  对被唤醒的条目按 `s`（或在详情里选 Skipped）是重新 skip：再写一次 Skipped、刷新设置时间，并重新 UNSUBSCRIBED（被 @ 时 GitHub 会自动订阅）
- **网页上改的 Status**：同步时发现 Status 在 app 之外变了（和本地缓存不同），订阅按上面的规则跟着改，和在 app 里改一样；只在变化的那一次改，之后在 GitHub 上手动改的订阅不会被改回去。Done（board 的 workflow 设的）、从 board 移除、archive 不算；第一次读 board 时没有可比较的，也不改
- 写操作立即在本地生效，再写到 GitHub；同步时以 board 为准

## 3.2 Parity（Rust parity agent）

Rust frontend 的 parity agent（`richard` 仓库的 `notes/vllm-rust-parity-agent-runbook.md`）每天在 fork 上开 staging PR，我 review；approve 后我手动让 agent promote 成 upstream PR，upstream approve 后再让它 merge。app 只负责看这条流水线、在里面 review，不运行 agent，也不读 agent 的 ledger：阶段全部从 GitHub 上的状态算出来。

- **staging PR**：`BugenZhao/vllm` 上 `richard-for-bugen[bot]` 开的 PR（`author:app/richard-for-bugen`），和主仓库一起增量同步，回溯同样 90 天。fork 上我自己开的 PR（比如挂在 upstream PR 下的 stack）不是 staging PR，不进 Parity tab，只在 Inbox 里出现
- **对应关系**：按分支名。staging 是 `richard/parity-fix-<slug>`、`richard/parity-impl-<slug>` 或 `richard/parity-run-<slug>`，promote 出来的 upstream PR 是我开的 `bz/rust-parity-<slug>`（run PR 的 slug 带 `run-` 前缀，两边一样）。只认 open 或 merged 的 upstream PR；同一个 slug 有多个时取 open 的，其次最新的。agent promote 时有时会缩短 slug（`parity-fix-drop-incomplete-call-markup` → `bz/rust-parity-drop-incomplete-call`），所以没有同名 upstream 的 staging PR 退而认一个没被别的 staging PR 认领、开得比它晚、标题相同或 slug 是它 slug 在 `-` 处截断的前缀的 upstream PR（标题相同优先，其次 slug 最长）
- **我的决定**就是 GitHub 上的动作，agent 下次运行时读取：
  - Approve：可以 promote
  - 评论或 Request changes：agent 下次运行时回复或修改
  - Park（转成 draft）：以后再说，agent 把条目停放为 `backlog`；Resume（转回 ready for review）撤销
  - Close：不要，agent 记为 `accepted-divergence`
- staging PR 不上 board，没有 Status / Priority，`w` / `b` / `s` / `m` 和数字键对它们不生效；也不进 Dashboard（Recently viewed、Pinned 也不收）。promote 出来的 upstream parity PR 虽然是我开的，也只在 Parity tab 里：它们由 agent 写、由 agent merge，混在 Working 里只是噪音；它们的 Status / Priority 照常可以设，通知照常进 Inbox，打开它们（链接、前进后退）会跳到 Parity tab。Dashboard 上它们本该在的分组标题后面注明数量，如 `Working 19 (+10 in Parity)`（open 的才算，跟着过滤走）
- **Turn**（staging PR）：approve 了是 `me`（等我让 agent promote）；draft 是 `them`；否则我从没评论或 review 过，或 agent 在我最后一次评论 / review 之后 push 或回复了，是 `me`，其余是 `them`
- 未读、摘要、Turn 都把 agent 的评论和 push 当作对方的动作（不像别处的 bot 那样不计）；详情的时间线也总是显示 agent 的评论和 push，不受 "Show automated" 影响
- **Parity tab** 的分组，从上到下：
  - **Review**：open、非 draft、没 approve、Turn = me 的 staging PR
  - **Discussing**：同上，但 Turn = them：我评论过，等 agent 回复
  - **Approved**：我 approve 了、还没有 upstream PR：等 promote
  - **Upstream**：open 的 upstream parity PR 本身（`bz/rust-parity-*`），所以 Review、CI、Turn 列都是 upstream 的。staging PR 这时不单独列出
  - **Parked**：draft 的 staging PR，默认折叠
  - **Landed**：14 天内合并的 upstream parity PR 本身（和 Upstream 一样列 upstream PR，合并后同一行从 Upstream 移到 Landed），默认折叠
  - **Rejected**：14 天内没合并就关闭的 staging PR，默认折叠
- tab 在 Dashboard 和 Inbox 之间，显示等我处理的数量（`Parity 3`）：Review 组，加上 Upstream 组里 Turn = me 的（upstream 有人 review、CI 失败、冲突）
- 列：Author（总是 agent 或我）换成 **Link**，显示另一端 PR 的状态图标和编号：Upstream 和 Landed 里的 upstream PR 显示它的 staging PR；悬停显示仓库和标题
- GitHub App（如 agent）的头像不能按用户名取，用同步时拿到的头像 URL

## 3.3 派给 Grok Bot

我在 Grok Bot 聊天里用 emoji 给 bot 派活；app 用同样的说法，把选中的条目发给 bot（经 app 内置的 grokbot CLI，`grokbot ask --no-wait`），结果照旧回到 Grok Bot 里：

- 👀 Investigate（`e`）→ Richard Loop：让 agent 进一步调查
- 🔥 Track（`f`）→ Richard Loop：加到 Notion tracker 下一个工作日；Richard 会把它在 board 上设为 Working，所以 app 不动 board
- 🚀 Merge（`r`）→ Merger：按 merge skill 走 CI 并合并；只对仓库里 open 且 approved（reviewDecision = APPROVED，和 Good 分组同一条件）的 PR 生效，其余条目右键菜单里是灰的、按键忽略（staging PR 走 parity agent）；给 PR 号就是授权，所以发之前总要确认

👀 和 🔥 都会让 Richard 开 agent session（现在是 Claude Code，以后也可能是 Codex、Kimi 等），它把链接追加到 board 的 **Session** 文本字段里（空格分隔，旧的在前；👀 的条目不在 board 上时它会加上，但不设 Status）。app 只读这个字段：有 session 的条目在标题后显示 `terminal` 图标，悬停列出链接；详情顶部的按钮打开最新的一个（有多个时按钮带菜单列出全部），`t`（或右键菜单 Open Agent Session）打开选中条目各自最新的一个。链接不限 agent，网页链接和桌面 app 自己的 deep link 都行：app 认得的 agent（`AgentSession.known`：Claude Code、Codex、Kimi Code）显示它的名字；Claude Code 的网页链接改写成 `claude://code/session_…` 在 Claude app 里打开，Codex 的 `codex://threads/<id>`（ChatGPT app）和 Kimi Code 的 `kimi-lite://sessions/<id>`（Kimi Lite）原样交给系统打开。其余链接以域名称呼（app 的 deep link 以 scheme 称呼），原样打开。换 agent 时只需让 Richard 写那个 agent 的 session 链接，要显示名字或改写链接再往 `known` 加一条。

消息是 `[Sent from PR Desk] <emoji> <链接> <标题>`，多选时一条消息、每条目一行（🚀 即一个批次）。按住 ⌥（`⌥E` / `⌥F` / `⌥R`，或右键菜单里按住 ⌥ 出现的「…」项）先打开发送面板，可以附一段给 bot 的备注，放在消息最后、空一行之后原样发出；🚀 和重发也总是先打开这个面板（备注可空，`⌘↩` 发送，`esc` 取消）。按下就在标题后画出 emoji：发送中半透明，CLI 返回成功后变实并存进本地数据库，失败则撤掉（不留痕迹）。发过的条目在标题后显示对应的 emoji，悬停显示发给谁、多久之前和当时的备注（每种请求只记最后一次）。bot 名字在 Settings → Grok Bot 里改（名字、唯一前缀或 id）；CLI 的登录和其他 grokbot 共用（`grokbot login`）。构建时 `scripts/embed-grokbot.sh` 按脚本里固定的 commit 编译 grokbot-cli（按 commit 缓存），签名后放进 `Contents/Helpers/`。测试时 dry-run 只记日志不发。

## 3.4 同步 pin 到 Yab

Settings → General → Yab 打开后（默认关），app 把 Pinned 单向同步到 Yab 侧边栏：指定 space（默认 Inferact）pinned 区里名为 `PR Desk` 的 folder，经 Yab 的 `yab exec` 执行，不弹确认。

- **Pin**：加一个休眠的 tab，folder 不存在时自动创建。这个 PR 已开在今天的 tab 里就移进 folder；已被我保留在别处就不动，等它离开后再加。
- **Unpin**：关闭 app 加的那个 tab。正看着的 tab 等离开后再关；已移出 folder 的算我的，不关。
- **在 Yab 里关掉 tab**：pin 不变，也不会加回来；取消再重新 pin 才会再加。Yab 这边的改动不回传。
- **时机**：pin 变化时和每轮同步后各对账一次。Yab 只能读写屏幕上的 space，所以 Yab 没开或目标 space 不在屏幕上时先不动，等之后的轮次，Settings 里显示在等什么。
- 测试时 dry-run 只记日志不动 Yab；测试副本有自己的偏好设置，默认不同步。

## 4. 主界面

```
┌ 顶栏：                    Dashboard | Parity (n) | Inbox (n)  🔍 Filter (/)  ⟳  ▣ │ Conversation | Checks | Files ┐
├ 列表 ─────────────────────────────────────────────┬ 详情 ──────────────────────────────────────────────┤
│                                                   │ #56492 [Core] Extensible KV cache                  │
│ ▾ Recently viewed 8                               │ by njhill ◆◆  draft  CI ● 16 failed  conflicts     │
│ ▾ Pinned 2                                        │ [Triage Working Backlog Skipped Muted] [H M L –]   │
│ ▾ Working 9                                       │ [Pin] [Open ↗]   Comment: ...                      │
│ ▾ Good 1                                          │ Conversation | Checks | Files                      │
│ ▾ Triage 180                                      │ ...时间线...                                       │
│ ▸ Backlog 31                                      │                                                    │
│                                                   │ ┌ 评论框 ──────────────── Comment / Approve … ┐   │
├───────────────────────────────────────────────────┴────────────────────────────────────────────────────┤
└ 状态栏：j/k move · w/b/s/m … (快捷键提示)   BugenZhao · vllm-project/vllm · Board #56 · 403 items · Synced 12s ago · API quota 4,821 left ┘
```

状态栏左侧平时是快捷键提示；写操作进行中时换成这次写入（转圈 + 如 `#63887 → Working`、`🔥 #63887 → Richard Loop`、`Approve #63887`），完成后打勾停 3 秒再恢复；失败时直接恢复，错误照旧弹框。覆盖 board 的 Status / Priority、发给 Grok Bot、评论 / review、Close、Park / Resume；同时有多个时显示最新的一个。

重启后回到上次的样子：Dashboard / Inbox、选中的条目（只是选中，不算打开：不标已读、不进 Recently viewed）、详情面板是否显示。

### 4.1 分组

从上到下：

- **Recently viewed**：最近查看的 8 条（本地）。选中一条即算查看并标已读，没有延迟；只算我自己的选中，列表自己选中的（比如所在行离开列表后选中邻行、启动时恢复选中）不算。在 Recently viewed 里选中只标已读、不改它的顺序，免得 `j` 在最上面两行间来回跳
- **Pinned**：`p` 置顶的条目（本地）
- **Working**：Status = Working 的 open 条目，加上我自己开的、没有 Status 的 open 条目；approve 了的 PR 除外；我自己开的排最前
- **Good**：同上，已 approve 的 open PR；我自己开的排最前
- **Triage**：别人开的、未分诊的 open 条目，加上被唤醒的 Skipped 条目；downvote 过的作者的条目沉到底部
- **Backlog**：Status = Backlog 的 open 条目，默认折叠；我自己开的排最前
- **Recently closed**：最近 14 天 merged / closed 的条目，默认折叠
- **Skipped**、**Muted**：对应 Status 的 open 条目，默认折叠

除 Recently viewed 和 Pinned 外，每个条目只出现在一个组里。所有组始终显示，空的也显示（数量为 0）；组标题的 tooltip 说明这个组装的是什么、和 board 的关系。组的折叠状态持久化，展开 / 折叠不改变滚动位置。过滤时显示所有匹配项，忽略折叠。改了 Status 的条目带动画移到新的组（新的组折叠时淡出），选中落到原位置的下一条；展开 / 折叠和过滤也一样带动画，不论行数多少。组标题之间有分隔线

**Stack**：同一组里属于同一个 stack 的 PR 排在一起，base 在上、栈顶在下（按 position），整组放在其中最靠 base 的那个成员按当前排序该在的位置（排序列任意）。stack 是 GitHub 官方的 stack（`stack` / `stackEntry`），也包括同一仓库里 base 分支正是另一个 PR head 分支的链（GitHub 不知道的 stack）。分在不同组里的成员各归各组，不另画占位行；组里只剩一个成员时不算 stack。Recently viewed、Pinned、Inbox 保持自己的顺序，不聚拢。Parity tab 的各组同样聚拢

### 4.2 列

| 列 | 内容 |
|---|---|
| (标记) | `•` 有未读的他人动态（相对我上次查看） |
| （整行） | 已关闭的条目整行变淡；draft PR 也整行变淡（只保留未读点），一眼和待 review 的 PR 分开 |
| P | 优先级（来自 board），用 SF Symbol：H 双感叹号（红）、M 单感叹号（橙）、L 横杠（灰） |
| （stack） | 窄列，在 # 左边：聚在一起的 stack 成员之间画一条竖线，节点是条目状态色的圆点（draft 为空心）；官方 stack 是实线，按分支推出的链是虚线。悬停显示 stack 编号和位置、base 分支 |
| # | 编号；PR / Issue 用不同的小图标区分 |
| Title | 状态图标 + 标题（开头的 `[..]` / `xx:` 标签变淡），被唤醒的条目带原因标签；发给过 Grok Bot 的条目带对应 emoji，board 上有 Session 的带 `terminal` 图标（§3.3）；有 board Comment 时接着显示备注；灰色的最新事件摘要（如 `@xx commented 2h`、`you reviewed 2d`）始终靠右对齐；被截断的文字（标题、备注、摘要）悬停时 tooltip 显示全文 |
| Author | 头像 + 用户名（首次贡献者为斜体）+ 投票图标；可信标记（seal、组织徽章，见 §5、§5.2）靠右对齐 |
| Review | 裸 ✓ + approve 总数（含我）：别人的 PR，我 approve 过时为绿色，只有别人 approve 时为灰色；我自己的 PR（自己不能 approve）在 reviewDecision = APPROVED（approve 已满足合并要求，和 Good 分组同一条件）时为绿色，否则灰色；我 request changes 时后面多一个红 ✗。和 CI 列同样的结构：小标记 + 数字，固定位置 |
| Turn | `review`（请求我 review 且未完成）/ `me` / `them` / 空（已关闭） |
| CI | 色点：绿 通过 / 红 失败 / 黄 运行中 / 灰 被取消；带 `ready` label 时实心，否则空心；失败 / 运行中的数量在悬停提示里 |
| Size | `+add` 靠左、`−del` 靠右；用比系统绿 / 红深一档的颜色（GitHub diff 配色），和 Review / CI 区分（Issue 为空）；至少放得下 `+8888 −8888` |
| Age / Upd | 相对时间 |

- 所有列都可点击排序，默认按 Upd 降序；列宽、顺序、显隐都持久化
- 行高约 20pt，字号 11–12pt，数字列用等宽数字

### 4.3 颜色

- 行底色：H 为淡橙，M 为淡黄，L 和无优先级不着色
- Turn = me 用正文颜色加粗（不用颜色，颜色留给优先级）；merged 和 closed 的行整体变淡
- 选中行用系统选中色；以上颜色在深色和浅色下各有一套

### 4.4 过滤

- 过滤框在顶栏列表一侧（`/` 聚焦，回车或空时按 esc 回到列表）；自由文本匹配标题、编号、作者
- 支持 token：`is:pr` `is:issue` `is:draft` `is:open` `is:unread` `is:pinned` `is:first` `is:regular` `status:triage|working|backlog|skipped|muted` `turn:me` `author:x` `label:x` `ci:fail` `p:h` `org:redhat` `vote:down` `merged:>=10`；前面加 `-` 取反

### 4.5 快捷键

| 键 | 作用 |
|---|---|
| `j` / `k`，`↑` / `↓` | 移动 |
| `esc` | 取消选中，详情面板回到空状态；没有选中时清空过滤 |
| `⌘` / `⇧` 点击 | 多选；下面的快捷键和右键菜单作用于所有选中条目（右键的行不在选区里时只作用于该行）。切换类操作按整体切换：都已是该状态则清除，否则全部设置 |
| `/` | 聚焦过滤框 |
| `w` / `b` / `s` / `m` | Status 设为 Working / Backlog / Skipped / Muted；再按一次同一个键清除 Status（回到未分诊）；被唤醒的 Skipped 条目按 `s` 是重新 skip，不清除 |
| `⌘Z` / `⇧⌘Z` | 列表有焦点时，撤销 / 重做列表里的操作：Status、Priority、Pin、作者投票（Mark as read、Close 不能撤销）；同一条目的 board 写入按顺序发出，撤销不会抢在原操作前面到达 GitHub；文本框里仍是文字的撤销 |
| `1` / `2` / `3` / `0` | Priority 设为 H / M / L / 清除 |
| `p` | 置顶 / 取消置顶 |
| `n` | 标为已读；已读的标回未读（最近一条他人动态起未读，仅本地，GitHub 通知不变） |
| `o` / `↩`，`⌘O` | 在浏览器打开（`⌘O` 在任何焦点下都可用，作用于当前选中项） |
| `u`，`⇧⌘O` | 打开作者的 GitHub 主页（也在行的右键菜单里；`⇧⌘O` 在任何焦点下都可用） |
| `⇧⌘C`，`⌘C` | 复制 GitHub 链接，多条一行一个（`⇧⌘C` 在任何焦点下都可用：列表有焦点时是所有选中条目，否则是详情里的条目；`⌘C` 只在列表里）。行也可以横向拖出去，作为带标题的链接 |
| `+` / `-` | upvote / downvote 作者 |
| `e` / `f` / `r` | 发给 Grok Bot：👀 Investigate / 🔥 Track / 🚀 Merge（§3.3；🚀 和重发先打开发送面板）；加 `⌥` 先打开面板写备注 |
| `t` | 打开 agent session（board 的 Session 字段，最新的一个；有桌面 app 的在 app 里；§3.3） |
| `c` | 聚焦评论框 |
| `⌘R` | 立即同步 |
| `⌘1` / `⌘2` / `⌘3` | 切换 Dashboard / Parity / Inbox |
| `⌥⌘1` / `⌥⌘2` / `⌥⌘3` | PR 详情切到 Conversation / Checks / Files |
| `⌘B` | 显示 / 隐藏详情面板（重启后保持） |
| `⌃⌥⌘D` | 全局：在 desk 里打开 Yab 当前 tab 的 issue / PR（§6 从浏览器回到 desk） |
| `⌘V` | 列表有焦点时，打开剪贴板里链接指向的 issue / PR |
| `⌥↑` / `⌥↓` | 沿选中 PR 的 stack 移到下一层（往 base / 往栈顶，§6） |

## 5. 组织徽章

徽章表示"可信"：**vLLM committer**、**Inferact**、**Red Hat**、**NVIDIA**，以及近半年贡献最多的公司（按总体和 Rust frontend 的 top contributors 选出）：**AMD**、**Intel**、**IBM**、**Hugging Face**、**Mistral AI**、**Meta**、**Google**、**DaoCloud**、**Huawei**、**Microsoft**、**Alibaba**、**Ant Group**、**ByteDance**、**Moonshot AI**、**Arm**、**Samsung**、**EmbeddedLLM**。图标都内置在 app 里，不走网络，尽量用透明底的图形标志、不带文字：vLLM、Inferact、NVIDIA、AMD（箭头）、Meta、Huawei、Mistral AI、DaoCloud、Alibaba（阿里云标志）、Ant Group、Moonshot AI 多来自 Simple Icons（AMD、Moonshot 深色模式下为白色）；Red Hat、Google、Hugging Face、Microsoft、ByteDance 的 GitHub 组织头像本身就是透明底标志，取 128px 的 PNG 内置；只有文字 logo 的（Intel、IBM、Arm、Samsung、EmbeddedLLM）画成品牌色小方块加简写。vLLM 另有低一档的灰色徽章（logo 去色），给不是 committer 的 `vllm-project` 组织成员和仓库 collaborator（triage 及以上权限）。

判定来源按优先级从高到低，命中即生效，悬停显示命中来源：

1. 手动设置：按人、按组织存在本地（`orgOverride`），可添加，也可强制排除（隐藏检测到的徽章）
   - 右键列表行的 **Author's Affiliation**、右键详情头部或时间线里的人名 **Affiliation**：列出全部组织（带各自的徽章图标），已有完整徽章的打勾（vLLM 的灰色档不算）；列表和时间线的菜单在单个人时于每项下方注明来源（检测来源，或 "Added manually" / "Hidden manually"）；选一个组织切换：没有就手动加上（之前手动隐藏过的检测徽章则恢复），已有就去掉（手动加的删掉，检测到的改为手动隐藏）。多选行时作用于所有作者，部分有的显示短横、选了给全部加上
   - **Clear Manual Affiliations** 删掉这个人的全部手动设置，回到检测结果
   - 设置 → Affiliations 里的表同样可增删；改动立即反映到列表和详情
2. vLLM committer：解析仓库里的 `docs/governance/committers.md`，悬停时显示负责领域（如 "Rust frontend"）；不在其中、但在 `.github/CODEOWNERS` 里的人（code owner，需要 write 权限）也拿彩色徽章，悬停显示负责的路径（前 3 条，其余计数），`org:committer` 同样匹配。其次是灰色档：`vllm-project` 组织成员，再其次是仓库 collaborator（列 collaborator 需要 push 权限，没有就跳过）。不用 `author_association`：它挂在单个条目上，不按人，也随查看者权限变化
3. GitHub 组织成员：每天拉 `Inferact`、`NVIDIA` / `ai-dynamo`、`RedHatOfficial` / `redhat-et` / `neuralmagic` 的成员列表（你所在的组织如 Inferact 能看到全部成员，其余只能看到公开成员）；大公司（`amd`、`intel`、`google` 等）公开成员太多，不拉列表，只看用户自己公开的组织
4. 个人资料的 company 字段，按整词匹配（`intel` 匹配 `@intel`、`Intel Corporation`，不匹配 `Intelligence`），例如 `@Inferact`、`Red Hat`、`AMD`、`@ROCm`
5. 该用户 PR commit 的作者邮箱域名（含子域名，如 `us.ibm.com`）：`redhat.com`、`nvidia.com`、`amd.com`、`intel.com` 等
6. 用户名后缀，例如 `-redhat`、`-nv`、`-amd`、`-intel`、`-ibm`

用户信息缓存 7 天；committers.md、CODEOWNERS、组织成员和 collaborator 每天刷新一次。

过滤：`org:vllm` 匹配两档，`org:committer` 只匹配 committer，`org:member` 只匹配灰色档。

## 5.1 对人投票

- 每个人可以是 upvote / 默认 / downvote，只存在本地
- 作者名后显示 👍 / 👎 小图标（列表、详情头部、时间线）
- downvote 的作者：他的条目在 Triage 里沉到底部，其余分组不受影响；不会自动改 Status
- upvote 目前只显示图标，没有其他效果
- 操作：选中行按 `+` / `-`（再按一次取消），右键行或右键人名，设置 → Votes 管理
- 过滤：`vote:up` / `vote:down` / `vote:none`

## 5.2 贡献者标记

- 统计每个作者在 vllm 合并过的 PR 数（GitHub search，每批 40 人，每周刷新；为 0 的每天刷新）
- 合并数 ≥ 阈值（默认 10，设置 → Affiliations 可改）：显示绿色描边 seal 图标，和组织徽章一起靠右；已有组织徽章的作者不显示
- 合并数 = 0 且没有任何组织徽章：作者名用斜体，表示"没有记录、需要留意"，不占徽章位置（悬停显示原因）；有组织徽章的首次贡献者不变斜体（`is:first` 仍能过滤出来）
- 悬停显示具体数字；列表、详情头部、时间线都显示
- 过滤：`merged:N`、`merged:>=N`（也支持 `>`、`<`、`<=`）、`is:regular`、`is:first`
- 只存本地，不写 board，也不影响分组

## 6. 详情面板

- **头部**：标题、作者和徽章、状态（draft / open / merged / closed）、CI 汇总、mergeable / conflicts、labels、创建和更新时间
- **Stack**：PR 在 stack 里时（官方 stack 取自详情查询；不在官方 stack 里的按分支在本地条目里找链），头部显示一个小表：标题行 `Stack 66533 · 3 of 4 · 2 merged`，第一行是 base 分支（`main`），往下是 position 1…N。一起合并的相邻 PR（合并时间相差一分钟内，即一次 stack merge）折叠成一行 `2 merged together · 5h ago`，点开展开；单独合并的照常一行。每行是状态图标、编号、标题，右侧注明：已合并 / 关闭的时间；parity staging PR 提升出的上游 PR（`⬆#65636` 及其状态，免得 fork 上 closed 的层被看成被拒）；open 的 PR 仍挂在已合并或关闭的 PR 的分支上时标橙 `on merged #N`。当前 PR 加粗高亮，点其他行在 app 内打开。`⌥↑` / `⌥↓`（列表或对话有焦点时）沿 stack 往 base / 往栈顶移动。时间线里显示加入 / 移出 stack 的事件
- **操作**：Status（Triage / Working / Backlog / Skipped / Muted）、Priority（H / M / L / –）、Pin、Open ↗；parity 的 staging PR 换成 Park / Resume（§3.2）
- **Conversation**：
  - 时间线包括评论、review（含行内评论的摘要和 diff hunk）、push、label、状态变化
  - "Show automated" 默认关闭，关闭时隐藏自动化内容：
    - bot 和 agent 账号（`[bot]` 账号、mergify、github-actions、vllm-agent 等）的事件
    - 只有命令的评论：`[AUTOMATED] …`，或每行都是 `@codex review`、`@claude review`、`/ci …` 这类命令（最多 3 行）
  - 列表的摘要、Turn、未读都不计这些账号的动作（列表不抓评论正文，所以命令评论在列表里仍算参与）
  - 点人名或头像打开他的 GitHub 主页（详情头部的作者名同样）；右键人名有投票、打开主页、复制用户名
  - 可全部展开 / 折叠；没有正文的评论和 review（多是不带文字的 approve）只显示一行头部，不能展开
  - Reactions 显示在描述、评论、review 和行内评论下方（悬停看是谁），点一下加上或撤回自己的；卡片和行内评论头部的笑脸按钮（悬停时出现）弹出全部 8 种。点了先在本地生效，写失败再恢复
  - 自上次查看以来的新内容高亮，并自动滚到第一条新内容
- **Checks**：按状态分组列出 check runs 和 statuses，失败的置顶，点击打开日志 URL
- **Files**：变更文件列表和 diff，同样是一个 `WKWebView` 页面；每个文件默认折叠，文件名过长时省略目录部分，文件头滚动时吸顶；按扩展名语法高亮（highlight.js，新旧两侧分别高亮）；复制时不带行号和 +/-；可切换自动换行；展开的文件接近屏幕时才生成 diff，⌘F 查找前补齐
  - 文件头有 GitHub 的 Viewed 勾选框（只有框，不带文字；右键文件头也可以），和 GitHub 网页同步：勾上折叠该文件，取消再展开；勾过之后又被新 push 改动的文件框变橙色；工具栏显示已看数量。点了先在本地生效，写失败再恢复；取不到标记时不显示勾选框
- **站内链接**：详情里指向本仓库 issue / PR 的链接在 app 内打开：已在列表里的直接跳过去（必要时展开所在分组、清掉过滤）；不在的临时取来，放进列表顶部的 **Opened from links** 分组（只在本次运行内保留，不写库），可以 Add to Desk（`a`，进 Triage），设置 Status / 优先级 / Pin 也会顺带加入。指向当前条目某条评论的链接直接展开并滚到那条评论。⌘-click 和 ↗ 按钮仍在浏览器打开
- **从浏览器回到 desk**：`⌃⌥⌘D`（全局快捷键，Carbon hot key，不需要辅助功能权限；也在 Go 菜单和菜单栏图标的菜单里）读 Yab 当前在前的 tab（`yab exec`，只读），把窗口叫到前面，按上面站内链接的规则打开它指向的 issue / PR：在列表里的直接选中，在 desk 上但被藏起来的展开 / 清掉过滤后选中，不在的取来放进 **Opened from links**。这算一次打开（标已读、进 Recently viewed）。链接里的 `/files`（或 `/changes`）、`/checks` 切到对应的详情 tab；`#issuecomment-…`、`#discussion_r…`、`#pullrequestreview-…` 等对话里出现那条评论后滚过去（缓存里还没有的，等实时详情到了再滚）。tab 不是这两个仓库的 issue / PR 时弹窗说明。不用 Yab 时：列表有焦点时 `⌘V` 粘贴链接、把链接拖到列表上，或在过滤框输入链接后按 `↩`，效果相同；过滤框里的 `#123` 只在列表里没有匹配项时按 `↩` 才去取，否则 `↩` 照旧回到列表
- **前进 / 后退**：⌘[ / ⌘]（以及鼠标侧键）在选中过的条目间来回，回到某条目时恢复它的滚动位置和展开状态
- **写操作**：底部是 Markdown 评论框（支持预览，`⌘↩` 发送）；open 的条目可以 Close：PR 直接关，issue 选 completed / not planned。框里有内容时先作为评论发出再关（Close with comment）。关之前要确认，没有快捷键
  - PR：Comment / Approve / Request changes，以带正文的整体 review 提交
  - Issue：仅 Comment
  - 行内代码评论放到 v2，届时在 Files 里实现

## 7. 本地状态（SQLite）

- `items`：PR / Issue 的快照字段 + 原始 JSON，带所在仓库（编号只在仓库内唯一）
- `item_state`：pinned、viewed_at、seen_at、各 Grok Bot 请求最后一次的发送时间和备注、pin 在 Yab 里对应的 tab id（只存本地，按条目的 node id）
- `board_item`：board 条目的缓存（item id、Status 及其设置时间、Priority、Comment、Session）
- `users`：login、头像、company、orgs、邮箱域名、committer 领域、来源、fetched_at
- `org_overrides`：手动设置的映射
- `timeline_cache`：详情缓存（附条目的更新时间，预取据此判断是否过期）
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
5. 写操作：评论、review、关闭；Inbox
6. 打磨：Files diff、菜单栏和 Dock 未读数、性能
