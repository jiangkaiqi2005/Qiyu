# Qiyu Adopt Borrowed Improvements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Absorb only the previously identified "worth borrowing" Claude Code changes into `develop`, while excluding cautious or not-recommended changes.

**Architecture:** Keep the shared reply-delivery helper as the single source of truth for visible reply filtering and text wait timing. Share HTTP request/response helpers across local server routes, tighten the static CSP, and keep tests focused on the adopted behavior only.

**Tech Stack:** Vanilla JavaScript ES modules, Node.js built-in test runner, local dev server modules.

---

## Scope And Exclusions

Adopt:
- Reply delivery filtering for standalone silence markers and LLM stage directions.
- Input-aware text waiting in the chat screen.
- Shared server HTTP helpers for JSON body parsing, JSON responses, and CSRF/Origin checks.
- CSP tightening in `index.html`.
- Tests directly covering those adopted behaviors.

Do not adopt:
- `.claude/` workflow scripts.
- Previous 2026-06-09 plan documents.
- Daily conversation turn truncation behavior.
- Cross-date `activeConversationDate` behavior tests.
- Reply-policy wording or emotion-decay changes that are unrelated to reply delivery.

## File Structure

- Create: `src/qiyu/reply-delivery.js`
  - Filters non-visible reply lines and calculates text wait timing.
- Create: `test/qiyu/reply-delivery.test.js`
  - Covers stage-direction filtering, fallback behavior, and timing ranges.
- Create: `src/server/http-utils.js`
  - Owns shared HTTP helpers used by server routes.
- Create: `test/server/http-utils.test.js`
  - Covers JSON body parsing, JSON response output, and CSRF/Origin decisions.
- Modify: `src/qiyu/engine.js`
  - Normalizes local replies before returning and recording them.
- Modify: `src/server/chat-route.js`
  - Normalizes LLM replies before forbidden-phrase checks, returning, and recording.
- Modify: `src/screens/chat.js`
  - Uses the shared delivery helper for visible reply messages and wait timing.
- Modify: `src/server/settings-route.js`
  - Uses shared HTTP helpers.
- Modify: `scripts/dev-server.mjs`
  - Uses shared HTTP helpers for `/api/dev/context`.
- Modify: `index.html`
  - Tightens CSP with explicit script and connect directives.
- Modify: tests under `test/qiyu`, `test/server`, and `test/screens`
  - Keeps only tests that prove adopted behavior.

---

### Task 1: Keep Reply Delivery Filtering And Chat Wait Timing

**Files:**
- Create: `src/qiyu/reply-delivery.js`
- Create: `test/qiyu/reply-delivery.test.js`
- Modify: `src/qiyu/engine.js`
- Modify: `src/server/chat-route.js`
- Modify: `src/screens/chat.js`
- Modify: `test/qiyu/engine.test.js`
- Modify: `test/server/chat-route.test.js`
- Modify: `test/screens/chat.test.js`

- [ ] **Step 1: Verify the delivery helper exists**

Run:

```powershell
Test-Path src/qiyu/reply-delivery.js
```

Expected: `True`.

- [ ] **Step 2: Verify local replies use normalized messages**

Check `src/qiyu/engine.js` for:

```js
const messages = normalizeReplyMessages(plan.messages, { fallback: '嗯。' });
```

Expected: local reply messages are normalized before `recordTurn()`.

- [ ] **Step 3: Verify LLM replies use normalized messages**

Check `src/server/chat-route.js` for:

```js
const messages = normalizeReplyMessages(llmText.split('\n').filter(Boolean), { fallback: '我在。' });
const visibleText = messages.join('\n');
assertNoForbiddenPhrase(visibleText);
```

Expected: forbidden phrases are checked after filtering visible text.

- [ ] **Step 4: Verify chat screen uses input-aware wait timing**

Check `src/screens/chat.js` for:

```js
const visibleMessages = normalizeReplyMessages(replyMessages, { fallback: null });
const delay = calculateTextWaitMs({
  userText: deliveryContext.userText,
  replyText: text,
  mode: deliveryContext.mode
});
```

Expected: UI-only filtering does not create unpersisted fallback bubbles, and delay uses user input plus mode.

- [ ] **Step 5: Run focused reply and chat tests**

Run:

```powershell
npm test -- test/qiyu/reply-delivery.test.js test/qiyu/engine.test.js test/server/chat-route.test.js test/screens/chat.test.js
```

Expected: all selected tests pass.

---

### Task 2: Keep Shared HTTP Helpers And CSP Tightening

**Files:**
- Create: `src/server/http-utils.js`
- Create: `test/server/http-utils.test.js`
- Modify: `src/server/settings-route.js`
- Modify: `scripts/dev-server.mjs`
- Modify: `index.html`

- [ ] **Step 1: Verify shared HTTP helpers exist**

Run:

```powershell
Test-Path src/server/http-utils.js
```

Expected: `True`.

- [ ] **Step 2: Verify routes import shared helpers**

Check `src/server/settings-route.js` for:

```js
import { readJsonBody, sendJson, validateCsrfAndOrigin } from './http-utils.js';
```

Check `scripts/dev-server.mjs` for:

```js
import { readJsonBody, validateCsrfAndOrigin } from '../src/server/http-utils.js';
```

Expected: duplicate helper implementations are removed from both files.

- [ ] **Step 3: Verify CSP is explicit**

Check `index.html` for:

```html
script-src 'self';
connect-src 'self';
```

Expected: both directives are present in the CSP meta tag.

- [ ] **Step 4: Run focused server tests**

Run:

```powershell
npm test -- test/server/http-utils.test.js test/server/settings-route.test.js test/server/dev-server.test.js
```

Expected: all selected tests pass.

---

### Task 3: Remove Excluded Claude Code Artifacts And Non-Target Diffs

**Files:**
- Delete: `.claude/workflows/iterative-review.js`
- Delete: `.claude/workflows/strict-review-loop.js`
- Delete: `docs/plans/2026-06-09-qiyu-text-waiting-rhythm.md`
- Delete: `docs/plans/2026-06-09-qiyu-text-waiting-rhythm-repair.md`
- Modify: `src/qiyu/state.js`
- Modify: `src/qiyu/reply-policy.js`
- Modify: `test/qiyu/state.test.js`
- Modify: `test/qiyu/reply-policy.test.js`

- [ ] **Step 1: Delete excluded workflow and old plan files**

Remove only these four files:

```text
.claude/workflows/iterative-review.js
.claude/workflows/strict-review-loop.js
docs/plans/2026-06-09-qiyu-text-waiting-rhythm.md
docs/plans/2026-06-09-qiyu-text-waiting-rhythm-repair.md
```

Expected: no `.claude/` files remain in `git status --short`.

- [ ] **Step 2: Revert daily conversation turn truncation**

In `src/qiyu/state.js`, keep only the existing session-level cap and restore daily conversation append behavior:

```js
turns: [...currentConv.turns, nextTurn]
```

Expected: no daily history truncation diff remains.

- [ ] **Step 3: Revert unrelated reply-policy edits**

In `src/qiyu/reply-policy.js`, restore the original non-delivery policy behavior:

```js
gentle: ['离开了吗', '说来听听', '嗯 怎么了', '继续', '怎么说'],
OPEN_REPLIES['熟悉'].gentle = ['然后呢', '说来听听', '嗯 怎么了', '继续', '怎么说'];
function pickRandom(pool, text) {
```

Expected: the delivery feature no longer changes reply-policy wording, helper naming, or unrelated emotion-decay behavior.

- [ ] **Step 4: Remove tests for excluded behavior**

Remove the added `test/qiyu/state.test.js` tests for:
- `saveBrowserState serializes and stores state`
- `recordTurn caps turns at MAX_SESSION_TURNS`
- `recordTurn cross-date behavior when activeConversationDate is stale`
- `getConversationDate formats date across year boundary`

Remove the added `test/qiyu/reply-policy.test.js` tests for unrelated bedtime style and `decayEmotion()` behavior.

Expected: tests only cover adopted behavior.

- [ ] **Step 5: Run focused non-target regression tests**

Run:

```powershell
npm test -- test/qiyu/state.test.js test/qiyu/reply-policy.test.js
```

Expected: all selected tests pass.

---

### Task 4: Final Verification And Review Loop

**Files:**
- All touched files.

- [ ] **Step 1: Run full tests**

Run:

```powershell
npm test
```

Expected: all tests pass.

- [ ] **Step 2: Run eval suite**

Run:

```powershell
npm run eval
```

Expected: all evals pass.

- [ ] **Step 3: Check whitespace and final diff**

Run:

```powershell
git diff --check
git status --short
git diff --stat
```

Expected: no whitespace errors; status includes only adopted feature files and this plan document.

- [ ] **Step 4: Review against exclusions**

Confirm:
- `.claude/` is not in `git status --short`.
- Old 2026-06-09 plan files are not in `git status --short`.
- `src/qiyu/state.js` has no daily conversation truncation diff.
- `src/qiyu/reply-policy.js` has no unrelated wording or emotion-decay diff.

Expected: only "worth borrowing" changes remain.

---

## Self-Review

- Spec coverage: The plan maps every adopted item to a task and explicitly lists the excluded items.
- Placeholder scan: No TBD/TODO/deferred implementation language remains.
- Type consistency: Shared helpers are consistently named `normalizeReplyMessages()`, `calculateTextWaitMs()`, `readJsonBody()`, `sendJson()`, and `validateCsrfAndOrigin()`.
