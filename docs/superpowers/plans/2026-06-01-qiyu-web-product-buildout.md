# 栖语完整 Web 产品 Buildout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the current 栖语 Web MVP into a polished, complete, high-standard Web/PWA product with onboarding, chat, settings, memory control, quality lab, and release-grade UX.

**Architecture:** Keep the existing vanilla JavaScript + Node server architecture, but split the app into route-level screens and product modules. The browser owns presentation and local interaction state; the Node server owns LLM calls, prompt construction, config loading, and secret handling. The existing deterministic 栖语 engine remains the fallback and regression baseline.

**Tech Stack:** Vanilla JavaScript ES modules, Node built-in `node:test`, Node `http` server, HTML/CSS, localStorage, server-side LLM gateway, PWA manifest/service worker, no mandatory frontend framework in this plan.

---

## 0. Scope And Delivery Strategy

This plan is not a single giant feature. It is a staged product buildout. Each stage should leave the product in a usable state and should be reviewed before moving on.

Source spec:

- `E:\Agent\栖语\docs\superpowers\specs\2026-06-01-qiyu-web-product-design.md`

Current known foundation:

- Existing Web MVP.
- Existing local chat UI.
- Existing 栖语 behavior engine.
- Existing LLM gateway modules.
- Existing tests for prompt, config, LLM client, chat route, state, safety, memory, and UI helpers.

Primary rule:

- Do not optimize for feature count. Optimize for “用户打开就想试，试完晚上还想回来”.

Out of scope for this plan:

- Native iOS.
- Native Android.
- Payment.
- Multi-user cloud accounts.
- Production database.
- Social/community features.

---

## 1. Product Slices

Implement in this order:

1. Product shell and routing.
2. Design system and visual baseline.
3. Homepage with first-use trial chat.
4. Main chat upgrade.
5. Onboarding.
6. Settings center.
7. Memory center.
8. Quality lab.
9. PWA and install experience.
10. Release quality pass.

The order matters. The product should first feel like a complete website, then become deeper.

---

## 2. File Ownership Map

Expected file areas:

- `src/main.js` - app bootstrap and route dispatch.
- `src/router.js` - client-side route parsing and navigation.
- `src/screens/home.js` - homepage / trial chat.
- `src/screens/chat.js` - main chat screen.
- `src/screens/onboarding.js` - first-use flow.
- `src/screens/settings.js` - settings center.
- `src/screens/memory.js` - memory center.
- `src/screens/lab.js` - quality lab.
- `src/screens/privacy.js` - privacy and safety explanation.
- `src/ui/` - reusable UI rendering utilities.
- `src/qiyu/` - persona, state, memory, prompt, safety, behavior logic.
- `src/server/` - config, LLM, prompt, API routes.
- `src/styles.css` - design system and page styles.
- `public/manifest.webmanifest` - PWA manifest.
- `public/icons/` - PWA icons.
- `public/offline.html` - offline fallback.
- `sw.js` - service worker.
- `test/screens/` - route and screen tests.
- `test/ui/` - UI utility tests.
- `test/server/` - server route and config tests.
- `test/qiyu/` - behavior and AI guardrail tests.
- `eval/` - golden cases and product regression fixtures.
- `docs/product/` - product behavior docs.

Use this map as a boundary guide. Do not put route rendering, LLM calls, memory editing, and prompt debugging all into one file.

---

## Task 1: Product Shell And Routing

**Purpose:** Turn the single-screen MVP into a multi-page Web product without adding visual complexity yet.

**Files:**

- Create: `src/router.js`
- Create: `src/screens/home.js`
- Create: `src/screens/chat.js`
- Create: `src/screens/onboarding.js`
- Create: `src/screens/settings.js`
- Create: `src/screens/memory.js`
- Create: `src/screens/lab.js`
- Create: `src/screens/privacy.js`
- Modify: `src/main.js`
- Modify: `scripts/dev-server.mjs`
- Add tests under `test/screens/`

**Steps:**

- [ ] Define route table for `/`, `/chat`, `/onboarding`, `/settings`, `/memory`, `/lab`, `/privacy`.
- [ ] Add a small router that renders screen modules without full page reloads.
- [ ] Ensure direct browser refresh on every route returns `index.html`.
- [ ] Create placeholder-quality but real screens for all routes.
- [ ] Keep `/chat` backed by the existing chat behavior.
- [ ] Add navigation landmarks and skip link for accessibility.
- [ ] Add tests for route matching and unknown-route fallback.
- [ ] Run full test suite.
- [ ] Commit as `feat: add product shell routing`.

**Acceptance Criteria:**

- Directly opening `/settings` works.
- Directly opening `/memory` works.
- Unknown routes show a friendly not-found state.
- Existing chat still works.
- No route exposes config files or markdown source through the static server.

---

## Task 2: Design System And Visual Baseline

**Purpose:** Establish the visual quality bar before building all pages.

**Files:**

- Modify: `src/styles.css`
- Create: `src/ui/layout.js`
- Create: `src/ui/components.js`
- Create: `docs/product/design-system.md`
- Add tests under `test/ui/`

**Steps:**

- [ ] Define design tokens: colors, text sizes, spacing, radii, shadows, motion timing.
- [ ] Define page layout primitives: app shell, narrow content, split content, settings layout.
- [ ] Define reusable components: button, icon button, input, textarea, segmented control, toggle, field row, notice, modal.
- [ ] Define chat primitives: message bubble, typing indicator, silence indicator, day marker.
- [ ] Define responsive behavior for mobile, tablet, desktop.
- [ ] Add reduced-motion styling.
- [ ] Add focus-visible styling.
- [ ] Document design rules in `docs/product/design-system.md`.
- [ ] Add render tests for core UI components.
- [ ] Run full test suite.
- [ ] Commit as `style: establish qiyu design system`.

**Acceptance Criteria:**

- The product looks coherent across all placeholder screens.
- No nested card-heavy UI.
- Chat remains the visual center.
- Text is readable on mobile.
- Keyboard focus is visible.
- Reduced-motion users do not get unnecessary animation.

---

## Task 3: Homepage And Trial Chat

**Purpose:** Make the first 30 seconds compelling.

**Files:**

- Modify: `src/screens/home.js`
- Modify: `src/ui/chat-api.js`
- Modify: `src/qiyu/state.js` if trial state needs separation
- Add tests under `test/screens/home.test.js`

**Steps:**

- [ ] Build homepage as product-first screen, not marketing page.
- [ ] Show 栖语 name, one-line positioning, and immediate input.
- [ ] Support anonymous trial chat for 3-5 turns.
- [ ] After trial threshold, invite user into onboarding without blocking abruptly.
- [ ] Keep trial state separate from full memory unless user consents.
- [ ] Add “继续今晚的对话” path for returning local users.
- [ ] Add tests for trial turn limit and onboarding invitation.
- [ ] Run full test suite.
- [ ] Commit as `feat: add homepage trial chat`.

**Acceptance Criteria:**

- User can type on first screen without scrolling.
- First reply feels like 栖语, not product copy.
- Trial does not expose model configuration.
- Trial does not silently create long-term memory.

---

## Task 4: Main Chat Experience Upgrade

**Purpose:** Turn chat from working demo into nightly product experience.

**Files:**

- Modify: `src/screens/chat.js`
- Modify: `src/main.js` if chat state is still centralized there
- Modify: `src/ui/render.js`
- Modify: `src/ui/chat-api.js`
- Modify: `src/qiyu/reply-policy.js`
- Modify: `src/qiyu/engine.js`
- Add tests under `test/screens/chat.test.js` and `test/qiyu/`

**Steps:**

- [ ] Move chat rendering out of `main.js` into `src/screens/chat.js`.
- [ ] Preserve existing LLM API route usage and local fallback.
- [ ] Add multi-bubble timing behavior.
- [ ] Add silence state.
- [ ] Add “晚安后收束” UI state.
- [ ] Add connection status for LLM fallback without exposing technical noise.
- [ ] Add message resend path when request fails.
- [ ] Add mobile keyboard handling.
- [ ] Add tests for bedtime state, fallback display, and message queue behavior.
- [ ] Run golden evals.
- [ ] Run full test suite.
- [ ] Commit as `feat: upgrade nightly chat experience`.

**Acceptance Criteria:**

- User can chat for 10 minutes without layout instability.
- User saying “晚安” does not trigger a new question.
- LLM failure does not break the session.
- Message queue cannot double-submit while 栖语 is responding.
- Chat is usable on mobile.

---

## Task 5: Onboarding Flow

**Purpose:** Make first-time setup feel like meeting 栖语, not filling a form.

**Files:**

- Modify: `src/screens/onboarding.js`
- Modify: `src/qiyu/state.js`
- Create: `src/qiyu/preferences.js`
- Add tests under `test/screens/onboarding.test.js` and `test/qiyu/preferences.test.js`

**Steps:**

- [ ] Define onboarding state: not started, in progress, completed, skipped.
- [ ] Ask no more than four main questions: name, sleep time, companionship style, memory consent.
- [ ] Allow skipping each step.
- [ ] Save preferences separately from conversational memories.
- [ ] Explain memory in human language.
- [ ] Route completed users to `/chat`.
- [ ] Add tests for completion, skip, and preference persistence.
- [ ] Run full test suite.
- [ ] Commit as `feat: add qiyu onboarding flow`.

**Acceptance Criteria:**

- Onboarding completes in under 90 seconds.
- User can skip all optional steps.
- Memory consent is explicit.
- User lands naturally in chat after onboarding.

---

## Task 6: Settings Center

**Purpose:** Provide complete configuration without overwhelming normal users.

**Files:**

- Modify: `src/screens/settings.js`
- Modify: `src/server/config.js`
- Modify: `src/server/chat-route.js`
- Create: `src/server/settings-route.js`
- Create: `src/ui/settings-controls.js`
- Add tests under `test/screens/settings.test.js` and `test/server/settings-route.test.js`

**Steps:**

- [ ] Split settings into normal, AI, privacy, safety, developer sections.
- [ ] Hide advanced model settings by default.
- [ ] Add API URL, API Key, Model, Temperature, Timeout fields.
- [ ] Add connection test action.
- [ ] Ensure API Key is never rendered back in plain text after save.
- [ ] Add recommended defaults.
- [ ] Add reset-to-defaults.
- [ ] Add developer preview of prompt context and last fallback reason.
- [ ] Add tests for advanced section visibility and connection test.
- [ ] Run full test suite.
- [ ] Commit as `feat: add settings center`.

**Acceptance Criteria:**

- Normal users see understandable settings first.
- Advanced users can configure LLM fully.
- API Key is not exposed in browser-readable long-term storage.
- Connection errors are human-readable.

---

## Task 7: Memory Center

**Purpose:** Make memory visible, editable, deletable, and trustworthy.

**Files:**

- Modify: `src/screens/memory.js`
- Modify: `src/qiyu/state.js`
- Create: `src/qiyu/memory-store.js`
- Modify: `src/qiyu/prompt-context.js`
- Add tests under `test/screens/memory.test.js` and `test/qiyu/memory-store.test.js`

**Steps:**

- [ ] Add memory list grouped by category.
- [ ] Show memory value, source, updated time, and prompt eligibility.
- [ ] Add edit memory.
- [ ] Add delete memory.
- [ ] Add freeze memory / do not mention.
- [ ] Add “allow in LLM context” toggle.
- [ ] Add sensitive memory collapsed state.
- [ ] Update prompt context to exclude frozen or disallowed memories.
- [ ] Add tests for edit, delete, freeze, and prompt exclusion.
- [ ] Run full test suite.
- [ ] Commit as `feat: add memory center`.

**Acceptance Criteria:**

- User can delete any memory in under 10 seconds.
- Every memory shows source.
- Frozen memory never enters prompt context.
- Sensitive memory is not overexposed in UI.

---

## Task 8: Privacy And Safety Page

**Purpose:** Make trust boundaries understandable.

**Files:**

- Modify: `src/screens/privacy.js`
- Modify: `docs/product/behavior-spec.md`
- Add tests under `test/screens/privacy.test.js`

**Steps:**

- [ ] Explain what data is stored locally.
- [ ] Explain what enters LLM context.
- [ ] Explain API Key boundary.
- [ ] Explain deletion and export.
- [ ] Explain crisis safety behavior.
- [ ] Explain what 栖语 will not do.
- [ ] Add test that page contains key privacy and safety sections.
- [ ] Run full test suite.
- [ ] Commit as `docs: add in-product privacy and safety page`.

**Acceptance Criteria:**

- Privacy page is readable by non-technical users.
- It explicitly covers memory, LLM context, API Key, and crisis handling.

---

## Task 9: Quality Lab

**Purpose:** Give development a product-quality control room.

**Files:**

- Modify: `src/screens/lab.js`
- Modify: `scripts/run-evals.mjs`
- Modify: `eval/golden-cases.json`
- Create: `src/qiyu/eval-runner.js`
- Add tests under `test/screens/lab.test.js` and `test/qiyu/eval-runner.test.js`

**Steps:**

- [ ] Move eval logic into reusable module.
- [ ] Show golden case pass/fail results in `/lab`.
- [ ] Show forbidden phrase hits.
- [ ] Show bedtime reopening failures.
- [ ] Show safety routing failures.
- [ ] Show relationship-stage behavior checks.
- [ ] Add exportable report.
- [ ] Keep `/lab` hidden from primary navigation unless developer mode is on.
- [ ] Run evals and full test suite.
- [ ] Commit as `feat: add qiyu quality lab`.

**Acceptance Criteria:**

- A prompt/model change can be evaluated from the UI.
- Failures show actionable reasons.
- Golden cases remain runnable from CLI.

---

## Task 10: PWA Install Experience

**Purpose:** Make the Web product feel like a daily-use app.

**Files:**

- Create: `public/manifest.webmanifest`
- Create: `public/offline.html`
- Create: `public/icons/`
- Create: `sw.js`
- Modify: `index.html`
- Modify: `scripts/dev-server.mjs`
- Add tests under `test/server/dev-server.test.js`

**Steps:**

- [ ] Add Web App Manifest.
- [ ] Add app name, short name, theme color, background color, display mode.
- [ ] Add required icon sizes.
- [ ] Add service worker for app shell caching.
- [ ] Add offline fallback page.
- [ ] Add install prompt UI only after user has experienced chat.
- [ ] Ensure service worker does not cache API Key or sensitive chat responses.
- [ ] Verify static server serves manifest, icons, service worker, and offline page.
- [ ] Run full test suite.
- [ ] Commit as `feat: add pwa install experience`.

**Acceptance Criteria:**

- Browser recognizes the app as installable.
- Offline fallback is graceful.
- Sensitive API responses are not cached.

---

## Task 11: Release Quality Pass

**Purpose:** Bring the product up to publishable quality.

**Files:**

- Modify files across `src/`, `scripts/`, `docs/`, and `eval/` as issues are found.
- Create: `docs/product/release-checklist.md`

**Steps:**

- [ ] Create release checklist document.
- [ ] Run full automated test suite.
- [ ] Run golden evals.
- [ ] Run manual mobile viewport check.
- [ ] Run keyboard-only navigation check.
- [ ] Run reduced-motion check.
- [ ] Run API key leakage check.
- [ ] Run static server exposure check for local config and markdown files.
- [ ] Measure Core Web Vitals locally or with Lighthouse.
- [ ] Fix issues found during the pass.
- [ ] Commit as `chore: complete web product release pass`.

**Acceptance Criteria:**

- `npm test` passes.
- `npm run eval` passes.
- Homepage supports immediate trial chat.
- `/chat`, `/onboarding`, `/settings`, `/memory`, `/lab`, `/privacy` all work.
- API Key is not visible in browser requests except opaque server session behavior.
- PWA installability checks pass.
- No critical accessibility blockers remain.

---

## Milestone Review Gates

Use these review gates before continuing.

### Gate A: Product Skeleton

After Tasks 1-3:

- The site feels like a real product shell.
- Homepage trial chat works.
- Visual baseline is coherent.

### Gate B: Core Product

After Tasks 4-7:

- Main chat is strong.
- Onboarding works.
- Settings and memory control are usable.

### Gate C: Release Candidate

After Tasks 8-11:

- Trust pages exist.
- Quality lab exists.
- PWA works.
- Release checklist passes.

---

## Self-Review

Spec coverage:

- Homepage / trial chat is Task 3.
- Main chat is Task 4.
- Onboarding is Task 5.
- Settings center is Task 6.
- Memory center is Task 7.
- Privacy and safety page is Task 8.
- Quality lab is Task 9.
- PWA is Task 10.
- SOTA release standards are Task 11.

Scope check:

- This plan intentionally excludes native iOS/Android, payments, production accounts, and cloud database. Those should be separate plans after the Web product reaches release-candidate quality.

No-code constraint:

- This plan gives execution route, owned files, tests, and acceptance criteria. It intentionally does not include concrete implementation code.

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-06-01-qiyu-web-product-buildout.md`. Two execution options:

1. **Subagent-Driven (recommended)** - dispatch a fresh subagent per task, review between tasks, fast iteration.
2. **Inline Execution** - execute tasks in this session using `superpowers:executing-plans`, batch execution with checkpoints.

Choose one before implementation begins.
