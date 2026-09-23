# 语音流式第二期：WS 连续喂文本

2026-09-23 流式传输三票之票三（spec `.scratch/streaming-delivery/spec.md`，对齐台账决定 11）。票二（ADR 0018）把首音从「整段生成 + 整段合成」提前到「首句生成 + 首块」；本 ADR 记录再提前一截的形态：**豆包双向 WebSocket（逐段发文本）与千问 Qwen-TTS Realtime WebSocket（流式追加文本）——模型前几个字一出，文本就持续喂给 Provider，PCM 持续回来持续播**。首音 = 前几个字生成完 + 首个音频块（多句回复不再等第一个标点）。票二建立的播放与降级语义（按序不抢占、一句失败即止、已播 standing、停止信号停合成、离页停播）在本供给方式下完全不变。

## 接入边界

- **服务地址始终是 HTTP 端点，WS 地址由 Host 派生**：用户在设置页填的 baseUrl 保持票二语义（豆包填 HTTP 单向端点、千问填 DashScope HTTP 端点）。传输走 WS 时 Host 按协议派生：豆包 `wss://<host>[:port]/api/v3/tts/bidirection`；千问 `wss://<host>[:port]/api-ws/v1/realtime?model=<model>`（host/port 保留，其余路径与 query 按协议写死；http→ws、https→wss）。这样地址栏不存在「两种含义」。派生地址单独过 `speechOutboundRefusalReason`（与 HTTP 出网同律，复用同一判定，不另写一套），配置校验本身仍只允许 http/https。
- **传输选择器只归豆包档**：`TtsConfig.transport`（wire 名 `http_chunk` 缺省 / `ws_bidirection`），仅豆包档（volc_tts）在设置页露出下拉与落盘；千问档继续型号驱动（型号名以 `-realtime` 结尾走 WS，官方仅列 `qwen3-tts-flash-realtime` 与 `qwen3-tts-instruct-flash-realtime`）；自定义档不动。禁止展示尚不可用的选项——两个协议都接通后才露出。
- **持续喂文本接缝**：`tts_gateway.dart` 在 `VoiceStreamSynthesizer`（票二分句）旁新增 `VoiceStreamSession`（appendText 收持续增量、close 收尾、音频块流、cancel 作废）与 `VoiceStreamSessionOpener`/`VoiceStreamSessionGateway` 两个分派面，由 `TtsSettingsService` 按配置实现（档位不支持 WS 时不开会话，一个字节的网络请求都不发）。`VoiceStreamPipeline` 增加会话模式：增量原文直接进 WS（不按标点切句、不受在途上限约束），块按到达序交付；HTTP 档维持票二分句模式。管线五个驱动点（`addText`/`close`/`takeChunk`/`whenProgress`/`cancel`）形状不变，模式选择在管线内部。
- **迟到挂载（首字绝不被握手 gate）**：`Provider` 分支里 `prepareChatRequest()` 返回非空（Provider 确实可用）之后才启动开会话；管线先以「会话在途」态就绪并登记（stopVoice 在握手窗口也能定位到），会话 Future 由交付主循环挂进 `Future.any` 等待集——**首个可见 delta 不等会话落定**：模型增量、取消、语音块推进与会话落定同台竞争，会话胜出才 `attachSession` 挂载。WS 端点不可达时文字照常秒级起（最坏情况首句不出声，文字永远优先）；落定前喂进的文本先缓冲、挂载时整段补喂（不丢内容，也不在握手窗口抢先起分句请求）。模型流已收尾时才落定：有界宽限（2s，覆盖配置读取与正常握手）内落定即挂载（尾块照常播完），超出的作废会话且**不发 voiceError**（语音没启动过，不是失败）；开会话失败仍走既定 D1（failedSession + 一次 voiceError）。`_activeVoiceStreams` 的登记/注销收敛在单一 helper（`_abandonVoiceStream`）：取消赶在落定前、模型流没开到、主循环提前 break 三条路径都 cancel + identical 校验移除，落定失败同样清表——不留死管线、stopVoice 不对死管线伪成功。
- **建连与握手都有界**：`connector.connect(...)` 与会话等待都包 [timeout]（可注入，与豆包 ASR 网关同律）；取消赶在会话落定前时丢弃会话、文字走取消语义——迭代器的取消交给主循环（StreamIterator 在首次 moveNext 前没有订阅可取消，提前 cancel 会漏掉底层模型流订阅，曾导致 `liveController.close()` 永久挂起）。
- **一次聊天轮次一条 WS 连接**：连接在收尾/取消时断开。两道计时器都在握手完成后（`onHandshakeComplete`）才武装：空闲计时器每帧重置（会话中途 60s 无帧按「响应超时」失败）；绝对截止计时器 = 空闲预算 ×10（10 分钟，自握手完成起算）——服务端持续涓流却永不停发终态事件时，该轮 done 不被无限期拖住（到点按会话失败走 D1：文字不受影响、轮次正常收尾）。握手阶段两道计时器都不武装，握手等待自带预算（否则 `ConnectionStarted` 到达就会武装空闲计时器，`SessionStarted` 永不来时误报「响应超时」而非「连接超时」）。

## 协议实现与推断假设

帧构造与解析集中在 `tts_ws_gateways.dart` 一套函数；客户端/服务端两个方向都有单测锁定位域。官方精确位域只放在依赖 zip（`TTS Websocket Bidirection protocols.zip`）里，页面正文与 research.md 均无，以下为实现假设，待真机验证：

- **豆包双向帧族（推断）**：4 字节头（byte0 = version 1 + 头长 1；byte1 高 4 位消息类型、低 4 位 flags；byte2 高 4 位序列化、低 4 位压缩；byte3 保留）+ 按 flags 跳 4 字节序列号/event + 大端 u32 载荷长度 + 载荷。消息类型照单向 V3 帧家族：客户端请求 0001、服务端全量响应 1001（JSON 载荷）、服务端仅音频 1011（裸 PCM 字节）、错误 1111（i32 错误码 + u32 消息长度 + UTF-8 消息）。音频帧与 JSON/错误帧同一口径：长度越界按解析失败拒（静默截断会让半截 PCM 播成噪音）。
- **客户端事件以 JSON 载荷的 `EventType` 字符串标识**（官方文档字段形态：「字段固定为 StartConnection」），帧头不带 event 字段。若真机要求头内 event 号，只需改帧构造一处。`StartSession` 带 `session_id`（客户端 UUID）与 `req_params`（`speaker`/`audio_params`/`additions`，section_id 在发送时并入）；`TaskRequest` 带 `session_id` 与逐段 `text`；收尾 `FinishSession`→`FinishConnection`，取消 `CancelSession`。`req_params.model` 不送（模型经 `X-Api-Resource-Id` 头传递，与 HTTP 路径同口径）。
- **服务端事件名优先取载荷里的 `EventType` 字符串**，缺失时回退推断的 header event 号映射（锚点 2/52/151/152/153/350-352 照单向 V3 与 HTTP SSE 两个已公开家族；50/51/154/353 为纯推断）。`MsgType` 两值按帧类型分派（1001=FullServerResponse、1011=AudioOnlyServer），音频即 1011 帧的裸字节（官方示例把 `msg.payload` 原样追加写文件）。
- **正常收尾判据**：`SessionFinished` 即音频到齐（事件序 TTSResponse→TTSSentenceEnd→SessionFinished），块流就此结束并发 `FinishConnection`；连接在没有终态事件的情况下关闭按音频不完整失败（D1，与票二「没等到结束码断流即失败」同构）。正常结束后不再发取消帧（连接已断，发出去只是诊断噪音）。
- **千问 Realtime 为 JSON 文本帧**（`provider_web_socket.dart` 新增文本帧视图与 `sendText`，二进制 `messages` 原样不动——豆包 ASR 行为不变）：生命周期 `session.created` → 客户端 `session.update`（`mode: server_commit`、`response_format: pcm`、`sample_rate: 24000`、`voice`、`language_type: Chinese`）→ `input_text_buffer.append`（`text` 逐段）→ `session.finish` → `session.finished`。音频在 `response.audio.delta` 的 `delta`（base64 PCM）。错误事件名官方未给全表，按 `error` 与 `*.failed` 识别并按允许列表映射（鉴权/限流/服务拒绝）。**千问 realtime 档不吃 extraParams**（音色走 session.update 的 voice 字段，协议没有 instructions 类控制字段的文档入口）——用户在高级参数里给该档写的字段不会生效，写不写都不报错。
- **音色/语速/方言换算与 HTTP 路径同一套函数**（`VolcTtsGateway.detectDialect`/`resolveAdditions`，speech_rate [-50,100]），不另抄。

## section_id 语义

每个聊天会话一个 `section_id`，网关实例内进程保持（`Map<chatSessionId, uuid>`），跨轮次合成上下文在服务端延续；Host 重启即新值——服务端上下文本就有超时，重启后换个新标识比拿一个必然失效的旧标识更诚实。ADR 记录该取舍。一次聊天轮次一条连接（连接不跨轮复用）：section_id 的跨轮上下文由服务端按标识保持，连接生命周期随轮次，少一套空闲连接管理。

## 与票二的传输分工

- **票二（ADR 0018）不变**：HTTP 分块/SSE 逐句合成、音频块搭车聊天事件流、播放端 AudioWorklet/AudioTrack、D1/E1 降级、停止信号端点、整段路径一问一答。
- **票三分工**：WS 只承载「连续供给」这一种新供给方式；拿不到 WS 的档位（OpenAI 兼容、自定义、豆包 http_chunk、千问非 realtime 型号）原样走票二分句。
- **E1 守卫同律**：用户经高级参数把豆包 `audio_params.format` 覆盖成压缩格式时，WS 会话不开（音频帧一律按裸 PCM 交付，压缩字节会播成噪音）——分句层自然回落票二分句 + 句子级整段朗读，与 HTTP 流式路径的 `_isStreamablePcm` 闸门同一判定（`VolcTtsGateway.effectiveAudioParams`/`isStreamablePcm` 两条路共用）。
- **整段路径随传输走（裁定 A）**：豆包档传输选了 `ws_bidirection` 时，试听、历史重听与连接测试都开一个一次性 WS 会话收完整 PCM，Host 本地包 WAV 头后走既有整段播放器——连接测试由此覆盖用户实际选的传输（选了 WS 却只测 HTTP 会是假绿：用户表现为「选了 WebSocket 双向 → 没声音、无提示、连接测试还绿」）。压缩格式覆盖的配置由网关内部回落 HTTP 单向端点（E1 不变）；千问 realtime 型号本就没有 HTTP 整段接口，同形态。
- **会话开失败按 D1 同口径提示一次（裁定 A）**：握手/建连失败建一个「已失败」管线——交付循环据此发一次 voiceError（同会话首次一次的既有口径），已播留着、文字完整交付，不回落分句模式（避免同一条链路上再烧一次配额）。用户显式选了 WS 传输时，「没声音且无提示」比提示一次更难排查。
- **Provider WebSocket 接缝的扩展方式**：选「增加文本帧流 + sendText」而非「把 messages 升级为带类型结构」——后者要改豆包 ASR 网关的全部帧处理与在飞二进制语义，前者对现有 ASR 行为零接触（两个视图同源，dart:io 单订阅流转广播流后派生）。

## 已知边界

- **共享 SSRF 判定的既有缺口**：`speechOutboundRefusalReason` 按字面量判定内网地址：带 zone-id 的链路本地 IPv6（`fe80::1%eth0`）与 NAT64（`64:ff9b::`）按放行处理。这是 HTTP 出网同款的既有边界（非本票回归），本次不改共享函数；如需收紧，两侧一起收。
- **空闲预算与整请求超时共用 60s**：慢思考模型的句间停顿若超过 60s，会话会被空闲计时器误杀（文字不受影响，该段语音提前结束）。官方是否提供心跳帧未载明；若真机证实有心跳且间隔大于 60s，把读循环的空闲预算调宽即可。
- **绝对截止 10 分钟**：远超正常轮次（栖语「默认少说」），但服务端持续涓流不发终态事件时，到点仍会按 D1 结束该段语音。

## Consequences

- 多句回复首音从「首句生成完」提前到「前几个字生成完」；单句回复与票二持平。契约 `voiceStreamingCases` 补两条用例锁新行为：连续供给下首音早于首句生成完（第一个语音块早于第一个带句末标点的 delta 事件）、会话失败即本段语音结束（已播留着、提示一次、文字完整落盘）。
- 文字与语音仍共享一条事件流与一套取消/停止语义；WS 会话失败走 D1 同一出口（voiceError，同会话首次一次）。
- 新增出网路径全部过同一 SSRF 判定；音频块仍只在内存，不落盘、不进 sessions/记忆/备份。
- 修复票二交付循环的一个缺陷（本票首音时序门禁的活流测试暴露）：语音块先到而 `iterator.moveNext()` 在途时，循环回到顶部会再次调用 `moveNext`，StreamIterator 抛 `StateError`，整轮回复被误判成半句。修为跨轮复用在途的 moveNext，只在它自己胜出时清空——回归用例「语音块在模型流在途时到达」用延时发块的脚本会话 + 活流模型流锁定（旧形状下该用例红）。
- 遗留（待真机冒烟，主 agent 另行安排）：豆包双向帧位域与客户端事件头的精确形态、服务端 event 号映射、千问错误事件名全表；两种 WS 的实连首音体感与多轮上下文连续性；豆包 PCM 位深（官方只给公式）。
