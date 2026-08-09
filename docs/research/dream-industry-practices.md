# 调研：Dream（记忆离线整理）业界实践

- **Ticket**: T13（设计闭环 / wayfinder:research）
- **日期**: 2026-08-06
- **调研方式**: WebSearch/WebFetch，优先官方博客、官方文档、arXiv 论文等一手来源
- **可靠性标注约定**: 「官方确认」= 一手来源可直接核实；「未核实」= 仅有二手转述或无法访问原文

## TL;DR

1. 「Dream」在 2026 年已是两大厂的**官方正式术语**：Anthropic 于 2026-05-06 Code with Claude 大会发布 Managed Agents **Dreams**（research preview，有完整 API 文档）；OpenAI 于 2026-06-04 发布 ChatGPT **Dreaming**（官方博客）。
2. 概念源头是 **Letta/MemGPT + UC Berkeley 的 sleep-time compute**（2025-04 论文 + 博客），主张 agent 在空闲期离线「思考」，重写记忆状态、预计算推理。
3. 两家大厂的 Dream 都**不直接原地改写记忆**：Anthropic 产出一个全新的 memory store（输入永不修改，开发者审阅后采用或丢弃）；OpenAI 产出可审阅的 synthesized memory summary（用户可纠正/忽略）。
4. 输入高度一致：**已整理记忆 + 近期原始对话**（Anthropic: memory store + 1–100 sessions；OpenAI: chat history）。
5. 整理动作高度一致：**合并重复、用最新值替换过期/矛盾条目**，并强调时间感知（stale 记忆随时间自动更新）。

---

## 1. Anthropic

### 1.1 Claude Code memory（CLAUDE.md + auto memory）

- **来源与性质**: 官方文档（code.claude.com），官方确认存在，持续更新中。
- **机制**: 两套互补机制，均在会话内完成，**无离线/后台整理**：
  - **CLAUDE.md**：用户手写的持久指令，每次会话全量加载。
  - **auto memory**：Claude 自己写的笔记，存为纯 markdown 目录（`~/.claude/projects/<project>/memory/`），含 `MEMORY.md` 索引 + 若干主题文件。每次会话只加载 `MEMORY.md` 的前 200 行或 25KB（先到者为准），主题文件按需读取。
- **触发时机**: 会话内。Claude 自行判断「什么值得记」；当 `MEMORY.md` 接近上限时，Claude Code **提醒 Claude 缩短**（keep one line per entry, move detail into topic files, merge or drop stale entries）——即「压缩」是会话内、由系统提示触发的，不是后台任务。
- **读写对象**: 读 `MEMORY.md`（自动）+ 主题文件（按需）；写纯 md 文件，写入时记录 `modified` 时间戳（YAML frontmatter，ISO 8601）。
- **冲突与纠错**: 无自动机制；文档明确说矛盾指令「Claude 可能任选其一」，靠用户定期人工清理。
- **引用**: <https://code.claude.com/docs/en/memory>

### 1.2 Claude API memory tool（2025）

- **来源与性质**: 官方文档 + 官方工程博客，官方确认。tool type `memory_20250818`（2025-08 beta，现已 GA，无需 beta header）。
- **机制**: **客户端文件工具**——Anthropic 定义 6 个命令（view / create / str_replace / insert / delete / rename），Claude 发起请求，**应用方执行并自行存储**（官方原话：memory lives entirely in your application）。本质是「一个 /memories 目录里的文件」。
- **触发时机**: 仅会话内。系统提示自动注入「先 view 记忆目录再干活；假设随时被打断，未记录的进度会丢」。
- **读写对象**: `/memories` 下的文件；按需读写（just-in-time retrieval），不是全量注入。
- **冲突与纠错**: 无内置整理。官方只给出建议（prompting guidance）：提示 Claude 保持记忆「up-to-date, coherent and organized」，以及开发者可自行「定期删除长期未访问的记忆文件」。**没有任何 consolidation / compaction / dreaming**。
- **引用**: <https://platform.claude.com/docs/en/agents-and-tools/tool-use/memory-tool>

### 1.3 context engineering 官方博文

- **来源与性质**: Anthropic 工程博客「Effective context engineering for AI agents」（2025-09-29），官方一手。
- **机制**: 提出 context rot 概念与三种长任务技术：**compaction**（接近窗口上限时摘要重启，会话内）、**structured note-taking / agentic memory**（把笔记写到窗口外、按需读回）、**sub-agent**。同文宣布 memory tool public beta。
- **触发时机**: 全部是**在线/会话内**机制；上下文重置后的恢复靠「读自己写的笔记」。
- **结论**: 该博文**没有**离线整理 / consolidation / dreaming 的内容。
- **引用**: <https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents>

### 1.4 Claude Managed Agents「Dreams」⭐（本次调研的核心发现）

- **来源与性质**: 官方文档（platform.claude.com）+ 2026-05-06 Code with Claude 大会发布（发布会信息来自 Ars Technica/InfoQ 等二手报道；机制细节以官方文档为准）。状态：**research preview**，beta header `dreaming-2026-04-21`。
- **机制**: Dream 是一个**异步 job**：
  - 输入 = 1 个已有 **memory store**（官方的记忆存储就是一组文本文件，挂载为目录，agent 在会话内用文件工具增量读写）+ **1–100 个 session 转录**；
  - 输出 = **一个全新的、重组后的 memory store**：官方原话「duplicates merged, stale or contradicted entries replaced with the latest value, and new insights surfaced」；
  - **输入 store 永不被修改**：「The input store is never modified, so you can review the output and discard it if you don't like the result.」
- **触发时机**: **按需、由开发者通过 API 创建**（`POST /v1/dreams`），不是自动定时任务。运行耗时「分钟到数小时」，随输入转录数量线性伸缩。可传 `instructions`（≤4096 字符）引导综合方向（如「聚焦编码风格偏好，忽略一次性调试笔记」）。
- **读写对象**: 读 memory store + session 转录；写一个独立的输出 store。开发者事后把新 store 挂到后续 session，或归档/删除旧的。
- **冲突与纠错**: 去重合并、以最新值覆盖过期/矛盾条目（见上）。此外 memory store 本身每次写入都产生**不可变的 memory version**（审计轨迹 + 时间点恢复，保留 30 天）——即使不跑 Dream 也有回滚能力。Dream 失败/取消时输出 store 保留部分内容供检查。
- **引用**:
  - <https://platform.claude.com/docs/en/managed-agents/dreams>
  - <https://platform.claude.com/docs/en/managed-agents/memory>
  - 发布报道: <https://arstechnica.com/ai/2026/05/anthropics-claude-can-now-dream-sort-of/>、<https://www.infoq.com/news/2026/05/code-with-claude/>

---

## 2. OpenAI：ChatGPT memory 与 Dreaming

- **来源与性质**: OpenAI 官方博客「Dreaming: Better memory for a more helpful ChatGPT」（2026-06-04）+ 官方帮助中心 Memory FAQ，官方一手。（openai.com 对抓取返回 403，正文经镜像获取，关键句均出自官方博客原文。）
- **机制演进（官方博客自述）**:
  1. **2024-04 saved memories**：只在对话中写入、依赖强线索触发、「容易过期」（官方原话：Saved memories were only written during the conversation / relied on strong cues / tend to go stale over time）。
  2. **2025-04 reference chat history**：「在后台通过引用聊天记录自动整理记忆」的方法上线，作为 saved memories 的补充，但官方承认「不足以独立作为记忆系统」。
  3. **2026-06 Dreaming（V3）**：「memory architecture built on top of dreaming」——后台进程从**大量对话**中学习，**synthesize ChatGPT's memory state**（合成整体记忆状态，而非逐条追加）。
- **触发时机**: 「background process」「automatically curate memories」；官方博客**未公布**具体触发条件与频率（是否在用户完全不使用时运行未明确说明——标注：未核实细节）。
- **读写对象**: 读 chat history（以及此前的 saved memories）；写「memories synthesized by dreaming」——一个可审阅的 **memory summary**。
- **冲突与纠错**: 官方给出的三个目标：carry forward useful context / follow preferences and constraints / **stay current over time**；「Memory should account for the passage of time」「memories are automatically updated as time passed」（例：旅行结束后「你要去新加坡」会被更新为「你 2026 年 7 月去了新加坡」）。显式的冲突消解算法未公开（未核实）。用户控制：memory summary 页面可**增补、纠正（correct）、忽略（dismiss）**具体条目。
- **灰度与成本**: 2026-06-04 起美国 Plus/Pro；数周内扩展到其他地区和 Free/Go（官方称服务 Free 用户的 dreaming 算力成本降低约 5 倍）。
- **Sam Altman 是否提过 dreaming**: 官方博客是「Dreaming」命名的官方出处；Altman 本人在 X 上宣传了此次记忆升级（"big upgrade to chatgpt memory rolling out today"），但**未找到他本人使用「dreaming」一词描述记忆整合的一手来源**（社区有转述，标注：未核实）。他多次公开说「下一个大突破是记忆而非推理」（CNBC 2025-08 等）。
- **引用**:
  - <https://openai.com/index/chatgpt-memory-dreaming/>
  - <https://help.openai.com/articles/8590148-memory-faq>
  - <https://openai.com/index/memory-and-new-controls-for-chatgpt/>（2024-04 初版 memory）

---

## 3. 概念出处：Letta/MemGPT 的 sleep-time compute

- **来源与性质**: 论文 arXiv:2504.13171（2025-04-17 提交）+ Letta 官方博客（2025-04-21）+ Letta 官方产品文档，全部一手。这是「agent 在空闲期离线整理记忆」这一方向最早的成体系工作，也是「Dream」一词在大厂产品中出现前的概念源头。
- **机制**:
  - 论文层面：sleep-time compute 指模型在**非服务时段**离线「思考」已有 context——预期用户可能的问题、**预计算**有用的推理，从而降低 test-time 算力（Stateful GSM-Symbolic 上约 5 倍推理节省且准确率不降，增加离线准备还可分别提升 13%/18% 准确率）。
  - 产品层面（Letta 博客原话）：sleep-time agent 在任务间隙「**rewriting their memory state**」，把「raw context」整理成「learned context」，形成「clean, concise, and detailed memories」。**直接改写记忆状态**（后台 editor 更新主 agent 的活跃记忆），不是产出候选。
- **触发时机**: 空闲期（sleep 是比喻）；Letta 官方文档（现状）给出两种可配置触发：**累计 N 条用户消息后** 或 **上下文窗口被压缩（compaction）时**，用 `/sleeptime` 配置。
- **读写对象**: 读近期对话与已有记忆；写 MemFS——**git-backed 的记忆文件系统**（官方文档：「Letta agents use MemFS, a git-backed memory filesystem」），dreaming 由**后台 subagent** 执行，「review recent conversations, consolidate useful lessons, and update memory」，直接 commit。
- **冲突与纠错/频率**: 博客未给出显式去重/纠错算法；**频率可调**（「run at different frequencies」，频率越高消耗 token 越多、修订越多）。
- **引用**:
  - <https://www.letta.com/blog/sleep-time-compute/>
  - <https://arxiv.org/abs/2504.13171>（Kevin Lin, Charlie Snell, Yu Wang, Charles Packer, Sarah Wooders, Ion Stoica, Joseph E. Gonzalez）
  - <https://docs.letta.com/configuration/memory/>
  - 代码: <https://github.com/letta-ai/sleep-time-compute>

---

## 4. 其他参考：Zep 的时序记忆（仅此一家入选）

- **入选理由**: 有 arXiv 论文一手材料，且其「事实过期处理」是所有来源中最精细的。Gemini memory 等未发现关于离线整理的一手材料，不展开（宁缺毋滥）。
- **来源与性质**: 论文 arXiv:2501.13956（2025-01-20），一手。
- **机制**: Graphiti 时序感知知识图谱。对话以 **episode** 形式非有损入库（episode 保留原文 + 引用时间戳）；提取事实为图的 edge。
- **冲突与纠错（最值得借鉴）**: **双时间轴（bi-temporal）模型**——一条轴是事实为真的时间，一条轴是系统记录的时间。新事实与已有事实在时间上重叠矛盾时，**invalidate（失效化）旧 edge 而不是删除**：「maintaining both current relationship states and historical records of relationship evolution over time」。
- **引用**: <https://arxiv.org/abs/2501.13956>

---

## 5. 对栖语 Dream 设计的启示

栖语约束回顾：纯 md 文件、无 RAG/向量/数据库、本地单用户、热层预算 2000–3000 tokens、零依赖 vanilla JS + Node。

### 可借鉴（6 条）

1. **产出草稿、不原地改写**（Anthropic Dreams）。Dream 读「热层 + 近期 episodes」，写出**新的热层草稿文件**（如 `memory.draft.md`），原热层在采用前保持不动；采用即替换，不满意即丢弃。本地场景下用 git commit 天然获得 Anthropic 靠 memory versions 实现的审计/回滚能力。
2. **整理动作清单明确化**（Anthropic Dreams 官方表述）：合并重复条目、用最新值替换过期或矛盾条目、浮现新洞察。这三条可以直接写进 Dream 的执行规则/prompt，不留模糊空间。
3. **输入 = 已整理记忆 + 近期原始证据**（三家一致：Anthropic 是 memory store + sessions，OpenAI 是 chat history，Letta 是 recent conversations）。对应栖语：热层 + 最近 N 天 episodes（必要时回溯 sessions raw），而不是只重读热层自己（避免信息衰减）。
4. **时间感知 + stale 更新**（OpenAI / Zep / Claude Code 的 modified 时间戳）。栖语热层条目应带日期标注；Dream 依据「今天的日期」判断哪些已过期（如旅行计划结束、情绪低谷已过），更新而非静默保留。
5. **触发时机显式定义、低频运行**。业界没有一家的 Dream 是每轮对话都跑的：Anthropic 按需 API 触发、Letta 每 N 条消息或 compaction 时、OpenAI 后台低频。栖语最自然的锚点是**睡前收束完成后**（会话结束事件）+ 最小间隔（如 24h 内不重复），与产品的睡前场景天然契合。
6. **预算即硬约束，索引与详情分层**（Claude Code auto memory）。Claude Code 用「MEMORY.md 限 200 行/25KB，超限系统强制要求压缩、详情移到主题文件」的模式管理注入预算——与栖语热层 2000–3000 token 预算同构。Dream 的产出必须塞进热层预算，超了就强制压缩/下沉到 episodes 层，而不是放宽预算。另外结果应**用户可见、可纠正**（OpenAI 的 correct/dismiss）：哪怕本地单用户，记忆写错对陪伴关系的伤害也大，至少在 `/lab` 或下次开场给用户一个「昨晚我整理了这些记忆」的可否决入口。

### 反例 / 不适用（3 条）

1. **Zep 的知识图谱与双时间轴图存储不适用**：需要图数据库与检索管线，违背「纯 md、无数据库、无 RAG」约束；只借鉴其「过期事实标记失效而非删除、保留演变痕迹」的思想（栖语可用 md 中的删除线/归档段落或 git 历史低成本实现）。
2. **Letta 论文的「预计算未来问题的答案」不适用**：栖语是睡前陪伴，回复价值在即时性与人格一致性，预测性问题预计算收益低、复杂度高，不做。
3. **OpenAI 式「全自动后台改写、默认无需用户确认」不完全适用**：那是为亿级用户降成本的设计；栖语单用户、本地、记忆即关系，建议 Dream 产出默认可见、可一键回退（结合第 1、6 条），而非静默覆盖。

### 未核实清单

- Anthropic/OpenAI Dream 的**具体运行频率与内部冲突消解算法**：官方均未公开细节。
- Sam Altman 本人使用「dreaming」一词描述记忆整合：未找到一手来源。
- OpenAI Dreaming 是否在用户完全不使用 App 时运行：官方博客只说 background process，未明确。
