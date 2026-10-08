# Qiyu Borrowed Improvements Scope Repair Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove remaining tests that are outside the "worth borrowing" adoption scope.

**Architecture:** Keep chat-route tests only when they directly prove adopted LLM reply filtering or forbidden visible-text fallback behavior. Do not change runtime code unless a remaining adopted test fails.

**Tech Stack:** Vanilla JavaScript ES modules, Node.js built-in test runner.

---

## Scope

Remove from `test/server/chat-route.test.js`:
- `chat route returns 400 for missing text or state`
- `chat route falls back to local engine on safety-triggering text`
- `chat route returns 500 for oversized body`

Keep:
- `chat route removes LLM stage directions before returning and recording reply text`
- `chat route falls back local when LLM returns forbidden phrase`

---

### Task 1: Remove Out-Of-Scope Chat Route Tests

**Files:**
- Modify: `test/server/chat-route.test.js`

- [ ] **Step 1: Delete the three out-of-scope tests**

Remove only these test blocks:

```js
test('chat route returns 400 for missing text or state', async () => {
  // entire block
});

test('chat route falls back to local engine on safety-triggering text', async () => {
  // entire block
});

test('chat route returns 500 for oversized body', async () => {
  // entire block
});
```

Expected: the file still contains LLM stage-direction cleanup and forbidden visible-text fallback tests.

- [ ] **Step 2: Run focused server test**

Run:

```powershell
npm test -- test/server/chat-route.test.js
```

Expected: pass.

- [ ] **Step 3: Run full verification**

Run:

```powershell
npm test
npm run eval
git diff --check
git status --short
```

Expected: tests and eval pass; no whitespace errors; status contains only adopted feature files and plan documents.

---

## Self-Review

- Spec coverage: This plan addresses the exact CHANGES_NEEDED finding from the scope-review subagent.
- Placeholder scan: No TBD/TODO/deferred work remains.
- Type consistency: The test names match the current `test/server/chat-route.test.js` blocks.
