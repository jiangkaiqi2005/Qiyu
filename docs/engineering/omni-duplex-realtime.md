# Omni 双工实时通话：已实装行为与限制

依据 [ADR 0026](../adr/0026-omni-unified-dialogue-and-immediate-audio.md) 与实施 spec（`.scratch/voice-omni-duplex/spec.md`，本机资产）落地的 Omni 双工实时通话。本页记录**已实装的工程行为与限制**；协议事实来源于 T01 原型在真实端点的实测（2026-10-02，`.scratch/voice-omni-duplex/prototype-results.md`），行为以仓库代码为准。一期手动通话与二期启动方式均已实现工程链路，三种形态的真实录放与完整体验尚未验收，不能据此宣称可发布。

## 架构与代码位置

| 层 | 位置 | 职责 |
| --- | --- | --- |
| 实时会话网关 | `packages/qiyu_local_host/lib/src/qwen_omni_realtime_gateway.dart` | DashScope Realtime WebSocket 建连、session.update、事件归一、回复看门狗 |
| 通话服务 | `packages/qiyu_local_host/lib/src/omni_call_service.dart` | 完整人格提示词、晚一拍回忆、隐藏动作提交、Markdown 落盘、有界重连 |
| 传输路由 | `packages/qiyu_local_host/lib/src/omni_call_routes.dart` | `GET api/omni/call` WebSocket，经 Host 会话/Origin 鉴权 |
| 前端控制器 | `apps/qiyu_flutter/lib/features/chat/omni_call_controller.dart` | 通话 WebSocket、上行采集、下行播放、打断与死轮隔离 |
| 启动偏好与设置 | `packages/qiyu_local_host/lib/src/provider_settings_service.dart`、`apps/qiyu_flutter/lib/features/settings/omni_startup_settings.dart` | 本机配置保存、首次麦克风授权、只对后续启动生效 |
| 同次使用状态 | `apps/qiyu_flutter/lib/features/chat/omni_call_usage_state.dart`、`omni_call_usage_state_web.dart` | 主动挂断与启动失败抑制；网页刷新保留、关页重开恢复 |
| Web 采集 | `apps/qiyu_flutter/lib/features/chat/voice_capture_platform_web.dart` | AudioWorklet 连续 PCM16/16kHz，浏览器标准回声消除 |
| Android 桥 | `apps/qiyu_flutter/android/app/src/main/kotlin/dev/qiyu/app/OmniCallBridge.kt` | 同时录放、VOICE_COMMUNICATION 音源、焦点管理、microphone 前台服务 |

模型档位：设置目录新增「Omni 实时对话」（`ProviderKind.qwenOmniRealtime`），独立于 Chat Completions 协议；选中后聊天轮与记忆维护都走实时会话，不悄悄沿用旧聊天模型。凭据只在 Host 内解析出网，前端与 Android 均拿不到 Provider Key。

## 已核实的协议事实（T01 实测，代码对齐）

- 端点 `wss://dashscope.aliyuncs.com/api-ws/v1/realtime`，型号以 `model` query 参数携带；Key 经 `Authorization: Bearer` 头出网（`qwen_omni_realtime_gateway.dart:275`）。
- **默认音色必须显式配置**：服务端回显的默认音色 Chelsie 在生成时刻被拒（400），Cherry/Ethan/Nyla/Nova 同拒；实测 Tina/Serena 可生成。会话配置显式携带 Tina（`qwenOmniRealtimeDefaultVoice`，`qwen_omni_realtime_gateway.dart:21`），最终默认音色属产品裁定，未定案。
- `turn_detection` 是会话配置参数，初值 `server_vad`（官方默认 threshold 0.5）。`semantic_vad` 裸配实测 18% 整轮漏检（含 speech_started 都不触发），不作初值；选型与参数调优待裁定（`qwen_omni_realtime_gateway.dart:41`）。
- **回复完成判定只认 `response.done` 的 `status`**（completed/cancelled/failed/incomplete）；`response.audio.done` 在取消时也会到达，不当作完成。原生取消没有独立事件，表现为 `status=cancelled` 的 `response.done`。
- `session.finish` 客户端事件不被本型号支持（返回 error 且连接保持），会话收束只走客户端关闭帧。
- 工具回填必须尽快于调用之后、用户新轮之前；回填前插入用户新轮，服务端收下结果却静默忽略续答请求。实现以用户活动计数判抢占，被抢占的旧检索只回填、不续答、不唤醒旧语音。
- 错误面三层全覆盖：`error` 事件（按允许列表指纹分类，第三方原文不透出）、无帧断开、建连后模型静默降级（回复空闲看门狗 + 请求级悬空看门狗，连续两轮超时按降级触发有界重连）。
- 未知事件类型与未核实协议（`conversation.item.truncate`、`input_text_buffer.*` 等）一律不发不判。

## 已实装行为

- **通话生命周期**：聊天页电话入口手动开始；同一时刻至多一通，重复开始顶替旧通。明确结束立即停麦、停播清队列、关连接、撤销重连等待；结束后的上行帧一律丢弃，旧事件不能复活通话。
- **重连**：每次断线最多 3 次、等待 1/2/4 秒；上一条连接真正跑过 10 秒才清零计数，瞬断抖动不绕开有界重连；鉴权/配置错误直接说明并结束。Provider 或凭据作用域切换后重连直接结束原通话，不沿用另一作用域的旧 Key。
- **人格与记忆**：instructions 用完整人格装配（实时工具指令变体：`<memory_actions>` 主块替换为函数工具指令，T01 §9.7 变体 B 实测形态）；建连回放最近 8 轮本机上下文（过记忆控制过滤与会话脱敏）；每轮收束后热层有变化才整体重发 instructions。
- **隐藏动作**：11 类聊天轮动作注册为同名扁平 function 工具；参数经行为核心与隐藏块同一套规则校验（限长、越权、秘密、枚举），按条校验通过即构成完整提案、与回复终态解耦提交；工具调用参数零发声。no_action 不映射——不调用任何工具即等价。
- **记忆控制硬清理**：禁提/冻结/删除等控制命中本通话已说内容时重建连接（跨连接无上下文为实测形态），不让云端残留绕过本机过滤。
- **晚一拍回忆**：`memory_recall` 后台检索，绝不阻塞、绝不在工具轮发声；检索完成回填后按抢占情况决定是否续答。
- **落盘**：复用现有 Markdown 会话（单段 80 turns 上限、跨日切段、requestId 幂等）；被打断回复落已显示前缀并如实标记未完成；转录缺失用「（这段语音没能转出文字）」类标识占位，不编原话。晚安信号照旧触发日终归档与 Dream 资格。
- **音频边界**：双方音频只在内存流转、用完即弃，不落盘、不进日志、不进备份（实现侧无文件写入，测试锁定该事实）。
- **前端**：通话中输入框上方状态栏（连接中/正在聆听/栖语在说话/重连中/已结束），闭麦只停收音、回答照常听；通话中打字进同一会话、沿用真正插话的取消旧回应语义；活动通话跨页显示底部通话条；通话外打字沿用自动朗读开关（开=有声+transcript，关=纯文字）。

## 二期启动方式

- 本机 Provider 设置保存 `callStartupMode`（`manual` / `auto_on_chat_entry`），默认及旧配置缺字段均为手动。非 Omni 不自动拨通，切回 Omni 保留偏好；读取配置不返回 Key，修改沿用会话、Origin、CSRF 保护。
- 设置中首次选择自动只申请麦克风权限并保存选择，不连接 Provider 或启动通话。Web 授权临时采集流立即停止；Android 只请求权限，不启动 FGS。拒绝、取消及过时授权结果保持现有有效设置，已有通话不受偏好修改影响。
- 下一次进入可见 Omni 聊天页且没有已有通话，才检查并尝试自动开始。活动通话跨页或切后台回来延续同一通；主动挂断、自动准备失败或未完成启动离页后，本次不反复开麦，电话入口仍可手动继续。网页刷新保留抑制；关闭页面重开或 Android 真正进程重启恢复保存的偏好，Host 是否退出不决定网页边界。
- Web 前检只读当前授权、可见性、安全上下文与设备；实际采集等待 AudioContext running 和首块 PCM，随后准备播放器并确认输出可用。Android 前检只读可见 Activity、已有权限、麦克风及设备条件，原生 FGS 启动时再复查可见性；自动路径不重新弹权限。`VoiceCapturePlatform.start(automatic: ...)` 显式区分本次自动／手动身份，旧前检不能影响后一次手动授权。
- 未就绪、播放失败、挂断或过时启动释放所属采集与输出资源，迟到结果不复活通话、不停止新手动通话。已建立通话的有界重连与一期链路相同，不能把仅采集／仅播放成功视作完整通话。

## 已知限制与待裁定

- **延迟目标未在真实双工环境复测**：T01 探针口径（合成上行 + waveOutWrite 锚点）P50 609–620ms 达标；P95 ≤2s 在 server_vad 下受首轮与单轮生成迟滞拖累（3241ms），semantic_vad 下达标但伴随漏检。三端真机口径的 P50/P95 待一期验收实测。
- **VAD 选型待用户裁定**：server_vad 初值换来了 22/22 全响应，代价是附和语必然打断当前回复（无附和过滤）；semantic_vad 附和零误断但整轮漏检。spec 以 semantic_vad 为起点，产品语义冲突已按 spec 要求报告。
- **默认音色待产品裁定**：spec 写「官方原生默认声音」，但默认音色实测不可生成；当前显式 Tina 是工程起步值，不是产品定案。
- **被抢占的工具续答无补偿**：用户新轮抢占后，服务端静默忽略续答请求，实现选择「旧检索不唤醒旧语音、轮次直接收束」（T01 实测该服务端行为不可恢复），空档补充语义在该场景下不成立。
- **服务端上下文不可精确裁剪**：打断只能保证本机停止播放与清队列；云端已生成但未播放的内容无法确认按听到的位置截断（`conversation.item.truncate` 未核实，未使用）。
- **电脑休眠、系统强杀前台服务**不属于持续通话承诺范围；Android 系统从系统入口停止前台服务时如实结束通话，不自行复活。
- **自动录放的实机证据仍缺失**：Windows 网页与 Windows App 客户端分别需在正常浏览器策略下验证真实麦克风和可听回复；带 autoplay 放行参数的自动化播放器测试不能替代。Android 可见 FGS 与录放虽有工程接线、测试及 debug APK 构建，尚无连接设备的授权、系统通知、前后台／重启与实际声音证据。

## 验证

- 自动化：四包 `dart analyze && dart test` / `flutter analyze && flutter test` 全绿；协议面（三种终止、取消、超时、迟到事件、工具时序、重连、幂等、闭麦）见 `qwen_omni_realtime_gateway_test.dart`、`omni_call_service_test.dart`、`omni_call_controller_test.dart`、`omni_call_android_platform_test.dart`、`omni_call_ui_test.dart`。
- 二期共享场景见 `omni_startup_settings_test.dart`、`omni_call_startup_lifecycle_test.dart`、`omni_call_app_lifecycle_test.dart`：设置授权不当场通话、下一次进页、跨页已有通话、挂断／前后台抑制、过时启动及手动继续。Chrome 的真实 reload／新 tab／opener 边界见 `omni_call_usage_state_web_test.dart`。
- `scripts/verify-release-baseline.ps1` 持续运行 Web 权限、采集、使用状态和原有播放回归；`voice_auto_start_policy_web_test.dart` 单独用无 autoplay 放行参数的默认浏览器平台验证受限分支。正向采集使用合成 MediaStream，原生 API 拒绝／设备占用使用接缝替身，均不代表真人授权或默认策略下真实自动录放成功。详细本机命令、结果与逐形态待测步骤记录在 ignored `phase-two-acceptance-results.md`，CI 不依赖该文件。
- 真机项（真实麦克风听说、回声、人耳听核、三端后台/锁屏）属一期验收范围，未测不标通过。
