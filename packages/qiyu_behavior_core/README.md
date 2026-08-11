# qiyu_behavior_core

不依赖 Flutter、浏览器、Node、Windows API 或具体存储的纯 Dart 行为核心。公开入口是 `QiyuBehaviorCore.reply(request, state)`，返回 `ChatResult` 或 `ErrorResult`。

行为状态只保留最近 80 条消息作为上下文；完整原始会话由平台侧 `MemoryRepository` 分段保存。

```powershell
dart analyze
dart test
```
