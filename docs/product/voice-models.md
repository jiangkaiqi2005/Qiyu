# 语音型号支持清单

栖语内置了一张语音档位映射表：连接测试或聊天时发现型号和档位对不上，设置页会按这张表告诉你「该去哪个档、该填什么地址」，多数建议可以一键回填。本文是这张表的用户版清单，配置前先在这里查一遍就够了。

> 表的真相在 `packages/qiyu_local_host/lib/src/voice_tier_mapping.dart`；新增或调整型号先改表、再同步本文。

## 千问识别档（语音转文字）

服务地址保持设置页缺省值即可（`https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation`）。

| 型号 | 说明 |
| --- | --- |
| `qwen-audio-3.1-asr-flash` | 现行识别型号（默认），整段录音上传后返回文字 |

## 千问朗读档（文字转语音）

服务地址填官方推理地址 `wss://dashscope.aliyuncs.com/api-ws/v1/inference`（设置页缺省值，连接测试给出建议时可直接一键回填）：

| 型号 | 说明 |
| --- | --- |
| `qwen-audio-3.1-tts-flash` | 现行合成型号（默认），推理通道按句流式，默认音色 `longanhuan_v3.1` |

也可以改填官方 maas HTTP 端点 `https://{业务空间ID}.cn-beijing.maas.aliyuncs.com/api/v1/services/audio/tts/SpeechSynthesizer`，把 `{业务空间ID}` 换成自己的百炼业务空间 ID——这条路要求自有百炼 Key，作为推理地址的备选。

## 豆包与 OpenAI 兼容档

豆包朗读档用火山引擎 seed-tts-2.0 系列模型（音色列表见 README），识别档用 Seed ASR；OpenAI 兼容档与自定义服务按各自服务文档填型号名。这几档按服务文档接线，型号名不收进本清单。

## 已知接不了的千问型号

填了下面这些型号，连接测试和聊天路径都会提示原因并给出替代型号：

| 型号 | 原因 | 替代 |
| --- | --- | --- |
| `qwen-audio-3.1-tts-next` | 统一音频生成型号，官方没有给朗读用的通道 | `qwen-audio-3.1-tts-flash` |
| `qwen-audio-3.1-realtime-plus` | 端到端语音对话型号，不归转写或朗读用 | `qwen-audio-3.1-tts-flash` |
| `qwen-audio-3.1-asr-flash-message` | 要边说边传的流式识别通道 | `qwen-audio-3.1-asr-flash` |
| `qwen-audio-3.1-asr-flash-filetrans` | 录音文件转写型号 | `qwen-audio-3.1-asr-flash` |

## 清单里没有的型号

栖语不按名字猜协议：没列出的型号照原样交给服务端，连不上时按「模型与接口不匹配」给出提示，不拦截也不臆测。
