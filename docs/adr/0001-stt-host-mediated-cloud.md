# 语音转写走 Host 中介的云端 STT

浏览器不得直接调 STT 服务：录音上传给本机 loopback Host，由 Host 持 Key 调 OpenAI-compatible `/audio/transcriptions`，文本返回后直接走现有发送链路。排除浏览器 Web Speech API，因为识别流量走浏览器厂商云端、绕过凭据管理；推迟本机 Whisper，因为它要引入原生二进制与模型文件，打破纯 Dart Host。Host 中介层保证将来换本机模型时只改 Host 内实现。

## Consequences

- 音频出网给 STT 服务商，与聊天文本出网给 LLM 服务商同级；本机内存之外不落盘。
- 转写文本直接发送（用户知情选择）：STT 错字会落进对话与 sessions，无法事后修改。
- 转写文本不携带语音标记，行为层与记忆管线对输入通道无感知。
