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

浏览器不会读取 API Key。所有 LLM 请求都从本地 Node dev server 的 `/api/chat` 发出。且任何请求中出现的 API Key (长度 > 3) 均会在错误或异常输出中被替换为 `[redacted]` 脱敏。

### 1. 自动地址规范化 (URL Auto-normalization)

无论以何种方式配置接口地址，系统会自动完成标准化。例如：
- `https://api.openai.com/v1` -> `https://api.openai.com/v1/chat/completions`
- `http://127.0.0.1:11434/v1` -> `http://127.0.0.1:11434/v1/chat/completions`

### 2. 环境变量方式

```powershell
cd E:\Agent\栖语
$env:LLM_API_URL="https://api.openai.com/v1"
$env:LLM_API_KEY="你的真实 key"
$env:LLM_MODEL="gpt-4o"
npm run dev
```

> [!NOTE]
> 环境变量的优先级高于本地 JSON 配置文件。如果环境变量已设置，设置中心会提示受其控制，且保存修改将不会覆盖环境变量的生效值。

### 3. 本地配置文件方式

复制 `qiyu.config.example.json` 为 `qiyu.config.local.json`，写入真实 `apiUrl`、`apiKey`、`model`。该本地配置文件已被 `.gitignore` 包含，绝对不会提交至 Git。

### 4. 本地 Ollama 调试指南

1. 本地启动 Ollama 模型（例如 `llama3`）：
   ```powershell
   ollama run llama3
   ```
2. 打开应用设置中心，在**服务商预设 (Provider Preset)** 下选择 `Local Ollama`；
3. 输入任意非空的 API Key（例如 `ollama`），随后即可进行连接测试与保存。
   *（注：虽然 Ollama 不需要 Key，但为通过前端/服务端非空校验，需填入 dummy 值）*

### 5. 调试与诊断

- **双阶段连接测试**: 
  - **测试 Provider 连接**: 验证基础 API 终结点的 HTTP 请求握手连通性与模型可用性。
  - **测试栖语回复**: 结合当前栖语的 Prompt 上下文与安全规则，模拟发送一句 `'今天好累'`，并校验模型输出是否合法、是否命中违禁词等。
- **对话页面实时诊断**:
  - 在设置中心底部激活 **「幻境」实验室 (开发者模式)**；
  - 返回对话页面时，顶部会渲染诊断面板。在发送消息后，会实时输出当轮对话的回复来源 (`LLM` 或 `本地兜底`)、通信耗时（延迟）以及具体的降级原因。

没有配置 LLM 时，应用自动使用本地规则引擎。

