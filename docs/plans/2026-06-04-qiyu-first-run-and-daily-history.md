# Qiyu First Run And Daily History Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把栖语入口从“先试聊几句”改成“先完成昵称、习惯、API 配置，再进入聊天”，并增加按天查看每日对话记录的前端能力。

**Architecture:** 移除首页试聊路径，复用现有 `/onboarding`、`/settings`、`/chat`，新增 `/history` 作为每日对话记录页。浏览器只保存昵称、习惯、对话和本地偏好；API Key 仍通过服务端 `/api/settings` 保存，不能进入 localStorage。

**Tech Stack:** Vanilla JavaScript ES modules, Node dev server settings API, localStorage state, existing router/layout/components, Node `node:test`.

---

## 产品决策

这次不要保留“未配置先试聊 3 轮”的逻辑。原因很直接：本地规则回复质量不足，第一次体验会劝退用户。

新的首次路径：

1. 用户打开 `/`。
2. 如果未完成首次设置，直接进入配置引导，不出现试聊输入框。
3. 引导用户填写昵称、睡前时间、陪伴风格、记忆授权、API URL、API Key、Model。
4. 允许跳过 API 配置，但跳过后必须清楚显示“当前使用本地规则兜底，回复质量有限”。
5. 完成后进入 `/chat`。
6. 每天的对话自动归档，用户可在 `/history` 按日期查看。

---

## Phase 1: 移除首页试聊，改成首次设置入口

**目标:** `/` 不再出现低质量试聊。首次用户进来就是设置引导；已完成设置的用户直接进入聊天或显示“继续今晚”入口。

**主要文件:**

- `src/screens/home.js`
- `src/router.js`
- `src/ui/layout.js`
- `test/screens/home.test.js`
- `test/screens/router.test.js`

**要做的事:**

- [ ] 删除 `home.js` 里的 `qiyu_trial_state`、试聊输入框、试聊次数限制、试聊后邀请 onboarding 的逻辑。
- [ ] 首页根据 `qiyu_preferences.onboardingState` 分流：
  - `completed` -> 显示“继续今晚的对话”和“查看对话记录”。
  - 其他状态 -> 显示产品名、极短说明、一个“开始设置”按钮。
- [ ] 首页文案保持克制，不要写“先聊几句试试”。
- [ ] 不自动强制跳转，避免用户打开首页时闪屏；按钮进入 `/onboarding` 或 `/chat`。

**验收:**

- 新用户打开 `/`，看不到聊天输入框。
- 新用户只能开始设置，不能直接试聊。
- 已完成设置的用户能进入 `/chat` 和 `/history`。

---

## Phase 2: 首次引导合并用户习惯和 API 配置

**目标:** `/onboarding` 变成真正的首次配置向导，而不是只有昵称和习惯。

**主要文件:**

- `src/screens/onboarding.js`
- `src/qiyu/preferences.js`
- `src/server/settings-route.js`
- `src/server/config.js`
- `src/ui/components.js`
- `test/screens/onboarding.test.js`
- `test/qiyu/preferences.test.js`
- `test/server/settings-route.test.js`

**要做的事:**

- [ ] 将 onboarding 步骤调整为 6 步：
  1. 昵称。
  2. 常用睡前时间。
  3. 陪伴风格：多听少说 / 适当接话 / 偶尔调侃。
  4. 记忆授权。
  5. API 配置：Provider preset、API URL、API Key、Model。
  6. 测试与完成：测试 Provider、测试栖语回复、完成进入聊天。
- [ ] API Key 步骤必须调用 `/api/settings` 保存，不能写入 `qiyu_preferences` 或 `qiyu.state`。
- [ ] 如果用户跳过 API 配置，保存 `onboardingState: "completed"`，但显示明确提示：当前使用本地兜底，回复质量有限。
- [ ] 如果用户填写 API 配置但测试失败，允许继续完成，但必须显示失败原因和“稍后到设置里修改”。
- [ ] 完成 onboarding 后同步昵称、睡前时间、陪伴风格到 `qiyu.state`，再进入 `/chat`。

**验收:**

- 新用户 2 分钟内可以完成基本配置。
- API Key 不出现在 localStorage。
- API 配置成功后 `/api/settings` 返回 masked key。
- 跳过 API 时 `/chat` 仍可用，但开发者模式能看到本地兜底。

---

## Phase 3: 保护 API Key 测试和配置链路

**目标:** 先处理 API 配置的安全底线，避免测试或前端误伤真实 key。

**主要文件:**

- `src/server/settings-route.js`
- `src/server/config.js`
- `test/server/settings-route.test.js`
- `docs/plans/2026-06-04-qiyu-api-connection-fix.md`

**要做的事:**

- [ ] 先执行 `2026-06-04-qiyu-api-connection-fix.md` 的 Phase 0：测试不得删除或覆盖真实 `qiyu.config.local.json`。
- [ ] settings route 测试全部改用临时 config path。
- [ ] onboarding 中的 API 保存和测试复用 settings route，不新增浏览器端 key 存储。
- [ ] 保存 API 配置后，下一次聊天立即生效。

**验收:**

- `node --test test/server/settings-route.test.js`
- 根目录真实 `qiyu.config.local.json` 不被测试修改。

---

## Phase 4: 新增每日对话数据结构

**目标:** 从单一 `turns` 数组升级为“当前会话 + 每日归档”，让前端能按日期列出对话。

**主要文件:**

- `src/qiyu/state.js`
- `test/qiyu/state.test.js`
- `src/qiyu/prompt-context.js`
- `test/qiyu/prompt-context.test.js`

**建议数据结构:**

```js
{
  turns: [],                 // 当前仍保留最近上下文，供 prompt 和聊天页使用
  dailyConversations: [
    {
      date: "2026-06-04",
      title: "6月4日 夜话",
      startedAt: "2026-06-04T21:30:00.000Z",
      updatedAt: "2026-06-04T22:10:00.000Z",
      turns: [
        { speaker: "user", text: "今天好累", at: "..." },
        { speaker: "qiyu", text: "咋了", at: "..." }
      ]
    }
  ],
  activeConversationDate: "2026-06-04"
}
```

**要做的事:**

- [ ] `createInitialState()` 增加 `dailyConversations` 和 `activeConversationDate`。
- [ ] 新增 `getConversationDate(now)`，按本地日期生成 `YYYY-MM-DD`。
- [ ] `startSession()` 确保当天 conversation 存在，不重复创建。
- [ ] `recordTurn()` 同时写入：
  - `turns`：继续保留最近 80 条，供上下文用。
  - `dailyConversations[date].turns`：完整保留当天对话。
- [ ] `loadBrowserState()` 对旧数据做迁移：如果旧 state 只有 `turns`，按 turn 的 `at` 字段分组生成 `dailyConversations`。
- [ ] 给 `dailyConversations` 设置合理上限，例如最多 180 天；每一天内部不截断，除非后续存储压力再处理。

**验收:**

- 旧用户刷新后不会丢历史。
- 同一天多次进入 `/chat` 仍写入同一个日期。
- 第二天进入 `/chat` 自动创建新的每日记录。
- `prompt-context.js` 继续只使用最近上下文，不把全部历史塞进 prompt。

---

## Phase 5: 聊天页写入每日记录，并减少重置破坏性

**目标:** `/chat` 每轮对话自动进入当天记录；重置只重置当前聊天上下文，不误删全部历史。

**主要文件:**

- `src/screens/chat.js`
- `src/qiyu/state.js`
- `test/screens/chat.test.js`
- `test/qiyu/state.test.js`

**要做的事:**

- [ ] `/chat` 初始化时调用 `startSession()`，确保当天记录存在。
- [ ] 用户消息和栖语回复保存后，`dailyConversations` 同步更新。
- [ ] “重置对话”改为低风险操作：
  - 默认改名为“清空当前上下文”。
  - 只清空 `turns` 和当前屏幕显示，不删除 `dailyConversations`。
  - 真正删除历史放到 `/history` 或设置里的数据管理。
- [ ] 如果用户晚安后第二天回来，新一天应自动显示空聊天或当天 welcome，而不是混入昨天的全部对话。

**验收:**

- 发送一轮消息后，`qiyu.state.dailyConversations` 中当天记录包含 user 和 qiyu 两条 turn。
- 点击“清空当前上下文”后，历史页仍能看到过去对话。

---

## Phase 6: 新增 `/history` 每日对话记录页

**目标:** 前端能列出每天的对话，并打开某一天查看完整记录。

**主要文件:**

- 新建 `src/screens/history.js`
- 修改 `src/router.js`
- 修改 `src/ui/layout.js`
- 新建 `test/screens/history.test.js`
- 修改 `test/screens/router.test.js`

**页面结构:**

- 左侧或上方：日期列表。
- 每个日期项显示：
  - 日期。
  - 最后一条更新时间。
  - 消息数量。
  - 简短预览：当天最后一条用户消息或栖语消息。
- 右侧或下方：选中日期的完整对话气泡。
- 空状态：还没有夜话记录。

**要做的事:**

- [ ] 新增 `/history` route，标题为 `记录 - 栖语`。
- [ ] 导航新增“记录”入口，放在 `/chat` 附近。
- [ ] `history.js` 从 `loadBrowserState(localStorage)` 读取 `dailyConversations`。
- [ ] 默认选中最近一天。
- [ ] 点击日期切换显示该天完整对话。
- [ ] 提供“删除这一天记录”按钮，但需要确认；只删除选中日期，不影响其他天。
- [ ] 不在历史页重新调用 LLM，不允许从历史页继续聊天；继续聊天只回 `/chat`。

**验收:**

- 有多天记录时，按日期倒序显示。
- 点击某一天，完整气泡记录正确渲染。
- 删除某一天后，其他日期保留。
- 移动端日期列表和对话详情不互相挤压。

---

## Phase 7: 设置页补入口，不重复实现 onboarding

**目标:** `/settings` 仍作为后续修改入口，但不承担首次配置主流程。

**主要文件:**

- `src/screens/settings.js`
- `test/screens/settings.test.js`

**要做的事:**

- [ ] 设置页保留昵称、睡前时间、陪伴风格、记忆、API 配置。
- [ ] 如果 onboarding 未完成，设置页顶部提示“建议先完成首次设置”，提供去 `/onboarding` 按钮。
- [ ] API 区域的按钮和文案沿用 API 修复计划：测试 Provider、测试栖语回复、保存 API 配置。
- [ ] 不要在设置页再做“开始聊天”的强引导，避免和 onboarding 混乱。

**验收:**

- 完成 onboarding 后，设置页能修改同一批配置。
- 修改昵称/习惯后，下一次 `/chat` welcome 和 state 同步更新。

---

## Phase 8: 文档和发布验收

**目标:** 后续 AI 知道入口逻辑和历史数据逻辑，不会再把首页试聊加回来。

**主要文件:**

- `README.md`
- `docs/product/behavior-spec.md`
- `docs/product/release-checklist.md`
- `docs/plans/2026-06-04-qiyu-api-connection-fix.md`

**要做的事:**

- [ ] README 更新首次使用流程：先配置，再聊天。
- [ ] 明确首页不提供试聊，这是产品决策，不是缺失功能。
- [ ] 行为规范补充：低质量本地规则不作为首屏体验，只作为兜底。
- [ ] release checklist 增加：
  - 首次用户不会看到试聊输入框。
  - API Key 不进 localStorage。
  - 每日对话能按日期查看。
  - 清空当前上下文不删除历史记录。

**验收:**

- 新用户、已配置用户、跳过 API 用户三条路径都写入 README。

---

## 推荐执行顺序

1. Phase 3：先保护真实 API Key 和测试环境。
2. Phase 1 + Phase 2：改入口和首次配置，移除试聊。
3. Phase 4 + Phase 5：加每日对话数据结构并接入聊天写入。
4. Phase 6：新增 `/history` 页面和导航。
5. Phase 7 + Phase 8：收设置页和文档。

## 验证命令

Phase 3 完成前，不要在含真实 `qiyu.config.local.json` 的 repo 根目录运行全量 `npm test`。

Phase 3 完成后：

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

手测路径：

1. 清空浏览器 localStorage，打开 `/`。
2. 确认没有试聊输入框，点击开始设置。
3. 填昵称、睡前时间、陪伴风格、记忆授权、API 配置。
4. 完成后进入 `/chat`。
5. 发送两轮消息。
6. 打开 `/history`，确认当天记录存在。
7. 模拟第二天或手造不同日期记录，确认历史页按天列出。

