# 调研：PersonaTree 论文与 persona.md v1 设计依据

- **Ticket**: T14（设计闭环 / wayfinder:research），产出供 T15（persona.md 设计）使用
- **日期**: 2026-08-06
- **调研方式**: WebFetch 直接阅读 arXiv 原文（HTML v1 全文）+ arXiv abs 页元数据 + GitHub 官方仓库（MemTensor/InsideOut）；设计约束对照 `E:\Note\Agent\栖语` 设计笔记与 `CONTEXT.md`
- **可靠性标注约定**: 「原文」= arXiv 论文正文/摘要可直接核实；「仓库」= GitHub 官方仓库可核实；「未核实」= 一手来源中未找到（论文标注 NOT FOUND）或无法访问

## TL;DR

1. 两篇论文同名异体：**PersonaTree（北航等，2026-06）** 是「证据→模式→稳定主张」的三层生命周期记忆框架，核心机制是 conservative writing + log-odds 置信度驱动的 consolidation + 按需证据深度的路径检索；**Inside Out（人大 + MemTensor，2026-01）** 是「固定主干 schema + RL 训练的轻量写入器 MemListener 用 ADD/UPDATE/DELETE/NO_OP 原子操作增量更新枝叶」的用户画像树，主打可控增长与 persona 一致性。
2. 两者共同结论：**结构化画像比全量上下文又好又省**——PersonaTree 把答题输入 P95 压到 3k tokens 以下（全量历史 30k+）；Inside Out 用约 2.2–2.6k tokens 的记忆上下文超过 32k 全量对话的准确率。
3. 对栖语最可移植的是**思想层**：保守写入（多次证据、跨时间、无冲突才升级）、类型化分区、差异化衰减（边界几乎不衰减、偏好会褪色）、按需证据深度（热层只注入主张层）、NO_OP 优先（默认不写）。**数值置信度、embedding 检索、真树结构**三样必须舍弃（违反硬规则/无向量库/平文件约束）。

---

## 1. PersonaTree: Structured Lifecycle Memory for Person Understanding in LLM Agents

- **作者/机构**: Yubo Hou, Jingwei Song, Hongbo Zhang, Zhisheng Chen, Bang Xiao, Tao Wan, Zengchang Qin（通讯）；北航 ASEE/BME、港大、北大、国科大、VinUniversity（CAIR/CECS）（原文）
- **提交**: 2026-06-03，arXiv 2606.04780 [cs.CL]（原文）
- **引用**: <https://arxiv.org/abs/2606.04780>，全文 <https://arxiv.org/html/2606.04780v1>

### 1.1 核心视角

论文把「理解一个人」定义为 **schema formation**（图式形成）：「situated evidence is abstracted into reusable patterns and stable person level claims」——情境证据被抽象为可复用的模式和稳定的人物层主张。现有记忆系统只管「存与取」，不管「证据如何升华成人格理解」，这是它要补的位。（原文摘要）

### 1.2 树结构

**三层 + 类型化支持边（typed support edges）**，证据指向抽象，方向 leaf → mid → root。

每个节点统一为六元组 **v = (x, t, a, z, c, ℓ)**：文本内容 x、时间元数据 t、schema 属性 a、embedding z、置信度 c、抽象层级 ℓ ∈ {L, M, R}。（原文）

| 层 | 存什么 | 节点字段 | 类型（typed） |
|---|---|---|---|
| **叶 L** | 「timestamped interaction evidence」带时间戳的交互证据 | 事件摘要、时间戳、embedding、confidence、父指针 | 描述子：domain/scene tags、emotion tag、factual state、preference signal、boundary signal、role/schedule cue |
| **中间 M** | 「recurring behavioral or state patterns」重复的行为或状态模式 | 模式描述、模式类型、scene tags、情绪倾向、confidence、子叶集合 | 模式类型：condition trigger、trend change、frequency statistic、continuing state、preference strength |
| **根 R** | 「stable persona level claims」稳定的人物层主张 | 持久主张、特质类型、confidence、支持的 mid 集合、support coverage | 特质类型：personality、value、principle、objective identity、hard boundary |

边除父子关系外带：支持方向、证据类别（support / conflict / unrelated，细分 strong/weak support、weak/strong conflict）、时间/schema 兼容性标记。未发现跨父子的横向 cross-link（原文 NOT FOUND）。

**官方示例（一条完整支持路径）**：
- 根：「The user benefits from work arrangements with outdoor movement, flexible timing, and a low commute burden.」
- 中间：「The user prefers flexible work schedules or remote options that allow midday outdoor breaks or exercise sessions.」
- 叶：「An hour long car commute left the user fatigued and frustrated, leading to an aversion to long car commutes.」（原文）

### 1.3 写入策略

**Conservative writing（保守写入）**：新交互**先**成为类型化叶节点，只有当「schema compatibility and evidence validation」（schema 兼容 + 证据校验）成立时，才挂载到已有抽象上。宁可不挂，不可错挂。（原文）

**在线挂叶流程**：
1. 从新交互抽取类型化叶（文本 + 时间 + schema 属性 + embedding）；内容按属性类型归一（事实更新 / 主观偏好 / 安全约束）。
2. 候选 mid 必须先过 schema 兼容闸门，再算匹配分 = 余弦相似度与证据验证器打分的加权和（验证器项 ψ(l,m) ∈ [−1,1]，从 conflict 到 support 映射）。
3. 匹配分 ≥ 阈值 **θ_M** → 挂到该 mid；验证器判冲突 → 叶子独立保留并贡献负证据；无候选过阈 → 成为孤儿叶，等离线 consolidation。（原文；θ_M 具体数值未公布，**未核实**）

**证据验证器（evidence validator）**：一个 prompted model 步骤，输入「叶子文本 + 候选 mid 描述 + 相关属性」，输出 support / conflict / unrelated + 简短理由。论文明确：「semantic closeness alone does not determine whether a leaf supports an abstraction」——光靠 embedding 相似不够，必须有判断环节。（原文；完整 prompt 与类别→权重映射未公布，**未核实**）

**置信度更新（log-odds 空间）**：

```
L_t = (L_{t−1} − L_base) · e^(−λΔt) + L_base + ω_E
c_t = σ(L_t)
```

L_base 是基线先验，Δt 是距上次更新的时长，λ 是按节点类型的衰减率，ω_E 是验证器给的证据权重（支持为正、冲突为负）。**schema 类型决定衰减**：「Schema types whose content should persist can use reduced or zero decay」——持久型描述子用低衰减或零衰减；根层中「代表约束的根使用保守衰减」（conservative decay）；而「subjective preferences and affective patterns continue to fade」（主观偏好与情感模式持续褪色）。（原文公式与引语；λ 的具体数值未公布，**未核实**）

**离线 consolidation（叶→中间）**：重访未挂载叶子与低置信抽象；按 schema 属性、时间邻近、语义相似聚类孤儿叶；**「only when it contains enough evidence」且叶子支持一个一致的模式时**才生成 mid 候选；若聚类与已有 mid 匹配则挂载并重写该 mid 描述，否则新建 mid、成员叶成为其支持。（原文；「足够证据」的计数未公布，**未核实**）

**中间→根升级（confidence-guided consolidation 的最高档）**：使用**比中层更严的阈值**，判据三条：「high confidence, multiple supporting leaves or mids, and coverage across time」（高置信、多个支持的叶/中间节点、跨时间覆盖）。流程：选出过阈 mid → 把兼容 mid 分组为根候选 → 每组总结成一条持久用户主张。（原文；三个阈值的具体数值均未公布，**未核实**）

### 1.4 检索：query-conditioned path retrieval

1. **层级路由**：把 query q 路由到抽象层 h ∈ {L, M, R}——叶层答具体事件/细节/事实；中间层答习惯/近期状态/偏好；根层答建议/核心人格/深度理解。
2. **schema 约束预测**：预测查询的属性以收缩搜索空间。
3. **取候选支持路径**：root–mid–leaf 链。
4. **选证据深度**：d=0 只给根；d=1 根 + 支持 mid；d=2 完整 root–mid–leaf 链。
5. **token 预算下选择**：最大化 Σ [r(q,x) − λ_b·tok(x)]，约束 Σ tok(x) ≤ B_q。相关性 r 偏向「与查询对齐、被可靠或近期激活节点支持」的材料；token 罚项保证上下文紧凑。
6. **按需深挖**：只有当查询需要论证、时间细节或事件级支持时才取更深的证据。（原文；路由模型的实现/训练细节未公布，**未核实**）

### 1.5 冲突与变化

- **矛盾证据**：验证器三分类（support/conflict/unrelated）；冲突产生负证据权重进入置信度更新；与该抽象冲突的叶子**不被合并**、独立保留。（原文）
- **人格随时间变化**：论文**没有**显式的 personality-drift 机制（NOT FOUND）。最接近的替代：无新证据时置信度向基线衰减 → 不被支持的模式自然褪色；持久状态/约束用低/零衰减；mid 模式类型里有 trend change 与 continuing state 专门刻画趋势与持续状态；离线 consolidation 会重访低置信结构、剪掉弱节点。（原文）

### 1.6 生命周期（遗忘/归档）

- **衰减**：置信度随时间向基线衰减，速率按节点类型区分（见 1.3）。
- **遗忘/剪枝**（离线 consolidation 附带）：「stale nodes decay」（陈旧节点衰减）；「old orphan leaves are removed」（老的孤儿叶被移除）；每个 mid 只保留**有界数量**的支持叶；「prunes mids and roots with low confidence」（剪掉低置信的中间与根）。弱根被删时，其 mid 被解绑、作为局部模式仍可存活。（原文）
- **归档**：论文**没有**显式的 archive 存储或归档策略（NOT FOUND）。（原文）

### 1.7 实验结果（供预算论证引用）

- 6 基准（KnowMe / LongMemEval / RealPref / RealMem / CUPID / LoCoMo-Plus）× 3 应答骨干（Qwen3-32B / Gemini 3 Flash / GPT-5.4 Mini）：「12 of 18 compact scores」第一、16 个设置进前二。（原文）
- **token 效率（RealPref）**：全量历史输入 P95 30.23k tokens，PersonaTree 2.99k；每 100 轮增长全量 24.46k vs PersonaTree 0.27k；「P95 answer input below 3k tokens」。（原文）
- **层级消融（KnowMe）**：Leaf Only 43.3 → No Root 45.9 → 完整三层 47.6；抽象理解子项 T7 从 16.2 升到 24.3——**层级结构主要增益在「抽象的人格理解」**。（原文）
- **路径检索消融（RealPref）**：扁平节点 75.7 → 支持路径 78.1，偏好对齐 3.61→3.91、应答质量 4.00→4.20，而上下文反而从 3.18k 降到 2.99k。（原文）

---

## 2. Inside Out: Evolving User-Centric Core Memory Trees for Long-Term Personalized Dialogue Systems

- **作者/机构**: Jihao Zhao, Ding Chen, Zhaoxin Fan, Kerun Xu, Mengting Hu, Bo Tang, Feiyu Xiong, Zhiyu Li；人大信息学院、MemTensor（上海）、上海高等算法研究院、北航、南开（原文）
- **提交**: 2026-01-08（v1），2026-01-25（v2）；arXiv 2601.05171（原文）
- **代码**: GitHub **MemTensor/InsideOut**（仓库描述即「Inside Out: PersonaTree, MemListener」）——注意：这篇的**方法名就叫 PersonaTree**，与第 1 篇撞名（仓库）
- **引用**: <https://arxiv.org/abs/2601.05171>，全文 <https://arxiv.org/html/2601.05171v1>，<https://github.com/MemTensor/InsideOut>

### 2.1 核心视角

长期个性化对话系统的三个病：记忆噪声累积、推理退化、persona 不一致。解法：「a globally maintained PersonaTree as the carrier of long-term user profiling」——一棵全局维护的用户画像树；「constraining the trunk with an initial schema and updating the branches and leaves」——**主干用初始 schema 锁死、只更新枝叶**，实现可控增长（controllable growth），压缩记忆同时保一致性。写入由 RL 训练的轻量模型 **MemListener** 完成，产出「structured, executable, and interpretable」的原子操作。（原文摘要）

### 2.2 树结构

- **主干（trunk）**= 预定义初始 schema，论文称基于 **Biopsychosocial（生物-心理-社会）模型**、三大维度（原文）；但官方开源的初始树 `human_tree_en.json` / `human_tree_zh.json` 实际是 **5 个顶级类**：1_Biological_Characteristics、2_Psychological_Characteristics、3_Personality_Characteristics、4_Identity_Characteristics、5_Behavioral_Characteristics，嵌套约 4 层（顶级 → 分支 → 子分支 → 属性槽）（仓库）。与栖语相关的叶子属性槽示例：Sleep_Characteristics、Circadian_Rhythm、Emotional_Baseline、Behavioral_Habits、Communication_Style、Interpersonal_Relationships（含 Sense_of_Boundaries）、Values、Life_Beliefs、Key_Life_Events 等（仓库）。
- **叶 = 属性槽（attribute slot）**：存储类型是「descriptive string」——压缩后的用户属性描述文本。节点用 **JSON key path**（英文句点分隔）寻址。（原文）
- **没有**逐节点的 confidence/timestamp/embedding 等数值字段（原文 NOT FOUND）——这是它与第 1 篇最大的结构差异：它是一棵**纯文本槽位树**。

### 2.3 写入策略

论文**没有**「conservative writing」术语（NOT FOUND），其保守性体现在别处（见下）。

**写入循环**：对话归一为 chunk → 载入上一版树 + 规则 → 模型生成原子操作 → parser/executor 校验执行 → 持久化为新版树。四个原子操作：

| 操作 | 语义 |
|---|---|
| `ADD(path, value)` | 向路径写文本；在扩展 schema 策略允许时可创建新路径 |
| `UPDATE(path, value)` | 覆盖目标叶；**要求整合**新旧信息而非盲目替换（见 2.5） |
| `DELETE(path, value)` | 清空目标叶或写删除标记 |
| `NO_OP()` | 该 chunk 没有稳定 persona 信息时**什么都不做** |

**Executor = 「safety gate」**：校验路径必须落在允许的叶、值必须是字符串或允许的删除标记、长度控制把超长值压缩到「per-leaf budget」（每叶预算，具体 token 数未公布，**未核实**）；executor **不做**语义改写或冲突消解——所有语义判断都在操作生成阶段完成。（原文）

**MemListener 训练**：SFT + 带过程奖励（process-based rewards）的 RL；训练集 28k 条指令（HaluMem / PersonaMem 子集构造）；关键超参：最大上下文 11K、输入上限 10K、最大生成 512、group size 8、clip 0.2/0.28、KL β 0.001、lr 1e-6。（原文）

### 2.4 检索

- **快速模式（latency-sensitive）**：最终树状态直接作为结构化记忆，树结构 + 非空叶文本 + 用户 query 一次生成。（原文）
- **Agentic recall 模式**（用户要细节 / 长尾查询）：以树和 query 为条件生成**多个扩展查询**（各指向不同属性维度或可能缺失面）→ 并行检索候选证据 → 重排 → 融合上下文 → 生成。检索器 BGE-M3、重排器 BGE-Reranker-Large、检索条数 4。（原文）
- 路径如何打分/遍历的算法细节：NOT FOUND（**未核实**）。

### 2.5 冲突与变化

冲突处理发生在**操作生成阶段**（模型同时看到当前 chunk 和上一版树），不在 executor：

- **矛盾时**：prompt 规定「most recent explicit statement」胜出——最新的明确陈述优先。（原文）
- **UPDATE 语义 = 整合而非覆盖**：新值应整合原有仍有效的信息与新信息；prompt 禁止在 UPDATE 时丢弃有用的旧内容；新旧冲突时，值应描述「current latest and most reasonable state」同时保留不冲突的旧细节。（原文）
- **DELETE 语义 = 显式失效**：只有对话明确说已有信息不再有效、被否定、应移除时才用。（原文）
- **随时间变化**：树随 chunk 迭代演化、每次更新产生新版树；基准中专设 **Pref-Evol**（偏好演化）评测项。（原文）

### 2.6 生命周期（遗忘/归档）

- **噪声控制**：NO_OP 阻止非核心信息写入；DELETE 移除/标记失效；长度控制压缩超长叶；容量由树 schema + 每叶预算封顶。（原文）
- **版本化持久**：更新后的树序列化为 JSON（可存 MongoDB），形成可追溯的树版本序列。（原文）
- **没有**时间衰减、置信度衰减、自动过期/归档策略（NOT FOUND）。（原文）

### 2.7 实验结果

- 基准：**PersonaMem**（每段历史约 10 场多轮对话、总上下文约 32K tokens、15 个真实个性化类别；7 项技能：Recall-Facts / Pref-Rec / New-Ideas / Recall-Reason / Pref-Evol / Gen-New / Recall-User）。（原文）
- 总体准确率（PersonaTree 最佳配置）：DeepSeek-V3.1 应答 71.31（+18.68 vs Only LLM，+8.83 vs MemoryOS）；Longcat-Flash-Chat 75.38；DeepSeek-R1-0528 76.06（其中 Pref-Rec +18.18、New-Ideas +17.20 vs 全量对话）。（原文）
- **上下文效率**：全量对话约 32K tokens；训练后的 PersonaTree 平均记忆上下文约 **2.2–2.6k tokens**（Qwen2.5-7B SFT+RL 2626、Qwen3-8B SFT+RL 2348）。（原文）
- 「小模型 MemListener 的记忆操作决策能力可比肩甚至超过 DeepSeek-R1-0528、Gemini-3-Pro 等强推理模型」。（原文摘要）

---

## 3. 两篇对照

| 维度 | PersonaTree（北航等，2026-06） | Inside Out（MemTensor 等，2026-01） |
|---|---|---|
| 树的形态 | 证据驱动生长的三层（叶证据/中间模式/根主张）+ 类型化支持边 | 固定主干 schema（生物心理社会/5 大类）+ 只更新枝叶的文本槽位树 |
| 节点内容 | 六元组：文本+时间+属性+embedding+置信度+层级 | 纯描述字符串（属性槽），无数值字段 |
| 写入 | 保守挂叶 + log-odds 置信度 + 离线 consolidation（叶→中间→根逐级升级） | MemListener 生成 ADD/UPDATE/DELETE/NO_OP，executor 只做形式校验 |
| 冲突 | 验证器判 support/conflict/unrelated；冲突=负证据、不合并 | 最新明确陈述胜出；UPDATE 整合不覆盖；DELETE 仅限显式失效 |
| 衰减/遗忘 | 类型差异化时间衰减 + 孤儿叶移除 + 低置信剪枝 | 无衰减；靠 NO_OP 拒写、每叶预算、DELETE |
| 检索 | 层级路由 + 支持路径 + 证据深度 d=0/1/2 + token 预算选择 | 快速模式整树直注；复杂查询走 agentic recall（查询扩展+检索重排） |
| 评测规模 | 6 基准 × 3 骨干，18 项 compact score 12 项第一 | PersonaMem 单基准，3 个应答模型 |

---

## 4. 对栖语 persona.md v1 的启示

**栖语约束（来自硬规则/CONTEXT.md/T15）**：纯 md 平文件（不做真树/文件夹）；热层 persona 块预算 300–600 tokens（热层总预算 2000–3000）；无向量库/数据库；**明确不加 confidence/priority/version 字段**；persona.md「不提供具体事实」（事实优先级见硬规则）。

### 4.1 可借鉴点（能用平文件表达的）

1. **「主张层」是画像的最高性价比形态（按需证据深度 d=0/1/2）**：PersonaTree 检索默认只给根主张、需要论证才加深证据，由此把输入压到 P95 <3k、每 100 轮仅增长 0.27k。平文件翻译：**persona.md 只写主张，不写证据与过程**——证据永远留在冷层 episodes，需要时走检索层。这一条直接支撑 300–600 tokens 预算成立。
2. **保守写入的升级判据（定性翻译 confidence-guided consolidation）**：论文的根升级三条件是「高置信 + 多个支持证据 + 跨时间覆盖」。去掉数值后平文件可执行的等价判据：**同类信号在 ≥2 个独立日期出现、跨 ≥1–2 周、且无用户纠正，才可从 episodes 升级进 persona.md**；单次观察一律不升级（对应论文「叶先独立存在、不急着挂」）。
3. **NO_OP 优先（Inside Out）**：MemListener 的四个原子操作里，默认动作是「这个 chunk 没有稳定 persona 信息 → 什么都不做」。平文件翻译：**Dream 整理时对 persona.md 的默认动作是「不变」**，日终归档几乎不应触碰 persona.md，只有月压缩级别的重复证据才产生候选变更。
4. **类型化分区（typed schema 的平文件版）**：PersonaTree 根节点特质类型为 personality / value / principle / objective identity / hard boundary。persona.md 用**小节分区**承载这个类型系统（如「身份与客观事实 / 性格与表达 / 价值观与原则 / 偏好与习惯 / 边界与禁区」），每条条目因此自带隐含类型——预算超限时按类型砍、冲突时按类型定处理策略都有抓手。**但不要照抄 Inside Out 的全量属性树**（human_tree_en.json 有 5 大类约 200 个属性槽，是穷举式人类特质百科；栖语预算只容得下证据驱动的稀疏条目）。
5. **差异化衰减 → 稳定性分区（类型差异化 decay 的平文件版）**：论文里「持久约束用保守衰减、主观偏好与情感模式持续褪色」。平文件翻译：**小节按稳定性从高到低排列**（身份/边界在上，偏好/习惯在下）；Dream 复核时底部小节频率最高、替换门槛最低；「边界与禁区」条目除非用户明确收回，几乎不动（对应 Inside Out 的 DELETE 语义：只有显式失效才删）。
6. **UPDATE = 整合而非覆盖（Inside Out 的冲突语义）**：矛盾时「最新明确陈述胜出」，但要保留不冲突的旧细节。这与栖语硬规则完全同向（「用户当前纠正最高」「遇到冲突不要立刻合并成一个新事实」）。平文件翻译：persona 条目被纠正时，**改写该条为最新表述**，而不是删掉重写、也不是新旧并列。
7. **层级结构本身的价值有实验背书**：KnowMe 消融显示层级（叶→中间→根）把抽象人格理解 T7 从 16.2 提到 24.3——即使 v1 用平文件模拟两层（主张 + 可选模式区），方向也是对的；证据层（episodes）与主张层（persona.md）分离本身就是层级的最小形态。

### 4.2 必须舍弃的

1. **数值置信度与阈值机制**（PersonaTree 的 confidence、log-odds 更新、θ_M、升级阈值）：与「不加 confidence/priority/version 字段」的硬规则直接冲突，且论文自身未公布数值。用 4.1-2 的定性判据（多次 + 跨时间 + 无冲突）替代。
2. **embedding + 验证器 + schema 约束检索**：栖语无向量库；且 persona 块是全量注入（300–600 tokens），不存在「路由到哪一层」的检索问题——PersonaTree 的 query routing 解决的是大记忆库的取数成本，对全量注入的小文件不适用。
3. **真树结构、JSON 路径操作、版本化持久**（Inside Out 的 path 寻址 / executor / MongoDB 版本链）：v1 是单个平 md 文件，层级只体现在 markdown 小节上；结构化树与原子操作引擎是 P2 PersonaTree 阶段的事（T15 已注明）。

### 4.3 边界建议：persona.md vs long-memory.md vs daily-state.md

三个文件按**回答的问题**分工，任何一条信息只进其一（沿用「任何字段只许有一个家」原则）：

| 问题 | 归属 | 内容性质 | PersonaTree 类比 |
|---|---|---|---|
| 「这个人是**什么样**的？」 | **persona.md** | 稳定特质主张：性格、价值观、原则、客观身份、硬边界、稳定偏好模式 | 根（+ 已稳定的中间模式） |
| 「这个人**经历过什么**？」 | **long-memory.md** | 人生印象压缩：重要的人/事/关系轨迹（叙事性压缩） | 不直接对应——它是叙事压缩，不是特质主张 |
| 「这个人**最近在**经历什么？」 | **daily-state.md** | 近 7 天投影：时间感、气氛、近日活跃、当前近况；每日重写 | 叶证据的当日投影（但证据本体在 episodes） |
| 「那天具体发生了什么？」 | episodes（冷层，不注入） | 证据本体 | 叶 |

**不撞车的具体规则**：

1. **persona.md 禁带时间词**：条目里不许出现「最近 / 这周 / 这几天」——一旦带时间，它就属于 daily-state 或 episodes。persona 条目必须是可以半年后仍成立的表述。
2. **long-memory 管轨迹、persona 管由轨迹沉淀出的特质**：硬规则已有示例——「小时候和母亲关系亲近、后来疏远」是 long-memory；只有当它沉淀出稳定行为主张（如「用户很少主动提家人，家庭话题需试探」）时，后者才进 persona（且须过 4.1-2 升级判据）。这与论文一致：PersonaTree 的叶证据不直接变根，必须经模式抽象。
3. **persona.md 不提供具体事实**（硬规则已锁定）：「用户 2026 年 7 月换了工作」是事实 → episodes/long-memory；「用户做重大决定前习惯先列清单」是特质 → persona。
4. **流向与闸门**：episodes →（Dream 月压缩，按「多证据 + 跨时间 + 无冲突」判据）→ persona 候选变更；单次证据永远不进 persona。用户当前纠正可直接覆盖 persona 条目（硬规则最高优先级），但自动整理不主动删除——对应论文「剪枝保守、删除需显式依据」的精神，也符合「用户手动操作高于自动 Dream」。
5. **遗忘的平文件表达**：PersonaTree 靠衰减 + 剪枝遗忘；栖语 v1 的等价物是**冷层不注入**（未被升级的证据天然不进热层）+ **预算裁剪**（persona 超 600 tokens 时从稳定性最低的小节开始砍）+ Dream 复核时把长期无新证据支持的偏好类条目降级回 long-memory 或删除候选。

### 4.4 给 T15 的一句话输入

persona.md v1 的推荐形态：**一个 300–600 tokens 的纯 md 平文件，按稳定性从高到低分 4–6 个类型化小节（身份与客观事实 / 性格与表达 / 价值观与原则 / 偏好与习惯 / 边界与禁区），每条一行、写成「无时间词的持久主张」，条目格式形如 `- 用户做重大决定前习惯先列清单（多次深夜长谈中体现）`——括号内是可追溯的弱证据提示（平文件版的 support edge，非结构化字段），仅当 ≥2 个独立日期证据、跨 ≥1–2 周、无用户纠正时由 Dream 月压缩写入；默认动作是不写（NO_OP）。**

---

## 附录：未核实清单

- PersonaTree（北航）：θ_M、根升级三阈值、mid 最小支持数、衰减率 λ、验证器权重映射、路由模型实现的具体数值/细节（论文未公布）。
- Inside Out（MemTensor）：per-leaf budget 的具体 token 数、agentic recall 的路径打分算法（论文未公布）；论文摘要称 schema 为 Biopsychosocial 三维度，但开源树为 5 个顶级类，两者口径差异未见论文解释。
- 两篇论文的 v1 之后版本更新内容（Inside Out 有 v2，2026-01-25；本调研基于 v1 全文，v2 差异未核）。
