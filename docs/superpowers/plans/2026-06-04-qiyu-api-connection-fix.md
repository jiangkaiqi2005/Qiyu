# Qiyu API Connection Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让栖语的外部 LLM API 接入变成可配置、可测试、可观察、失败原因明确的真实可用链路。

**Architecture:** 保留当前 Node 本地 dev server 代理 `/api/chat` 的方向，浏览器仍不直接持有 API Key。优先修配置文件安全、Provider URL 兼容、连接测试、聊天链路诊断和 UI 反馈，不重写整套聊天系统。

**Tech Stack:** Vanilla JavaScript ES modules, Node `http` server, Node `node:test`, localStorage, OpenAI-compatible Chat Completions API, local JSON config.

---

## 问题判断

当前不是“完全没有 API 代码”，而是 API 接入对用户来说不可用、不可信：

- `/api/chat` 失败会静默降级到本地规则引擎，页面上看不出到底有没有走 LLM。
- 设置页只做“连接测试”，没有跑真实的“栖语聊天链路测试”。
- 用户必须填写完整 `/v1/chat/completions` endpoint；如果只填 provider base URL，大概率失败。
- 配置保存提示“重启生效”，但服务端聊天请求实际每次会重新 `loadRuntimeConfig()`，文案和行为不一致。
- 当前 `test/server/settings-route.test.js` 会删除/重写真实 `qiyu.config.local.json`，而这个文件可能含真实 API Key。先修这个，否则任何自动测试都有误伤密钥风险。

## 成功标准

- 用户在设置页填入 API URL、API Key、Model 后，能一键确认：
  - 配置已保存。
  - Provider 连接成功。
  - `/api/chat` 真实走了 LLM。
  - 如果失败，能看到脱敏后的具体原因。
- 聊天页在开发者模式下能显示本轮回复来源：`llm` 或 `local fallback`。
- Provider key 不出现在浏览器请求、localStorage、错误提示、导出报告中。
- 所有测试不再读写真实 `qiyu.config.local.json`。

---

## Phase 0: 先隔离真实 API Key

**目标:** 任何测试都不能删除、覆盖或读取真实 `qiyu.config.local.json`。

**主要文件:**

- `src/server/settings-route.js`
- `src/server/config.js`
- `test/server/settings-route.test.js`
- `test/server/config.test.js`

**要做的事:**

- [ ] 给 `handleSettingsRequest()` 增加可注入依赖：`configPath`、`loadRuntimeConfigImpl`、`writeFileImpl`、`callChatCompletionsImpl`。
- [ ] `settings-route.test.js` 必须使用 `mkdtemp()` 生成临时目录，把测试配置写到临时 `qiyu.config.local.json`。
- [ ] 测试结束只删除临时目录内文件，绝不操作 repo 根目录的真实 `qiyu.config.local.json`。
- [ ] 增加一条回归测试：repo 根目录存在真实 `qiyu.config.local.json` 时，settings route 测试不会删除或改写它。

**验收:**

- `node --test test/server/settings-route.test.js`
- 人工确认：根目录 `qiyu.config.local.json` 修改时间不变。

---

## Phase 1: 配置保存后立即可用

**目标:** 保存 API 配置后，下一次 `/api/chat` 立即读取新配置，不需要用户猜是否重启。

**主要文件:**

- `src/server/config.js`
- `src/server/settings-route.js`
- `scripts/dev-server.mjs`
- `src/screens/settings.js`
- `test/server/config.test.js`
- `test/server/settings-route.test.js`

**要做的事:**

- [ ] 统一配置来源：环境变量优先，本地 JSON 次之，返回 `source: "env" | "local-file" | "empty"`。
- [ ] 设置页保存接口返回脱敏后的 effective config：`apiUrl`、`model`、`temperature`、`timeoutMs`、`hasLlm`、`source`。
- [ ] 如果环境变量已设置，UI 要提示“当前由环境变量控制，页面保存不会覆盖环境变量生效值”。
- [ ] 修改保存成功文案：不要说“重启生效”，改成“已保存，下一次消息会使用新配置”。
- [ ] 配置写入失败时返回明确错误，例如文件权限、JSON 写入失败，但错误里不能带 API Key。

**验收:**

- 保存配置后立刻请求 `/api/settings`，返回 masked key 和 `hasLlm: true`。
- 不重启 dev server，下一次 `/api/chat` 使用新配置。

---

## Phase 2: Provider URL 兼容与校验

**目标:** 用户不用猜 URL 格式，常见填写方式都能被规范化。

**主要文件:**

- `src/server/config.js`
- `src/server/llm-client.js`
- `src/screens/settings.js`
- `qiyu.config.example.json`
- `README.md`
- `test/server/config.test.js`
- `test/server/llm-client.test.js`

**要做的事:**

- [ ] 增加 `normalizeChatCompletionsUrl(input)`：
  - `https://api.openai.com/v1` -> `https://api.openai.com/v1/chat/completions`
  - `https://api.openai.com/v1/` -> `https://api.openai.com/v1/chat/completions`
  - `https://api.openai.com/v1/chat/completions` -> 原样保留
  - `http://127.0.0.1:11434/v1` -> `http://127.0.0.1:11434/v1/chat/completions`
- [ ] 拒绝明显错误的 URL：空字符串、非 http/https、包含空格、无法解析。
- [ ] 设置页增加 provider preset：
  - OpenAI: `https://api.openai.com/v1`
  - OpenAI-compatible custom: 用户自填
  - Local OpenAI-compatible: `http://127.0.0.1:11434/v1`
- [ ] `llm-client.js` 统一使用规范化后的 URL 发请求。

**验收:**

- 用户填 base URL 也能连通。
- UI 显示“实际请求地址”，但永远不显示 key。

---

## Phase 3: 连接测试改成端到端测试

**目标:** 设置页测试的不只是 provider ping，而是真实验证“栖语能不能用这个 API 聊一句”。

**主要文件:**

- `src/server/settings-route.js`
- `src/server/chat-route.js`
- `src/server/llm-client.js`
- `src/screens/settings.js`
- `test/server/settings-route.test.js`
- `test/server/chat-route.test.js`
- `test/screens/settings.test.js`

**要做的事:**

- [ ] 保留 `/api/settings/test`，但它要返回：
  - `success`
  - `normalizedApiUrl`
  - `model`
  - `latencyMs`
  - `sampleText`
  - `error`（脱敏）
- [ ] 测试请求使用同一套 `callChatCompletions()`，不要另写一套 provider 请求逻辑。
- [ ] 新增 `/api/settings/test-chat` 或等价接口，用当前输入配置构造一次真实栖语 prompt/context，请求样例：`今天好累`。
- [ ] 如果 LLM 返回禁用语或空内容，测试应失败并说明原因，而不是只显示 provider 成功。
- [ ] 设置页把按钮拆清楚：
  - “测试 Provider”
  - “测试栖语回复”
  - “保存配置”

**验收:**

- Provider 可用但模型输出不符合栖语规则时，UI 能明确显示“Provider 通了，但栖语回复校验失败”。
- Provider 不通时，UI 显示 HTTP 状态、超时、URL 错误或模型错误，全部脱敏。

---

## Phase 4: 聊天页暴露 LLM 使用状态

**目标:** 用户能知道“这次到底有没有走 API”，否则 API 再通也像没用。

**主要文件:**

- `src/server/chat-route.js`
- `src/ui/chat-api.js`
- `src/screens/chat.js`
- `src/screens/settings.js`
- `test/server/chat-route.test.js`
- `test/screens/chat.test.js`
- `test/ui/chat-api.test.js`

**要做的事:**

- [ ] `/api/chat` 响应里保留并规范：
  - `source: "llm" | "local"`
  - `fallbackReason`
  - `providerError`
  - `relationshipStage`
  - `latencyMs`
- [ ] 正常用户界面不显示技术细节，避免打扰夜聊。
- [ ] 开发者模式开启时，在聊天页或设置页显示最近一次请求状态：
  - “本轮使用 LLM”
  - “本轮回退本地：401 invalid key”
  - “本轮回退本地：禁用语命中”
- [ ] 如果用户刚刚保存了 API 配置但聊天仍然 `source: local`，设置页要能引导查看失败原因。

**验收:**

- 用 mock provider 成功时，聊天响应 `source` 为 `llm`。
- 用错误 key 时，聊天响应 `source` 为 `local`，但 `fallbackReason` 能说明原因。
- 开发者模式下能看到最近一次请求来源。

---

## Phase 5: LLM Client 兼容与错误脱敏

**目标:** 支持常见 OpenAI-compatible 返回形态，并把错误变成人能修的提示。

**主要文件:**

- `src/server/llm-client.js`
- `test/server/llm-client.test.js`

**要做的事:**

- [ ] 支持 `choices[0].message.content` 为 string。
- [ ] 支持 `choices[0].message.content` 为数组时提取 text parts。
- [ ] 支持 provider 返回 `{ error: { message } }` 时提取错误信息。
- [ ] 捕获 abort timeout，返回 `LLM request timeout after ...ms`。
- [ ] 错误脱敏：任何错误文本里出现的 API Key 都替换为 `[redacted]`。
- [ ] 请求体可选 `max_tokens` 或 `max_completion_tokens` 先不加，除非真实 provider 需要；保持最小可用。

**验收:**

- `test/server/llm-client.test.js` 覆盖 401、timeout、空内容、content array、错误脱敏。

---

## Phase 6: 设置页体验改成“能接上”

**目标:** 设置页要像一个配置向导，而不是一堆高级字段。

**主要文件:**

- `src/screens/settings.js`
- `src/ui/components.js`
- `src/styles.css`
- `test/screens/settings.test.js`

**要做的事:**

- [ ] AI 设置区顶部显示当前状态：
  - 未配置
  - 已配置但未测试
  - Provider 已连接
  - 栖语回复测试通过
  - 最近一次聊天回退本地
- [ ] 保存按钮不再用“注入灵魂引擎”这种隐喻，改成“保存 API 配置”。
- [ ] 连接测试按钮不再用“灵魂连接测试”，改成“测试 Provider 连接”。
- [ ] 增加一个只读诊断摘要：实际请求地址、模型、配置来源、最后测试时间。
- [ ] Key 输入框保留 masked key 时，提交 `••••••••` 表示沿用旧 key。

**验收:**

- 一个新用户按顺序完成：选择 preset -> 填 key/model -> 测试 Provider -> 测试栖语回复 -> 保存 -> 去聊天。
- 失败时页面能告诉用户下一步该改 URL、key 还是 model。

---

## Phase 7: 文档和真实手测流程

**目标:** 后续 AI 和用户都知道怎么确认 API 真接上了。

**主要文件:**

- `README.md`
- `docs/product/release-checklist.md`
- `docs/superpowers/plans/2026-06-01-llm-api-integration.md`（只追加“已知问题/修复后流程”，不要重写旧计划）

**要做的事:**

- [ ] README 写清两种配置方式：页面配置和环境变量配置。
- [ ] 明确环境变量优先级高于页面配置。
- [ ] 写清常见 URL：
  - OpenAI: `https://api.openai.com/v1`
  - OpenAI-compatible full endpoint: `.../v1/chat/completions`
  - local compatible server: `http://127.0.0.1:11434/v1`
- [ ] 写清如何确认接入成功：
  - 设置页 Provider 测试通过。
  - 栖语回复测试通过。
  - 聊天页开发者模式显示 `source: llm`。
- [ ] release checklist 增加“真实 API 接入验收”。

**验收:**

- 按 README 从零配置一遍，能看见 `source: llm`。
- 不配置 API 时仍可本地兜底。

---

## 推荐执行顺序

1. 先做 Phase 0。这个最重要，因为真实 key 文件现在会被测试误伤。
2. 再做 Phase 1 + Phase 2。先保证配置能保存、能规范化、能立即生效。
3. 再做 Phase 3 + Phase 4。让用户能确认“API 真的在工作”。
4. 再做 Phase 5。提升 provider 兼容和错误质量。
5. 最后做 Phase 6 + Phase 7。收设置页和文档。

## 验证命令

Phase 0 完成前，不要在含真实 `qiyu.config.local.json` 的 repo 根目录运行全量 `npm test`。

Phase 0 完成后再运行：

```powershell
cd E:\Agent\栖语
npm test
npm run eval
```

手测：

```powershell
cd E:\Agent\栖语
npm run dev
```

然后打开 `http://127.0.0.1:5173/settings`，完成：

1. 填 API URL / API Key / Model。
2. 测试 Provider。
3. 测试栖语回复。
4. 保存配置。
5. 到 `/chat` 发送 `今天好累`。
6. 开发者模式确认最近一次响应 `source: llm`。

