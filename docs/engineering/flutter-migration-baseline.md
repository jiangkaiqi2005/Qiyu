# Dart/Flutter 迁移基线

本基线对应 `.scratch/qiyu-local-flutter-windows/issues/01-establish-dart-flutter-migration-baseline.md`。现有 JavaScript/Node 产品继续运行，新目录只建立后续迁移所需的公共边界。

## 工程边界

- `packages/qiyu_behavior_core/`：纯 Dart 行为核心。不得导入 Flutter、浏览器 API、Node、Windows API 或具体存储实现。
- `apps/qiyu_flutter/`：Flutter Web 外壳，采用 View、ViewModel、`provider` 和 `go_router`；当前只验证行为核心接线。
- `apps/qiyu_windows_host/`：可编译为 Windows exe 的 Dart 宿主骨架；当前只执行平台与行为核心启动前检查，不监听端口。
- `contracts/qiyu_behavior_contracts.json`：JS 与 Dart 共用的语言无关 fixtures。

本票没有加入数据库、云服务、账号系统、远程静态托管、移动端工程、Provider 网络访问或本机 HTTP 服务。

## 稳定契约

契约当前为 `schemaVersion: 1`：

- `ChatRequest`：请求版本、`requestId` 和用户文本。
- `StateSnapshot`：用户标识、关系阶段、可观察对话轮次和情绪快照。
- `ChatResult`：可见消息、下一状态、回复来源、降级原因、安全分类和行为模式。
- `ErrorResult`：稳定错误码、可展示消息和是否可重试。

最高测试接缝是 `QiyuBehaviorCore.reply(request, state, candidateReply: ...)`。`candidateReply` 是 runtime 已取得的候选模型文本，不属于浏览器请求；行为核心只负责安全前置、候选输出检查和确定性结果。后续切片必须通过这些契约扩展，不直接把 Flutter 或宿主接到内部函数。

共享 fixtures 固定四个迁移起点：普通本地回复、晚安收束、危机输入绕过 Provider、模型命中违禁话术后本地降级。JS 测试使用现有 `/api/chat` 管线作为 oracle，Dart 测试读取同一文件。

## 直接依赖选择

版本由 2026-08-09 的 Flutter 3.44.8 / Dart 3.12.2 解析并锁定在应用的 `pubspec.lock` 中。

| 依赖 | 当前约束 | 维护与许可证 | 使用理由 |
| --- | --- | --- | --- |
| `go_router` | `^17.4.0` | Flutter 团队维护，BSD-3-Clause，支持 Flutter Web/Windows | Spec 已选定的统一 URL 路由；不自研浏览器路由同步。 |
| `provider` | `^6.1.5+1` | 长期活跃，MIT，支持 Flutter Web/Windows | Spec 已选定的轻量依赖注入与 `ChangeNotifier` 接线；不同时引入 Riverpod。 |
| `test` | `^1.25.6`（核心）、`^1.31.2`（宿主） | Dart 团队维护，BSD-3-Clause | 公开契约与宿主检查的标准测试工具，生产产物不包含。 |
| `lints` | `^6.0.0` | Dart 团队维护，BSD-3-Clause | 统一静态检查，生产产物不包含。 |
| `flutter_test` / `flutter_lints` | Flutter SDK / `^6.0.0` | Flutter 团队维护，BSD-3-Clause | Widget 测试与 Flutter 官方 lint，生产产物不包含。 |

`qiyu_behavior_core` 是仓库内 path dependency，不是第三方包。其生产依赖为空。

## 验证

在 Windows PowerShell 中运行：

```powershell
npm run verify:migration-baseline
```

脚本依次执行 Dart core analyze/test、Flutter analyze/test/Web build、Windows host analyze/test/exe build/启动前检查，以及现有 `npm test` 和 `npm run eval`。生成物只进入各工程已忽略的 `.dart_tool/` 与 `build/`。
