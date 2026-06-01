# 栖语 MVP

栖语是一个睡前 AI 陪伴原型。这个 MVP 先实现可测试的行为层：人格一致性、记忆、关系阶段、微摩擦、少回应、睡前收束和安全边界。

## 运行

```powershell
cd E:\Agent\栖语
npm test
npm run eval
npm run dev
```

打开 `http://localhost:5173`。

## 核心行为

- 默认少说，不把每句话都处理成客服式共情。
- 禁止「我理解你的感受」「谢谢你愿意和我分享」这类 AI 话术。
- 关系变深后才调侃、翻旧账、制造轻微摩擦。
- 用户说「晚安」时只收束，不重新打开新话题。
- 危机表达优先进入安全回应，并提供 `12356`。

## 当前边界

这个版本已接入外部 LLM API，支持流式风格调取，但同时保留本地规则引擎作为离线降级兜底和安全边界的测试轨道。不做账号系统，不做云端记忆。

## LLM API 配置

浏览器不会读取 API Key。所有 LLM 请求都从本地 Node dev server 的 `/api/chat` 发出。

环境变量方式：

```powershell
cd E:\Agent\栖语
$env:LLM_API_URL="https://api.example.com/v1/chat/completions"
$env:LLM_API_KEY="你的真实 key"
$env:LLM_MODEL="provider-model-name"
npm run dev
```

本地配置文件方式：

复制 `qiyu.config.example.json` 为 `qiyu.config.local.json`，写入真实 `apiUrl`、`apiKey`、`model`。`qiyu.config.local.json` 已加入 `.gitignore`，不要提交。

没有配置 LLM 时，应用自动使用本地规则引擎。
