# RAG 候选相关性与无证据处理调研

核查日期：2026-10-08。本文记录栖语 RAG 接入设计中 Q9 的研究依据；研究本身不替代用户裁定。用户后续已采纳精简 A，裁定记录见 `docs/specs/2026-10-08-rag-memory-recall.md`；本文不修改产品代码。

## 结论

公开一手资料支持一种足够简单的首版：检索产生候选，由本来就要回应的模型判断哪些证据能用于回答；没有相关证据时承认回忆不足。独立 LLM 评分器、专用 reranker、反思循环都是可以添加的机制，不能因为叫 RAG 就认为每种机制都必需。[OpenAI Retrieval](https://developers.openai.com/api/docs/guides/retrieval)、[Azure RAG 提示设计](https://learn.microsoft.com/en-us/azure/architecture/ai-ml/guide/rag/rag-prompt-engineering)

对栖语的设计推断是：保留既有文字组织调用与 Omni 的后续回答调用即可，不新增一次“审核模型”调用；文字组织模型明确拒绝了候选，就停止把这些候选保留到下一轮；Omni 直接收到的工具结果应标为候选，不能声称已经通过模型相关性判断。这是建议，仍需用户裁定。

本文没有行业普及率数据，不能据此断言“所有产品都这样做”或“这就是行业统一标准”。

## 来源与能够支持的事实

| 编号 | 一手来源 | 可核实的事实 | 不能据此推断的事 |
| --- | --- | --- | --- |
| S1 | [OpenAI Retrieval 官方指南](https://developers.openai.com/api/docs/guides/retrieval) | 搜索返回文本、来源与分数，再把结果与查询交给生成模型；提供 `score_threshold`，提高阈值也可能排除有用内容。 | 0–1 的搜索分数是事实正确率；某个阈值适合栖语；必须采用其托管存储。 |
| S2 | [Azure RAG 提示设计](https://learn.microsoft.com/en-us/azure/architecture/ai-ml/guide/rag/rag-prompt-engineering) | 官方示例直接指导回答模型：没有相关上下文时说明不足，部分可答时区分可答与缺失部分；结构化输出帮助下游解释结果。 | 提示词能保证模型永不幻觉；文档客服的拒答话术适合陪伴产品。 |
| S3 | [Azure 向量排序](https://learn.microsoft.com/en-us/azure/search/vector-search-ranking) | `k` 选择排名靠前的匹配；Azure 的向量 `@search.score` 是经过转换的分数，不能直接当原始 cosine；支持以阈值裁掉低质结果。 | 不同平台分数可直接比较；返回前几名就表示一定存在答案。 |
| S4 | [Azure Semantic Ranking](https://learn.microsoft.com/en-us/azure/search/semantic-search-overview) | 语义重排只处理既有结果集；可选 semantic answer 是从原文抽取，不是生成新事实；官方提醒分数分布会随环境与模型更新变化，不宜把阈值设得过细。 | 重排能找回首轮漏掉的证据；最高分条目自动解决纠正、有效期和隐私控制。 |
| S5 | [Anthropic Contextual Retrieval](https://www.anthropic.com/engineering/contextual-retrieval) | 基础流程把检索片段送进生成模型；实验再用 reranker 对候选排序、缩减后交给生成模型；重排增加运行时步骤，有延迟、成本与候选数量的取舍。 | 文中的候选数量和实验收益适合中文陪伴记忆；必须另加通用 LLM 评分器。 |
| S6 | [LlamaIndex Node Postprocessors](https://developers.llamaindex.ai/python/framework/module_guides/querying/node_postprocessors/node_postprocessors/) | 在检索与生成之间提供相似度过滤、关键词过滤与多种重排组件；`LLMRerank` 是其中一种，会让 LLM 返回相关文档与分数。 | 每个 RAG 必须安装全部组件；示例 `0.7` 是通用正确阈值。 |
| S7 | [Corrective RAG 原论文](https://arxiv.org/abs/2401.15884) | 研究引入轻量检索评价器，根据检索质量触发不同动作，并使用网页搜索扩充与内容分解重组。 | 评价器必须是额外通用 LLM；网页搜索适合找回用户私人经历；论文效果能直接套用栖语。 |
| S8 | [Self-RAG 原论文](https://arxiv.org/abs/2310.11511) | 原方案训练生成模型输出检索与反思 token，分别考虑片段相关、生成是否被支持和回答有用性；训练阶段有 critic，推理时由训练过的生成模型输出反思 token。 | 任意普通聊天模型加一句提示就等价于 Self-RAG；原论文一定要在线调用独立 critic。 |

全部来源均于上述核查日期实时检索和阅读。这里选取官方文档与原论文，未用二手博客或论坛回答作证据。

## 四件容易被混在一起的事

**候选召回**回答“哪些片段值得看”。向量相似度与 top-k 是相对排序方式。没有阈值或其他过滤、且库内候选足够时，它仍可以返回排名靠前但对问题无用的内容。[S1](https://developers.openai.com/api/docs/guides/retrieval)、[S3](https://learn.microsoft.com/en-us/azure/search/vector-search-ranking)

**重排**回答“候选中哪个更相关”。专用交叉编码器、服务端重排模型和 LLM 重排并非同一种调用方式；它们可以改善候选顺序或缩减数量。重排仍只操作召回候选，不能补出未召回的材料。[S4](https://learn.microsoft.com/en-us/azure/search/semantic-search-overview)、[S6](https://developers.llamaindex.ai/python/framework/module_guides/querying/node_postprocessors/node_postprocessors/)

**可回答性判断**回答“这些材料是否足够支持这次回答”。主题相关也可能缺少所问细节。例如记忆写了“准备面试”，不能据此回答“面试是否通过”。基础实现可以让已有生成模型按明确指令识别不足，不一定再开一个调用。[S2](https://learn.microsoft.com/en-us/azure/architecture/ai-ml/guide/rag/rag-prompt-engineering)

**事实有效性与使用授权**回答“内容现在是否仍有效、是否允许使用”。这是本项目的设计判断：禁提、删除、冻结、失效派生内容等必须由 Host 的确定规则执行，不能靠相似度、reranker 或模型自觉代替。相关性很高的旧错误仍可能不该使用。

因此，“没有候选”“候选不能回答”和“检索暂不可用”具有不同含义。任何一种都不能证明用户从未说过或事情从未发生。上述区别是根据检索和生成职责做出的设计推断，不是某个平台规定的协议。

## 对 Q9 复杂度的回答

不必把 Q9 A 理解成新加一个模型筛选层。已有文字召回组织模型原本就读候选并决定是否补发气泡；可以让它在同一次调用中给出明确的使用回执。已有的“无关则没有了”约定也可继续解析，关键在于把明确拒绝与调用失败、无有效解析区分开。

| 方案 | 新增运行时负担 | 何时值得考虑 |
| --- | --- | --- |
| 候选直接交给已有回应模型，明确允许忽略、说明不足 | 不新增独立 LLM 调用；提示与回执可能增加少量 token | 适合作为待验证的首版建议。 |
| 相似度阈值 | 程序比较分数；需要本项目校准 | 整理层评测能证明明显减少无关结果、且可接受漏召回时。 |
| 专用 reranker | 多一个推理步骤；可能本机计算或外部服务请求 | 整理层评测表明候选排序不足，再验证重排的实际贡献时。 |
| 独立 LLM grader | 额外一次或分批多次模型请求，以及解析、失败路径 | 既有生成模型利用候选仍频繁误答，且能证明新增判断改善结果时。 |
| CRAG / Self-RAG 式循环 | 额外评价、分支、检索或训练机制；具体开销依方案变化 | 首版之外的质量问题已有证据，简单方案不足时。 |

表中的首版取舍是本项目推断。现有“两阶段”指实验的两个交付阶段，当前检索仍为一次查询 embedding 加精确余弦 top-k，没有 reranker。新增重排属于另外的扩展，不是适配现有实验必须保留的步骤；建议首版暂不加入，整理层评测出现候选排序问题后再验证收益。重排和反思机制的能力与取舍见 [S5](https://www.anthropic.com/engineering/contextual-retrieval)、[S6](https://developers.llamaindex.ai/python/framework/module_guides/querying/node_postprocessors/node_postprocessors/)、[S7](https://arxiv.org/abs/2401.15884)、[S8](https://arxiv.org/abs/2310.11511)。

## 栖语现状与最小接入建议

以下代码定位由主调查提供：文字召回在本轮通过图谱 `get_code_snippet` 重新核验；Omni 定位来自前一轮调查，实施时应再核验。本文未独立执行产品用例。

- `packages/qiyu_local_host/lib/src/memory_recall.dart:232–291` 的 `_runTurnRecallInner` 在组织回复之后仍构造 pending。
- 同文件 `797–820` 的 `_validatedEntries` 把空或无效回执归成 `null`；`875–928` 的 `_composeBubble` 对调用异常与“没有了”哨兵均返回空的文字/条目；`934–976` 的 `_buildPendingContext` 在 `usedEntryIds == null` 时保留全部。
- 同文件 `1059–1124` 的 `_composeMessages` 已要求不相关时只输出“没有了”。问题是程序如何解释这个拒绝，现有文本链路已经有相关性判断调用。
- Omni 的 `lookupForRealtime`（`191–227`）与 `omni_call_service.dart:773–799` 直接把工具 context 回填；有 context 就是 `found`，未在回填前做文字组织判断。因此不能声称“found 已经通过独立模型审核”。

在已选择保留交付方式的前提下，最小设计建议是：

1. RAG 返回经过记忆控制与有效性校验的候选及来源，明确候选尚未等于已确认可用于回答。
2. 文字链路复用当前组织模型调用；明确不相关的回执不生成补发，也不保留到下一轮。若有有效使用条目回执，只保留允许范围中的条目，防止未用候选跟随。
3. 召回来得太晚、组织调用失败或输出无法解析，属于未完成判断；不要伪造“查过且无相关结果”。保留下一轮临时候选时继续明确其候选身份，并按既有到期/清理规则处理。具体协议和回执字段在实施设计中裁定。
4. Omni 维持工具回填与后续回应方式，由当前回应模型利用或忽略候选；工具结果清楚区分候选、无结果、不可用。没有结构化使用回执时不假造“已拒绝/已确认”的状态。
5. “回忆不足”仅限制用户历史事实断言，栖语仍可继续正常聊天或澄清；不把文档客服的整句拒答模板搬进陪伴回复。

这里没有建议新增永久的“已拒绝记忆”文件或跨轮拒绝索引，也没有建议调整五段记忆整理机制；明确拒绝是本次查询及其临时候选的处理结果。

## 建议重新呈现给用户的 Q9

建议选项 A 简化为：**检索得到候选，继续由已有回应调用决定使用；明确拒绝的候选本次作废，不带进下一轮；没有完成判断的结果仍标为候选；不为此新增独立评分调用。** Omni 由本来要回答的模型判断，工具结果不冒称已审过。

另一个选项是 B：主要使用分数阈值挡掉弱候选，但仍由回应模型决定是否足以回答；这需要先做阈值校准，不能直接套别家示例数值。阈值可以作为后续补充，不宜被描述成自动确认记忆。

用户在阅读调研结论后已采纳精简 A。本调研不替用户决定阈值、回执字段或未完成判断的具体到期策略；后续细节以设计草案中的裁定记录为准。

## 验证与局限

首版应加入整理层的无答案题、同主题不同事实题、只覆盖部分问题题、模糊指代题与旧错误/用户纠正题。至少分别观察：相关证据召回、最终历史事实是否有证据、错误自信回答、明确拒绝后下一轮是否再收到原候选、不可用是否被误写成没发生，以及文字/Omni 的一致性。这是本项目的验证建议。

现有实验是原始 sessions 检索，不能直接替代整理后内容和最终回答评测。官方资料的企业文档检索、英文公开问答及专门训练模型实验，也不证明栖语中文陪伴场景会有同样结果。本文没有重新跑实验、没有测量本项目新增延迟或费用、没有读取真实用户记忆或凭据。
