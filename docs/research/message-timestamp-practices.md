# 调研：消息时间戳的 UI 显示与 LLM 时间注入业界实践

- **日期**: 2026-09-02
- **背景**: 栖语已定两个方向——(1) UI 层消息时间戳倾向「默认几乎不可见、悬停显现」，触屏必须有降级；(2) LLM 层已定「最近对话每条消息文本前带时刻前缀（含当前消息）」。本调研为这两项决策提供业界事实参照。
- **调研方式**: WebSearch/WebFetch + GitHub 源码直查（gh api / PyPI sdist），优先官方文档、官方源码等一手来源
- **可靠性标注约定**: 「官方确认」= 一手来源（官方文档/源码/规范）可直接核实；「产品行为观察」= 基于产品公开界面或社区文档的行为描述，非正式规范文档；「未核实」= 仅有二手转述或无法访问原文；「未找到一手出处」= 多次检索无一手材料

## TL;DR

1. **UI 层**：主流聊天 UI 库与 IM 产品是「每条/每组消息常驻弱色小字时刻」，但 **Element Web 的出厂默认正是「默认隐藏、hover/键盘聚焦显现、仅最后一条常显、可设置常驻」**——栖语倾向的形态有成熟一手先例，且该先例还顺带处理了键盘可达性（focusWithin）与 24h 制默认。触屏降级的一手先例是 **iMessage 的左滑手势**（临时全显、松手即隐）。
2. **分组**：Rocket.Chat 源码一手确认「同人相邻 + 默认 300 秒（5 分钟）+ 跨天打断」，且 300 秒是可调的管理设置；Telegram/Discord/Slack 的「约 5 分钟」只有社区转述，无官方文档。组内省时刻（Telegram）与组内每条都带（WhatsApp）两种形态并存。
3. **LLM 层**：「历史消息带时刻进上下文」有一手成文先例——**MemGPT 把所有进入模型的消息打包成含 `time` 字段的 JSON**；**NousResearch hermes-agent 已实现/提案「每条消息在 API 调用时加 `[sent: ISO+时区]` 前缀」**，并且显式记录了工程约束：时间不进 system prompt（保缓存）、前缀紧凑省 token、不破坏 role 交替、ephemeral 不落盘。系统提示注入「当前日期」在 Cline、aider 是默认行为（aider 显式取本地时区）。
4. **公开记录的坑**：缓存失效（时间进 system prompt 或秒级变化导致 prompt cache miss）、token 开销、时区混乱（hermes 明确要求时区感知、MemGPT 用 `astimezone()` 本地时区）；「模型模仿时间戳输出到可见回复」未找到一手公开记录。

---

## A. 聊天 UI 时间显示惯例

### A.1 桌面/Web 端：常驻弱色小字 vs 默认隐藏

主流是**常驻弱色小字**（每条消息直接渲染 HH:mm），但也有成熟 UI 把「默认隐藏、hover 显现」作为出厂默认：

1. **Element Web（Matrix 客户端）是「默认隐藏、hover/聚焦显现」的一手先例**（官方确认）：
   - 用户设置 `alwaysShowTimestamps` 默认 `false`（`apps/web/src/settings/Settings.tsx`，L817-821）。
   - 渲染判定 `getShouldShowTimestamp`（`apps/web/src/viewmodels/room/timeline/event-tile/EventTileDerivedState.ts`，L233-248）：`!!eventTs && !isRtcNotification && !hideTimestamp && (alwaysShowTimestamps || last || hover || focusWithin || actionBarFocused || hasContextMenu)`——即默认情况下**只有时间线最后一条消息常显时间戳**，其余消息在鼠标悬停、键盘聚焦（focusWithin）、操作条聚焦或上下文菜单打开时显现。
   - 另有 `showTwelveHourTimestamps`（默认 false，即默认 24 小时制 HH:mm）与设备级 `userTimezone` 设置（同文件 L812-823 附近）。
   - 引用：<https://github.com/element-hq/element-web>（develop 分支，文件路径如上）
2. **Flutter 两大聊天 UI 库默认「每条消息常驻时间」**（官方确认）：
   - `flutter_chat_ui`（Flyer Chat）：文本消息组件 `flyer_chat_text_message.dart` 内 `showTime` **默认 true**，`timeStyle` 控制样式，`timeAndStatusPosition` 默认 `TimeAndStatusPosition.end`（时间与状态内联在气泡末尾）。引用：<https://github.com/flyerhq/flutter_chat_ui>（packages/flyer_chat_text_message/lib/src/flyer_chat_text_message.dart）
   - `dash_chat_2`：`TextContainer` 在 `messageOptions.showTime` 时于气泡文本下方渲染时间，默认格式 `intl.DateFormat('HH:mm')`，可用 `timeFormat`/`messageTimeBuilder` 覆盖（lib/src/widgets/message_row/text_container.dart + default_message_text.dart）。`showTime` 构造默认值未逐字段复核（未核实），但默认模板即带常驻时间。引用：<https://github.com/SebastienBtr/Dash-Chat-2>
3. **产品行为观察**：
   - WhatsApp / Telegram / Discord / Slack / iMessage 均不在桌面端把「完整时刻」做成每条消息的显著常驻元素（详见 A.2/A.5）。
   - 旁证：存在专门给 ChatGPT 网页版「补时间戳」的浏览器插件与教程（如[为ChatGPT聊天记录添加时间戳](https://wenku.csdn.net/doc/6ccedyya5a)、[如何显示Chatgpt聊天的时间](https://m.blog.csdn.net/tealcwu/article/details/151015253)），说明 ChatGPT 官方 UI 默认不给每条消息显示时刻——产品行为观察，二手。

**小结**：栖语设想的「默认几乎不可见、悬停显现」并非异端——Element Web 的出厂默认正是「除最后一条外全部隐藏、hover/键盘聚焦显现」；主流聊天 UI 库与产品则更多用「常驻弱色小字」。两者都有成熟先例。

### A.2 触屏端替代 hover 的做法

- **iMessage（iOS 系统消息）**：默认不显示每条消息的时刻（只有按日期的分隔），触屏手势是**在会话气泡上向左拖动/滑动**临时显出全部消息的时刻，松手即隐。这是「无 hover 时用一次性手势换取全局时间可见性」的代表。Apple 官方 iPhone 使用手册有对应页（[Send and reply to messages on iPhone](https://support.apple.com/guide/iphone/send-and-reply-to-messages-iph82fb73ba3/ios)），本次抓取仅返回样式表未能核对原文表述（未核实具体文字），手势本身为产品行为观察，广泛见于二手教程。
- **WhatsApp / Telegram（产品行为观察）**：采取「常驻每条/每组时刻」策略，触屏与桌面同构，不需要 hover 替代物；Telegram 只在**一组消息的最后一条**下方显示时刻，组内省略。
- **Slack / Discord（产品行为观察）**：桌面靠 hover 提示完整日期时间；移动端为常驻显示或进入长按菜单/消息详情可见（细节未核实）。
- **开源库层面**：`dash_chat_2` 的消息行自带 `onLongPress` 回调（`GestureDetector.onLongPress`，message_row.dart L86-92），把「长按」作为触屏侧的标准信息入口留给宿主自行接线（官方确认存在回调，官方建议文案未核实）。
- **键盘可达性旁注**（官方确认）：Element Web 的时间戳显现条件包含 `focusWithin`/`actionBarFocused`，即键盘 Tab 进入消息也会显现时刻——「仅 hover」的方案在桌面端同样会漏掉键盘用户。

### A.3 相邻消息分组规则（几分钟算一组、组内是否省时间）

- **Rocket.Chat：默认 300 秒（5 分钟）**（官方确认）。`MessageList.tsx`：`const messageGroupingPeriod = useSetting('Message_GroupingPeriod', 300)`；分组判定 `isMessageSequential`（`apps/meteor/client/views/room/MessageList/lib/isMessageSequential.ts`）：同用户、同 alias、`differenceInSeconds(current.ts, previous.ts) < groupingRange` 且 `!isMessageNewDay(current, previous)`、非系统消息、`current.groupable !== false`。**5 分钟内的同一人相邻消息折叠为组，跨天强制打断**。引用：<https://github.com/RocketChat/Rocket.Chat>（master 分支）
- **dash_chat_2：仅按同作者分组，未见时间窗**。`MessageRow` 用 `isPreviousSameAuthor`/`isNextSameAuthor` 决定气泡圆角、头像显隐与边距（message_row.dart L57-83），未发现按时间间隔折叠的逻辑（未核实库内其他位置是否有时间窗）。
- **flutter_chat_ui（Flyer Chat）**：本次未核查其有无时间窗分组（未核实）。
- **Telegram（产品行为观察）**：时刻只出现在一组消息最后一条下方；社区普遍转述分组窗口为 5 分钟，**未找到官方一手出处**。
- **WhatsApp（产品行为观察）**：每条气泡内部常驻时刻（组内不省略）；分组窗口未找到一手出处。
- **Discord / Slack（产品行为观察）**：同一人相邻消息折叠成组（Discord 社区转述约 5–7 分钟，Slack 同人相邻折叠；两轮检索未找到官方一手出处）。

**小结**：「同人相邻 + 约 5 分钟 + 跨天打断」是可确认的最主流分组参数（Rocket.Chat 一手确认 300 秒；Telegram/Discord/Slack 为产品观察）；也有库（dash_chat_2）完全不做时间窗。

### A.4 日期分隔条（今天/昨天）惯例

- **Rocket.Chat**：分组逻辑显式以 `isMessageNewDay(current, previous)` 打断组（isMessageSequential.ts 引用），跨天插入日期分隔（官方确认文件存在；「今天/昨天/星期」具体文案格式未核实）。
- **dash_chat_2**：`MessageRow` 有 `isAfterDateSeparator`/`isBeforeDateSeparator` 状态位驱动样式（官方确认），库内置日期分隔组件与默认格式细节未核实。
- **产品层面（产品行为观察）**：iMessage/WhatsApp/Telegram/Slack/Discord 都在日期变化处插分隔条，格式普遍为「今天/昨天/星期几/具体日期」的相对化序列；无一家在分隔条里放具体时刻。
- **未核实**：flutter_chat_ui 的日期分隔组件名与默认文案格式。

### A.5 逐产品/逐库事实清单

| 对象 | 每条消息时刻 | 完整日期获取方式 | 分组窗口 | 证据强度 |
| --- | --- | --- | --- | --- |
| Element Web | 默认隐藏，仅最后一条常显；hover/键盘聚焦显现（可设置常驻） | 悬停时间戳/消息信息面板（细节未核实） | 不做同人折叠；跨天分隔 | 官方确认（源码） |
| Rocket.Chat Web | 消息组内跟随展示时刻（弱色小字） | hover 消息元信息（未核实） | 300 秒默认，`Message_GroupingPeriod` 可调 | 官方确认（源码） |
| flutter_chat_ui | 常驻（showTime 默认 true，气泡内联 end） | timeStyle 自定义；完整日期未见默认 | 未核实 | 官方确认（源码） |
| dash_chat_2 | 常驻（showTime 开关，HH:mm 默认） | timeFormat 可改完整日期 | 仅同人分组，无时间窗 | 官方确认（源码） |
| Open WebUI | 侧栏会话列表有相对时间（`formatTimeAgo`，ChatItem.svelte）；消息气泡内时刻显示**未核实**（两轮源码搜索未命中） | 未核实 | 未核实 | 部分官方确认 + 未核实 |
| Telegram | 仅组内最后一条下方常驻 HH:mm | 点击消息进入消息详情（产品观察） | ~5 分钟（社区转述） | 产品行为观察 |
| WhatsApp | 每条气泡内常驻 HH:mm | 消息信息页 | 未找到一手出处 | 产品行为观察 |
| Discord | 桌面 hover 显示完整时间 tooltip；组头带时刻 | hover tooltip | ~5–7 分钟（社区转述） | 产品行为观察 |
| Slack | 桌面 hover 显示完整时间 tooltip | hover tooltip | 同人相邻折叠（分钟数未核实） | 产品行为观察 |
| iMessage | 默认不显示；左滑手势临时全显 | 左滑手势；长按「更多信息」（未核实） | 仅日期分隔，无同人折叠 | 产品行为观察 + 官方手册页存在 |

---

## B. LLM 上下文时间感知注入惯例

### B.1 哪些产品往 system prompt 注入当前日期/时间

**已确认注入「当前日期」的一手实例（均为编码工具/Agent 框架，非聊天陪伴产品）**：

1. **Cline**（官方确认）：系统提示模板含 `{{CURRENT_DATE}}` 占位符，装配时 `.replace("{{CURRENT_DATE}}", new Date().toLocaleDateString())`（`sdk/packages/shared/src/prompt/cline.ts`，buildClineSystemPrompt，L209）。注入的是**本地化日期字符串（仅日期，无时刻）**。引用：<https://github.com/cline/cline>
2. **aider**（官方确认）：`aider/coders/base_coder.py` L1143-1144：`dt = datetime.now().astimezone().strftime("%Y-%m-%d")` 后 `platform_text += f"- Current date: {dt}\n"`，拼进 system prompt 的平台信息块；**显式取本地时区（astimezone），格式仅年月日**。引用：<https://github.com/Aider-AI/aider>
3. **LibreChat**（官方确认，属「可选模板变量」而非默认注入）：`packages/data-provider/src/parsers.ts` L463-473 把用户自定义提示词里的模板变量替换为时间：`{{current_date}}` → `YYYY-MM-DD (weekday)`、`{{current_datetime}}` → `YYYY-MM-DD HH:mm:ss Z (weekday)`、`{{iso_datetime}}` → ISO 格式，且经 `applyTimezone` 支持时区配置。时间是否进 prompt 由用户决定（放进自己的自定义提示词才生效）。引用：<https://github.com/danny-avila/LibreChat>
4. **MemGPT**（官方确认，间接形态）：system message 中的记忆元数据块带本地时区时间戳——`compile_memory_metadata_block`（`memgpt/agent.py` L53-70）生成 `### Memory [last modified: YYYY-MM-DD hh:mm:ss AM/PM 时区偏移]`，时间用 `astimezone()` 转本地时区。引用：PyPI `pymemgpt` 0.3.25 sdist（<https://pypi.org/project/pymemgpt/>；代码现属 <https://github.com/letta-ai/letta>）
5. **hermes-agent**（官方确认，反其道）：把时间放进 **system prompt 反而被列为不可取**——PR #41425 明说 "without putting live time into the cached system prompt"，即时间应挂在消息级以保持系统提示缓存稳定（详见 B.2/B.3）。引用：<https://github.com/NousResearch/hermes-agent/pull/41425>

**未能核验的**：

- **Anthropic 官方文档对提供当前日期的指引**：目标文档 `platform.claude.com/docs/en/build-with-claude/reduce-hallucinations` 在本次环境被 307 重定向到区域不可用页（app-unavailable-in-region），docs.claude.com 又 302 回同一地址，两次均未能取得原文——**未核实**（不作任何引述）。
- **ChatGPT 本体**：社区流传多份自称泄漏的 ChatGPT/GPT 系列系统提示词文本普遍含「Current date: …」一行（如 [163 文章自称的 GPT-5 系统提示词泄漏](https://www.163.com/dy/article/K6H2PMEE0519EA27.html)），但均为**非官方二手转述，真伪无法核验**——标注：非官方、未核实。

### B.2 历史消息带时刻前缀喂给模型：有无成文先例

**有，且可分两代形态。**

**形态一：JSON 结构化内嵌（MemGPT，官方确认）**。`pymemgpt` 0.3.25 的 `memgpt/system.py` 把**所有**进入模型上下文的消息统一打包成 JSON 字符串，`time` 是必带字段：

- `package_user_message`（L119-140）：`{"type": "user_message", "message": <原文>, "time": <get_local_time()>}`（可选再带 `location`、`name`）；
- `package_system_message` / heartbeat / login / 摘要消息（L89-208）：同样结构，`time` 字段一律存在——即**当前事件（heartbeat、login）与历史消息一样都带时刻**；
- 时间源 `get_local_time()`；配合 `compile_memory_metadata_block` 在系统提示里声明记忆最后修改的本地时区时间戳。

这是「历史消息带时刻喂给模型」最著名的一手实现：时刻以结构化字段内嵌在消息 content 里，而非裸文本前缀。引用：<https://pypi.org/project/pymemgpt/>（sdist 0.3.25，memgpt/system.py）

**形态二：API 调用时逐消息加文本前缀（hermes-agent，官方确认，与栖语方案几乎同构）**：

- **Issue #10421「Turn-level live time context」**：提出 agent 需要 turn 级「现在/今天/星期几」感知，应作为核心基线能力；现状只有 session 级「Conversation started」，历史消息无时间元数据导致相对时间语言失准。引用：<https://github.com/NousResearch/hermes-agent/issues/10421>
- **Issue #62369「Inject message timestamps into agent context for time awareness」**：完整记录动机（跨天会话中模型混淆昨天/今天、streak 判断错、引用过期上下文）与方案选项——**首选「Per-message timestamp prefix — simplest, most visible to the LLM」**，示例格式 `[2026-07-09 19:11 AEST] <消息原文>`；备选：session 头 + 相对偏移、每 N 条注入系统注记、时间工具调用。硬性要求：时区感知（用配置时区而非仅 UTC）、**不破坏 role 交替**、缓存安全、跨平台一致、**紧凑省 token**。引用：<https://github.com/NousResearch/hermes-agent/issues/62369>
- **PR #41425「feat(agent): add timestamp context for replayed messages」**：实现即栖语方案——"Each string message sent to the model is prefixed at API-call time with a compact ISO timestamp"，格式 `[sent: 2026-06-07T17:42+02:00]`；**历史消息用存储的 `messages.timestamp`，当前轮回退到当前墙钟时间**；前缀是 **ephemeral，不写回会话历史**；保持 system prompt 缓存稳定。PR 状态 open（未合并）。引用：<https://github.com/NousResearch/hermes-agent/pull/41425>
- **落地证据（同仓库 issue 评论，官方确认）**：#62369 评论指网关路径已有 `gateway.message_timestamps.enabled` 配置为 iMessage/Telegram 等平台注入时间戳，PR #73967 把同一机制扩展到 cron/HA 会话；另有社区插件 `Randool/time-gap` 走 `pre_llm_call` hook 在跨 2 小时级时间隙或跨午夜时注入粗粒度提示（"prompt-cache friendly, ephemeral"）。引用：<https://github.com/NousResearch/hermes-agent/issues/62369>（评论）、<https://github.com/Randool/time-gap>

**如实说明的空白**：把「无日期、无时区的纯 HH:mm 短前缀」写进消息文本作为**成文惯例/规范文档**——未找到一手出处。业界成文先例用的是「日期+时刻+时区」的紧凑 ISO（hermes）或结构化 JSON（MemGPT）。另：OpenAI/Anthropic 的 messages 协议本身没有时间字段（协议事实），时间只能进 system 或消息文本/结构。

### B.3 公开记录的坑（模型模仿时间戳、时区混乱、token 开销）

1. **缓存失效（记录最充分的坑）**（官方确认）：hermes PR #41425 的核心设计动机即「不能把 live time 放进被缓存的 system prompt」；time-gap 插件强调 "prompt-cache friendly"。二手实践博客（[时间上下文注入：让 LLM 真正知道今天是几号](https://tianpan.co/zh/blog/2026-04-20-temporal-context-injection-llm)，2026-04）同述：system prompt 放 ISO UTC 日期 + 用户消息放本地时间的组合下，**秒级变化会导致 prompt cache 反复 miss**；对策是把变化的时间下放到消息级。栖语场景无 API 级 prompt cache（本地拼接），此坑风险主要影响 Token 计费类产品——仅陈述。
2. **token 开销**（官方确认）：hermes issue 需求 5 "Minimal footprint: Timestamps should be compact to avoid bloating token count"；其格式选择 `[sent: 2026-06-07T17:42+02:00]` 即为紧凑化结果。
3. **时区混乱**（官方确认）：hermes 需求 1 "timezone-aware (use the configured timezone, not just UTC)"；MemGPT 全链路用 `get_local_time()` / `astimezone()`（agent.py L58-59 注释明说 "Put the timestamp in the local timezone"）；LibreChat 模板变量配 `applyTimezone`。三家一手实现都不裸用 UTC。
4. **模型模仿时间戳（把前缀当内容复述）**：**未找到一手公开记录**（hermes issue/PR 未提此现象，两轮检索未见一手报告）——标注：未找到一手出处，风险只能自行验证。
5. **消息角色交替被破坏**（官方确认）：hermes 需求 2 "Must not break message role alternation (no two user or two assistant messages in a row)"——若用「独立 system 消息插时间」的形态，在要求严格交替的 API 上会报错；文本前缀形态天然规避此坑（hermes 备选方案之一 `[Message received: …]` 系统消息即受此约束）。
6. **不落盘污染**（官方确认）：hermes PR 明确时间前缀 "is ephemeral and is not persisted back into session history"——避免注入物在下一轮被当作历史原文二次拼接、层层叠加。

### B.4 开源聊天前端发给 LLM 的 messages 是否只带裸 role+content

- **LibreChat**（官方确认）：出站消息构造（`BaseClient.getMessagesForConversation` → `buildMessages`，api/app/clients/BaseClient.js）只做角色遍历与内容装载，无时间戳；时间仅经模板变量替换进文本（见 B.1 第 3 条）；BaseClient 构造函数里的 `currentDateString` 只剩 cleanup.js 置空的遗留引用，未找到注入点。结论：**发给 LLM 的是裸 role+content（+图片等 content part），无每消息时间**。引用：<https://github.com/danny-avila/LibreChat>
- **lobe-chat**（官方确认）：LLM 侧消息类型 `OpenAIChatMessage`（packages/types/src/openai/chat.ts L56-70+）字段为 `content`、`function_call`(deprecated)、`model`、`name`、`provider`、`reasoning` 等 OpenAI 形态字段，**无时间字段**。引用：<https://github.com/lobehub/lobehub>（原 lobehub/lobe-chat 已改名）
- **Open WebUI**：侧栏有相对时间（`formatTimeAgo`，src/lib/components/layout/Sidebar/ChatItem.svelte，官方确认）；消息级时间显示与出站 payload 结构两轮源码搜索未命中——**未核实**。
- **协议层佐证**（协议事实）：OpenAI/Anthropic messages 协议无时间字段；MemGPT 是自觉的例外——把时间作为 content 内 JSON 字段主动塞入（B.2 形态一）。

---

## C. 对栖语方案的映射

以下逐条对应已定的两个决策，只陈述业界事实与差异点，不替项目拍板。

### 决策 (1)：UI「默认几乎不可见、悬停显现」+ 触屏降级

- **形态先例**：Element Web 出厂默认与该倾向高度一致——除最后一条消息外默认隐藏，hover 显现，且提供「常驻」设置开关（`alwaysShowTimestamps` 默认 false）。差异：Element 的显现条件还包括**键盘聚焦与操作条聚焦**，说明「仅鼠标 hover」在成熟实现里被视为不完整——触屏与键盘的替代路径是同一问题的两半。
- **与主流库默认相反**：flutter_chat_ui（showTime 默认 true）与 dash_chat_2（默认渲染 HH:mm）都以常驻为默认；栖语若走「几乎不可见」，属于少数派但有一手先例（Element Web），不是自创形态。
- **触屏降级先例**：iMessage 的左滑手势（临时全显、松手即隐）是「无 hover 时全局显时刻」的最成熟产品先例；库层面 dash_chat_2 提供长按回调作为触屏信息入口的标准挂点；WhatsApp/Telegram 则以常驻显示回避该问题。若做分组省略（组内只留时刻），Telegram 是产品层先例（组尾时刻），Rocket.Chat 是参数层先例（300 秒）。
- **日期分隔条**：跨天打断 + 「今天/昨天/星期几」序列是全行业一致做法，无一家用时刻做分隔；Rocket.Chat 的 `isMessageNewDay` 打断分组可作工程参照。

### 决策 (2)：LLM「最近对话每条消息文本前带时刻前缀（含当前消息）」

- **同构先例**：hermes-agent PR #41425 与该决策几乎逐点对应——每条消息（含当前轮，用墙钟回退）在 API 调用时加 `[sent: ISO 日期+时刻+时区偏移]` 前缀，ephemeral 不写回会话历史。这是目前能找到的与栖语方案最接近的一手成文实现记录（PR 状态 open；网关平台路径已有同名机制在跑）。
- **结构化替代先例**：MemGPT 以 JSON 字段（`time`）内嵌覆盖全部消息与当前事件，等价于「每条都带时刻」，且历史与当前统一处理——与「含当前消息」的决策同构。
- **业界前缀格式与栖语候选形态的差异点**（仅陈述）：成文先例均带**日期与时区**（`[sent: 2026-06-07T17:42+02:00]` 或 MemGPT 的 `YYYY-MM-DD hh:mm:ss AM/PM 时区`）；「纯 HH:mm、无日期无时区」的短前缀未找到一手成文出处。业界同时记录：时刻带日期可消除跨日歧义（hermes 动机一），时区须显式（hermes 需求 1、MemGPT/LibreChat 实现）；短前缀的 token 收益由 hermes「compact」要求间接支持。
- **公开的坑与栖语的对应关系**（均为业界记录，非栖语实测）：
  1. 时间进 system prompt 伤缓存 → 栖语已定的「放消息文本前缀而非系统提示」与业界结论同向；
  2. role 交替约束 → 文本前缀形态天然合规；
  3. ephemeral 不落盘 → 栖语 sessions 的 Markdown 落盘是否包含该前缀需要自行裁定（业界是注入物不落盘、存储层时间戳另存——MemGPT `created_at`、Zep episode 时间戳均为存储侧字段，栖语的 sessions/episodes 已有独立时间元数据）；
  4. 模型模仿前缀复述 → 无一手公开记录，需自测。
- **日期注入的另一面**：Cline/aider 只在 system prompt 注入「日期」（aider 显式本地时区），不逐消息带时刻；若栖语同时在系统提示放日期、消息前放 HH:mm，等于业界两种形态的组合——此组合本身在 hermes issue 的备选方案清单里出现过（session 级日期 + 消息级时刻），属已知选项。

### 未核实清单（汇总）

- Anthropic 官方文档「提供当前日期」指引原文（区域屏蔽，两次抓取失败）。
- ChatGPT 本体注入当前日期时间（仅自称泄漏的二手文本，无官方证据）。
- Open WebUI 消息气泡级时间显示与出站 payload 结构（两轮搜索未命中）。
- Telegram/Discord/Slack 分组窗口的官方文档（均无，只有社区转述）。
- iMessage 左滑手势的 Apple 手册原文表述（页面存在但抓取仅返回样式表）。
- flutter_chat_ui 的时间窗分组与日期分隔组件细节；dash_chat_2 `showTime` 构造默认值。
- MemGPT 论文对时间感知的精确表述（arXiv PDF 抓取两次结论互相矛盾，弃用论文转述、以 pymemgpt 源码为准）。
