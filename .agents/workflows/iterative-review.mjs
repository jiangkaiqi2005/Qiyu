// E:\Agent\栖语\.agents\workflows\iterative-review.mjs
//
// 可复用的迭代式代码审查工作流。
//
// 调用方式（在 Claude Code 主对话里）：
//   Workflow({ scriptPath: "<abs path to this file>", args: { ... } })
//
// 设计原则：
//   1. 全部配置走 args（高复用性）。
//   2. 每个 review 维度派出 2 名独立审查员，去重时要求至少 N 人一致（高要求）。
//   3. Modify agent 在改代码前必须做分支 + 路径双重守卫（高标准）。
//   4. 连续 cleanRoundsToStop 轮零新发现才退出（严谨）。
//   5. 最后一轮再 git commit，并写一份 markdown 报告。

export const meta = {
  name: 'iterative-review',
  description: '迭代式多 Agent 代码审查、修改、验证循环',
  phases: [
    { title: 'Init' },
    { title: 'Review' },
    { title: 'Modify' },
    { title: 'Verify' },
    { title: 'Decide' },
  ],
}

// ---------- 默认配置（可被 args 覆盖） ----------

const DEFAULTS = {
  // 审查范围：相对仓库根的 glob / 路径
  scope: ['src/**', 'test/**', 'scripts/**', 'index.html', 'sw.js', 'package.json', 'README.md'],

  // 唯一允许修改的分支（Modify / Verify 阶段会硬断言）
  branch: 'claude_code',

  // 审查维度
  dimensions: [
    'correctness',   // 逻辑、边界、错误处理
    'security',      // 注入、XSS、密钥、不安全 DOM
    'performance',   // 热路径、内存、网络浪费
    'style',         // 命名、结构、复杂度、死代码
    'testing',       // 覆盖缺口、测试质量
    'architecture',  // 关注点分离、依赖方向
  ],

  // 每个维度的独立审查员数（高要求：>=2）
  reviewersPerDim: 2,

  // 一条 finding 需要几名审查员达成一致才算数（高标准）
  requireAgreement: 2,

  // 低于这个 severity 的 finding 直接丢弃（噪声过滤）
  minSeverity: 'low',

  // 连续多少轮无新 finding 才停止
  cleanRoundsToStop: 3,

  // 硬上限
  maxRounds: 8,

  // 完成后是否 commit（只在最后一轮一次性 commit）
  commitOnDone: true,

  // 报告输出路径
  reportPath: '.agents/workflows/last-review-report.md',

  // commit 信息模板
  commitMessageTemplate: 'chore(review): round {round} — {fixedCount} fixes, {findingCount} findings',
}

// ---------- 常量 ----------

const SEVERITY_RANK = { low: 0, medium: 1, high: 2, critical: 3 }
const cfg = { ...DEFAULTS, ...(args || {}) }

// ---------- Schemas ----------

const CTX_SCHEMA = {
  type: 'object',
  properties: {
    projectRoot: { type: 'string' },
    currentBranch: { type: 'string' },
    headSha: { type: 'string' },
    fileList: { type: 'array', items: { type: 'string' } },
    fileCount: { type: 'number' },
    testCommand: { type: 'string' },
    notes: { type: 'string' },
  },
  required: ['projectRoot', 'currentBranch', 'headSha', 'fileList', 'fileCount'],
}

const FINDING_SCHEMA = {
  type: 'object',
  properties: {
    id: { type: 'string' },
    file: { type: 'string' },
    line: { type: 'number' },
    severity: { type: 'string', enum: ['critical', 'high', 'medium', 'low'] },
    dimension: { type: 'string' },
    title: { type: 'string' },
    description: { type: 'string' },
    suggestedFix: { type: 'string' },
    confidence: { type: 'string', enum: ['high', 'medium', 'low'] },
  },
  required: ['file', 'severity', 'title', 'description', 'suggestedFix', 'confidence'],
}

const REVIEW_SCHEMA = {
  type: 'object',
  properties: {
    findings: { type: 'array', items: FINDING_SCHEMA },
    notes: { type: 'string' },
  },
  required: ['findings'],
}

const MODIFY_SCHEMA = {
  type: 'object',
  properties: {
    findingId: { type: 'string' },
    applied: { type: 'boolean' },
    blockedBy: { type: 'string' }, // 'branch' | 'scope' | 'tests' | null
    reasonIfNotApplied: { type: 'string' },
    filesChanged: { type: 'array', items: { type: 'string' } },
    diffSummary: { type: 'string' },
    testsRun: { type: 'array', items: { type: 'string' } },
    testsResult: { type: 'string', enum: ['pass', 'fail', 'partial', 'skipped'] },
  },
  required: ['findingId', 'applied', 'filesChanged'],
}

const VERIFY_SCHEMA = {
  type: 'object',
  properties: {
    modifyId: { type: 'string' },
    findingId: { type: 'string' },
    stillPresent: { type: 'boolean' },
    introducedRegression: { type: 'boolean' },
    notes: { type: 'string' },
    suggestedRevert: { type: 'boolean' },
  },
  required: ['findingId', 'stillPresent', 'introducedRegression'],
}

// ---------- Prompt 模板（高复用：纯函数 + cfg） ----------

function initPrompt() {
  return `你是初始化探员。完成下列任务并按 schema 返回 JSON：

1. 用 \`git rev-parse --show-toplevel\` 获取仓库根路径。
2. 用 \`git branch --show-current\` 确认当前分支。
3. 用 \`git rev-parse HEAD\` 获取 head SHA。
4. 列出本次审查范围内的所有文件（基于 scope: ${JSON.stringify(cfg.scope)}）。对每个目录用 \`git ls-files <dir>\`。
5. 检测测试命令（package.json 的 scripts.test）。
6. 把所有信息填入 schema。

只读，不要修改任何文件。不要执行 npm install / build。`
}

function reviewPrompt(dimension, reviewerIndex) {
  return `你是一名【严格、苛刻、零容忍虚假 finding】的代码审查员 #${reviewerIndex}，专攻「${dimension}」维度。

【必须使用】superpowers:requesting-code-review skill（用 Skill 工具调用），按它的工作流执行。

【审查范围】仅限以下文件（不要审查 scope 之外的目录）：
${cfg.scope.map(s => '  - ' + s).join('\n')}

【分支守卫】当前分支必须是 \`${cfg.branch}\`。先用 \`git branch --show-current\` 确认。如果不是 \`${cfg.branch}\`，直接返回空 findings 并在 notes 里说明。

【项目背景】
- 项目名：栖语（qiyu-mvp），睡前 AI 陪伴 Web PWA 前端
- 运行时：Node >=20，vanilla JS（无打包器），Playwright/原生 \`node --test\` 测试
- 重要路径：
    src/qiyu/  业务核心
    src/server/  本地 dev server
    src/screens/ 屏幕
    src/ui/     UI 组件
    test/       测试
    scripts/    构建/工具脚本
    sw.js       Service Worker
    index.html  入口

【你的维度定义】${dimensionDefinition(dimension)}

【严格度要求 — 这是高标准】
- 只报告你能【通过读源码直接验证】的 finding。读不到验证证据的，不要写。
- 优先报告 critical / high severity。medium / low 给一两个最确定的即可，避免噪声。
- confidence 必须诚实：能复现 = high；理论上可能但未复现 = medium；纯推测 = low。
- 如果一轮没有 finding，**就返回空数组**——这正是"高要求"想要的，比勉强凑数重要。
- 不要建议加注释、改格式、改命名（那是 style 维度的事）。
- 不要给"应该""或许""可以"这种空话建议。suggestedFix 必须可执行。

【schema 严格遵守】输出必须满足 REVIEW_SCHEMA。file 路径相对仓库根，line 是行号（如能定位）。`
}

function modifyPrompt(finding) {
  return `你是一名【保守、精确、零副作用】的代码修改员。

【必须使用】superpowers:receiving-code-review skill（用 Skill 工具调用），按它的工作流评估并应用这条 finding。

【finding】
${JSON.stringify(finding, null, 2)}

【双重硬守卫 — 失败就 abort】
1. 分支守卫：先跑 \`git branch --show-current\`，确认等于 \`${cfg.branch}\`。否则**立刻停止**，返回 applied=false, blockedBy='branch'。
2. 路径守卫：你只能改以下范围内的文件：
${cfg.scope.map(s => '   - ' + s).join('\n')}
   你的修复如果需要改 scope 之外的文件（例如 \`qiyu.config.local.json\`、\`.gitignore\`、\`node_modules/\`、\`docs/\`、\`.agents/skills/*\`），**立刻停止**，返回 applied=false, blockedBy='scope'，并在 reasonIfNotApplied 里写清楚"为什么必须改这个文件 + 建议的人工改动是什么"。

【修改原则 — 这是高标准】
- 最小 diff。只改必要的行。
- 不重构、不"顺手优化"、不调格式。
- 改完跑 \`npm test\`，把结果填到 testsResult。
- 如果测试原本就 fail 且与本次修改无关，注明（testsResult='partial'）并继续。
- 不 commit（commit 由本 workflow 的最后一轮统一做）。
- 不安装依赖、不改 package.json（除非 finding 直接要求）。
- 不改 \`qiyu.config.local.json\`（它含真实 API key，被 .gitignore 保护）。

【schema 严格遵守】输出 MODIFY_SCHEMA。filesChanged 列出所有触碰过的文件。`
}

function verifyPrompt(finding, modifyResult) {
  return `你是一名【独立、严格、可证伪】的验证员。

【必须使用】superpowers:verify skill（用 Skill 工具调用），按它的工作流验证这条修复。

【finding 原始问题】
${JSON.stringify(finding, null, 2)}

【modify agent 报告的结果】
${JSON.stringify(modifyResult, null, 2)}

【你的任务】
1. 重新读修改前后的 diff（\`git diff <path>\`）。
2. 独立判断：原 finding 描述的问题是否真的被修好了？（不是看 modify agent 自己怎么说，而是你自己读代码确认）
3. 跑 \`npm test\`，记录结果。
4. 看相邻代码、相关模块、测试文件，判断有没有引入回归。
5. 不重跑 modify agent 的工作——你是独立验证。

【schema 严格遵守】输出 VERIFY_SCHEMA。
- stillPresent: 原始问题是否仍然存在
- introducedRegression: 这次修改是否引入了新问题
- suggestedRevert: 是否建议回滚
- notes 里写具体的证据（行号、命令输出片段）`
}

function dimensionDefinition(d) {
  return {
    correctness: '逻辑错误、边界条件、错误处理、竞态、空值/undefined 访问、类型错误、异步错误传播。',
    security:   'XSS、注入（HTML/JS/SQL/命令）、密钥/Token 泄漏、unsafe innerHTML、eval、CSP 绕过、本地存储敏感数据、不安全随机数、SSRF。',
    performance:' 不必要的重渲染、阻塞主线程、热路径上的 O(n²)、内存泄漏、未清理的事件监听器、未节流的 scroll/resize、网络请求冗余、大体积资源、缓存缺失。',
    style:      '命名一致性、函数/模块长度、圈复杂度过高、死代码、重复代码（DRY 违规）、magic numbers、注释与代码不同步。',
    testing:    '缺测试的分支、断言太弱、测试不存在的 edge case、测试假阳性、snapshot 过时、测试互相耦合、慢测试。',
    architecture:' 关注点分离、模块边界、依赖方向（高层依赖低层？）、循环依赖、全局状态、隐式耦合、抽象泄漏。',
  }[d] || d
}

// ---------- 去重 / 决策辅助 ----------

function keyFinding(f) {
  // 用 file + 模糊化的行号区间 + 维度作为 key
  // 行号允许 ±2 漂移（不同 reviewer 看到的行可能差 1-2）
  const lineBucket = f.line ? Math.floor(f.line / 3) : 'x'
  return `${f.file}::${lineBucket}::${f.dimension}`
}

function dedupeAcross(reviews, requireAgreement) {
  const groups = new Map()
  for (const r of reviews) {
    if (!r || !Array.isArray(r.findings)) continue
    for (const f of r.findings) {
      if (SEVERITY_RANK[f.severity] < SEVERITY_RANK[cfg.minSeverity]) continue
      const k = keyFinding(f)
      if (!groups.has(k)) groups.set(k, [])
      groups.get(k).push(f)
    }
  }
  const out = []
  for (const [k, list] of groups) {
    if (list.length < requireAgreement) continue
    // 选 severity 最高、confidence 最高的那个作代表
    const rep = list.slice().sort((a, b) =>
      SEVERITY_RANK[b.severity] - SEVERITY_RANK[a.severity] ||
      (b.confidence === 'high' ? 1 : 0) - (a.confidence === 'high' ? 1 : 0)
    )[0]
    out.push({ ...rep, agreementCount: list.length, agreementReviewers: list.map(x => x.id).filter(Boolean) })
  }
  return out
}

function inScope(file) {
  // 简单 glob 匹配：支持 ** / * / 字面
  for (const pat of cfg.scope) {
    if (matchGlob(pat, file)) return true
  }
  return false
}

function matchGlob(pat, str) {
  // 极简 glob：把 ** / * 转成正则
  const re = '^' + pat
    .replace(/[.+^${}()|[\]\\]/g, '\\$&')
    .replace(/\\\*\\\*/g, '::DOUBLESTAR::')
    .replace(/\\\*/g, '[^/]*')
    .replace(/::DOUBLESTAR::/g, '.*') + '$'
  return new RegExp(re).test(str)
}

// ---------- 主流程 ----------

let report = []
let round = 0
let cleanRounds = 0
const findingsHistory = []
const modifyHistory = []
const verifyHistory = []

// Phase: Init
phase('Init')
log('初始化：探查仓库结构、确认分支、收集文件清单')
const ctx = await agent(initPrompt(), {
  label: 'init',
  phase: 'Init',
  agentType: 'Explore',
  schema: CTX_SCHEMA,
})

if (!ctx) {
  log('Init agent 返回 null，终止。')
  throw new Error('init-failed: init agent returned null')
}

if (ctx.currentBranch !== cfg.branch) {
  log(`❌ 当前分支 \`${ctx.currentBranch}\` != 配置的 \`${cfg.branch}\`。本 workflow 拒绝运行。`)
  throw new Error(`wrong-branch: current=${ctx.currentBranch}, expected=${cfg.branch}`)
}

log(`✓ 分支守卫通过（${ctx.currentBranch}），共 ${ctx.fileCount} 个待审文件。`)

while (round < cfg.maxRounds && cleanRounds < cfg.cleanRoundsToStop) {
  round++
  log(`━━━ Round ${round}（clean streak ${cleanRounds}/${cfg.cleanRoundsToStop}）━━━`)

  // Phase: Review
  phase(`R${round} · Review`)
  log(`派出 ${cfg.dimensions.length} 维度 × ${cfg.reviewersPerDim} 审查员 = ${cfg.dimensions.length * cfg.reviewersPerDim} 个并行 review agent`)

  const reviewItems = []
  for (const d of cfg.dimensions) {
    for (let i = 0; i < cfg.reviewersPerDim; i++) {
      reviewItems.push({ dimension: d, index: i + 1 })
    }
  }

  const reviews = (await parallel(reviewItems.map(it => () =>
    agent(reviewPrompt(it.dimension, it.index), {
      label: `${it.dimension}#${it.index}`,
      phase: `R${round} · Review`,
      agentType: 'Explore',
      schema: REVIEW_SCHEMA,
    })
  ))).filter(Boolean)

  const totalRaw = reviews.reduce((n, r) => n + (r.findings?.length || 0), 0)
  log(`Review 完成：${totalRaw} 条原始 finding，进入去重。`)

  // 去重（要求 ≥ requireAgreement 名审查员一致）
  const unique = dedupeAcross(reviews, cfg.requireAgreement)
  log(`去重后剩余 ${unique.length} 条 finding。`)

  if (unique.length === 0) {
    cleanRounds++
    report.push(`R${round}: 0 新 finding (clean streak ${cleanRounds}/${cfg.cleanRoundsToStop})`)
    log(`✓ Clean round ${cleanRounds}/${cfg.cleanRoundsToStop}`)
    if (cleanRounds >= cfg.cleanRoundsToStop) {
      log(`已连续 ${cleanRounds} 轮 clean，退出循环。`)
      break
    }
    continue
  }

  cleanRounds = 0
  findingsHistory.push(...unique.map(f => ({ round, ...f })))

  // Phase: Modify
  phase(`R${round} · Modify`)
  log(`派出 ${unique.length} 个 modify agent，并行修复`)

  const mods = (await parallel(unique.map(f => () =>
    agent(modifyPrompt(f), {
      label: `fix:${keyFinding(f)}`,
      phase: `R${round} · Modify`,
      agentType: 'general-purpose',
      schema: MODIFY_SCHEMA,
    })
  ))).filter(Boolean)

  const applied = mods.filter(m => m.applied).length
  const blocked = mods.length - applied
  log(`Modify 完成：${applied} 已应用，${blocked} 被守卫拦截（branch/scope/tests）`)
  modifyHistory.push(...mods.map(m => ({ round, ...m })))

  if (applied === 0) {
    report.push(`R${round}: ${unique.length} finding 全部被守卫拦截（branch/scope/tests）—— 见 modifyHistory`)
    log(`⚠️  全部被拦截，本轮没有产生可验证的修复。`)
    // 不递增 cleanRounds，因为有 finding 但修不动——这算"无法收敛"
    if (blocked === unique.length) break
    continue
  }

  // Phase: Verify
  phase(`R${round} · Verify`)
  const verifyTargets = mods.filter(m => m.applied)
  log(`派出 ${verifyTargets.length} 个独立 verify agent 交叉验证`)

  const verifies = (await parallel(verifyTargets.map(m => () =>
    agent(verifyPrompt(unique.find(f => keyFinding(f) === keyFinding({
      file: m.filesChanged?.[0] || '',
      dimension: m.findingId,
    })), m), {
      label: `verify:${m.findingId}`,
      phase: `R${round} · Verify`,
      agentType: 'general-purpose',
      schema: VERIFY_SCHEMA,
    })
  ))).filter(Boolean)

  const regressions = verifies.filter(v => v.introducedRegression).length
  const stillBad = verifies.filter(v => v.stillPresent).length
  log(`Verify 完成：${regressions} 回归，${stillBad} 未修复`)

  verifyHistory.push(...verifies.map(v => ({ round, ...v })))

  if (regressions > 0) {
    report.push(`R${round}: ⚠️ ${regressions} 个修复引入回归 —— 见 verifyHistory`)
  }
  if (stillBad > 0) {
    report.push(`R${round}: ⚠️ ${stillBad} 个修复未真正解决 finding`)
  }
}

// Phase: Done
phase('Done')

const summary = {
  rounds: round,
  cleanRounds,
  totalFindings: findingsHistory.length,
  totalModifies: modifyHistory.length,
  totalApplies: modifyHistory.filter(m => m.applied).length,
  totalBlocked: modifyHistory.filter(m => !m.applied).length,
  totalRegressions: verifyHistory.filter(v => v.introducedRegression).length,
  findingsHistory,
  modifyHistory,
  verifyHistory,
  report,
}

log(`━━━ 总结 ━━━`)
log(`轮数: ${summary.rounds} | clean 连续: ${summary.cleanRounds}`)
log(`finding: ${summary.totalFindings} | 已应用: ${summary.totalApplies} | 被拦截: ${summary.totalBlocked} | 回归: ${summary.totalRegressions}`)

return summary
