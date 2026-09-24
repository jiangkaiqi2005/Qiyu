# 流式交付架构：文字与语音共享同一个事件流

2026-09-23 流式传输三票之票二（spec `.scratch/streaming-delivery/spec.md`，对齐台账决定 4/5/6/7/8/9/10）。票一（ADR 0017）移除输出侧裁决后，终校判决不再存在，「整段缓存校验后交付」的理由随之消失；本 ADR 记录语音侧的流式交付架构：**文字流式推进中每出一个完整句就请求该句合成，PCM 音频块搭车现有聊天 NDJSON 事件流推给前端，Web 与安卓边收边播**。首音 = 首句生成完 + 首个音频块（多句回复比整段合成早一截；单句回复与今天持平——这是已知边界）。

## 取代与继承（对 ADR 0002 的精确划线）

- **作废**：ADR 0002「完整交付并落盘后才整段送去合成、不在增量流上分句合成」的合成时机结论。ADR 0002 顶部已同步标注。
- **逐条继承（本 ADR 的 Consequences 逐项对应）**：音频只在内存即焚（不落盘、不进 sessions/记忆/备份）；合成失败只降级不报错阻断；播放队列按序全播不抢占；点麦克风立即停播清队；停止按钮随时可停；离开聊天页与导航换页一律无条件停播；安卓仅前台播放、恢复不续播；所有栖语 turn 一律朗读。
- **整段路径没有废除**：设置页试听、历史重听、连接测试继续「一段文字 → 一段完整音频」一问一答；PCM 字节在 Host 本地包 WAV 头后走既有播放器（浏览器 decodeAudioData / 安卓 MediaPlayer 零改动）。

## Decisions

- **音频格式统一 PCM**（行业调研 `.scratch/streaming-delivery/research.md`，全一手来源）：没有一家 Provider 在一手文档承诺 mp3 块与帧边界对齐，W3C mp3 字节流规范以「整帧 = init+media segment」建模、半帧 append 未定义，Safari 的 mp3-in-MSE 未找到一手支持证据；PCM 无对齐问题（OpenAI 官方明示 chunk 边界任意、16-bit 样本完整且有序连续即可）。豆包官方明示流式推荐 pcm、禁 wav（流式会重复 header）。各档请求形态：豆包 `audio_params.format=pcm`；千问 `qwen3-tts-flash` + 请求头 `X-DashScope-SSE: enable`（中间块即 base64 音频段）；OpenAI 兼容/自定义 `/audio/speech` + `stream_format=audio` + `response_format=pcm`（chunked 原始字节）。协商采样率随语音块事件上行（PCM 块带 sampleRate、E1 整段块带容器 MIME），**播放端按块上携带的采样率初始化，不猜**——不另存一份配置快照。千问档另做容器归一：DashScope 文档未载明 SSE 中间块的音频格式（唯一线索是完整音频 URL 为 `.wav`），块带 RIFF/WAVE 头就按块遍历定位 fmt /data 子块剥掉容器只送裸样本（不按固定 44 字节——带 LIST 等扩展块时 data 不在固定偏移）、并读回头里的协商采样率沿用给后续裸块；裸 PCM 块不以 RIFF 开头，原样通过（真机冒烟复核项）。
- **TTS 网关双接口**：整段接口 `TtsSynthesisGateway` 保留（整段路径用）；新增 `TtsStreamSynthesisGateway`（一段文字 → 音频块流）。分句不在网关里做——网关只认「一段文字」，句边界是上层的事。
- **分句层放 Host 行为层**（`local_chat_service.dart` + `voice_stream_pipeline.dart`）：与文字流式**共用同一个活前缀**（`CandidateReplyStream` 的增量输出），不二次解析最终文本；按句末标点（。！？!?…与换行；不收 ASCII 句点——「3.14」会被错切）切句，句边界即合成请求边界与播放边界；每句一个合成请求，请求间不抢占（在途并发有上限，块按句序交付）。
- **Host→前端链路不开新连接**：音频块搭车现有聊天 NDJSON 事件流，`ChatDeliveryEvent` 新增 `voiceChunk`（base64 PCM 块 + 交付段序号 + 块序号 + 采样率）与 `voiceError`（一句合成失败）两种事件。刷新/Host 重启的重放路径不进流式分支，天然不重复合成（与今天朗读定位语义一致）。
- **播放端按平台原生流式形态改造**：Web 以 AudioWorklet 环形缓冲替代整段 decodeAudioData（主线程收块 → postMessage → worklet 输出，MDN 标准形态）；安卓以 AudioTrack `MODE_STREAM` 流式写替代整段 MediaDataSource（官方流式形态）。音频仍只在内存。用户手势恢复 AudioContext 的现有处理保留。
- **失败降级（D1）**：一句合成失败即本段语音结束——已交付的块 standing（已排队到的音频照常播完），后续句不合成、不出声，在途请求取消；`voiceError` 信号由界面按「同会话首次失败提示一次，之后静默」落地。文字显示不受影响（文/音解耦）。
- **播放端开流失败**：`startStream` 返回 null 或抛错时不立即 `/speak`，保留该交付段占位等 done；done 后整段回退一次（接受一次 `/speak` 重合成的配额代价）。D1 合成失败（`voiceError`）不整段回退；取消、异常、EOF、恢复或丢弃翻代时释放占位，不伪造回退。
- **非流式档位降级（E1）**：拿不到音频块的档位（自定义档 JSON 字段/逐行 JSON 形态——响应是完整信封，容器由服务定义；以及用户经高级参数把 format/response_format 覆盖成压缩格式）**仍跑分句层，但每句独立整段合成、按序播放**：一句一个完整容器块（不包 WAV 头）走既有整段播放器。首音 = 首句生成完 + 首句合成完（不再等全文）；现有配置全部保留、不淘汰在用型号，也不把压缩字节塞进 PCM 播放器。
- **传输选择器（F3 第一期形态）**：豆包档只开放已实现的 HTTP 流式通道（WS 选项随票三协议接通后再暴露，禁止展示尚不可用的选项）；千问档不加选择器——型号决定 API 家族，界面提示流式型号名；自定义档的响应形态下拉作逃生口，只列已实现形态（裸音频字节且协商到 PCM 走流式分块；逐行 JSON/JSON 字段走 E1 句子级整段播）。全局传输下拉不做（型号与 API 家族是 Provider 硬绑定）。
- **停止信号**：新增 `POST /api/chat/voice-stop`，前端停播时通知 Host 作废该轮在途分句合成，不白烧 Provider 配额；与 `/api/chat/cancel`（轮交付取消）分开。
- **安全约束**：音频块只在内存流转，不落盘、不进 sessions/记忆/备份（契约用例锁定落盘会话无音频痕迹）；HTTP 分块出网与既有 TTS 出网同律（`ensureTtsOutboundAllowed`：仅 http/https、拒绝 localhost/环回/私有/保留地址）。
- **ADR 0015 修订记录**：该 ADR 把 `qwen-audio-3.1-tts-next` 记为「WebSocket 流式合成型号」，官方现标注 **Non-streaming**（AudioGen 统一音频生成模型，无 WS 实时通道），该记录已过时且有偏，不可用于流式场景；千问档的流式型号是 `qwen3-tts-flash`（HTTP SSE）。ADR 0015 的失败分类机制（`modelInterfaceMismatch`）本身不受影响。

## Consequences

- 多句回复的首音从「全文生成 + 全文合成」提前到「首句生成 + 首块」；文字流式期间音频先到口先出声，句序即播放序。
- 文字与语音共享一条事件流与一套取消/停止语义：少一套连接、少一半竞态；块丢失或播不出来都不影响文字显示。
- 「一句失败即收声」让故障代价从「整段」降到「一句」：已播句子 standing，提示不刷屏。
- 整段路径零改动（试听/重听/连接测试），存量配置不淘汰；唯一的行为变化是多句回复的朗读时机与分段粒度。
- 遗留：WS 连续喂文本（豆包双向 `TaskRequest`、千问 Realtime `input_text_buffer.append`）归票三；数值目标（首音约 2–3 秒级）归真机冒烟，不进门禁。
