# Qiyu Web Soul Buildout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把当前已有雏形升级成更贴近 `栖语产品灵魂.md` 的 Web 睡前陪伴产品。

**Architecture:** 保留当前 vanilla JS + Node dev server + 本地状态 + 可选 LLM 代理架构。优先加深现有模块，不重写项目；先强化对话人格和睡前体验，再补记忆、设置、实验室和视觉完成度。

**Tech Stack:** Vanilla JavaScript ES modules, Node.js `node:test`, localStorage, OpenAI-compatible chat completions endpoint, PWA static assets.

---

## 当前基线

- 路由已覆盖 `/`、`/chat`、`/onboarding`、`/settings`、`/memory`、`/lab`、`/privacy`。
- 核心行为模块已存在：`src/qiyu/persona.js`、`src/qiyu/reply-policy.js`、`src/qiyu/engine.js`、`src/qiyu/state.js`、`src/qiyu/relationship.js`、`src/qiyu/safety.js`、`src/qiyu/prompt-context.js`。
- 服务端能力已存在：`src/server/chat-route.js`、`src/server/settings-route.js`、`scripts/dev-server.mjs`。
- 当前验证基线：`npm test` 通过 68/68，`npm run eval` 通过 9/9。

## 总体判断

当前产品已经不是空壳，下一步不应该重构或换技术栈。主要问题是“灵魂机制太薄”：很多页面和规则已经有了，但栖语仍容易像关键词回复器或诗意化表单，而不是一个稳定的人。

执行顺序应该是：

1. 先加深对话人格。
2. 再把主聊天做成真正睡前体验。
3. 然后完善记忆可控性。
4. 最后处理设置、实验室、视觉和发布质量。

---

## Phase 1: 对话人格加深

**目标:** 让栖语更像同一个人，而不是关键词规则回复器。

**主要文件:**

- `src/qiyu/reply-policy.js`
- `src/qiyu/engine.js`
- `src/qiyu/persona.js`
- `src/qiyu/prompt-context.js`
- `eval/golden-cases.json`
- `test/qiyu/*.test.js`

**要做的事:**

- [ ] 把 `reply-policy.js` 从少量关键词规则扩展成“回复策略层”：低信号、疲惫、丧失/吵架、好消息、荒谬吐槽、反复作死、钻牛角尖、晚安收束。
- [ ] 加入“沉默/停顿”作为合法输出状态，不是每次都必须有完整文本。
- [ ] 加入更稳定的口癖和句式分布，避免随机 fallback 过于机械。
- [ ] 让 `companionshipStyle` 真正影响回复尺度：安静、轻松调侃、温柔倾听都只调节强度，不改变栖语人格。
- [ ] 扩充 golden cases：不只测精确句子，也测禁止模式、长度、是否重新开启话题、是否过度共情。

**验收:**

- `npm test`
- `npm run eval`
- 手测 `/chat` 连续输入：`我到家了`、`今天好累`、`我又熬夜了`、`我不想干了`、`晚安`。
- 结果应该短、稳、不客服、不突然心理咨询师化。

---

## Phase 2: 主聊天睡前体验

**目标:** `/chat` 从“聊天页面”变成“睡前夜聊场景”。

**主要文件:**

- `src/screens/chat.js`
- `src/ui/render.js`
- `src/ui/layout.js`
- `src/styles.css`
- `src/ui/chat-api.js`
- `test/screens/chat.test.js`
- `test/ui/*.test.js`

**要做的事:**

- [ ] 给主聊天增加明确的对话状态：正常、栖语在想、栖语沉默、晚安后收束、LLM 本地兜底。
- [ ] 晚安后锁住“不开新话题”的体验，可以允许用户继续输入，但栖语不能再主动拉长对话。
- [ ] 多气泡回复要有节奏差异：短句快一点，沉重句慢一点，沉默不显示成尴尬 loading。
- [ ] 优化移动端输入区：键盘弹起后最后一条消息和输入框都必须可见。
- [ ] 重置按钮现在过于强，改成更低权重入口，避免破坏夜聊沉浸。

**验收:**

- `npm test`
- 在浏览器手测 `/chat`：连续聊 10 分钟不应出现明显布局跳动、输入区遮挡或晚安后重新提问。

---

## Phase 3: 记忆系统产品化

**目标:** 让“她记得我”既自然又可信。

**主要文件:**

- `src/qiyu/state.js`
- `src/qiyu/memory-extraction.js`
- `src/qiyu/prompt-context.js`
- `src/screens/memory.js`
- `test/qiyu/memory-extraction.test.js`
- `test/qiyu/state.test.js`
- `test/screens/memory.test.js`

**要做的事:**

- [ ] 把记忆结构补成可产品化字段：分类、敏感等级、来源原文、最近使用时间、使用次数、是否允许进上下文、是否冻结。
- [ ] 记忆提取不要只靠宽泛关键词；优先提取明确偏好、作息、反复压力源、用户主动要求记住的事。
- [ ] `prompt-context.js` 只注入少量相关记忆，避免“炫耀式记忆”。
- [ ] `/memory` 里强化来源展示和“不要再提”控制。
- [ ] 敏感记忆默认折叠，且默认不主动进入上下文，除非用户明确允许。

**验收:**

- `npm test`
- 手动添加、编辑、冻结、删除记忆后，刷新页面状态仍正确。
- 聊天中不会每次都提旧事，只在相关时自然引用。

---

## Phase 4: Onboarding 改成第一次认识

**目标:** `/onboarding` 不像设置表单，而像栖语和用户第一次认识。

**主要文件:**

- `src/screens/onboarding.js`
- `src/qiyu/preferences.js`
- `src/styles.css`
- `test/screens/onboarding.test.js`
- `test/qiyu/preferences.test.js`

**要做的事:**

- [ ] 语气从“诗意功能说明”收敛成栖语本人说话：短、日常、克制。
- [ ] 每屏只保留一个问题：怎么叫你、几点睡、你希望我少说还是多说一点、记忆是否开启。
- [ ] 跳过逻辑保持存在，但跳过后不要显得流程失败。
- [ ] 完成后直接进入 `/chat`，并让第一句聊天承接刚刚的认识。

**验收:**

- `npm test`
- 90 秒内可完成。
- 页面不出现功能清单感，不出现明显客服/表单腔。

---

## Phase 5: 设置中心分层与安全

**目标:** 普通用户不被高级配置打扰，高级用户能安全配置 LLM。

**主要文件:**

- `src/screens/settings.js`
- `src/server/settings-route.js`
- `src/server/config.js`
- `src/server/llm-client.js`
- `test/screens/settings.test.js`
- `test/server/settings-route.test.js`
- `test/server/config.test.js`

**要做的事:**

- [ ] 默认只显示普通体验设置和隐私入口。
- [ ] AI 设置、开发者模式、Prompt 预览都需要主动展开。
- [ ] API Key 显示、保存、测试连接的文案要更清楚，避免“绝不上传”这类可能误导的话；实际是保存到本地服务端配置。
- [ ] 设置保存后要明确哪些立即生效，哪些需要重启服务。
- [ ] 保持 CSRF、同源校验、密钥遮罩和错误脱敏。

**验收:**

- `npm test`
- 手测 `/settings`：普通用户能看懂，高级配置不抢首屏。
- 错误提示不泄露路径、密钥或原始栈。

---

## Phase 6: 质量实验室升级

**目标:** `/lab` 能指导后续 prompt/规则/模型迭代，而不只是展示 9 个用例。

**主要文件:**

- `src/screens/lab.js`
- `src/qiyu/eval-runner.js`
- `eval/golden-cases.json`
- `scripts/run-evals.mjs`
- `scripts/dev-server.mjs`
- `test/qiyu/eval-runner.test.js`
- `test/screens/lab.test.js`

**要做的事:**

- [ ] 给 golden cases 增加分类：低信号、晚安、关系阶段、调侃、安全、记忆引用、禁用语。
- [ ] 实验室页面按分类展示失败，而不是只展示平铺列表。
- [ ] 报告里写清失败原因：过长、禁用语、关系阶段错、晚安后开启话题、安全边界错。
- [ ] 允许开发者把当前 prompt/context 预览和 eval 结果一起导出。

**验收:**

- `npm test`
- `npm run eval`
- `/lab` 能让 AI 或人类快速知道下一步该改哪个模块。

---

## Phase 7: 视觉与页面完成度

**目标:** 让网页看起来像完整产品，而不是功能测试页。

**主要文件:**

- `src/styles.css`
- `src/ui/layout.js`
- `src/ui/components.js`
- `src/screens/home.js`
- `src/screens/chat.js`
- `src/screens/memory.js`
- `src/screens/settings.js`
- `docs/product/design-system.md`

**要做的事:**

- [ ] 降低“卡片套卡片”和内联样式密度，把页面气质统一到 CSS。
- [ ] 首页减少“AI 伴侣”这种泛化词，回到“睡前说说今天”。
- [ ] 聊天气泡、输入区、导航、按钮保持稳定尺寸，移动端不挤压。
- [ ] 统一按钮文案，减少“灵魂引擎/幻境/镌刻”等过密隐喻，保留少量即可。
- [ ] 补一次移动端视觉检查，重点看 375px 宽度。

**验收:**

- `npm test`
- 手测 `/`、`/chat`、`/onboarding`、`/memory`、`/settings`、`/lab`、`/privacy`。
- 文案不解释功能，不营销，不客服化。

---

## Phase 8: 发布质量收口

**目标:** 把功能雏形收成可发布的 Web/PWA。

**主要文件:**

- `public/manifest.webmanifest`
- `public/offline.html`
- `sw.js`
- `scripts/dev-server.mjs`
- `docs/product/release-checklist.md`
- `README.md`

**要做的事:**

- [ ] 检查 PWA manifest、icon、offline fallback 是否和当前产品名/视觉一致。
- [ ] 检查 service worker 缓存策略不会缓存敏感接口响应。
- [ ] 更新 release checklist，把人格一致性、记忆控制、安全边界、移动端体验放进发布门槛。
- [ ] README 只写真实可运行命令和当前能力，不夸大产品成熟度。

**验收:**

- `npm test`
- `npm run eval`
- `npm run dev` 后浏览器手测主路径。

---

## 推荐给后续 AI 的执行方式

一次不要全做。建议按下面顺序开工：

1. Phase 1 + Phase 6：先把人格质量标准和规则层打牢。
2. Phase 2 + Phase 4：再把用户实际体验的聊天和初遇做好。
3. Phase 3 + Phase 5：补信任、隐私、配置和记忆控制。
4. Phase 7 + Phase 8：最后做视觉收口和发布质量。

每个 phase 做完都必须跑：

```bash
npm test
npm run eval
```

如果涉及页面体验，还要启动：

```bash
npm run dev
```

然后至少手测对应路由。

