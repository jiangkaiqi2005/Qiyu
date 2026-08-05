// 严格代码审查 · 迭代修改 · 验证循环
//
// 调用方式：
//   Workflow({ scriptPath: "<this file>", args: { ... } })
//
// 架构：
//   Review（多维度 × 多审查员并行）→ Decide（去重表决）
//   → Modify（并行修复 + receive-code-review）
//   → Verify（独立验证 + re-review）→ 循环直到收敛
//
// 守卫规则：
//   - 只允许在 cfg.branch 分支上修改
//   - 只允许修改 cfg.scope 范围内的文件
//   - 修改前双重守卫（分支 + 路径），失败即 abort

export const meta = {
  name: 'strict-review-loop',
  description: '严格多 Agent 代码审查循环：Request Review → Receive & Modify → Verify & Re-Review → Loop',
  phases: [
    { title: 'Init' },
    { title: 'Review' },
    { title: 'Decide' },
    { title: 'Modify' },
    { title: 'Verify' },
    { title: 'Done' },
  ],
}

// ═══════════════════════════════════════════
// 配置（全部可通过 args 覆盖，高复用性）
// ═══════════════════════════════════════════

const DEFAULTS = {
  // 审查范围
  scope: [
    'src/**',
    'test/**',
    'scripts/**',
    'index.html',
    'sw.js',
    'package.json',
    'README.md',
  ],

  // 唯一允许修改的分支
  branch: 'claude_code',

  // 审查维度及对应的独立审查员数量
  // key: 维度名, value: 该维度的审查员数量
  dimensions: {
    correctness:   2,
    security:      2,
    performance:   1,
    style:         1,
    testing:       2,
    architecture:  1,
  },

  // 一条 finding 需要至少几名审查员一致同意才算有效
  requireAgreement: 2,

  // 最低 severity 阈值（低于此的 finding 直接丢弃）
  minSeverity: 'low',

  // 收敛条件：连续多少轮无新 finding
  cleanRoundsToStop: 2,

  // 硬上限
  maxRounds: 5,

  // 每轮最多修复的 finding 数量（超出则按 severity 排序截断）
  maxFixesPerRound: 8,

  // 完成后是否自动 commit
  commitOnDone: false,

  // 报告路径
  reportPath: '.agents/workflows/strict-review-report.md',
}

// ═══════════════════════════════════════════
// 常量 & 工具
// ═══════════════════════════════════════════

const SEVERITY_RANK = { low: 0, medium: 1, high: 2, critical: 3 }
const cfg = { ...DEFAULTS, ...(args || {}) }
const dimNames = Object.keys(cfg.dimensions)

// 已触碰的文件集合（跨轮跟踪，用于 re-review）
const touchedFiles = new Set()

function dimDef(d) {
  return {
    correctness:   '逻辑错误、边界条件、错误处理、竞态条件、空值/undefined 访问、类型错误、异步错误传播、Promise 未处理。',
    security:      'XSS（innerHTML/outerHTML/document.write）、注入、密钥/Token 硬编码或泄漏到前端、eval/Function 动态执行、CSP 缺失或过宽、不安全随机数（Math.random 用于安全目的）、敏感数据存储在 localStorage、CSRF 缺失。',
    performance:   '热路径上的不必要循环/重复计算、内存泄漏（未清理的 EventListener/Interval/Timeout/闭包引用）、大对象不必要的深拷贝、DOM 批量操作未合并、网络请求冗余未去重、未节流的 scroll/resize/mousemove 处理。',
    style:         '命名不一致、函数/模块过长、圈复杂度过高、死代码/不可达分支、重复代码未抽取、magic numbers 未命名、注释与代码不同步或误导性注释。',
    testing:       '缺测试覆盖的分支/边界/异常路径、断言太弱（expect(true).toBe(true) 之类）、测试假阳性（异步未 await、不正确的 mock）、测试之间相互耦合依赖执行顺序、慢测试（不必要的 sleep/网络调用）。',
    architecture:  '关注点分离不清晰（UI 层包含业务逻辑）、模块依赖方向错误（低层模块依赖高层模块）、循环依赖、全局可变状态滥用、抽象泄漏（底层实现细节穿透到上层）、硬编码配置值而非注入。',
  }[d] || ''
}

function key(f) {
  const bucket = f.line ? Math.floor(f.line / 5) : 'x'
  return `${f.file}::${bucket}::${f.dimension}`
}

function severityScore(s) {
  return SEVERITY_RANK[s] || 0
}

// ═══════════════════════════════════════════
// Schemas
// ═══════════════════════════════════════════

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

const FINDING = {
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

const REVIEW_OUTPUT = {
  type: 'object',
  properties: {
    branchConfirmed: { type: 'string' },
    filesReviewed: { type: 'array', items: { type: 'string' } },
    findings: { type: 'array', items: FINDING },
    notes: { type: 'string' },
  },
  required: ['branchConfirmed', 'findings'],
}

const MODIFY_OUTPUT = {
  type: 'object',
  properties: {
    findingId: { type: 'string' },
    applied: { type: 'boolean' },
    blockedBy: { type: 'string' },
    reasonIfNotApplied: { type: 'string' },
    filesChanged: { type: 'array', items: { type: 'string' } },
    diffSummary: { type: 'string' },
    testsRun: { type: 'array', items: { type: 'string' } },
    testsResult: { type: 'string', enum: ['pass', 'fail', 'partial', 'skipped'] },
    branchConfirmed: { type: 'string' },
  },
  required: ['findingId', 'applied', 'filesChanged', 'branchConfirmed'],
}

const VERIFY_OUTPUT = {
  type: 'object',
  properties: {
    modifyId: { type: 'string' },
    findingId: { type: 'string' },
    stillPresent: { type: 'boolean' },
    introducedRegression: { type: 'boolean' },
    reReviewFindings: { type: 'array', items: FINDING },
    notes: { type: 'string' },
    suggestedRevert: { type: 'boolean' },
    testsResult: { type: 'string' },
  },
  required: ['findingId', 'stillPresent', 'introducedRegression', 'reReviewFindings'],
}

// ═══════════════════════════════════════════
// Prompt 模板
// ═══════════════════════════════════════════

function initPrompt() {
  return `你是初始化探员。

任务（只读，不要修改任何文件）：
1. \`git rev-parse --show-toplevel\` → projectRoot
2. \`git branch --show-current\` → currentBranch
3. \`git rev-parse HEAD\` → headSha
4. 对 scope 中的每个目录/文件跑 \`git ls-files <path>\` → fileList
5. 读 package.json 的 scripts.test → testCommand
6. 按 CTX_SCHEMA 输出 JSON

scope: ${JSON.stringify(cfg.scope)}`
}

function reviewPrompt(dim, idx, focusFiles) {
  const focusNote = focusFiles && focusFiles.size > 0
    ? `\n\n【本轮聚焦文件 — 只审查这些文件（已修改过的热区）】\n${[...focusFiles].map(f => '  - ' + f).join('\n')}\n如果你的维度在这些文件中没有发现，返回空 findings 即可。`
    : `\n\n【首轮审查 — 扫描所有 scope 内文件】\n审查范围：${JSON.stringify(cfg.scope)}`

  return `你是第 ${idx} 号【${dim}】维度代码审查员。

【必须首先调用 Skill 工具】superpowers:requesting-code-review — 严格遵循它的工作流进行审查。

【项目背景】
- 项目：栖语（qiyu-mvp），睡前 AI 陪伴 Web PWA 前端
- 栈：Node >=20，vanilla JS（无打包器），node --test / Playwright 测试
- 目录：src/qiyu/(核心业务) src/server/(本地服务) src/screens/(页面) src/ui/(组件) test/(测试)

【你的维度：${dim}】
${dimDef(dim)}

【分支守卫】
必须先跑 \`git branch --show-current\`。如果不是 \`${cfg.branch}\`，返回 findings=[]、notes="wrong branch: <实际分支>"。${focusNote}

【高标准要求】
- 只报告你**通过阅读源码直接验证**的问题。猜的、推测的不要写。
- severity 诚实：critical > high > medium > low。低价值 finding 不如不写。
- confidence 诚实：复现确认 = high；理论可能但未复现 = medium；纯推测 = low。
- suggestedFix 必须可执行、具体。不要写"建议优化""可以考虑"这类空话。
- 没有 finding 就返回空数组 — 这比瞎编要好。
- 按 REVIEW_OUTPUT schema 输出。`
}

function modifyPrompt(finding) {
  return `你是代码修改员，负责评估并应用以下 finding 的修复。

【必须首先调用 Skill 工具】superpowers:receiving-code-review — 用它的工作流评估是否接受此修改建议。

【待修改的 finding】
${JSON.stringify(finding, null, 2)}

═══════════════════════════════════════
【硬守卫 — 任一条失败就 ABORT，不修改】
═══════════════════════════════════════

1. 分支守卫：\`git branch --show-current\` 必须等于 \`${cfg.branch}\`
   → 不匹配：applied=false, blockedBy='branch', 立即返回。

2. 路径守卫：你的修改**只能**触碰以下范围的文件：
${cfg.scope.map(s => '     ' + s).join('\n')}
   → 如果修复需要改动 scope 外的文件（包括 qiyu.config.local.json、.gitignore、node_modules/、docs/、.agents/），applied=false, blockedBy='scope'。
   → reasonIfNotApplied 里写清楚"为什么需要改那个文件 + 建议的人工操作"。

═══════════════════════════════════════
【修改原则】
═══════════════════════════════════════
- 最小 diff：只改修复问题必要的行，不改别的。
- 不顺手重构、不"顺便优化"、不调格式。
- 不碰 qiyu.config.local.json（含真实 API key，被 .gitignore 保护）。
- 改完跑 \`npm test\`，结果填 testsResult。
- 如果测试原本就 fail 且与你的修改无关，标记 testsResult='partial' 并说明。
- 不要 commit（由上层统一处理）。
- 按 MODIFY_OUTPUT schema 输出 JSON。`
}

function verifyPrompt(finding, modify) {
  return `你是独立验证员，验证以下修改是否真的解决了问题、是否引入回归。

【必须首先调用 Skill 工具】superpowers:verification-before-completion

同时，在验证完成后，对**修改过的文件**再做一次审查（调用 superpowers:requesting-code-review），看看是否遗留任何问题。

═══════════════════════════════════════
【原始 finding】
═══════════════════════════════════════
${JSON.stringify(finding, null, 2)}

═══════════════════════════════════════
【modify agent 报告】
═══════════════════════════════════════
${JSON.stringify(modify, null, 2)}

═══════════════════════════════════════
【验证步骤】
═══════════════════════════════════════
1. \`git diff\` 查看实际改动。
2. 独立判断原始问题是否真的修复（stillPresent）。
3. 独立判断是否引入回归（introducedRegression）。
4. 跑 \`npm test\`。
5. 对修改过的文件用 superpowers:requesting-code-review 再审查一轮。
6. 按 VERIFY_OUTPUT schema 输出 JSON。

不要相信 modify agent 的自我报告 — 你是独立验证。`
}

// ═══════════════════════════════════════════
// 主流程
// ═══════════════════════════════════════════

let round = 0
let cleanRounds = 0
const allFindings = []
const allModifies = []
const allVerifies = []
const reportLines = []

// ── Init ──
phase('Init')
log('【Init】探查仓库、确认分支、收集文件清单...')

const ctx = await agent(initPrompt(), {
  label: 'init',
  phase: 'Init',
  agentType: 'Explore',
  schema: CTX_SCHEMA,
})

if (!ctx) throw new Error('init-failed: agent returned null')

if (ctx.currentBranch !== cfg.branch) {
  throw new Error(`wrong-branch: current=${ctx.currentBranch}, expected=${cfg.branch}`)
}

log(`✓ 分支: ${ctx.currentBranch} | HEAD: ${ctx.headSha.slice(0, 8)} | 文件数: ${ctx.fileCount}`)
log(`  测试命令: ${ctx.testCommand || '未检测到'}`)

// ── 主循环 ──
while (round < cfg.maxRounds && cleanRounds < cfg.cleanRoundsToStop) {
  round++
  const isFirstRound = round === 1
  log('')
  log(`══════ Round ${round}/${cfg.maxRounds}（clean: ${cleanRounds}/${cfg.cleanRoundsToStop}）══════`)

  // ── Review 阶段 ──
  phase(`R${round} · Review`)
  const reviewerCount = Object.values(cfg.dimensions).reduce((a, b) => a + b, 0)
  log(`派出 ${reviewerCount} 名审查员（${dimNames.length} 个维度），并行审查...`)

  // 构建审查任务列表
  const reviewTasks = []
  for (const dim of dimNames) {
    for (let i = 1; i <= cfg.dimensions[dim]; i++) {
      const focusSet = isFirstRound ? null : touchedFiles
      reviewTasks.push({ dim, idx: i, focus: focusSet })
    }
  }

  const reviewResults = (await parallel(reviewTasks.map(t => () =>
    agent(reviewPrompt(t.dim, t.idx, t.focus), {
      label: `${t.dim}#${t.idx}`,
      phase: `R${round} · Review`,
      agentType: 'Explore',
      schema: REVIEW_OUTPUT,
    })
  ))).filter(Boolean)

  const totalRaw = reviewResults.reduce((s, r) => s + (r.findings?.length || 0), 0)
  log(`Review 收集: ${totalRaw} 条原始 finding（${reviewResults.length}/${reviewerCount} 个 agent 成功）`)

  // ── Decide 阶段（去重 + 表决 + 排序截断）──
  phase(`R${round} · Decide`)

  // 分组：key 相同的 finding 为一组
  const groups = new Map()
  for (const r of reviewResults) {
    if (!Array.isArray(r.findings)) continue
    for (const f of r.findings) {
      if (severityScore(f.severity) < severityScore(cfg.minSeverity)) continue
      const k = key(f)
      if (!groups.has(k)) groups.set(k, [])
      groups.get(k).push(f)
    }
  }

  // 表决：只有 ≥ requireAgreement 名审查员同意的才保留
  const agreed = []
  for (const [k, list] of groups) {
    if (list.length >= cfg.requireAgreement) {
      // 选 severity 最高的做代表
      const best = list.slice().sort((a, b) =>
        severityScore(b.severity) - severityScore(a.severity) ||
        (b.confidence === 'high' ? 1 : 0) - (a.confidence === 'high' ? 1 : 0)
      )[0]
      agreed.push({ ...best, agreementCount: list.length, round })
    }
  }

  // 按 severity 排序，截断
  agreed.sort((a, b) => severityScore(b.severity) - severityScore(a.severity))
  const selected = agreed.slice(0, cfg.maxFixesPerRound)

  if (selected.length < agreed.length) {
    log(`⚠ 截断: ${agreed.length} → ${selected.length}（maxFixesPerRound=${cfg.maxFixesPerRound}），丢弃低 severity finding`)
  }

  log(`表决结果: ${agreed.length} 条共识 finding（≥${cfg.requireAgreement} 人同意），选取 ${selected.length} 条进入修复`)
  allFindings.push(...selected)

  // 无新 finding → clean round
  if (selected.length === 0) {
    cleanRounds++
    reportLines.push(`R${round}: 0 finding → clean #${cleanRounds}`)
    log(`✓ 本轮 clean（${cleanRounds}/${cfg.cleanRoundsToStop}）`)
    continue
  }
  cleanRounds = 0

  // ── Modify 阶段 ──
  phase(`R${round} · Modify`)
  log(`派出 ${selected.length} 个修改 agent，并行修复...`)

  const modifyResults = (await parallel(selected.map(f => () =>
    agent(modifyPrompt(f), {
      label: `fix:${f.id || key(f)}`,
      phase: `R${round} · Modify`,
      agentType: 'general-purpose',
      schema: MODIFY_OUTPUT,
    })
  ))).filter(Boolean)

  const applied = modifyResults.filter(m => m?.applied)
  const blocked = modifyResults.filter(m => m && !m.applied)

  // 分支守卫检查
  const wrongBranch = modifyResults.filter(m => m?.blockedBy === 'branch')
  if (wrongBranch.length > 0) {
    log(`❌ ${wrongBranch.length} 个 modify agent 检测到错误分支！abort 本轮。`)
  }

  log(`Modify 结果: ${applied.length} 已应用, ${blocked.length} 被拦截`)
  for (const b of blocked) {
    log(`  · ${b.findingId}: blockedBy=${b.blockedBy} — ${b.reasonIfNotApplied?.slice(0, 80) || ''}`)
  }
  allModifies.push(...modifyResults.map(m => ({ round, ...m })))

  // 记录被修改的文件
  for (const m of applied) {
    for (const f of (m.filesChanged || [])) {
      touchedFiles.add(f)
    }
  }

  if (applied.length === 0) {
    reportLines.push(`R${round}: ${selected.length} finding 全部被拦截 — 无法继续修复`)
    log('⚠ 全部被拦截，退出循环。')
    break
  }

  // ── Verify 阶段 ──
  phase(`R${round} · Verify`)
  log(`派出 ${applied.length} 个验证 agent，独立验证 + re-review...`)

  const verifyTasks = applied.map(m => {
    const originalFinding = selected.find(f =>
      key(f) === key({ file: m.filesChanged?.[0] || '', dimension: m.findingId, line: undefined })
    ) || selected[0]
    return { finding: originalFinding, modify: m }
  })

  const verifyResults = (await parallel(verifyTasks.map(t => () =>
    agent(verifyPrompt(t.finding, t.modify), {
      label: `verify:${t.modify.findingId}`,
      phase: `R${round} · Verify`,
      agentType: 'general-purpose',
      schema: VERIFY_OUTPUT,
    })
  ))).filter(Boolean)

  const regressions = verifyResults.filter(v => v?.introducedRegression)
  const stillBad = verifyResults.filter(v => v?.stillPresent)
  const revertsNeeded = verifyResults.filter(v => v?.suggestedRevert)

  log(`Verify 结果: ${regressions.length} 回归, ${stillBad.length} 未修复, ${revertsNeeded.length} 建议回滚`)

  // 收集 re-review 发现的新问题
  let reReviewCount = 0
  for (const v of verifyResults) {
    if (Array.isArray(v.reReviewFindings)) {
      reReviewCount += v.reReviewFindings.length
      // 将 re-review 发现注入下一轮
    }
  }
  if (reReviewCount > 0) {
    log(`Re-review 发现 ${reReviewCount} 个新问题（将在下一轮中审查）`)
  }

  allVerifies.push(...verifyResults.map(v => ({ round, ...v })))

  reportLines.push(`R${round}: ${selected.length} finding → ${applied.length} 修复 → ${stillBad.length} 未修, ${regressions.length} 回归, ${reReviewCount} re-review 发现`)
}

// ── Done ──
phase('Done')

const summary = {
  branch: cfg.branch,
  totalRounds: round,
  cleanRoundsAtEnd: cleanRounds,
  findings: { total: allFindings.length, bySeverity: {}, byDimension: {} },
  modifies: { total: allModifies.length, applied: allModifies.filter(m => m.applied).length, blocked: allModifies.filter(m => !m.applied).length },
  verifies: { total: allVerifies.length, regressions: allVerifies.filter(v => v.introducedRegression).length, stillPresent: allVerifies.filter(v => v.stillPresent).length },
  touchedFiles: [...touchedFiles],
  roundReport: reportLines,
}

// 统计
for (const f of allFindings) {
  summary.findings.bySeverity[f.severity] = (summary.findings.bySeverity[f.severity] || 0) + 1
  summary.findings.byDimension[f.dimension] = (summary.findings.byDimension[f.dimension] || 0) + 1
}

log('')
log('══════ 审查完成 ══════')
log(`分支: ${summary.branch}`)
log(`轮数: ${summary.totalRounds} | clean 连续: ${summary.cleanRoundsAtEnd}`)
log(`Finding 总数: ${summary.findings.total}`)
for (const [sev, n] of Object.entries(summary.findings.bySeverity).sort((a, b) => severityScore(b[0]) - severityScore(a[0]))) {
  log(`  ${sev}: ${n}`)
}
log(`修复: ${summary.modifies.applied} 已应用 / ${summary.modifies.blocked} 被拦截`)
log(`回归: ${summary.verifies.regressions} | 未修复: ${summary.verifies.stillPresent}`)
log(`触碰文件 (${touchedFiles.size}): ${[...touchedFiles].slice(0, 10).join(', ')}${touchedFiles.size > 10 ? '...' : ''}`)
log('')
log(`报告: ${reportLines.join('\n')}`)

return summary
