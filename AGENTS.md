# AGENTS.md

This file provides guidance to Claude Code (claude.ai/code) and other coding agents when working with code in this repository. `CLAUDE.md` is a symlink to this file — edit this file, never the link.

## What this repository is

栖语 (qiyu) MVP：一个睡前 AI 陪伴原型，重点在行为层——人格一致性、本地记忆、关系阶段、微摩擦、少回应、睡前收束、安全边界。

技术形态：vanilla JavaScript + ESM，**零运行时依赖、无构建步骤**（Node >= 20）。没有 bundler、没有框架、不需要 `npm install`。前端是一个由自研 Node dev server 直出静态文件的 SPA；所有 LLM 调用都走本地服务端代理，API Key 永远不进浏览器。

## Commands

```sh
npm run dev     # 静态 + API dev server → http://127.0.0.1:5173（可用 PORT / HOST 环境变量改）
npm test        # node --test "test/**/*.test.js"
npm run eval    # 黄金行为用例套件（eval/golden-cases.json），任何一条失败即 exit 1
```

- 跑单个测试文件：`node --test test/qiyu/engine.test.js`
- eval 套件在 dev server 运行时也可通过 `POST /api/eval/run` 在线跑（`/lab` 页面用的就是它）。
- 未配置 LLM 时应用自动降级为本地规则引擎，功能完整可测。

## Architecture

### 分层

- `src/qiyu/` — **纯行为核心**，不依赖 DOM/Node，被浏览器、Node 测试、eval、服务端四方共用。人格与违禁词（`persona.js`）、安全分类（`safety.js`）、意图匹配与回复策略（`reply-policy.js`）、关系阶段（`relationship.js`）、记忆抽取（`memory-extraction.js`）、状态迁移（`state.js`）、prompt 上下文拼装（`prompt-context.js`）、回复清洗（`reply-delivery.js`）、eval 执行器（`eval-runner.js`）。
- `src/server/` — 仅 Node 侧的服务路由：`chat-route.js`、`settings-route.js`、`llm-client.js`、`config.js`、`system-prompt.js`。静态文件服务**禁止**直接访问该目录（见 `dev-server.mjs` 的 `isAllowedStaticFile`）。
- `src/screens/` — 每个 SPA 路由一个 `render(container, context)` 模块，由 `src/router.js` 动态 import 懒加载。
- `src/ui/` — 共享 DOM 工具（app shell、组件、escape/render、`chat-api.js` fetch 封装）。
- `scripts/dev-server.mjs` 是唯一的服务器入口；`scripts/run-evals.mjs` 是 eval 的 CLI 包装。

### 回复管线（核心数据流）

`/chat` 页面 → `sendChatMessage`（`src/ui/chat-api.js`）→ `POST /api/chat`（body 为 `{ text, state }`）→ `handleChatRequest`：

1. `classifySafety(text)` 非 normal（危机/医疗等）→ **一律本地引擎应答，绝不发给 LLM**；危机话术包含 `12356`。
2. 未配置 LLM → 本地引擎（`createQiyuReply`）。
3. 否则：先剥离输入中的类 XML 标签（防注入），**先**做 `rememberFactsFromText` + `recordTurn(user)` 再生成回复（刻意为之，消除状态更新延迟一拍的问题）；关系阶段按 `初识→熟悉→朋友→深交` 权重取 max，**只升不降（sticky）**——这段逻辑在 `chat-route.js` 和 `engine.js` 里各有一份，改动时两处都要同步。
4. system prompt = 硬规则 + `栖语产品灵魂.md` 全文（包在 `<product_soul>` 里，服务启动时读入）；`buildPromptContext`（`includeHistory: false`，避免历史重复）+ 最近 8 轮 turns 一起发给 `callChatCompletions`。
5. LLM 输出经 `normalizeReplyMessages` 清洗后过 `assertNoForbiddenPhrase`——命中违禁词或 API 出错都**优雅降级回本地引擎**，返回体带 `source: 'llm' | 'local'` 和 `fallbackReason: 'safety' | 'no_llm_config' | 'forbidden_phrases' | 'llm_error'`（`/lab` 诊断面板靠这些字段渲染）。

**本地规则引擎不是占位 stub，而是行为基准（ground truth）**：黄金 eval 锁定的就是它的输出。

### 状态与配置

- 全部会话状态在浏览器 localStorage（`createInitialState` 定义形状；单会话上限 80 轮、历史保留 180 天）。无账号、无云端记忆。
- 配置优先级：环境变量 `LLM_API_URL` / `LLM_API_KEY` / `LLM_MODEL` **高于** `qiyu.config.local.json`（已 gitignore）。URL 会被 `normalizeChatCompletionsUrl` 自动规范化（OpenAI 系补 `/chat/completions`，`api.anthropic.com` 补 `/messages`）。
- 安全不变量：settings/dev 路由有 CSRF token + Origin 校验；GET `/api/settings` 返回的 key 一律打码；错误输出中的 key 会被 redact。
- PWA：`main.js` 注册 `sw.js`，离线回退 `public/offline.html`。

## Behavior constraints（改动回复行为前必读）

- `栖语产品灵魂.md` 是人格/风格的最高优先级依据（直接注入 system prompt）；`docs/product/behavior-spec.md` 是从它提炼的工程行为规范。
- 关键约束：默认少说（回复频谱取最少一侧）；禁止客服式话术（`FORBIDDEN_PHRASES`，如「我理解你的感受」「谢谢你愿意和我分享」）；用户说「晚安」只收束、不开新话题；调侃/翻旧账只在关系变深后出现；一致性高于聪明。
- 改回复逻辑时，同步更新 `eval/golden-cases.json`，并保持 `npm test` 与 `npm run eval` 全绿。

## Testing conventions

- `test/` 目录镜像 `src/` 结构（`test/qiyu`、`test/screens`、`test/server`、`test/ui`）。
- 零依赖约束的代价：screen 测试手写 `globalThis.window` / `globalThis.document` 桩对象；server 测试通过**参数注入**替换 `fetchImpl` / `writeFileImpl` / `loadRuntimeConfigImpl` 等。写新测试请沿用这两种手法，不要引入任何测试框架或 DOM 库。

## Notes

- 本仓库已建立 codebase-memory 知识图谱索引（项目名 `qiyu`），可用 `search_graph` / `trace_path` / `get_architecture` 等 MCP 工具做代码探索；结构性大改后可重新 `index_repository`。
