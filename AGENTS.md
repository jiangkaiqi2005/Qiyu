# AGENTS.md

This file provides guidance to Claude Code (claude.ai/code) and other coding agents when working with code in this repository. `CLAUDE.md` is a symlink to this file — edit this file, never the link.

## 交互语言（最高优先）

**面向用户的所有输出一律用中文**：对话、提问、选项、报告、解释、ticket 与地图文字。代码、文件路径、字段名、命令等技术标识保留原文，但解释性文字必须中文。

## What this repository is

栖语 (qiyu) MVP：一个睡前 AI 陪伴原型，重点在行为层——人格一致性、本地记忆、关系阶段、微摩擦、少回应、睡前收束、安全边界。

当前主交付形态是 **Flutter Web UI + Dart Windows 本机 Host + 纯 Dart 行为核心**。Windows Host 只监听 `127.0.0.1`，负责静态资源、Provider 调用、凭据与 Markdown 会话持久化；浏览器只负责 UI，API Key 永远不进入浏览器。仓库根目录的 vanilla JavaScript + ESM 应用仍作为迁移期行为基准、回归轨道与实验界面保留（Node >= 20，零运行时依赖）。

## Commands

```sh
npm run dev     # 静态 + API dev server → http://127.0.0.1:5173（可用 PORT / HOST 环境变量改）
npm test        # node --test "test/**/*.test.js"
npm run eval    # 黄金行为用例套件（eval/golden-cases.json），任何一条失败即 exit 1
npm run verify:migration-baseline # Dart/Flutter/Windows Host/JS/eval/构建与冒烟全量验证
npm run build:windows-bundle      # 构建可移动的 Windows Host + Flutter Web 资源包
```

- 跑单个测试文件：`node --test test/qiyu/engine.test.js`
- Dart Core：在 `packages/qiyu_behavior_core` 下运行 `dart analyze && dart test`。
- Flutter：在 `apps/qiyu_flutter` 下运行 `flutter analyze && flutter test`。
- Windows Host：在 `apps/qiyu_windows_host` 下运行 `dart analyze && dart test`。
- eval 套件在 dev server 运行时也可通过 `POST /api/eval/run` 在线跑（`/lab` 页面用的就是它）。
- 未配置 LLM 时应用自动降级为本地规则引擎，功能完整可测。

## Architecture

### 分层

- `packages/qiyu_behavior_core/` — **纯 Dart 行为与协议核心**，不依赖 Flutter、DOM、Node、Windows API 或具体存储。`QiyuBehaviorCore.reply` 负责安全分类、本地回复、候选模型输出清洗/人格边界校验与降级；稳定 DTO、`ChatDeliveryEvent` 流式事件协议也在这里。
- `apps/qiyu_flutter/` — Flutter Web UI。`features/chat/` 负责本机会话恢复、NDJSON 事件消费、等待/渐进文本/停止生成界面；`features/settings/` 负责 Provider 设置与连接测试。浏览器不持久化 Provider Key。
- `apps/qiyu_windows_host/` — Dart Windows 本机 Host。`LocalAppHost` 提供 loopback 静态站点和受会话、Origin、CSRF 保护的 API；`LocalChatService` 编排安全回复、流式交付与会话持久化；`ProviderModelGateway` 适配 OpenAI-compatible、Anthropic、Ollama；`MarkdownMemoryRepository` 管理本地 Markdown 会话。
- `contracts/` — JS/Dart 共用的行为契约 fixture；行为变更必须保证两端一致。
- `src/`、`test/`、`eval/` — 迁移前的 vanilla JS 行为核心、Node 服务与回归基准。它们仍参与完整验证，不能因 Dart 主链路可用而跳过。
- `scripts/verify-migration-baseline.ps1` 串联所有分析、测试、Flutter Web 构建、Windows bundle/preflight/launch smoke、JS 测试和黄金 eval。

### 回复管线（核心数据流）

Flutter `/chat` → `HttpLocalChatGateway` → `POST /api/chat` → `LocalChatService.deliver`：

1. Host 先校验 `requestId`/文本，按 `requestId` 幂等写入用户原始消息；写入 sessions 的文本只做 secrets 脱敏，发送给安全分类与模型的文本另行清洗类 XML、ChatML 与角色控制结构。
2. `QiyuBehaviorCore.reply` 先在本地分类危机、医疗、法律、金融等 non-normal 输入；这类输入**绝不调用 Provider**。未配置 Provider、Provider 失败或模型输出不合格时统一走本地规则回复。
3. 普通输入通过 `ModelPromptBuilder` 注入硬规则、`栖语产品灵魂.md` 全文与最近已完成会话，再交给 `StreamingProviderChatClient`。
4. `ProviderModelGateway` 将 OpenAI SSE、Anthropic SSE、Ollama NDJSON 统一为 `delta / done / failure`。只有收到协议原生终止标记（OpenAI `finish_reason`/`[DONE]`、Anthropic `message_stop`、Ollama `done:true`）才算完成；提前 EOF、超时或原生 error 必须失败并降级，不能把半句当完整回复。
5. Provider 的原始增量先在 Host 内完整缓存；候选回复通过结构清洗、违禁词与人格边界校验后，才以共享 `ChatDeliveryEvent` 协议发送 `accepted → waiting → [fallback] → delta* → message → state → done`。页面绝不能看到未经完整安全校验的原始 token。
6. 用户可通过 `/api/chat/cancel` 按 `requestId` 停止生成；取消会向下取消 Provider/HTTP 流，只保留可重试的用户 turn，不把已展示半句或未完成候选记录为完整栖语回复。
7. 只有安全可见文本交付完成后才追加栖语 turn。刷新、Host 重启或同一 `requestId` 重试必须复用已有用户 turn/已完成回复，不能重复展示或落盘。晚安类输入在本地直接收束，不调用 Provider、不开新话题。

**本地规则引擎不是占位 stub，而是行为基准（ground truth）**：黄金 eval 锁定的就是它的输出。

### 状态与配置

- 主链路会话由 Windows Host 写入本机 Markdown sessions；单段最多 80 turns，活动历史窗口 180 天。浏览器刷新后从 Host 恢复，不以 localStorage 作为主持久化层。无账号、无云端记忆。
- Provider 非敏感配置写在本机 runtime 目录；API Key 由 Windows Credential Manager 保存。切换 Provider/URL 时不得沿用另一 credential scope 的旧 Key。
- 支持 OpenAI-compatible、Anthropic、Ollama。地址规范化、鉴权头、请求体、流式解析和错误分类集中在 Provider 层；不要在 UI 或 Chat Service 重复 Provider 分支。
- 安全不变量：Host 仅监听 loopback；API 需要 Host 会话，修改请求还需同源 Origin + CSRF；读取设置永不返回明文 Key；对外错误只返回允许列表诊断，禁止透出授权头、Cookie、完整敏感输入、第三方错误原文或本机路径。
- 根目录旧 Node 应用仍使用环境变量/`qiyu.config.local.json`，但这是迁移回归轨道，不代表 Flutter/Windows 主链路把 Key 放进浏览器。

## Behavior constraints（改动回复行为前必读）

- `栖语产品灵魂.md` 是人格/风格的最高优先级依据（直接注入 system prompt）；`docs/product/behavior-spec.md` 是从它提炼的工程行为规范。
- 关键约束：默认少说（回复频谱取最少一侧）；禁止客服式话术（`FORBIDDEN_PHRASES`，如「我理解你的感受」「谢谢你愿意和我分享」）；用户说「晚安」只收束、不开新话题；调侃/翻旧账只在关系变深后出现；一致性高于聪明。
- 改回复逻辑时，同步更新 `eval/golden-cases.json`，并保持 `npm test` 与 `npm run eval` 全绿。
- 跨 JS/Dart 的行为或协议改动还要同步 `contracts/qiyu_behavior_contracts.json` 和两端消费测试；不得用一端自测掩盖 wire 分叉。

## Testing conventions

- 根 `test/` 目录镜像旧 JS `src/` 结构；screen 测试使用手写 DOM 桩，server 测试使用参数注入，不要为旧轨道引入测试框架或 DOM 库。
- Dart Core、Flutter、Windows Host 各自在包内维护测试。Host 通过抽象接口注入 Provider、HTTP、凭据、时钟和原子写入；Flutter widget 测试注入流式 gateway 与 Host probe。
- 流式改动至少覆盖：三种 Provider 正常终止、提前 EOF、超时/原生错误、底层订阅取消；Host 正常/取消/半途失败/本地回退/晚安/刷新重启幂等；Flutter 等待态、安全增量可见节奏、停止按钮与最终只提交一次。
- 交付前运行 `npm run verify:migration-baseline`，不能只跑本次改动的专项测试。该命令必须保持 Dart analyze/test、Flutter analyze/test/Web build、Windows Host analyze/test/bundle/preflight/launch smoke、JS test、golden eval 全绿。

## Notes

- 本仓库已建立 codebase-memory 知识图谱索引（项目名 `qiyu`），可用 `search_graph` / `trace_path` / `get_architecture` 等 MCP 工具做代码探索；结构性大改后可重新 `index_repository`。
- `.codebase-memory/` 下的产物（`graph.db.zst`、`artifact.json` 等）由索引进程自动更新，属于预期变更：**每次发现改动必须随当次提交一起 commit 并推送，严禁还原（`git restore` / `git checkout --`）**。
