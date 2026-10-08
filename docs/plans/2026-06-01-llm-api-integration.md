# LLM API Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Connect the current 栖语 Web MVP to a configurable LLM API while preserving the existing persona, memory, relationship stage, safety, and forbidden-phrase guardrails.

**Architecture:** Keep the browser free of secrets by adding a Node-side `/api/chat` route to `scripts/dev-server.mjs`. The server reads `栖语产品灵魂.md` into a system prompt, injects memory/relationship/forbidden-phrase context, calls an OpenAI-compatible chat-completions HTTP API, validates the response, and falls back to the current deterministic engine when no API key is configured or a guardrail fails. The existing local rule engine remains the offline safety net and regression oracle.

**Tech Stack:** Vanilla JavaScript ES modules, Node `http` server, Node built-in `node:test`, browser `fetch`, localStorage state, environment variables plus optional untracked JSON config.

---

## Current Repo State

- Branch: `develop`.
- Existing MVP is a Web app, not Android/iOS.
- Current worktree is dirty before this plan. Do not revert those changes.
- Existing synchronous engine entrypoint: `src/qiyu/engine.js` exports `createQiyuReply(text, state)`.
- Existing behavior modules: `persona.js`, `state.js`, `relationship.js`, `reply-policy.js`, `safety.js`.
- Existing static server only serves files; it has no API route yet.

## Assumptions Fixed For This Plan

- LLM API shape: OpenAI-compatible `POST /v1/chat/completions`.
- Config names:
  - `LLM_API_URL`
  - `LLM_API_KEY`
  - `LLM_MODEL`
  - `LLM_TEMPERATURE`
  - `LLM_TIMEOUT_MS`
- Optional local config file: `qiyu.config.local.json`, ignored by git.
- Committed example config never contains a real key.
- If the configured provider uses a different request schema, implement a second adapter after this plan rather than weakening this one.

## File Structure

- Create: `E:\Agent\栖语\.gitignore` - exclude secrets and local config.
- Create: `E:\Agent\栖语\qiyu.config.example.json` - non-secret config example.
- Create: `E:\Agent\栖语\src\server\config.js` - read env and optional local JSON config.
- Create: `E:\Agent\栖语\src\server\system-prompt.js` - read `栖语产品灵魂.md` and build system prompt.
- Create: `E:\Agent\栖语\src\qiyu\prompt-context.js` - build memory/relationship/forbidden phrase context.
- Create: `E:\Agent\栖语\src\qiyu\memory-extraction.js` - move fact extraction out of `engine.js`.
- Create: `E:\Agent\栖语\src\server\llm-client.js` - call OpenAI-compatible chat completions.
- Create: `E:\Agent\栖语\src\server\chat-route.js` - handle `POST /api/chat`.
- Create: `E:\Agent\栖语\src\ui\chat-api.js` - browser API client.
- Modify: `E:\Agent\栖语\scripts\dev-server.mjs` - dispatch `/api/chat`.
- Modify: `E:\Agent\栖语\src\qiyu\engine.js` - import shared memory extraction.
- Modify: `E:\Agent\栖语\src\main.js` - send messages through `/api/chat` with local fallback.
- Modify: `E:\Agent\栖语\README.md` - document LLM config.
- Create tests under `E:\Agent\栖语\test\server\` and `E:\Agent\栖语\test\qiyu\`.

---

### Task 0: Baseline Dirty Tree

**Files:**
- No file edits.

- [ ] **Step 1: Confirm branch and dirty state**

Run:

```powershell
cd E:\Agent\栖语
git status --short --branch
```

Expected: output starts with `## develop`. Existing modified and untracked files may remain.

- [ ] **Step 2: Commit current MVP baseline before LLM work**

Run:

```powershell
cd E:\Agent\栖语
git add package.json README.md index.html scripts src test eval docs skills-lock.json 栖语产品灵魂.md
git commit -m "chore: baseline qiyu mvp before llm integration"
```

Expected: baseline commit succeeds. This prevents later LLM commits from mixing with already-existing MVP changes.

---

### Task 1: Runtime Config And Secret Boundary

**Files:**
- Create: `E:\Agent\栖语\.gitignore`
- Create: `E:\Agent\栖语\qiyu.config.example.json`
- Create: `E:\Agent\栖语\src\server\config.js`
- Create: `E:\Agent\栖语\test\server\config.test.js`

- [ ] **Step 1: Write the failing config tests**

Create `test/server/config.test.js`:

```js
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { loadRuntimeConfig } from '../../src/server/config.js';

test('runtime config reads complete LLM settings from environment', async () => {
  const config = await loadRuntimeConfig({
    env: {
      LLM_API_URL: 'https://llm.example.test/v1/chat/completions',
      LLM_API_KEY: 'test-key',
      LLM_MODEL: 'qiyu-test-model',
      LLM_TEMPERATURE: '0.7',
      LLM_TIMEOUT_MS: '12000'
    },
    configPath: join(tmpdir(), 'missing-qiyu-config.json')
  });

  assert.equal(config.hasLlm, true);
  assert.equal(config.llm.apiUrl, 'https://llm.example.test/v1/chat/completions');
  assert.equal(config.llm.apiKey, 'test-key');
  assert.equal(config.llm.model, 'qiyu-test-model');
  assert.equal(config.llm.temperature, 0.7);
  assert.equal(config.llm.timeoutMs, 12000);
});

test('runtime config can read optional local JSON config', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'qiyu-config-'));
  const configPath = join(dir, 'qiyu.config.local.json');
  await writeFile(configPath, JSON.stringify({
    llm: {
      apiUrl: 'https://file.example.test/v1/chat/completions',
      apiKey: 'file-key',
      model: 'file-model',
      temperature: 0.8,
      timeoutMs: 9000
    }
  }));

  const config = await loadRuntimeConfig({ env: {}, configPath });
  assert.equal(config.hasLlm, true);
  assert.equal(config.llm.apiKey, 'file-key');
  assert.equal(config.llm.model, 'file-model');
});

test('runtime config marks LLM disabled when key details are missing', async () => {
  const config = await loadRuntimeConfig({
    env: { LLM_API_URL: 'https://llm.example.test/v1/chat/completions' },
    configPath: join(tmpdir(), 'missing-qiyu-config.json')
  });

  assert.equal(config.hasLlm, false);
});
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```powershell
cd E:\Agent\栖语
node --test test\server\config.test.js
```

Expected: FAIL because `src/server/config.js` does not exist.

- [ ] **Step 3: Add secret ignore rules and example config**

Create `.gitignore`:

```gitignore
node_modules/
.env.local
qiyu.config.local.json
*.log
```

Create `qiyu.config.example.json`:

```json
{
  "llm": {
    "apiUrl": "https://api.example.com/v1/chat/completions",
    "model": "provider-model-name",
    "temperature": 0.8,
    "timeoutMs": 30000
  }
}
```

- [ ] **Step 4: Implement config loader**

Create `src/server/config.js`:

```js
import { readFile } from 'node:fs/promises';

async function readJsonIfPresent(configPath) {
  try {
    const raw = await readFile(configPath, 'utf8');
    return JSON.parse(raw);
  } catch (error) {
    if (error.code === 'ENOENT') {
      return {};
    }
    throw error;
  }
}

function numberFrom(value, fallback) {
  if (value === undefined || value === null || value === '') {
    return fallback;
  }
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

export async function loadRuntimeConfig({
  env = process.env,
  configPath = 'qiyu.config.local.json'
} = {}) {
  const fileConfig = await readJsonIfPresent(configPath);
  const fileLlm = fileConfig.llm || {};

  const llm = {
    apiUrl: env.LLM_API_URL || fileLlm.apiUrl || '',
    apiKey: env.LLM_API_KEY || fileLlm.apiKey || '',
    model: env.LLM_MODEL || fileLlm.model || '',
    temperature: numberFrom(env.LLM_TEMPERATURE ?? fileLlm.temperature, 0.8),
    timeoutMs: numberFrom(env.LLM_TIMEOUT_MS ?? fileLlm.timeoutMs, 30000)
  };

  return {
    llm,
    hasLlm: Boolean(llm.apiUrl && llm.apiKey && llm.model)
  };
}
```

- [ ] **Step 5: Verify config tests pass**

Run:

```powershell
cd E:\Agent\栖语
node --test test\server\config.test.js
```

Expected: PASS for all config tests.

- [ ] **Step 6: Commit**

Run:

```powershell
cd E:\Agent\栖语
git add .gitignore qiyu.config.example.json src/server/config.js test/server/config.test.js
git commit -m "feat: add llm runtime config"
```

---

### Task 2: Product Soul System Prompt

**Files:**
- Create: `E:\Agent\栖语\src\server\system-prompt.js`
- Create: `E:\Agent\栖语\test\server\system-prompt.test.js`

- [ ] **Step 1: Write the failing system prompt tests**

Create `test/server/system-prompt.test.js`:

```js
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { buildSystemPrompt, loadProductSoul } from '../../src/server/system-prompt.js';

test('loadProductSoul reads utf8 product soul markdown', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'qiyu-soul-'));
  const file = join(dir, 'soul.md');
  await writeFile(file, '# 栖语\n\n一致性。');

  assert.equal(await loadProductSoul(file), '# 栖语\n\n一致性。');
});

test('system prompt contains product soul and hard output rules', () => {
  const prompt = buildSystemPrompt('# 栖语\n\n她永远是同一个人。');

  assert.match(prompt, /你是栖语/);
  assert.match(prompt, /产品灵魂原文/);
  assert.match(prompt, /她永远是同一个人/);
  assert.match(prompt, /只输出栖语要说的话/);
  assert.match(prompt, /不要解释系统规则/);
});
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```powershell
cd E:\Agent\栖语
node --test test\server\system-prompt.test.js
```

Expected: FAIL because `src/server/system-prompt.js` does not exist.

- [ ] **Step 3: Implement system prompt builder**

Create `src/server/system-prompt.js`:

```js
import { readFile } from 'node:fs/promises';

export async function loadProductSoul(path = '栖语产品灵魂.md') {
  return readFile(path, 'utf8');
}

export function buildSystemPrompt(productSoulMarkdown) {
  return [
    '你是栖语，一个睡前 AI 陪伴。你的目标不是回答问题，而是在用户栖息的时刻，像一个稳定、真实、有自己重心的朋友一样和用户说话。',
    '',
    '硬规则：',
    '1. 只输出栖语要说的话，不输出分析、标签、JSON、系统说明或候选回复。',
    '2. 不要解释系统规则，不要提到 prompt，不要说自己正在遵循文档。',
    '3. 宁可短、笨拙、沉默，也不要变成客服、心理咨询师、人生导师。',
    '4. 用户已经要睡时，只收束，不重新打开新话题。',
    '5. 遇到危机、安全和专业建议边界时，按上下文里的安全规则执行。',
    '',
    '产品灵魂原文如下。它是最高优先级的人格和风格依据：',
    '<product_soul>',
    productSoulMarkdown.trim(),
    '</product_soul>'
  ].join('\n');
}
```

- [ ] **Step 4: Verify system prompt tests pass**

Run:

```powershell
cd E:\Agent\栖语
node --test test\server\system-prompt.test.js
```

Expected: PASS for all system prompt tests.

- [ ] **Step 5: Commit**

Run:

```powershell
cd E:\Agent\栖语
git add src/server/system-prompt.js test/server/system-prompt.test.js
git commit -m "feat: build system prompt from product soul"
```

---

### Task 3: Prompt Context Injection

**Files:**
- Create: `E:\Agent\栖语\src\qiyu\prompt-context.js`
- Create: `E:\Agent\栖语\test\qiyu\prompt-context.test.js`

- [ ] **Step 1: Write the failing context tests**

Create `test/qiyu/prompt-context.test.js`:

```js
import test from 'node:test';
import assert from 'node:assert/strict';
import { buildPromptContext } from '../../src/qiyu/prompt-context.js';
import { createInitialState, rememberUserFact, recordTurn } from '../../src/qiyu/state.js';

test('prompt context injects relationship stage, memories, and forbidden phrases', () => {
  let state = createInitialState('local-user');
  state = { ...state, sessionCount: 14 };
  state = rememberUserFact(state, {
    key: 'work.general',
    value: '最近项目快 deadline，经常加班',
    source: '用户连续几天提到项目'
  });
  state = rememberUserFact(state, {
    key: 'family.general',
    value: '和妈妈沟通时容易吵起来',
    source: '用户说今天跟妈妈吵架'
  });
  state = recordTurn(state, 'user', '今天好累');

  const context = buildPromptContext({ state, userText: '今天又加班到很晚' });

  assert.equal(context.role, 'system');
  assert.match(context.content, /关系阶段：朋友/);
  assert.match(context.content, /最近项目快 deadline/);
  assert.match(context.content, /禁用语/);
  assert.match(context.content, /我理解你的感受/);
  assert.match(context.content, /最近对话/);
});
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```powershell
cd E:\Agent\栖语
node --test test\qiyu\prompt-context.test.js
```

Expected: FAIL because `src/qiyu/prompt-context.js` does not exist.

- [ ] **Step 3: Implement prompt context builder**

Create `src/qiyu/prompt-context.js`:

```js
import { FORBIDDEN_PHRASES, QIYU_PERSONA } from './persona.js';
import { inferRelationshipStage } from './relationship.js';
import { recallRelevantFacts } from './state.js';

function formatMemories(memories) {
  if (!memories.length) {
    return '- 暂无相关记忆。不要假装记得用户没有说过的事。';
  }

  return memories
    .map((memory) => `- ${memory.key}: ${memory.value}（来源：${memory.source}）`)
    .join('\n');
}

function formatRecentTurns(turns) {
  const recent = turns.slice(-8);
  if (!recent.length) {
    return '- 没有最近对话。';
  }

  return recent
    .map((turn) => `- ${turn.speaker === 'user' ? '用户' : '栖语'}：${turn.text}`)
    .join('\n');
}

export function buildPromptContext({ state, userText }) {
  const relationshipStage = inferRelationshipStage(state);
  const relevantMemories = recallRelevantFacts(state, userText);

  return {
    role: 'system',
    content: [
      '当前对话上下文：',
      `- 关系阶段：${relationshipStage}`,
      `- 当前情绪惯性：${state.lastEmotion?.kind || 'neutral'}，强度 ${state.lastEmotion?.intensity ?? 0}`,
      `- 栖语口癖：${QIYU_PERSONA.habits.join('、')}`,
      '',
      '相关记忆：',
      formatMemories(relevantMemories),
      '',
      '最近对话：',
      formatRecentTurns(state.turns || []),
      '',
      '禁用语：',
      FORBIDDEN_PHRASES.map((phrase) => `- ${phrase}`).join('\n'),
      '',
      '回复约束：',
      '- 默认短，不要为了完整而长。',
      '- 不要复述用户的话来假装共情。',
      '- 可以有停顿、口癖和不完整句。',
      '- 如果用户只是低信号消息，可以只回一个短句。',
      '- 如果用户说晚安、困了、睡了，只收束。'
    ].join('\n')
  };
}
```

- [ ] **Step 4: Verify context tests pass**

Run:

```powershell
cd E:\Agent\栖语
node --test test\qiyu\prompt-context.test.js
```

Expected: PASS for all context tests.

- [ ] **Step 5: Commit**

Run:

```powershell
cd E:\Agent\栖语
git add src/qiyu/prompt-context.js test/qiyu/prompt-context.test.js
git commit -m "feat: inject qiyu prompt context"
```

---

### Task 4: Shared Memory Extraction

**Files:**
- Create: `E:\Agent\栖语\src\qiyu\memory-extraction.js`
- Modify: `E:\Agent\栖语\src\qiyu\engine.js`
- Create: `E:\Agent\栖语\test\qiyu\memory-extraction.test.js`

- [ ] **Step 1: Write the failing memory extraction test**

Create `test/qiyu/memory-extraction.test.js`:

```js
import test from 'node:test';
import assert from 'node:assert/strict';
import { createInitialState } from '../../src/qiyu/state.js';
import { rememberFactsFromText } from '../../src/qiyu/memory-extraction.js';

test('rememberFactsFromText extracts reusable prompt memories', () => {
  const state = createInitialState('local-user');
  const next = rememberFactsFromText(state, '今天又加班到十点，还喝了咖啡');

  assert.deepEqual(next.memories.map((memory) => memory.key).sort(), [
    'drink.coffee',
    'work.general'
  ]);
});
```

- [ ] **Step 2: Run test to verify failure**

Run:

```powershell
cd E:\Agent\栖语
node --test test\qiyu\memory-extraction.test.js
```

Expected: FAIL because `src/qiyu/memory-extraction.js` does not exist.

- [ ] **Step 3: Move fact extraction into shared module**

Create `src/qiyu/memory-extraction.js`:

```js
import { rememberUserFact } from './state.js';

const FACT_EXTRACTORS = [
  {
    pattern: /杨枝甘露|奶茶/,
    key: 'drink.milkTea',
    getValue: (text) => text.includes('戒奶茶') ? '说要戒奶茶' : '提到奶茶或杨枝甘露'
  },
  {
    pattern: /咖啡/,
    key: 'drink.coffee',
    getValue: () => '提到咖啡'
  },
  {
    pattern: /加班|上班|工作|同事|领导|老板|项目/,
    key: 'work.general',
    getValue: () => '提到工作或加班'
  },
  {
    pattern: /妈|爸|家人|家里|父母/,
    key: 'family.general',
    getValue: () => '提到家人或父母'
  },
  {
    pattern: /失眠|熬夜|睡不着/,
    key: 'sleep.pattern',
    getValue: () => '提到睡眠问题或熬夜'
  }
];

export function rememberFactsFromText(state, text) {
  return FACT_EXTRACTORS.reduce((nextState, extractor) => {
    if (!extractor.pattern.test(text)) {
      return nextState;
    }

    return rememberUserFact(nextState, {
      key: extractor.key,
      value: extractor.getValue(text),
      source: text
    });
  }, state);
}
```

- [ ] **Step 4: Modify engine to use shared extraction**

In `src/qiyu/engine.js`, remove the local `FACT_EXTRACTORS` array and local `rememberFactsFromText()` function. Add this import:

```js
import { rememberFactsFromText } from './memory-extraction.js';
```

Keep the existing call:

```js
const stateWithMemory = rememberFactsFromText(state, trimmed);
```

- [ ] **Step 5: Verify extraction and engine tests pass**

Run:

```powershell
cd E:\Agent\栖语
node --test test\qiyu\memory-extraction.test.js test\qiyu\engine.test.js
```

Expected: PASS for memory extraction and existing engine tests.

- [ ] **Step 6: Commit**

Run:

```powershell
cd E:\Agent\栖语
git add src/qiyu/memory-extraction.js src/qiyu/engine.js test/qiyu/memory-extraction.test.js
git commit -m "refactor: share qiyu memory extraction"
```

---

### Task 5: LLM Client

**Files:**
- Create: `E:\Agent\栖语\src\server\llm-client.js`
- Create: `E:\Agent\栖语\test\server\llm-client.test.js`

- [ ] **Step 1: Write the failing LLM client tests**

Create `test/server/llm-client.test.js`:

```js
import test from 'node:test';
import assert from 'node:assert/strict';
import { callChatCompletions } from '../../src/server/llm-client.js';

test('callChatCompletions posts OpenAI-compatible request', async () => {
  const calls = [];
  const fetchImpl = async (url, options) => {
    calls.push({ url, options });
    return {
      ok: true,
      status: 200,
      async json() {
        return { choices: [{ message: { content: '……怎么回事' } }] };
      }
    };
  };

  const text = await callChatCompletions({
    config: {
      apiUrl: 'https://llm.example.test/v1/chat/completions',
      apiKey: 'key',
      model: 'qiyu-test-model',
      temperature: 0.8,
      timeoutMs: 30000
    },
    messages: [{ role: 'system', content: '你是栖语' }],
    fetchImpl
  });

  assert.equal(text, '……怎么回事');
  assert.equal(calls[0].url, 'https://llm.example.test/v1/chat/completions');
  assert.equal(calls[0].options.method, 'POST');
  assert.equal(calls[0].options.headers.Authorization, 'Bearer key');
  assert.equal(JSON.parse(calls[0].options.body).model, 'qiyu-test-model');
});

test('callChatCompletions reports provider errors', async () => {
  const fetchImpl = async () => ({
    ok: false,
    status: 401,
    async text() {
      return 'bad key';
    }
  });

  await assert.rejects(
    () => callChatCompletions({
      config: {
        apiUrl: 'https://llm.example.test/v1/chat/completions',
        apiKey: 'key',
        model: 'qiyu-test-model',
        temperature: 0.8,
        timeoutMs: 30000
      },
      messages: [],
      fetchImpl
    }),
    /LLM request failed: 401 bad key/
  );
});
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```powershell
cd E:\Agent\栖语
node --test test\server\llm-client.test.js
```

Expected: FAIL because `src/server/llm-client.js` does not exist.

- [ ] **Step 3: Implement OpenAI-compatible client**

Create `src/server/llm-client.js`:

```js
export async function callChatCompletions({ config, messages, fetchImpl = fetch }) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), config.timeoutMs);

  try {
    const response = await fetchImpl(config.apiUrl, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${config.apiKey}`
      },
      body: JSON.stringify({
        model: config.model,
        messages,
        temperature: config.temperature
      }),
      signal: controller.signal
    });

    if (!response.ok) {
      const body = await response.text();
      throw new Error(`LLM request failed: ${response.status} ${body}`);
    }

    const payload = await response.json();
    const content = payload?.choices?.[0]?.message?.content;
    if (typeof content !== 'string' || !content.trim()) {
      throw new Error('LLM response missing message content');
    }

    return content.trim();
  } finally {
    clearTimeout(timeout);
  }
}
```

- [ ] **Step 4: Verify LLM client tests pass**

Run:

```powershell
cd E:\Agent\栖语
node --test test\server\llm-client.test.js
```

Expected: PASS for all LLM client tests.

- [ ] **Step 5: Commit**

Run:

```powershell
cd E:\Agent\栖语
git add src/server/llm-client.js test/server/llm-client.test.js
git commit -m "feat: add llm chat completions client"
```

---

### Task 6: Server Chat Route

**Files:**
- Create: `E:\Agent\栖语\src\server\chat-route.js`
- Modify: `E:\Agent\栖语\scripts\dev-server.mjs`
- Create: `E:\Agent\栖语\test\server\chat-route.test.js`

- [ ] **Step 1: Write the failing route tests**

Create `test/server/chat-route.test.js`:

```js
import test from 'node:test';
import assert from 'node:assert/strict';
import { Readable, Writable } from 'node:stream';
import { handleChatRequest } from '../../src/server/chat-route.js';
import { createInitialState } from '../../src/qiyu/state.js';

function reqWithJson(body) {
  const req = Readable.from([JSON.stringify(body)]);
  req.method = 'POST';
  req.url = '/api/chat';
  return req;
}

function captureRes() {
  const chunks = [];
  const res = new Writable({
    write(chunk, encoding, callback) {
      chunks.push(Buffer.from(chunk));
      callback();
    }
  });
  res.statusCode = 200;
  res.headers = {};
  res.writeHead = (status, headers = {}) => {
    res.statusCode = status;
    res.headers = headers;
  };
  res.body = () => Buffer.concat(chunks).toString('utf8');
  return res;
}

test('chat route falls back to local engine when LLM is disabled', async () => {
  const req = reqWithJson({ text: '今天好累', state: createInitialState('local-user') });
  const res = captureRes();

  await handleChatRequest(req, res, {
    runtimeConfig: { hasLlm: false, llm: {} },
    productSoul: '# 栖语',
    fetchImpl: async () => { throw new Error('fetch should not be called'); }
  });

  const body = JSON.parse(res.body());
  assert.equal(res.statusCode, 200);
  assert.deepEqual(body.messages, ['咋了']);
  assert.equal(body.source, 'local');
});

test('chat route uses LLM when configured and injects context', async () => {
  const calls = [];
  const req = reqWithJson({ text: '今天又加班了', state: createInitialState('local-user') });
  const res = captureRes();

  await handleChatRequest(req, res, {
    runtimeConfig: {
      hasLlm: true,
      llm: {
        apiUrl: 'https://llm.example.test/v1/chat/completions',
        apiKey: 'key',
        model: 'qiyu-test-model',
        temperature: 0.8,
        timeoutMs: 30000
      }
    },
    productSoul: '# 栖语\n\n一致性。',
    fetchImpl: async (url, options) => {
      calls.push(JSON.parse(options.body));
      return {
        ok: true,
        status: 200,
        async json() {
          return { choices: [{ message: { content: '又加班了？' } }] };
        }
      };
    }
  });

  const body = JSON.parse(res.body());
  assert.equal(body.source, 'llm');
  assert.deepEqual(body.messages, ['又加班了？']);
  assert.match(calls[0].messages[0].content, /产品灵魂原文/);
  assert.match(calls[0].messages[1].content, /关系阶段/);
  assert.match(calls[0].messages[1].content, /禁用语/);
});
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```powershell
cd E:\Agent\栖语
node --test test\server\chat-route.test.js
```

Expected: FAIL because `src/server/chat-route.js` does not exist.

- [ ] **Step 3: Implement chat route**

Create `src/server/chat-route.js`:

```js
import { buildPromptContext } from '../qiyu/prompt-context.js';
import { assertNoForbiddenPhrase } from '../qiyu/persona.js';
import { classifySafety } from '../qiyu/safety.js';
import { createQiyuReply } from '../qiyu/engine.js';
import { rememberFactsFromText } from '../qiyu/memory-extraction.js';
import { recordTurn } from '../qiyu/state.js';
import { buildSystemPrompt } from './system-prompt.js';
import { callChatCompletions } from './llm-client.js';

async function readJsonBody(req, limitBytes = 65536) {
  let raw = '';
  for await (const chunk of req) {
    raw += chunk;
    if (Buffer.byteLength(raw, 'utf8') > limitBytes) {
      throw new Error('Request body too large');
    }
  }
  return JSON.parse(raw || '{}');
}

function sendJson(res, status, payload) {
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8' });
  res.end(JSON.stringify(payload));
}

function fallbackReply(text, state) {
  const result = createQiyuReply(text, state);
  return { ...result, source: 'local' };
}

export async function handleChatRequest(req, res, { runtimeConfig, productSoul, fetchImpl = fetch }) {
  try {
    const body = await readJsonBody(req);
    const text = typeof body.text === 'string' ? body.text.trim() : '';
    const state = body.state && typeof body.state === 'object' ? body.state : null;

    if (!text || !state) {
      sendJson(res, 400, { error: 'Expected JSON body with text and state' });
      return;
    }

    const safety = classifySafety(text);
    if (safety.kind !== 'normal' || !runtimeConfig.hasLlm) {
      const result = fallbackReply(text, state);
      sendJson(res, 200, {
        messages: result.messages,
        nextState: result.nextState,
        debug: result.debug,
        source: 'local'
      });
      return;
    }

    const stateWithMemory = rememberFactsFromText(state, text);
    const systemPrompt = buildSystemPrompt(productSoul);
    const context = buildPromptContext({ state: stateWithMemory, userText: text });
    const recentTurns = (stateWithMemory.turns || []).slice(-8).map((turn) => ({
      role: turn.speaker === 'user' ? 'user' : 'assistant',
      content: turn.text
    }));

    const llmText = await callChatCompletions({
      config: runtimeConfig.llm,
      messages: [
        { role: 'system', content: systemPrompt },
        context,
        ...recentTurns,
        { role: 'user', content: text }
      ],
      fetchImpl
    });

    assertNoForbiddenPhrase(llmText);
    const withUserTurn = recordTurn(stateWithMemory, 'user', text);
    const nextState = recordTurn(withUserTurn, 'qiyu', llmText);

    sendJson(res, 200, {
      messages: llmText.split('\n').filter(Boolean),
      nextState,
      debug: { mode: 'llm' },
      source: 'llm'
    });
  } catch (error) {
    sendJson(res, 500, { error: error.message });
  }
}
```

- [ ] **Step 4: Dispatch API route from dev server**

Modify `scripts/dev-server.mjs`:

```js
import { handleChatRequest } from '../src/server/chat-route.js';
import { loadRuntimeConfig } from '../src/server/config.js';
import { loadProductSoul } from '../src/server/system-prompt.js';
```

Inside `createStaticServer(staticRoot = root)`, load config and product soul once before returning the server:

```js
export async function createStaticServer(staticRoot = root) {
  const runtimeConfig = await loadRuntimeConfig();
  const productSoul = await loadProductSoul(join(staticRoot, '栖语产品灵魂.md'));

  return createServer(async (req, res) => {
    if (req.url?.startsWith('/api/chat')) {
      await handleChatRequest(req, res, { runtimeConfig, productSoul });
      return;
    }

    const resolved = resolveRequestPath(req.url || '/', staticRoot);
    // keep the existing static-file handling below this line
  });
}
```

Update the startup block because `createStaticServer()` is now async:

```js
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const server = await createStaticServer();
  server.listen(port, host, () => {
    console.log(`栖语 MVP running at http://${host}:${port}`);
  });
}
```

- [ ] **Step 5: Verify route tests pass**

Run:

```powershell
cd E:\Agent\栖语
node --test test\server\chat-route.test.js
```

Expected: PASS for all chat route tests.

- [ ] **Step 6: Commit**

Run:

```powershell
cd E:\Agent\栖语
git add src/server/chat-route.js scripts/dev-server.mjs test/server/chat-route.test.js
git commit -m "feat: add server chat route"
```

---

### Task 7: Browser API Client

**Files:**
- Create: `E:\Agent\栖语\src\ui\chat-api.js`
- Modify: `E:\Agent\栖语\src\main.js`
- Create: `E:\Agent\栖语\test\ui\chat-api.test.js`

- [ ] **Step 1: Write failing API client tests**

Create `test/ui/chat-api.test.js`:

```js
import test from 'node:test';
import assert from 'node:assert/strict';
import { sendChatMessage } from '../../src/ui/chat-api.js';
import { createInitialState } from '../../src/qiyu/state.js';

test('sendChatMessage posts text and state to api route', async () => {
  const calls = [];
  const fetchImpl = async (url, options) => {
    calls.push({ url, options });
    return {
      ok: true,
      status: 200,
      async json() {
        return {
          messages: ['咋了'],
          nextState: createInitialState('local-user'),
          debug: { mode: 'llm' },
          source: 'llm'
        };
      }
    };
  };

  const state = createInitialState('local-user');
  const result = await sendChatMessage({ text: '今天好累', state, fetchImpl });

  assert.deepEqual(result.messages, ['咋了']);
  assert.equal(calls[0].url, '/api/chat');
  assert.equal(calls[0].options.method, 'POST');
  assert.equal(JSON.parse(calls[0].options.body).text, '今天好累');
});

test('sendChatMessage reports bad api responses', async () => {
  await assert.rejects(
    () => sendChatMessage({
      text: '今天好累',
      state: createInitialState('local-user'),
      fetchImpl: async () => ({
        ok: false,
        status: 500,
        async text() {
          return '{"error":"bad"}';
        }
      })
    }),
    /Chat API failed: 500/
  );
});
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```powershell
cd E:\Agent\栖语
node --test test\ui\chat-api.test.js
```

Expected: FAIL because `src/ui/chat-api.js` does not exist.

- [ ] **Step 3: Implement browser chat API client**

Create `src/ui/chat-api.js`:

```js
export async function sendChatMessage({ text, state, fetchImpl = fetch }) {
  const response = await fetchImpl('/api/chat', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ text, state })
  });

  if (!response.ok) {
    const body = await response.text();
    throw new Error(`Chat API failed: ${response.status} ${body}`);
  }

  return response.json();
}
```

- [ ] **Step 4: Wire main UI to server with local fallback**

Modify `src/main.js`:

```js
import { sendChatMessage } from './ui/chat-api.js';
```

In the submit handler, replace the direct local engine call:

```js
const result = createQiyuReply(text, state);
state = result.nextState;
saveBrowserState(storage, state);

processReplyQueue(result.messages);
```

with:

```js
let result;
try {
  result = await sendChatMessage({ text, state });
} catch {
  result = createQiyuReply(text, state);
}

state = result.nextState;
saveBrowserState(storage, state);
processReplyQueue(result.messages);
```

Make the submit listener async:

```js
form.addEventListener('submit', async (event) => {
```

- [ ] **Step 5: Verify UI API tests and existing UI tests pass**

Run:

```powershell
cd E:\Agent\栖语
node --test test\ui\chat-api.test.js test\ui\render.test.js
```

Expected: PASS for API client and render tests.

- [ ] **Step 6: Commit**

Run:

```powershell
cd E:\Agent\栖语
git add src/ui/chat-api.js src/main.js test/ui/chat-api.test.js
git commit -m "feat: send browser chat through api route"
```

---

### Task 8: Docs And Verification

**Files:**
- Modify: `E:\Agent\栖语\README.md`
- Modify: `E:\Agent\栖语\docs\product\behavior-spec.md`

- [ ] **Step 1: Add LLM config docs to README**

Append this section to `README.md`:

````markdown
## LLM API 配置

浏览器不会读取 API Key。所有 LLM 请求都从本地 Node dev server 的 `/api/chat` 发出。

环境变量方式：

```powershell
cd E:\Agent\栖语
$env:LLM_API_URL="https://api.example.com/v1/chat/completions"
$env:LLM_API_KEY="你的真实 key"
$env:LLM_MODEL="provider-model-name"
npm run dev
```

本地配置文件方式：

复制 `qiyu.config.example.json` 为 `qiyu.config.local.json`，写入真实 `apiUrl`、`apiKey`、`model`。`qiyu.config.local.json` 已加入 `.gitignore`，不要提交。

没有配置 LLM 时，应用自动使用本地规则引擎。
````

- [ ] **Step 2: Add prompt boundary docs to behavior spec**

Append this section to `docs/product/behavior-spec.md`:

```markdown
## LLM Prompt 注入边界

每次调用 LLM 时注入三层上下文：

1. `栖语产品灵魂.md` 生成的 system prompt。
2. 当前关系阶段、相关记忆、最近对话、情绪惯性。
3. 禁用语清单与回复约束。

LLM 输出后必须再次做禁用语检查。检查失败时不把该回复展示给用户，改用本地规则引擎兜底。
```

- [ ] **Step 3: Run full verification**

Run:

```powershell
cd E:\Agent\栖语
npm test
npm run eval
```

Expected: all tests pass and evals print `Qiyu evals passed`.

- [ ] **Step 4: Manual local verification without API key**

Run:

```powershell
cd E:\Agent\栖语
npm run dev
```

Expected:

- Server starts at `http://127.0.0.1:5173`.
- Sending `今天好累` returns local fallback reply `咋了`.
- Browser console has no API key.

- [ ] **Step 5: Manual local verification with API key**

Run with a real provider config:

```powershell
cd E:\Agent\栖语
$env:LLM_API_URL="https://api.example.com/v1/chat/completions"
$env:LLM_API_KEY="你的真实 key"
$env:LLM_MODEL="provider-model-name"
npm run dev
```

Expected:

- Sending `今天好累` goes through `/api/chat`.
- Network tab shows browser request only to `/api/chat`.
- Provider key is not visible in browser requests.
- Response does not contain any phrase from `FORBIDDEN_PHRASES`.

- [ ] **Step 6: Commit**

Run:

```powershell
cd E:\Agent\栖语
git add README.md docs/product/behavior-spec.md
git commit -m "docs: document llm api integration"
```

---

## Self-Review

Spec coverage:

- "接一个 LLM API" is covered by `llm-client.js`, `chat-route.js`, and `/api/chat`.
- "把产品灵魂文档变成 system prompt" is covered by `system-prompt.js`.
- "记忆、关系阶段、禁用语检查作为 prompt 上下文注入" is covered by `prompt-context.js`.
- "API Key 配置（环境变量或配置文件）" is covered by `config.js`, `.gitignore`, and README docs.
- Secret safety is covered by server-side-only API calls and browser client tests.
- Existing deterministic behavior remains as local fallback.

Placeholder scan:

- No task uses unspecified file names.
- No code step says to add generic handling without a concrete snippet.
- Provider-specific uncertainty is explicitly scoped to OpenAI-compatible chat completions.

Type and name consistency:

- Browser client is consistently named `sendChatMessage({ text, state, fetchImpl })`.
- Server route is consistently named `handleChatRequest(req, res, deps)`.
- Runtime config is consistently named `loadRuntimeConfig()`.
- LLM client is consistently named `callChatCompletions()`.
- Prompt context is consistently named `buildPromptContext({ state, userText })`.

## Execution Handoff

Plan complete and saved to `docs/plans/2026-06-01-llm-api-integration.md`. Two execution options:

1. **Subagent-Driven (recommended)** - dispatch a fresh subagent per task, review between tasks, fast iteration.
2. **Inline Execution** - execute tasks in this session using `superpowers:executing-plans`, batch execution with checkpoints.

Choose one before implementation begins.
