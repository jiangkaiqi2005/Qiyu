# 语音输出方言支持、自定义高级参数与音量控制

## Context & Decision

为了满足睡前陪伴场景下的多样化语言风格（如四川话、粤语、东北话等地方方言）与不同用户的细粒度参数微调诉求，同时保持极简易用的操作体验与向后兼容性：

1. **预设音色库与方言支持**：
   - 豆包 TTS（Volcengine）：预设标准音色（灿灿、御姐、醇厚男声、爽快女声）与 9 种地方方言音色（四川话、粤语、东北话、河南话、陕西话、天津话、山东话、闽南话、台湾普通话）。
   - OpenAI 兼容 TTS：预设 6 种官方音色（alloy, echo, fable, onyx, nova, shimmer）。
   - 保留「输入其他音色 ID」的自定义扩展能力，用户可自由输入未列出的新音色 ID。

2. **自定义高级参数（extraParams）**：
   - 在 `TtsConfig` 中引入 `Map<String, Object?>? extraParams`（兼容 `extra_params` 别名解析与非空校验）。
   - 豆包 TTS 请求体：`extraParams` 智能深合并入 `req_params`。其中 `audio_params` 做深度字典合并（保留 `format: mp3, sample_rate: 24000` 缺省值，支持覆盖或追加新字段），其它顶层字段（如 `additions: {"explicit_dialect": "sichuan"}` 等）安全合并入 `req_params`。
   - OpenAI 兼容 TTS 请求体：`extraParams` 展平合并至顶层 JSON。
   - 前端设置页面提供可折叠的「高级参数」面板与 JSON 语法校验。

3. **客户端音量控制与持久化**：
   - Web 客户端在 Web Audio 播放链路中引入 `GainNode`（`AudioBufferSourceNode -> GainNode -> AudioContext.destination`），实现 0.0 ~ 1.0 的平滑音量控制与实时动态调节。
   - 音量偏好通过浏览器 `localStorage`（键名 `qiyu_voice_output_volume`）在本地持久化，独立于服务端配置。
   - 顶部导航栏小喇叭支持一键静音/恢复与呼出音量调节浮层。

## Consequences

- 丰富了语音输出的陪伴氛围，支持方言朗读及特定业务参数配置。
- 保持配置协议的向后兼容：不传或留空 `extraParams` 时完全按默认行为合成，不破坏存量配置。
- 音量调节纯前端闭环，不产生服务端状态与额外的网络请求。
