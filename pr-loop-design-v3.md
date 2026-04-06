# PR Loop Shell 工具设计方案（改进版）

## 1. 目标

实现一个**全部由 shell 脚本组成**的 PR 监测与处理工具。当它在某个目录启动时，应先确认该目录是一个 GitHub 仓库的根目录，然后持续扫描该仓库的所有 open PR，并按统一流程对每个 PR 进行处理。

工具的核心目标：

- 尽量少的脚本数量
- 通用逻辑集中复用
- 状态可恢复、可回退
- 对并发和异常有较强鲁棒性
- 能与 `claude code` 非交互模式配合工作
- 控制 GitHub API 调用成本，避免快速耗尽 Rate Limit

---

## 2. 总体设计原则

### 2.1 阶段真值只来自 GitHub comment

每个 PR 的阶段分为：

- `plan`
- `impl`
- `review`
- `finished`

阶段**不以本地状态文件为真值**，而是通过 GitHub 上仍然存在的特定 marker comment 实时计算得到。

这样设计的好处是：

- 删除 marker comment 可以自然回退阶段
- 本地状态损坏时不会影响阶段判定
- 阶段状态与 PR 实际讨论串保持一致

### 2.2 本地 status file 只记录“处理进度”和轻量缓存

本地状态文件只记录：

- 已处理过的 comment id
- 已处理过的 sub comment id
- 上次处理时的 head sha
- 上次整体快照 hash
- 上次看到的 PR `updatedAt`
- 一句 hint
- 更新时间

本地文件**不保存 comment 正文**，避免体积膨胀、状态漂移和回退困难。

### 2.3 单 PR 独占锁

每个 PR 对应一个独立的 flock 文件。处理某个 PR 前必须先拿锁，这样即使多个 loop 实例同时运行，也不会重复处理同一个 PR。

### 2.4 通用逻辑集中在库文件中

- 与 GitHub 无关的通用能力：放到 `lib/core.sh`
- 与 Git / GitHub 相关的能力：放到 `lib/gh.sh`

这样能最大化复用，减少重复代码。

### 2.5 昂贵查询前必须有轻量拦截

不要在每轮循环里对每个 PR 都抓全量 comments。应先用轻量字段（如 `updatedAt`）做第一层过滤，只有疑似变化的 PR 才进入深度查询和 snapshot 计算。

---

## 3. 推荐目录结构

```text
pr-loop/
├── pr-loop.sh        # 主循环：先调 issue-scan，再扫 PR、派发 worker
├── issue-scan.sh     # 扫 open issue；必要时创建 seed branch 和 PR
├── worker.sh         # 单个 PR 的完整处理流程
├── statectl.sh       # 给 claude code 调用：安全写入受限业务状态
└── lib/
    ├── core.sh       # 通用能力：日志、原子写、repo 校验、路径、JSON 状态读写
    └── gh.sh         # 所有 Git/GitHub 相关操作
```

总共 6 个 shell 文件，已经足够覆盖第一版实现。

---

## 4. 各模块职责

## 4.1 `pr-loop.sh`

主循环入口，只做调度，不处理复杂业务。

### 关键职责

- 检查当前目录是否是 GitHub repo root
- 初始化 repo 对应的状态目录
- 每轮先调用 `issue-scan.sh` 扫描同 repo 的 open issues
- 定期扫描所有 open PR
- 对每个 PR 调用 `worker.sh`

### 建议关键函数

- `main`
- `loop_once`
- `dispatch_pr`

---

## 4.1.1 `issue-scan.sh`

issue 扫描入口，只负责“issue 是否需要先被提升为 seed PR”这件事。

### 关键职责

- 扫描当前 repo 的所有 open issues
- 判断 issue 是否已经有关联的 open PR
- 若无关联 PR，则创建 `cc-happy/issue-<id>` 分支
- 新分支必须从 repo 默认分支切出，且除一个空的 `PROGRESS.md` 外与默认分支完全一致
- 将该分支 push 到远端后创建 PR
- 新创建 PR 的 title 和 body 必须直接复制自 issue 的 title 和 body

### 关联规则

- 首选关联信号：PR head branch 名精确等于 `cc-happy/issue-<id>`
- 这个命名同时也是自动创建 seed PR 时必须使用的 branch 名

### 建议关键函数

- `main`
- `scan_open_issues`

---

## 4.2 `worker.sh`
处理单个 PR 的完整生命周期，是整个系统的核心协调器。

### 关键职责

1. 获取该 PR 的 flock 锁
2. 再次确认该 PR 仍是 open
3. 先检查轻量元数据（如 `updatedAt`）
4. 必要时拉取 PR 深度上下文并计算实时阶段
5. 若已是 `finished`，则退出
6. 比较 snapshot，判断是否真的有新变化
7. 准备 git 工作区
8. 启动 `claude code` 非交互模式
9. 解析 claude 最后一行返回结果
10. 校验阶段跳转是否合法
11. 必要时更新 PR 的阶段 marker comment
12. 若本轮对 GitHub 产生了变更（如新增 marker comment），重新计算**最终 snapshot**
13. 在持锁状态下一次性原子写回本地状态文件
14. 释放锁并清理临时文件

### 建议关键函数

- `main`
- `process_pr`
- `should_skip_pr`
- `run_claude_for_pr`
- `validate_stage_transition`
- `cleanup`

### 异常清理要求

`worker.sh` 开头应设置标准 `trap`，统一做清理和日志输出：

```bash
trap 'cleanup' EXIT INT TERM
```

`cleanup` 至少负责：

- 删除临时 context / cache 文件
- 输出中断或失败日志到 stderr
- 关闭临时文件描述符

说明：`flock` 绑定文件描述符后，进程退出时 OS 通常会自动释放锁，但仍建议显式使用 `trap` 做审计和临时文件清理。

## 4.3 `statectl.sh`
`statectl.sh` 不是系统里唯一的状态写入机制，而是**暴露给 Claude 的唯一业务状态写入口**。

也就是说：

- `statectl.sh`：给 Claude 调用，只允许修改有限的业务字段
- `lib/core.sh` 中的 `state_read_json` / `state_write_json` / `atomic_write`：底层通用读写机制
- `worker.sh`：作为调度器，负责更新 `last_snapshot`、`last_pr_updated_at` 等系统字段，并在本轮结束时统一落盘

这样职责就清晰了：

- Claude 的能力面被限制，命令集简洁
- Worker 不被 `statectl.sh` 限制，可以直接做系统级状态维护
- 整个 state 文件仍然只有受控路径修改

### 建议支持的子命令

```bash
statectl.sh set-hint "下一次先处理 reviewer A 的线程"
statectl.sh add-solved-comment 123456789
statectl.sh add-solved-subcomment 987654321
statectl.sh set-last-head-sha abcdef123
statectl.sh mark-updated
```

### 约束要求

- `statectl.sh` 必须在当前 PR 的锁已被 worker 持有的上下文中调用
- `statectl.sh` 不再单独拿新的 PR 锁，避免与 worker 形成嵌套锁
- `statectl.sh` 每次修改都应读入最新 JSON、只改允许字段、再原子重写
- `statectl.sh` 写入的 `hint` 必须限制为**单行短文本**，并做 JSON 安全转义

### 不建议暴露给 Claude 的命令

以下字段应由 `worker.sh` 直接维护，而不是让 Claude 写：

- `last_snapshot`
- `last_pr_updated_at`
- 运行级临时缓存路径
- 运行时诊断字段

## 4.4 `lib/core.sh`
存放与 GitHub 业务无关的通用能力。

### 建议关键函数

- `log_info`
- `log_warn`
- `log_error`
- `die`
- `require_cmd`
- `assert_repo_root`
- `repo_slug`
- `repo_key`
- `repo_state_dir`
- `ensure_repo_state_dir`
- `pr_state_file`
- `pr_lock_file`
- `load_state_json`
- `state_read_json`
- `state_write_json`
- `atomic_write`
- `json_array_add_unique`
- `now_utc`

### 主要职责

- 日志和错误处理（统一输出到 stdout / stderr）
- repo 标识与路径计算
- 状态目录与 PR 文件路径生成
- JSON 状态文件读写
- 原子写入
- 一些小型字符串 / JSON 工具函数

## 4.5 `lib/gh.sh`
存放所有 git / GitHub 相关逻辑。

### 建议关键函数

- `gh_list_open_prs`
- `gh_pr_meta`
- `gh_pr_is_open`
- `gh_pr_stage`
- `gh_pr_snapshot`
- `gh_prepare_pr_workspace`
- `gh_post_stage_marker`
- `gh_collect_context`
- `gh_write_context_cache`

### 主要职责

- 列出所有 open PR
- 查询某个 PR 的轻量元数据
- 通过单次深度抓取收集 PR 上下文
- 根据带 bot 前缀的 marker comment 判定阶段
- 计算 PR 当前 snapshot
- 将 repo checkout 到对应 PR 代码
- 向 PR 添加新的阶段 marker comment
- 将单次查询结果写入本地 JSON cache，供多个函数复用

## 5. 状态目录与文件命名

## 5.1 repo 级状态目录

同一个 GitHub repo，无论从哪个本地 clone 路径执行，都应该映射到同一个状态目录。

建议使用：

```text
${XDG_STATE_HOME:-$HOME/.local/state}/pr-loop/<owner>__<repo>/
```

例如：

```text
~/.local/state/pr-loop/openai__myrepo/
```

其中 `<owner>/<repo>` 通过 `git remote get-url origin` 或 `gh repo view` 提取。

---

## 5.2 PR 级文件
每个 PR 固定对应以下文件：

```text
pr-123.lock
pr-123.state.json
```

如需本轮复用深度查询结果，还可以使用临时缓存：

```text
pr-123.ctx.json
```

其中：

- `pr-123.lock`：flock 文件
- `pr-123.state.json`：本地状态文件
- `pr-123.ctx.json`：单轮处理过程中的 JSON cache，可在退出时删除或短暂保留

不再为单个 PR 维护独立日志文件。工具的运行日志统一由 `log_*` 函数输出到 stdout / stderr，并在日志前缀中带上 repo / PR / 模块信息，便于外部 supervisor、systemd 或 shell 重定向统一收集。

## 6. status file 格式
建议使用简单的 JSON 格式，而不是 `KEY=VALUE` shell 格式。

原因：

- `hint` 等字段可能包含引号、反斜杠或其他特殊字符，JSON 更安全
- 避免直接 `source` 状态文件带来的解析和注入风险
- shell 中可统一用 `jq` 读写，规则更稳定
- 便于后续扩展数组和诊断字段

示例：

```json
{
  "last_solved_comments": [123, 456],
  "last_solved_subcomments": [888, 999],
  "last_head_sha": "abcde12345",
  "last_snapshot": "6c8c1f...",
  "last_pr_updated_at": "2026-04-06T14:20:00Z",
  "hint": "下一次先看 reviewer 对缓存一致性的追问",
  "updated_at": "2026-04-06T14:30:00Z"
}
```

### 字段说明

- `last_solved_comments`：已处理过的顶层评论 id 集合
- `last_solved_subcomments`：已处理过的回复评论 id 集合
- `last_head_sha`：上次处理时看到的 PR head commit sha
- `last_snapshot`：上次处理时的整体 PR 快照 hash
- `last_pr_updated_at`：上次看到的 PR 轻量更新时间，用于前置拦截
- `hint`：给下一次处理的一句话提示，必须为单行短文本
- `updated_at`：最后更新时间，仅用于调试和观察

### 读写约束

- 状态文件扩展名统一为 `.state.json`
- 所有修改必须通过“读 JSON -> 修改字段 -> 原子替换写回”的方式完成
- 读取时统一使用 `jq`，禁止 `source` 任意状态文件

## 7. 阶段判定设计
## 7.1 marker comment 形式

必须使用**带 bot 前缀且带 magic string 的机器可读注释**，避免普通文本误触发。建议格式如下：

```text
[pr-loop-bot] <!-- PR-LOOP:STAGE:plan:DO-NOT-EDIT -->
[pr-loop-bot] <!-- PR-LOOP:STAGE:impl:DO-NOT-EDIT -->
[pr-loop-bot] <!-- PR-LOOP:STAGE:review:DO-NOT-EDIT -->
[pr-loop-bot] <!-- PR-LOOP:STAGE:finished:DO-NOT-EDIT -->
```

推荐要求：

- marker comment 的正文**只包含这一行**
- 所有由工具主动发出的业务 comment 都统一加上 `[pr-loop-bot] ` 前缀
- 不在同一条 comment 中混入其他说明文字
- 若要补充说明，单独发另一条 comment

这样最容易精确解析，也最不容易被 Markdown 语法干扰。

## 7.2 阶段 Marker 的防伪与解析规则

不能只做“包含子串”匹配，否则会被以下情况误伤：

- 有人在评论里引用了旧 marker comment
- 普通开发者在正文中无意写入相似字符串
- Markdown `>` 引用块中出现 marker
- 普通用户手工输入了类似字符串但没有 bot 前缀

### 解析要求

匹配时应满足以下条件：

1. 只解析 comment **原始正文**，不解析网页渲染结果
2. 要求正文去掉首尾空白后，**完整等于**某个 marker
3. marker 必须同时包含固定 bot 前缀 `[pr-loop-bot] `
4. 不接受前缀为 `>` 的引用行
5. 不接受正文中夹杂其他文本的 comment

推荐正则思路：

```text
^[[:space:]]*\[pr-loop-bot\][[:space:]]*<!--[[:space:]]*PR-LOOP:STAGE:(plan|impl|review|finished):DO-NOT-EDIT[[:space:]]*-->[[:space:]]*$
```

### 阶段计算规则

对某个 PR：

1. 拉取所有 issue comments
2. 过滤出严格匹配 marker 的 comments
3. 取仍然存在的、**创建时间最新**的一条 marker
4. 其值即当前阶段
5. 若不存在任何 marker，则默认阶段为 `plan`

### 好处

- 删除最新 marker 就会回退到上一阶段
- 删除全部 marker 会回退到 `plan`
- 阶段真值始终与 GitHub 当前状态一致
- 可以有效防止 Quote 或误写字符串导致阶段污染
- 不依赖 GitHub 账号身份判断，迁移 bot 运行身份时更简单

## 7.1 marker comment 形式

必须使用**带 magic string 的机器可读注释**，避免普通文本误触发。建议格式如下：

```text
<!-- PR-LOOP:STAGE:plan:DO-NOT-EDIT -->
<!-- PR-LOOP:STAGE:impl:DO-NOT-EDIT -->
<!-- PR-LOOP:STAGE:review:DO-NOT-EDIT -->
<!-- PR-LOOP:STAGE:finished:DO-NOT-EDIT -->
```

推荐要求：

- marker comment 的正文**只包含这一行**
- 不在同一条 comment 中混入其他说明文字
- 若要补充说明，单独发另一条 comment

这样最容易精确解析，也最不容易被 Markdown 语法干扰。

---

## 7.2 阶段 Marker 的防伪与解析规则

不能只做“包含子串”匹配，否则会被以下情况误伤：

- 有人在评论里引用了旧 marker comment
- 普通开发者在正文中无意写入相似字符串
- Markdown `>` 引用块中出现 marker

### 解析要求

匹配时应满足以下条件：

1. 只解析 comment **原始正文**，不解析网页渲染结果
2. 要求正文去掉首尾空白后，**完整等于**某个 marker
3. 或者使用严格正则，确保 marker 是 comment 中唯一有效内容
4. 不接受前缀为 `>` 的引用行
5. 不接受正文中夹杂其他文本的 comment

推荐正则思路：

```text
^[[:space:]]*<!--[[:space:]]*PR-LOOP:STAGE:(plan|impl|review|finished):DO-NOT-EDIT[[:space:]]*-->[[:space:]]*$
```

### 阶段计算规则

对某个 PR：

1. 拉取所有 issue comments
2. 过滤出严格匹配 marker 的 comments
3. 取仍然存在的、时间最新的一条 marker
4. 其值即当前阶段
5. 若不存在任何 marker，则默认阶段为 `plan`

### 好处

- 删除最新 marker 就会回退到上一阶段
- 删除全部 marker 会回退到 `plan`
- 阶段真值始终与 GitHub 当前状态一致
- 可以有效防止 Quote 或误写字符串导致阶段污染

---

## 8. GitHub 查询与 snapshot 设计

## 8.1 两层查询机制

为了避免频繁轮询时快速耗尽 GitHub API Rate Limit，应分成两层：

### 第一层：轻量元数据查询

主循环先查询每个 open PR 的轻量字段，例如：

- `number`
- `updatedAt`
- `headRefOid`
- `state`

只有当：

- `updatedAt > LAST_PR_UPDATED_AT`
- 或本地尚无状态文件
- 或当前正在处理中的 PR 需要强制刷新

才进入第二层。

### 第二层：深度上下文查询

对通过第一层筛选的 PR，再抓取：

- issue comments
- review comments
- review replies
- 需要的 commit / review 元信息

随后计算：

- 当前阶段
- 当前 snapshot
- 提供给 Claude 的处理上下文

---

## 8.2 单次深度抓取结果必须复用

不要对同一个 PR 分别调用：

- 一次查 stage
- 一次查 head sha
- 一次查 issue comments
- 一次查 review comments
- 一次查 replies

更合理的做法是：

- 在 `gh_collect_context` 中，用**一条 GraphQL 查询**或一次聚合 API 请求
- 将当前 PR 的完整处理上下文拉下来
- 写入本地 `pr-123.ctx.json`
- `gh_pr_stage`、`gh_pr_snapshot`、`run_claude_for_pr` 都直接解析这个 JSON

这样可以显著减少重复请求和重复 JSON 解析。

推荐实践：

- `gh_pr_meta`：轻量查询
- `gh_collect_context`：深度查询并返回 JSON
- `gh_write_context_cache`：写本地 cache
- `gh_pr_stage_from_cache` / `gh_pr_snapshot_from_cache`：从 cache 解析

---

## 8.3 snapshot 输入内容
建议将以下信息拼成稳定文本后做 `sha256`：

- PR 当前 open/closed 状态
- PR 当前 head sha
- 当前阶段
- 所有 issue comments 的 `id + updatedAt`
- 所有 review comments 的 `id + updatedAt`
- 所有 review replies 的 `id + updatedAt`

### 最终 snapshot 的计算时机

`worker.sh` 在进入 Claude 之前计算的 snapshot，只能作为“是否需要处理”的判断依据，**不能直接作为本轮最终落盘的 `last_snapshot`**。

原因是本轮处理期间系统自己可能还会对 GitHub 产生副作用，例如：

- 新增阶段 marker comment
- 编辑或删除由工具自己维护的机器 comment（若未来扩展）
- 触发会改变 PR `updatedAt` 的其他自动化动作

因此规则必须是：

1. 进入 Claude 前，先根据当前上下文计算 `pre_snapshot`
2. Claude 返回后，如无任何 GitHub 写操作，`final_snapshot = pre_snapshot`
3. 若本轮新增了 marker comment 或发生任何 GitHub 写操作，则必须重新抓取必要上下文并计算 `final_snapshot`
4. 只有 `final_snapshot` 才允许写入状态文件的 `last_snapshot`

这样可以避免“worker 自己发完 marker 后，下轮又把自己当成新变化再处理一次”的空转问题。

## 8.4 覆盖的变化类型
此设计可以检测到：

- 新 comment
- comment 删除
- comment 编辑
- 新 commit push
- 阶段推进
- 阶段回退
- 由工具自身产生的阶段 marker 变更

因此在通过轻量 `updatedAt` 拦截后，仍可用：

> 如果 `final_snapshot == last_snapshot`，则跳过该 PR

作为最终的深度变化判定。

## 9. 主循环流程

`pr-loop.sh` 推荐采用最简单的串行循环：

```text
while true
  1. 调用 issue-scan.sh，扫描 open issues，必要时补建 seed PR
  2. 扫描 open PR 列表（仅拉轻量元数据）
  3. 逐个调用 worker.sh <pr_number>
  4. sleep N 秒
done
```

### 为什么第一版建议串行

- 代码最少
- 行为最稳定
- 每个 PR 已经有独立锁
- 后续若要并行，只需修改 `pr-loop.sh`

---

## 10. 单个 PR 处理流程
`worker.sh` 中建议固定以下流程：

```text
1. 获取 pr-<n>.lock
2. 确认 PR 仍然 open
3. 读取 pr 的轻量元数据（updatedAt / head sha / state）
4. 若 updatedAt 未超过 last_pr_updated_at，则退出
5. 拉取深度上下文并生成 pr-<n>.ctx.json
6. 计算实时 stage
7. 如果 stage=finished，退出
8. 计算 pre_snapshot；若和 last_snapshot 一样，退出
9. 准备 workspace
10. 启动 claude code
11. 读取最后一行 RESULT_STAGE=...
12. 校验 stage 跳转是否合法
13. 若 RESULT_STAGE 与当前 stage 不同，则追加 stage marker comment
14. 若第 13 步产生了 GitHub 写操作，则重新计算 final_snapshot；否则 final_snapshot=pre_snapshot
15. 由 worker 更新 last_snapshot / last_pr_updated_at / last_head_sha / updated_at
16. 释放锁并清理临时文件
```

这是第一版最合理、最简单、最稳的一条链路。

## 11. Git 工作区与代码推送策略（Critical）

建议统一直接检出 PR 的 head branch：

```bash
git fetch <head-remote> refs/heads/<head-branch>:refs/remotes/<head-remote>/<head-branch>
git checkout -B <head-branch> refs/remotes/<head-remote>/<head-branch>
git reset --hard
git clean -ffd
```

### 优点

- Bot 本地工作分支与 PR branch 保持一致
- 提交、推送、排查问题时不再混入额外的临时分支名
- 对同仓库 PR 与 fork PR 都可以统一处理
- 能稳定切到 PR 当前代码
- 强制清理工作区，减少脏状态影响

### 关键风险

由于每次进入处理前都会执行：

- `git reset --hard`
- `git clean -ffd`

所以**任何未提交、未推送的本地修改都会被清空**。

### 强制要求

必须在提供给 Claude 的 Prompt 中明确要求：

> 如果你在 `impl` 阶段修改了代码，必须在结束前完成 `git add`、`git commit`，并将结果 `git push origin HEAD:<对应远程分支>` 推送到远程。未 push 的本地改动在下次 loop 进入时会被清空。

### 建议约束

- Claude 不应把“只改了本地工作区但未提交未推送”视为完成
- 若 push 失败，应在最后输出里显式保留当前阶段，不要推进到下一阶段
- `worker.sh` 可以在 Claude 退出后额外检查一次工作区是否仍 dirty，并通过 stderr 输出

此逻辑应封装在 `gh_prepare_pr_workspace` 中，并在 Prompt 中反复强调。

---

## 12. Claude Code 输入输出契约

## 12.1 输入给 Claude 的内容
建议固定输入以下信息：

- PR 编号
- 当前阶段
- 当前 head sha
- 上次已处理 comment ids
- 上次已处理 subcomment ids
- 当前 hint
- 可调用命令说明
- 最终输出格式要求
- 工作区会被清理的提醒
- 代码修改后必须 commit + push 的要求
- 允许的阶段跳转规则

示例：

```text
PR: 123
Stage: impl
Head SHA: abcdef

Last solved comments: 11,22,33
Last solved subcomments: 44,55
Hint: 优先处理 reviewer 关于 cache invalidation 的追问

Important workspace rule:
- This worker resets and cleans the git worktree before each run.
- If you change code, you must git add, git commit, and git push origin HEAD:<remote-branch> before finishing.
- Unpushed local changes will be lost on the next run.

Bot comment prefix rule:
- Any machine-written business comment must start with: [pr-loop-bot]

Allowed stage transitions:
- plan -> impl
- impl -> review
- review -> finished
- otherwise keep the current stage

Available commands:
- statectl.sh set-hint "..."
- statectl.sh add-solved-comment <id>
- statectl.sh add-solved-subcomment <id>
- statectl.sh set-last-head-sha <sha>

Final line must be exactly one of:
RESULT_STAGE=plan
RESULT_STAGE=impl
RESULT_STAGE=review
RESULT_STAGE=finished
```

## 12.2 Claude 的输出要求
要求 `claude code` 最后一行固定输出：

```text
RESULT_STAGE=plan
```

或：

```text
RESULT_STAGE=impl
RESULT_STAGE=review
RESULT_STAGE=finished
```

### 额外约束

- 若代码已修改但未成功 push，不允许输出推进后的阶段
- 若遇到不可恢复错误，应保持原阶段并在 stderr 中写明原因
- `worker.sh` 必须对 `RESULT_STAGE` 做合法状态机校验，而不是无条件接受

### 推荐的合法跳转

```text
plan   -> impl
impl   -> review
review -> finished
```

其余情况统一按“保持当前阶段”处理；阶段回退仍主要通过删除较新的 marker comment 来实现。

### 为什么不用 JSON

因为 shell 中解析最后一行 `KEY=VALUE` 最简单、最稳、最少代码。

## 13. 模块调用关系

```text
pr-loop.sh
  -> core.sh
  -> gh.sh
  -> issue-scan.sh
  -> worker.sh

issue-scan.sh
  -> core.sh
  -> gh.sh

worker.sh
  -> core.sh
  -> gh.sh
  -> statectl.sh (仅供 claude 调用)

statectl.sh
  -> core.sh
```

### 约束原则

- `pr-loop.sh` 不直接操作状态文件细节
- `worker.sh` 不直接散落拼接 GitHub API 调用，应复用 `gh_collect_context`
- Claude 不直接编辑状态文件，只能调用 `statectl.sh`
- `worker.sh` 可以直接调用 `state_set` 更新系统级状态字段

---

## 14. 最小接口清单

## 14.1 `lib/core.sh`
```bash
log_info
log_warn
log_error
die
require_cmd
assert_repo_root
repo_slug
repo_key
repo_state_dir
ensure_repo_state_dir
pr_state_file
pr_lock_file
issue_scan_lock_file
load_state_json
state_read_json
state_write_json
atomic_write
json_array_add_unique
now_utc
```

## 14.2 `lib/gh.sh`

```bash
gh_list_open_prs
gh_list_open_issues
gh_repo_default_branch
gh_issue_branch_name
gh_find_related_pr_number
gh_seed_issue_branch
gh_create_issue_pr
gh_pr_meta
gh_pr_is_open
gh_collect_context
gh_write_context_cache
gh_pr_stage
gh_pr_snapshot
gh_prepare_pr_workspace
gh_post_stage_marker
```

## 14.3 `statectl.sh`

```bash
cmd_set_hint
cmd_add_solved_comment
cmd_add_solved_subcomment
cmd_set_last_head_sha
cmd_mark_updated
```

## 14.4 `worker.sh`
```bash
process_pr
should_skip_pr
run_claude_for_pr
validate_stage_transition
cleanup
```

## 14.5 `pr-loop.sh`

```bash
main
loop_once
dispatch_pr
```

## 14.6 `issue-scan.sh`

```bash
main
scan_open_issues
```

---

## 15. 审计日志设计
第一版不再为每个 PR 维护独立日志文件，也不额外维护单独的 `tool.log` 文件。

统一策略是：

- 所有日志直接输出到 stdout / stderr
- 使用统一的结构化前缀，例如 `[pr-loop][repo=<repo>][pr=<n>][worker] ...`
- 正常流程走 stdout
- 警告与错误走 stderr
- Claude 的 stdout / stderr 直接透传到当前进程的 stdout / stderr，由外部重定向或 supervisor 收集

### 建议记录内容

- worker 开始和结束时间
- 本轮读取到的 stage / head sha / updatedAt / snapshot
- 是否命中 skip 逻辑
- Claude 的 stdout / stderr
- git push 是否成功
- 异常退出或 trap 清理信息

### 价值

这样可以减少状态目录内的附加文件数量，同时保留足够的可观测性。若后续部署到 `systemd`、`tmux`、容器日志系统或 shell 重定向环境中，也更容易统一收集和检索。

## 16. 最简流程图
```text
pr-loop.sh
  └─ scan open PRs (meta only)
      └─ for each PR
          └─ worker.sh <pr>
              ├─ flock
              ├─ recheck open
              ├─ compare updatedAt with last_pr_updated_at
              ├─ if unchanged -> exit
              ├─ fetch full context once -> ctx.json
              ├─ compute current stage from cache
              ├─ if finished -> exit
              ├─ compute pre_snapshot
              ├─ if unchanged -> exit
              ├─ prepare workspace
              ├─ run claude
              ├─ parse RESULT_STAGE
              ├─ validate stage transition
              ├─ maybe post new stage marker
              ├─ recompute final_snapshot if GitHub changed
              ├─ update system state fields
              └─ cleanup
```

## 17. 推荐实现顺序

为了减少返工，建议按下面顺序实现：

1. `lib/core.sh`
2. `lib/gh.sh` 中的基础函数：
   - `gh_list_open_prs`
   - `gh_pr_meta`
   - `gh_pr_is_open`
3. `pr-loop.sh`
4. `worker.sh` 的基本骨架 + `trap cleanup`
5. `gh_collect_context` 与本地 `ctx.json` 复用
6. `gh_pr_stage` 的严格 marker 解析
7. `gh_pr_snapshot`
8. `statectl.sh`
9. `run_claude_for_pr`
10. `gh_prepare_pr_workspace`
11. `handle_claude_result`
12. `pr-<n>.log` 审计日志完善

---

## 18. 第一版必须坚持的稳健性原则
1. **阶段只信 GitHub comment，且必须严格匹配带 `[pr-loop-bot]` 前缀的防伪 marker**
2. **状态文件只存进度与轻量缓存，不存正文**
3. **状态文件统一使用 JSON；所有写入都走原子替换**
4. **处理 PR 前必须先拿锁**
5. **拿锁后要重新检查 PR 是否仍 open**
6. **是否需要深度处理，先看 `updatedAt`，再看 snapshot**
7. **Claude 只能通过 `statectl.sh` 更新受限业务状态**
8. **Worker 必须校验合法阶段跳转，不能盲信 Claude 输出**
9. **任何代码修改都必须 commit + push，否则不应推进阶段**
10. **工具日志统一输出到 stdout / stderr，不再维护 per-PR 日志文件**
11. **单次深度抓取结果必须复用，避免重复调用 GitHub API**
12. **若本轮写入了新的 marker comment，必须重新计算 final snapshot 再落盘**
13. **所有异常退出都应走 `trap cleanup`**

## 19. 结论
这套改进版设计的重点是：

- 用最少的脚本数量解决问题
- 将高复用逻辑集中到 `core.sh` 和 `gh.sh`
- 用 GitHub comment 作为阶段真值，天然支持回退
- 用带 `[pr-loop-bot]` 前缀的严格 marker 解析避免 Quote 或误写导致阶段污染
- 用 `updatedAt -> snapshot` 两层判断减少无效查询
- 用单次深度抓取 + 本地 JSON cache 降低 API 压力
- 用 `statectl.sh` 限制 Claude 的写入面，同时保留 Worker 的系统维护能力
- 用 stdout / stderr 统一日志输出，提高部署和收集的一致性
- 用“最终 snapshot”落盘规则避免系统自己发 marker 后触发空转
- 用明确的 commit + push 责任避免实现阶段代码在下一轮被清空

对于第一版实现，这已经是一个**代码量小、职责清晰、对真实运行场景更稳**的方案。后续如果需要：

- 并行处理多个 PR
- 增加更丰富的 hint 策略
- 扩展更多状态字段
- 支持多 repo 或多 worker
- 引入更强的 GraphQL 聚合查询

都可以在这个结构上平滑演进，而不需要推翻重写。
