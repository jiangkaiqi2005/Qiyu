# AGENTS.md

This file provides guidance to Claude Code (claude.ai/code) and other coding agents when working with code in this repository. `CLAUDE.md` is a symlink to this file — edit this file, never the link.

## 交互语言（最高优先）

**面向用户的所有输出一律用中文**：对话、提问、选项、报告、解释、ticket 与地图文字。代码、文件路径、字段名、命令等技术标识保留原文，但解释性文字必须中文。

## What this repository is

栖语 (qiyu) MVP：一个睡前 AI 陪伴原型，重点在行为层——人格一致性、本地记忆、关系阶段、微摩擦、少回应、睡前收束、安全边界。

当前 Release 1 交付形态是 **Flutter Web UI + Dart Windows 本机 Host + 纯 Dart 行为核心**。Windows Host 只监听 `127.0.0.1`，负责静态资源、Provider 调用、凭据与 Markdown 持久化；浏览器只负责 UI，API Key 永远不进入浏览器。旧 Node/JavaScript 产品轨道已在 Ticket 26 退役；`contracts/qiyu_behavior_contracts.json` 是当前可执行 Release 契约，`contracts/legacy-migration-golden-cases.json` 只冻结保留旧迁移 golden，不接入当前状态模型。

## 设计笔记权威（最高设计优先级）

本项目的定稿设计笔记在 `E:\Note\Agent\栖语`（Obsidian 库），本仓库一切行为、人格、提示词与记忆机制改动必须与其对齐：

- 根目录：`栖语产品灵魂.md`（产品目标与人格基调）、`栖语目标达成效果.md`（体验验收判准）、`栖语机制想法.md`、`栖语还存在的问题.md`、`栖语启动.md`（运行说明）。
- `栖语system prompt/`：可注入提示词模块——人格宪法、硬规则与优先级（输出契约/首响速度/事实来源优先级/安全与专业边界）、Memory注入、每日状态包、自我世界、总览、具体实现（装配图，ticket T11 定稿）。
- `栖语记忆/`：记忆方案定稿——Memory（五层）、long-memory、open-loop、Dream（每周一次、晚安后、距上次 ≥7 天）、checkpoint、PersonaTree（五分支真树）。
- `设计闭环/`：设计地图与 tickets T01–T27，每张 ticket 的 Resolution 即定稿答案。

对齐规则：

- 改动前先查笔记对应定稿；**发现代码与笔记出入时，第一时间向用户报告，不得擅自裁定哪边为准**。
- 不要仅凭设计笔记声称功能已实现；涉及行为、存储或提示词注入时，必须对照本仓库实际代码与运行结果。
- 笔记中已定稿但尚未实现的机制（Dream、PersonaTree 真树、月压缩、memory-controls 冻结/禁提、热层预算控制等）落地时必须照定稿实现，不得自行偏离或简化；当前实现进度以 `apps/qiyu_windows_host` 中 episode_memory 等 TODO ticket 为准。
- 记忆与笔记内容必须隐私优先：密钥、密码、Cookie、证件号和原始敏感对话不得写入记忆或注入内容。
- 程序代码仓库为 `E:\Agent\Qiyu`；笔记中 `栖语启动.md` 与其 AGENTS.md 的运行路径已于 2026-08-16 同步修正为该路径，两侧保持一致。

## Commands

```powershell
& .\scripts\verify-release-baseline.ps1 # Dart/Flutter/Windows Host/构包与冒烟全量验证
& .\scripts\build-windows-bundle.ps1    # 构建可安装的 Windows Host + Flutter Web 资源包
```

- 跑单个 Host 测试文件：在 `apps/qiyu_windows_host` 下运行 `dart test test/local_chat_service_test.dart`。
- Dart Core：在 `packages/qiyu_behavior_core` 下运行 `dart analyze && dart test`。
- Flutter：在 `apps/qiyu_flutter` 下运行 `flutter analyze && flutter test`。
- Windows Host：在 `apps/qiyu_windows_host` 下运行 `dart analyze && dart test`。
- 未配置 LLM 时应用自动降级为本地规则引擎，功能完整可测。

## Architecture

### 分层

- `packages/qiyu_behavior_core/` — **纯 Dart 行为与协议核心**，不依赖 Flutter、DOM、Node、Windows API 或具体存储。`QiyuBehaviorCore.reply` 负责安全分类、本地回复、候选模型输出清洗/人格边界校验与降级；稳定 DTO、`ChatDeliveryEvent` 流式事件协议也在这里。
- `apps/qiyu_flutter/` — Flutter Web UI。`features/chat/` 负责本机会话恢复、NDJSON 事件消费、等待/渐进文本/停止生成界面；`features/settings/` 负责 Provider 设置与连接测试。浏览器不持久化 Provider Key。
- `apps/qiyu_windows_host/` — Dart Windows 本机 Host。`LocalAppHost` 提供 loopback 静态站点和受会话、Origin、CSRF 保护的 API；`LocalChatService` 编排安全回复、流式交付与会话持久化；`ProviderModelGateway` 适配 OpenAI-compatible、Anthropic、Ollama；`MarkdownMemoryRepository` 管理本地 Markdown 会话。
- `contracts/` — `qiyu_behavior_contracts.json` 是纯 Dart Core 直接消费的当前行为契约；`legacy-migration-golden-cases.json` 是 4a5d24f 旧 golden 的冻结历史快照，只供迁移审计与完整性门禁，不由当前运行时消费。
- `scripts/verify-release-baseline.ps1` 串联所有分析、测试、Flutter Web 构建、Windows bundle/preflight/launch smoke 与发布策略检查。

### 回复管线（核心数据流）

Flutter `/chat` → `HttpLocalChatGateway` → `POST /api/chat` → `LocalChatService.deliver`：

1. Host 先校验 `requestId`/文本，按 `requestId` 幂等写入用户原始消息；写入 sessions 的文本只做 secrets 脱敏，发送给安全分类与模型的文本另行清洗类 XML、ChatML 与角色控制结构。
2. `QiyuBehaviorCore.reply` 先在本地分类危机、医疗、法律、金融等 non-normal 输入；这类输入**绝不调用 Provider**。未配置 Provider、Provider 失败或模型输出不合格时统一走本地规则回复。
3. 普通输入通过 `ModelPromptBuilder` 按定稿装配图组装上下文：人格宪法（`栖语人格宪法.md`）→ 硬规则与优先级 → 隐藏块协议 → `<daily_state>`【近况】/ `<long_memory>`【长期印象】/ `<persona>`【用户画像】（空块不输出；自我世界 v1 不注入）→ 最近已完成会话 → 格式提醒 → `<memory_context>`【检索结果】（只有命中才出现，临时附加不进 system prompt）→ 当前消息，再交给 `StreamingProviderChatClient`。装配前读取 `memory-controls.md` 过滤冻结/禁提内容，controls 本身不进 prompt。
4. `ProviderModelGateway` 将 OpenAI SSE、Anthropic SSE、Ollama NDJSON 统一为 `delta / done / failure`。只有收到协议原生终止标记（OpenAI `finish_reason`/`[DONE]`、Anthropic `message_stop`、Ollama `done:true`）才算完成；提前 EOF、超时或原生 error 必须失败并降级，不能把半句当完整回复。
5. Provider 的原始增量先在 Host 内完整缓存；候选回复通过结构清洗、违禁词与人格边界校验后，才以共享 `ChatDeliveryEvent` 协议发送 `accepted → waiting → [fallback] → delta* → message → state → done`。页面绝不能看到未经完整安全校验的原始 token。
6. 用户可通过 `/api/chat/cancel` 按 `requestId` 停止生成；取消会向下取消 Provider/HTTP 流，只保留可重试的用户 turn，不把已展示半句或未完成候选记录为完整栖语回复。
7. 只有安全可见文本交付完成后才追加栖语 turn。刷新、Host 重启或同一 `requestId` 重试必须复用已有用户 turn/已完成回复，不能重复展示或落盘。晚安类输入在本地直接收束，不调用 Provider、不开新话题。
8. 召回模型查找轮内循环：本轮模型在隐藏块发出 `memory_recall` 时，bubble 1 交付后 Host 读取两级索引（`episodes/index.md` → `episodes/YYYY/MM/index.md`）连同查找意图递回，模型选月份/日期，代码做成员校验（选取必须出自递过的目录，编造的丢弃记诊断），再回读选中日原文递回，模型组织 bubble 2。命中快（秒级窗口预算）且用户未停止时用同一套 `ChatDeliveryEvent` 交付与安全校验补上，落为同一 `requestId` 的栖语 turn；没赶上则压缩结果并入下一用户轮 `<memory_context>`。查找只由模型隐藏动作触发，无规则兜底、不打分；晚安/安全回复/未配置 Provider 不查找。

**本地规则引擎不是占位 stub，而是行为基准（ground truth）**：黄金 eval 锁定的就是它的输出。

### 状态与配置

- 主链路会话由 Windows Host 写入本机 Markdown sessions；单段最多 80 turns，活动历史窗口 180 天。浏览器刷新后从 Host 恢复，不以 localStorage 作为主持久化层。无账号、无云端记忆。
- Provider 非敏感配置写在本机 runtime 目录；API Key 由 Windows Credential Manager 保存。切换 Provider/URL 时不得沿用另一 credential scope 的旧 Key。
- 支持 OpenAI-compatible、Anthropic、Ollama。地址规范化、鉴权头、请求体、流式解析和错误分类集中在 Provider 层；不要在 UI 或 Chat Service 重复 Provider 分支。
- 安全不变量：Host 仅监听 loopback；API 需要 Host 会话，修改请求还需同源 Origin + CSRF；读取设置永不返回明文 Key；对外错误只返回允许列表诊断，禁止透出授权头、Cookie、完整敏感输入、第三方错误原文或本机路径。
- Release 1 不迁移旧 localStorage 或旧 `qiyu.config.local.json`。不要重新引入旧 Web 产品入口或浏览器持久化主链路。

## Behavior constraints（改动回复行为前必读）

- `栖语产品灵魂.md` 是人格/风格的最高优先级设计依据（只作设计文档，不再注入 prompt）；注入 system prompt 的是从它定稿的 `栖语人格宪法.md`（与笔记 `栖语system prompt/人格宪法.md` 保持同步，仓库版去除 Obsidian 链接）；`docs/product/behavior-spec.md` 是从它提炼的工程行为规范。
- 人格基调固定为「温暖但不讨好，聪明但不炫耀，安静但不冷淡」；不要把示例话术扩展成机械模板。
- 关键约束：默认少说（回复频谱取最少一侧）；禁止客服式话术（`FORBIDDEN_PHRASES`，如「我理解你的感受」「谢谢你愿意和我分享」）；用户说「晚安」只收束、不开新话题；调侃/翻旧账只在关系变深后出现；一致性高于聪明（宁可笨，不可不一致）。
- 改回复逻辑时同步更新 `contracts/qiyu_behavior_contracts.json` 和 Dart Core 消费测试，并运行完整 Release 1 门禁。
- `contracts/qiyu_behavior_contracts.json` 是退役后仍保留的规范 fixture；不得以实现内常量或单端自测替代它。

## Testing conventions

- Dart Core、Flutter、Windows Host 各自在包内维护测试。Host 通过抽象接口注入 Provider、HTTP、凭据、时钟和原子写入；Flutter widget 测试注入流式 gateway 与 Host probe。
- 流式改动至少覆盖：三种 Provider 正常终止、提前 EOF、超时/原生错误、底层订阅取消；Host 正常/取消/半途失败/本地回退/晚安/刷新重启幂等；Flutter 等待态、安全增量可见节奏、停止按钮与最终只提交一次。
- 交付前运行 `& .\scripts\verify-release-baseline.ps1`，不能只跑本次改动的专项测试。门禁必须保持 Dart analyze/test、Flutter analyze/test/Web build、Windows Host analyze/test、安装生命周期、bundle 校验、preflight 与 launch smoke 全绿，且不得依赖 Node/npm。

## 提交规范（与设计笔记对齐）

- 每次提交必须同时包含非空标题和描述正文，并且不得添加 `Co-authored-by` 或任何协作者、共同作者信息。
- 标题用中文「动词 + 模块 + 内容」，如 `完善 栖语 Memory 注入规则`。正文写清影响的人格、提示词、记忆或运行说明，以及代码或测试验证；只暂存本项目明确文件。若改变可见行为，PR 中附运行步骤和实际结果。

## Notes

- 本仓库已建立 codebase-memory 知识图谱索引（项目名 `qiyu`），可用 `search_graph` / `trace_path` / `get_architecture` 等 MCP 工具做代码探索；结构性大改后可重新 `index_repository`。
- `.codebase-memory/` 下的产物（`graph.db.zst`、`artifact.json` 等）由索引进程自动更新，属于预期变更：**必须随引起变化的功能提交一起 commit 并推送，严禁为索引产物单独提交（不要再出现「刷新知识图谱索引产物」这类独立提交），严禁还原（`git restore` / `git checkout --`）**。
