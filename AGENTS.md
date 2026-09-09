# AGENTS.md

栖语 (qiyu)：睡前 AI 陪伴原型，重点在行为层——人格一致性、本地记忆、关系阶段、微摩擦、少回应、安全边界。`CLAUDE.md` 是指向本文件的软链接，改约定只编辑本文件。

## 交互语言（最高优先）

**面向用户的所有输出一律用中文**：对话、提问、选项、报告、ticket 文字。代码、路径、字段名、命令等技术标识保留原文。

## 仓库形态

Release 1 = **Flutter Web UI + Dart Windows 本机 Host + 纯 Dart 行为核心**。Host 只监听 `127.0.0.1`，负责静态资源、Provider 调用、凭据与 Markdown 持久化；浏览器只负责 UI，API Key 永不进入浏览器。仓库为双壳结构：Windows 壳（`apps/qiyu_windows_host/`）与安卓壳（`apps/qiyu_flutter/android/`，进程内 Host + 原生编译 UI）依赖同一个平台无关服务包 `packages/qiyu_local_host`。旧 Node/JS 产品轨道已退役，不迁移旧 localStorage 或旧 `qiyu.config.local.json`，勿重新引入浏览器持久化主链路。

- `packages/qiyu_behavior_core/` — 纯 Dart 行为与协议核心：安全分类、本地回复、模型输出清洗与人格边界校验、稳定 DTO 与 `ChatDeliveryEvent` 流式协议；不依赖 Flutter/DOM/Windows API/具体存储。
- `packages/qiyu_local_host/` — 平台无关本机 Host 纯 Dart 核心包：`LocalAppHost`（loopback 站点 + 受会话/Origin/CSRF 保护的 API）、`LocalChatService`（交付编排）、`MemoryCadence`（记忆节奏：日终归档、月压缩、Dream、启动恢复扫描、空闲补办）、`model_gateway.dart`（OpenAI-compatible / Anthropic / Ollama 适配）、Markdown 会话与记忆模块（episode_memory、dream、persona_tree、memory_recall 等）、凭据仓接口 `SecretStore`（平台壳注入实现）；不依赖 Flutter/DOM/Windows API。
- `apps/qiyu_flutter/` — Flutter Web UI，`features/` 下含 chat、settings、memory、history、onboarding、shell 等领域。
- `apps/qiyu_windows_host/` — Dart Windows 薄壳：`bin/qiyu_windows_host.dart` 启动入口、`host_runner` 启动编排与单实例激活、`host_command` CLI 参数与 PC 路径缺省、`single_instance` 文件锁单实例、Windows 凭据管理器实现（`WindowsCredentialSecretStore`）、rundll32 浏览器引导（`WindowsDefaultBrowserLauncher`）与启动前自检；平台无关逻辑一律在 `qiyu_local_host`。
- `contracts/qiyu_behavior_contracts.json` — 当前行为契约，Core 直接消费；`legacy-migration-golden-cases.json` 只冻结旧迁移 golden，运行时不消费。
- `docs/product/behavior-spec.md` — 从产品灵魂提炼的工程行为规范。

## 设计笔记权威

定稿设计笔记在 `E:\Note\Agent\栖语`（Obsidian 库）：根目录 `栖语产品灵魂.md`（人格基调最高依据）、`栖语目标达成效果.md`（验收判准）；`栖语system prompt/`（提示词定稿，含装配图）、`栖语记忆/`（记忆方案定稿）、`设计闭环/`（tickets T01–T27，Resolution 即定稿答案）。仓库根 `栖语人格宪法.md` 是注入 system prompt 的版本，与笔记版保持同步（仓库版去 Obsidian 链接）。

- 改行为、人格、提示词、记忆前先查笔记定稿；**发现代码与笔记出入时，第一时间向用户报告，不得擅自裁定哪边为准**。
- 不要仅凭笔记声称功能已实现；涉及行为、存储或注入，必须对照仓库实际代码与运行结果。
- 隐私优先：密钥、密码、Cookie、证件号、原始敏感对话不得写入记忆或注入内容。

## Commands

```powershell
& .\scripts\verify-release-baseline.ps1 # 交付前全量门禁（analyze/test/build/bundle/smoke，不得依赖 Node/npm）
& .\scripts\build-windows-bundle.ps1    # 构建 Windows Host + Flutter Web 资源包
& .\scripts\build-android-apk.ps1       # 构建并签名安卓 release APK（缺 android/key.properties 或 keystore 直接失败，不退回调试签名；不入 CI）
cd apps\qiyu_flutter; flutter build apk --debug # 安卓调试包，无需 keystore
```

- `packages/qiyu_behavior_core`：`dart analyze && dart test`
- `packages/qiyu_local_host`：`dart analyze && dart test`
- `apps/qiyu_flutter`：`flutter analyze && flutter test`
- `apps/qiyu_windows_host`：`dart analyze && dart test`（单文件如 `dart test test/host_runner_test.dart`）
- 安卓构建与签名、覆盖升级说明与真机冒烟清单见 `docs/engineering/android-release-build.md`。
- 未配置 LLM 时自动降级本地规则引擎，功能完整可测。

## 回复管线不变量

`/chat` → `POST /api/chat` → `LocalChatService.deliver`：

1. 危机/医疗/法律/金融等 non-normal 输入先在本地分类，**绝不调用 Provider**；Provider 未配置、失败或输出不合格时统一降级本地规则回复。本地规则引擎是行为基准（golden eval 锁定其输出），不是 stub。
2. Prompt 由 `ModelPromptBuilder` 装配：人格宪法 → 硬规则 → 隐藏块协议 → `<daily_state>`/`<long_memory>`/`<persona>`（空块不输出）→ 最近已完成会话 → `<memory_context>`（仅命中时，临时附加不进 system prompt）。装配前读 `memory-controls.md` 过滤冻结/禁提内容，controls 本身不进 prompt。
3. Provider 原始增量先在 Host 完整缓存，候选回复经清洗、违禁词与人格边界校验后才按 `ChatDeliveryEvent` 交付；**页面绝不能看到未经安全校验的原始 token**。只有协议原生终止标记（OpenAI `finish_reason`/`[DONE]`、Anthropic `message_stop`、Ollama `done:true`）才算完成；提前 EOF、超时、原生 error 必须失败降级，不能把半句当完整回复。
4. `requestId` 幂等：刷新、Host 重启、重试复用已有 turn，不重复展示或落盘；`/api/chat/cancel` 取消只保留可重试的用户 turn。
5. 晚安输入正常交给 Provider 结合语境回应，不走本地固定收束；晚安信号在可见回复后触发日终归档与符合间隔的 Dream。记忆召回是模型隐藏动作（`memory_recall`）触发的轮内循环，无规则兜底、不打分。

安全不变量：API 需 Host 会话，修改请求还需同源 Origin + CSRF；读取设置永不返回明文 Key；对外错误只返回允许列表诊断，禁止透出授权头、Cookie、完整敏感输入、第三方错误原文或本机路径。Provider 分支集中在 Provider 层，勿散入 UI 或 Chat Service。

状态：会话写本机 Markdown sessions（单段最多 80 turns，活动窗口 180 天）；Provider 配置（含 Key）在本机 runtime `provider.json`，切换 Provider/URL 时不得沿用另一 credential scope 的旧 Key；浏览器不用 localStorage 作主持久化。

## 行为红线

- 人格基调固定「温暖但不讨好，聪明但不炫耀，安静但不冷淡」；示例话术不得扩展成机械模板。
- 默认少说（回复频谱取最少一侧）；禁客服式话术（`FORBIDDEN_PHRASES`）；调侃/翻旧账只在关系变深后；一致性高于聪明（宁可笨，不可不一致）。
- 改回复逻辑必须同步 `contracts/qiyu_behavior_contracts.json` 与 Core 消费测试，并跑完整门禁；契约不得以实现内常量或单端自测替代。

## 测试与提交

- 流式改动至少覆盖：三种 Provider 正常终止、提前 EOF、超时/原生错误、订阅取消；Host 正常/取消/半途失败/本地回退/晚安/幂等；Flutter 等待态、增量可见节奏、停止按钮、最终只提交一次。Host 靠抽象接口注入 Provider、HTTP、凭据、时钟、原子写入。
- 提交：中文「动词 + 模块 + 内容」标题 + 非空正文（动机、改动、验证），**不得添加 `Co-authored-by` 或任何协作者信息**；只暂存本项目明确文件；重构类提交不得混入无关的 dart format 纯重排；正文不写审查轮次等过程叙事。改变可见行为时 PR 附运行步骤与实际结果。

## Notes

- CI 在 `.github/workflows/ci.yml`：PR 与 main push 跑四包分析/测试/覆盖率门禁（阈值脚本 `scripts/coverage_gate.dart`，水位只升不降：core 88 / host 91 / flutter 91（2026-09-07 基线）、local_host 92（2026-09-09 抽包后实测 92.74））；main push 另跑 `verify-release-baseline.ps1` 全量门禁。浏览器侧用例不计入覆盖率。
- 已建 codebase-memory 知识图谱（项目名 `qiyu`），可用 `search_graph` / `trace_path` / `get_architecture` 探索；结构性大改后重新 `index_repository`。
- `.codebase-memory/` 产物不入库（已 `.gitignore`）：不要暂存、提交、还原或删除该目录任何文件。
