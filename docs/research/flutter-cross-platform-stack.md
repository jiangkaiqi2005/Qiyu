# 调研：栖语纯本地 Flutter 跨端技术路线

- **日期**：2026-08-09
- **目标平台**：电脑本机 Web 页面、iOS、Android
- **硬约束**：无远程托管、无栖语云端业务服务器；电脑先运行本机程序，再通过 `127.0.0.1` 打开 Web 页面；记忆采用 Markdown 文件体系，不引入数据库
- **来源原则**：Flutter/Dart、浏览器、Apple、Android、模型服务商及依赖项目的一手文档；版本在实现时由 `pubspec.lock` 固定

## 结论

纯 Dart/Flutter 的电脑本机 Web、iOS、Android 客户端可行。必须撤销此前“远程静态托管”和“Web 只做浏览器沙盒客户端”的前提：电脑端由一个本机 Dart 程序持有配置、Key、Markdown 记忆和行为核心，并只在回环地址提供 Flutter Web 页面。`src/qiyu/*.js` 的行为核心、`src/server` 中仍属产品行为的安全门和模型适配必须迁移为纯 Dart；Node 只能在迁移期间作为对拍基准，不进入最终运行架构。

推荐路线：

1. Flutter 共用 UI、领域模型、行为核心、Markdown codec、模型网关与黄金行为基准。
2. Android/iOS 在 App 沙盒中维护真实 `.md` 目录；电脑端由本机 Dart 程序维护用户可备份的真实 `.md` 目录。浏览器只负责呈现，不持有记忆事实源。
3. Provider 与用户自己的 API Key 持续保存在本机：移动端进 Keychain/Keystore；电脑端由本机程序使用操作系统安全存储或受限本地配置持有，浏览器页面不直接接触明文 Key。
4. 模型请求由移动 App 或电脑本机 Dart 程序直连 OpenAI-compatible、Anthropic 或 Ollama；电脑 Web 页面只调用 `127.0.0.1`，因此不受模型端点浏览器 CORS 限制。
5. 日终归档与 Dream 是两个不同周期：日终归档按跨日/晚安/启动补扫执行；Dream 只在晚安后检查且距上次至少 7 天时运行，漏跑才在下次启动或空闲补跑。

Flutter 官方将 PWA、SPA 和移动应用的浏览器交付列为 Flutter Web 的合适场景，栖语属于应用型 SPA。[Flutter Web 支持](https://docs.flutter.dev/platform-integration/web)

## 1. 最终本地架构

```text
电脑：本机 Dart Launcher
  -> LocalAppHost (127.0.0.1 only)
       -> Flutter Web 静态页面
       -> QiyuBehaviorCore / MemoryRepository / ModelGateway

iOS / Android：Flutter App
  -> 同一套 QiyuBehaviorCore / MemoryRepository / ModelGateway（进程内调用）
```

仍采用 Flutter 官方推荐的 View/ViewModel、Repository/Service、单向数据流；`provider` 做依赖注入，`ChangeNotifier`/`Listenable` 驱动当前体量的 UI，`go_router` 负责 Web URL、浏览器前进后退和移动深链。[官方架构建议](https://docs.flutter.dev/app-architecture/recommendations)；[`provider`](https://pub.dev/packages/provider)；[`go_router`](https://pub.dev/packages/go_router)

推荐的最小依赖：

| 关注点 | 选择 | 说明 |
| --- | --- | --- |
| 状态/DI | `provider` + `ChangeNotifier` | 不与 Riverpod 并存；复杂度真实出现后才换 |
| 路由 | `go_router` | Flutter 团队维护、支持三端与 URL |
| HTTP | `package:http`，注入 `http.Client` | Dart 团队维护、三端共用、方便 fake client 测试。[`http`](https://pub.dev/packages/http) |
| 本地 Web 宿主 | `shelf` + `shelf_static` | Dart 团队维护的组合；只绑定 `127.0.0.1`，提供 Flutter Web 静态资源和本机接口。[`shelf`](https://pub.dev/packages/shelf)；[`shelf_static`](https://pub.dev/packages/shelf_static) |
| 本地文件根目录 | `path_provider` + `dart:io` | Android/iOS App 沙盒及电脑本机程序内的真实目录和文件。[`path_provider`](https://pub.dev/packages/path_provider) |
| 用户导入导出 | `file_selector` | Flutter 团队维护；移动端交给系统选择器，电脑端由本机程序生成/导入 Markdown 备份包。[`file_selector`](https://pub.dev/packages/file_selector) |
| 移动端 Key | `flutter_secure_storage` | iOS Keychain、Android 加密存储；Web 实现不等价，见第 4 节。[`flutter_secure_storage`](https://pub.dev/packages/flutter_secure_storage) |

## 2. Dart 行为核心必须迁移

纯本地约束下，以下职责全部进入纯 Dart、无 Flutter Widget 依赖的 `QiyuBehaviorCore`：

- `safety.js`：危机/医疗等分类必须在任何模型请求之前执行。
- `persona.js`、`reply-policy.js`、`reply-delivery.js`：人格、违禁词、回复清洗与本地规则回复。
- `relationship.js`、`state.js`、`memory-extraction.js`、`prompt-context.js`：关系阶段、状态迁移、记忆抽取与 prompt 上下文。
- `system-prompt.js`：把 `栖语产品灵魂.md` 作为 Flutter asset 打包并在本地拼装。
- `llm-client.js`：改成三个 Dart `ModelGateway` 实现；Key、URL、model 只由本地设置提供。
- Dream/日终整理：读取 Markdown 快照，写 draft，再原子采用，不能原地边读边覆写。

迁移不是重新设计。先把 `eval/golden-cases.json` 与关键 API 请求/响应整理成语言无关 fixtures；同一 fixtures 同时跑 JS 和 Dart，逐条相等后才移除运行时 Node。现有 `npm test`/`npm run eval` 在迁移期是 oracle，最终由 `dart test`/`flutter test` 接管。Flutter 官方建议大量 unit/widget test，仅为关键路径保留少量 integration test。[Flutter 测试总览](https://docs.flutter.dev/testing/overview)

建议的最高测试接缝依次为：

1. `QiyuBehaviorCore.reply(input, state) -> result` 黄金行为对拍。
2. `MemoryRepository` 合约测试：同一套测试分别跑移动端临时目录与电脑本机目录 adapter。
3. `ModelGateway` 通过 fake `http.Client` 验证请求格式、流/非流响应、错误脱敏与降级。
4. 首启、发送、重启恢复、删除/导出、日终补跑的三端 integration tests。

## 3. Markdown 存储：移动 App 与电脑本机程序

### Android / iOS

使用 `path_provider` 获取 App Documents/Support 目录，再用 `dart:io` 维护真实 Markdown 层级。它是真实文件，但处于系统 App 沙盒，不等于用户能在“文件”应用里随意浏览的公共目录。导入通过系统文件选择器；导出应生成快照，再交给系统分享/保存界面。

每次 turn、记忆变更和任务 checkpoint 都应立即写穿，写入流程采用 `target.tmp -> flush -> rename`，不能等“退出时保存”。Android 官方明确说明进程可能被系统直接杀死，`onDestroy()` 不保证调用。[Android 进程生命周期](https://developer.android.com/guide/components/activities/process-lifecycle)

### 电脑本机 Web

浏览器页面不承担文件系统职责。本机 Dart 程序使用 `dart:io` 维护与移动端同构的真实 Markdown 目录，再通过回环接口向 Flutter Web 页面提供所需视图和动作。这样 Provider、Key、sessions、episodes、PersonaTree、Dream 草稿和恢复目录都能持续保留；关闭标签页不会清除数据，下次启动本机程序并打开页面即可继续。

本机接口必须只绑定 `127.0.0.1`，不得监听局域网地址；每次启动生成短期会话令牌并校验 Origin，避免其他网页借浏览器向本机接口发请求。浏览器不得取得完整文件路径或未打码 Key。电脑端仍提供“导出全部 Markdown”与“从备份恢复”。

## 4. 本地 API Key 与直连模型

### 安全结论

- iOS/Android：`flutter_secure_storage` 可利用 Keychain/Android 安全存储保护静态保存的 Key；Key 在发请求时仍必须进入应用内存，越狱/root、恶意设备或调试环境不能被完全防住。
- 电脑本机 Web：Key 不写入浏览器存储；由本机 Dart 程序持久保存并代发模型请求。优先使用操作系统安全存储；若某桌面平台缺少成熟统一实现，再使用权限受限、明确告知风险的本地配置文件，而不是退回浏览器 localStorage。
- OpenAI 官方明确建议不要在浏览器或移动 App 中部署 API Key，并推荐经后端转发；纯本地硬约束意味着必须接受偏离该最佳实践的风险，而且只能使用**用户自己的 Key**，绝不能内置开发者共享 Key。[OpenAI API Key 安全建议](https://help.openai.com/en/articles/5112595-best-practices-for-api-key-safety)

推荐交互：移动端与电脑端都允许持久保存 Provider 配置和 Key；Web 设置页显示掩码值，只通过本机接口执行保存、忘记和连接测试。日志、异常、导出和 Markdown 永不包含 Key。

### CORS 与服务商可行性

CORS 是浏览器实施的限制；本架构由移动 App 或电脑本机 Dart 程序发起模型 HTTP 请求，因此不把 Provider CORS 当兼容性门槛。电脑浏览器只请求同一回环宿主。

| 目标 | Android/iOS | 电脑本机 Web |
| --- | --- | --- |
| OpenAI 官方 API | 技术上可直连，但只能使用用户自己的 Key | 由本机 Dart 程序直连；Key 不进入页面 |
| Anthropic API | 技术上可直连，同样使用用户自己的 Key | 由本机 Dart 程序直连；Key 不进入页面 |
| OpenAI-compatible 第三方 | 逐个验证鉴权和响应格式 | 同左，不受浏览器 CORS 限制 |
| 本机 Ollama | 手机上 `localhost` 指手机自身，需填写同一局域网电脑地址 | 本机程序可直接访问本机 Ollama。[Ollama FAQ](https://docs.ollama.com/faq) |

产品仍不能承诺任意 OpenAI-compatible URL 的响应格式都兼容。设置页应把连接测试结果区分为 DNS/TLS、鉴权、模型不存在和响应格式不兼容。

## 5. 无远程托管的电脑本机 Web

电脑用户先启动打包后的本机程序。程序用 Dart 团队维护的 `shelf`/`shelf_static` 只在回环地址提供编译好的 Flutter Web 资源和本机接口，然后自动打开默认浏览器。整个过程不访问远程静态站点，也没有栖语云端服务；退出本机程序后页面失去本地能力，但所有配置和数据继续保存在电脑上。[`shelf_static`](https://pub.dev/packages/shelf_static)

这仍然是本机 HTTP 服务，但不是远程服务器。它比 `file://` 稳定，也让浏览器 UI 能通过受控接口使用本机文件、持久 Key、模型连接和 Dream。Flutter 官方同时支持 Windows、macOS、Linux 桌面构建；Spec 仍需确定首版电脑平台范围。[Flutter 桌面支持](https://docs.flutter.dev/platform-integration/desktop)

## 6. Dream、日终任务与退出边界

任何平台都不能把“用户退出应用”当可靠事件：移动系统可直接杀进程，本机进程也可能异常结束。因此：

- 每轮立即落盘原始证据与 `pending-dream.json`/Markdown frontmatter checkpoint。
- 日终归档用“跨日、晚安、启动补扫”触发；Dream 只在晚安后且距上次 Dream 至少 7 天时触发。
- App 启动/恢复时先扫描 pending task，满足条件就补跑；写 `memory.draft.md`，校验成功后原子替换。
- Dream 调模型时允许取消和续跑；没有网络、Key 或 Ollama 不可达就保持 pending，不破坏当前记忆。

平台限制：

- 电脑端只要本机程序仍在运行就可继续整理；若程序退出，下一次启动按 checkpoint 补跑。
- Android WorkManager 是官方推荐的持久后台工作 API，但执行时间由系统和约束决定，并有运行时间上限；可用成熟的 Flutter Community [`workmanager`](https://pub.dev/packages/workmanager) 作为机会性加速。[Android WorkManager](https://developer.android.com/reference/androidx/work/WorkManager.html)
- iOS 的 `BGProcessingTask`/`BGAppRefreshTask` 由系统决定何时启动；短 refresh 只有有限运行时间，不能承诺固定午夜执行。[Apple Background Tasks](https://developer.apple.com/documentation/BackgroundTasks/choosing-background-strategies-for-your-app)

首版推荐**不引入 `workmanager`**：先把前台补跑、checkpoint、幂等和性能做好。日终归档可以补跑；Dream 的最小间隔始终是 7 天，补跑不得把它变成每日任务。

## 7. 推荐实施顺序

1. 固化 JS/Dart 共用 fixtures 与黄金行为，不改行为语义。
2. 逐模块移植纯 Dart `QiyuBehaviorCore`，完成相等性对拍。
3. 建立 `MemoryRepository` 合约，移动端和电脑本机程序都使用真实 Markdown，并实现备份导入/导出。
4. 实现 `ModelGateway` 三适配器及 fake HTTP tests；在移动端和电脑本机宿主逐服务商验证鉴权与响应格式。
5. 电脑端用 `shelf`/`shelf_static` 打包本机宿主并自动打开 Flutter Web；移动端继续进程内调用共享核心。
6. 实现日终前台补跑；后台调度延后到真实需求出现。
7. 电脑安装包 + iOS TestFlight + Play 内测，验证异常退出、Key 持久化、备份恢复和跨日/Dream 补跑。

## 8. Spec 前仍需用户决定

1. **电脑平台范围**：首版只做 Windows 本机宿主，还是同时做 Windows、macOS、Linux。
2. **伪 Agent 边界**：它是否指“LLM 生成隐藏动作，由本地运行时执行记忆检索、整理、Dream 和回复编排，但不具备通用自主任务循环、外部工具生态或无人值守主动行动”。
3. **旧原型数据**：是否需要从现有浏览器 localStorage 一次性迁移；默认不迁移。
