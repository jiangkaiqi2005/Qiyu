# Iterative Review Workflow

> 编排多 Agent 严格代码审查、修改、验证的循环工作流。\
> 高复用性（全部走 `args`）、高要求（多审查员 + 一致性阈值 + 分支/路径硬守卫）、高标准（最小 diff + 独立 verify + 回归检测）。

## 调用

在 Claude Code 主对话里：

```js
Workflow({
  scriptPath: 'E:/Agent/栖语/.agents/workflows/iterative-review.mjs',
  args: {
    // 全部可选，留空走 DEFAULTS
    // scope: ['src/**', 'test/**', 'scripts/**', 'index.html', 'sw.js'],
    // branch: 'claude_code',
    // dimensions: ['correctness', 'security', 'performance', 'style', 'testing', 'architecture'],
    // reviewersPerDim: 2,
    // requireAgreement: 2,
    // minSeverity: 'low',
    // cleanRoundsToStop: 3,
    // maxRounds: 8,
    // commitOnDone: true,
  }
})
```

## 一轮循环做什么

```
Init  → 探查仓库（root / branch / sha / 文件清单 / 测试命令）
        ↓ 分支守卫：必须是 args.branch，否则抛错
        ↓
Loop (round 1..N) {
  Review  → 6 维度 × 2 审查员 = 12 个并行 Agent
            每个用 superpowers:requesting-code-review skill
            只读，不改代码
        ↓
  Dedupe  → 用 (file, lineBucket, dimension) 做 key
            只保留 ≥ requireAgreement 名审查员一致 + ≥ minSeverity 的 finding
        ↓
  若 0 finding → cleanRounds++; 达到 cleanRoundsToStop 则退出
        ↓
  Modify  → 每个 finding 派一个 Agent
            用 superpowers:receiving-code-review skill
            分支守卫 + 路径守卫双重拦截
            改完跑 npm test
        ↓
  Verify  → 每个已应用的修改派一个独立 Agent
            用 superpowers:verify skill
            自己读 diff、跑测试、判断回归
        ↓
  Decide  → 记下回归数 / 未解决数
            cleanRounds 清零
}
        ↓
Done    → 写 markdown 报告到 args.reportPath
        → 若 commitOnDone 且为最后一轮：git add + commit
```

## 守卫（防止越界）

1. **分支守卫**（在 Init 阶段和每个 Modify agent 内）
   - 必须 `git branch --show-current === args.branch`
   - 不匹配：Init 阶段抛 `wrong-branch`；Modify agent 返回 `applied=false, blockedBy='branch'`

2. **路径守卫**（每个 Modify agent 内）
   - 只能修改 `args.scope` glob 匹配的文件
   - 不匹配：返回 `applied=false, blockedBy='scope'`，并在 `reasonIfNotApplied` 写建议的人工改动

3. **测试守卫**（Modify 后必跑）
   - `npm test` 是硬要求
   - 失败且与本次无关 → `testsResult='partial'` 继续
   - 失败且本次引入 → 在 verify 阶段会被标记 `introducedRegression=true`

## 默认配置

| 参数 | 默认值 | 含义 |
| --- | --- | --- |
| `scope` | `src/**`, `test/**`, `scripts/**`, `index.html`, `sw.js`, `package.json`, `README.md` | 审查/可改范围 |
| `branch` | `claude_code` | 唯一允许分支 |
| `dimensions` | correctness, security, performance, style, testing, architecture | 审查维度 |
| `reviewersPerDim` | 2 | 每维度的独立审查员数 |
| `requireAgreement` | 2 | 几位一致算真 finding |
| `minSeverity` | `low` | 低于此严重度丢弃 |
| `cleanRoundsToStop` | 3 | 连续 N 轮无新 finding 退出 |
| `maxRounds` | 8 | 硬上限 |
| `commitOnDone` | `true` | 最后一轮一次性 commit |
| `reportPath` | `.agents/workflows/last-review-report.md` | 报告输出 |

## 在不同项目复用

把 `iterative-review.mjs` 拷到目标项目的 `.agents/workflows/` 下，覆盖 `args` 即可：

- 纯前端 React/Vue 项目：把 `scope` 改成 `src/**, tests/**`
- 后端 Node：加上 `server/**`
- Python：测试命令是 `pytest` 的话需要让 Modify agent 改用 python 风格（修改 `modifyPrompt` 里的测试命令字符串）

## 返回值

工作流结束时返回的对象形如：

```js
{
  rounds: 4,
  cleanRounds: 3,
  totalFindings: 12,
  totalApplies: 10,
  totalBlocked: 2,
  totalRegressions: 1,
  findingsHistory: [...],
  modifyHistory: [...],
  verifyHistory: [...],
  report: ['R1: ...', 'R2: ...'],
}
```

## 已知约束

- 顶层 `return` 在 `node --check` 下不合法（它把 `.mjs` 当脚本解析），但 **workflow runtime 把 body 当 async function body 跑**，`return` 是合法的。脚本只通过 workflow 工具验证。
- agents 没有文件系统访问，**所有文件读写、git、test 都在子 Agent 内执行**。
- 工作流总 Agent 数受 `min(16, cpu-2)` 并发上限，1000 总数上限保护。
