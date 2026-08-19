# 栖语（Qiyu）

> 一个在一天结束时陪你说话、隐私优先、本地运行的 AI 伙伴。

[English](README.md) | [简体中文](README.zh-CN.md)

栖语是一个睡前 AI 陪伴。她会听你讲完一天，但不像客服那样回应每一句话；聊天、记忆和关系上下文保存在 Windows 电脑上，关闭浏览器或重启本机 Host 后，你们之间发生过的事仍会延续。

没有配置模型时，栖语仍可通过本地行为核心完成少回应、晚安收束和安全回复。配置自己的 OpenAI-compatible、Anthropic 或 Ollama Provider 后，请求由 Windows Host 代发，浏览器始终拿不到 API Key。

## 栖语有什么不同

许多托管式助手追求在服务端会话中给出完整答案。栖语选择了不同的交互方式和数据归属：

| 常见托管式助手模式 | 栖语 |
| --- | --- |
| 把每句话都当成问题 | 可以少说、停一下，或安静地结束今晚 |
| 对话数据由服务保存 | 聊天与记忆以本地 Markdown 留在电脑上 |
| 使用服务提供的模型能力 | 本地规则可用，也可以连接你配置的 Provider |
| 身份与云端账号绑定 | 没有栖语账号、远端后端或云同步 |
| 追求广泛适用的完整回答 | 一致的人格比炫耀能力更重要 |

她的人格基线很简单：**温暖但不讨好，聪明但不炫耀，安静但不冷淡。**

## 核心能力

- **本地优先的对话**：sessions、episodes、长期印象、关系阶段与 PersonaTree 都以 Markdown 保存在本机。
- **不配置模型也能使用**：晚安收束和安全相关回复由确定性的 Dart 行为核心承接。
- **使用自己的 Provider**：支持 OpenAI-compatible、Anthropic 与 Ollama，并处理流式回复、取消、超时和本地降级。
- **能追溯证据的记忆**：结论可以沿摘要、日期回到原始会话；记忆支持纠正、冻结、禁提和删除。
- **跨夜延续**：日终整理更新下一次对话使用的状态；Dream 只在晚安后触发，距离上次成功至少七天。
- **本机安全边界**：Host 只绑定 `127.0.0.1`，API 受本机会话、Origin 和 CSRF 校验保护。
- **备份与恢复**：Markdown 数据支持导出、导入前预览、回滚，以及损坏隔离后的证据驱动恢复。

## Windows 快速开始

普通用户不需要安装 Node.js、Dart 或 Flutter。

1. 解压 `qiyu-windows-x64-<version>.zip`。
2. 运行 `install.cmd`，完成当前用户安装。
3. 从桌面或开始菜单打开“栖语”。Host 会在 `127.0.0.1` 启动，并用默认浏览器打开应用。
4. 直接离线聊天，或在设置中配置 OpenAI-compatible、Anthropic 或 Ollama Provider。

卸载时运行安装目录中的 `uninstall.cmd`。脚本会询问保留还是永久删除聊天、Markdown 记忆、Provider 设置和保存的 API Key。

> [!IMPORTANT]
> “本地优先”指栖语程序与记忆存储在本机。只有当你主动配置并使用远程模型 Provider 时，消息才会发往对应服务；使用 Ollama 可以让模型推理也留在本机。

## 工作方式

```text
浏览器中的 Flutter Web UI
          │
          │ 受保护的本机回环 API
          ▼
127.0.0.1 上的 Dart Windows Host
    ├── QiyuBehaviorCore（行为与安全）
    ├── Markdown 记忆、历史、Dream、备份与恢复
    ├── Windows Credential Manager（API Key）
    └── 你的模型 Provider（可选）
```

浏览器只是界面，不是持久化层。Windows Host 负责本机文件、凭据、Provider 调用，以及回复通过完整校验后的安全交付。

## 数据与隐私

| 数据 | 默认位置 |
| --- | --- |
| 聊天与 Markdown 记忆 | `%USERPROFILE%\.qiyu\memories` |
| Provider 非敏感设置与运行状态 | `%LOCALAPPDATA%\Qiyu` |
| Provider API Key | Windows Credential Manager |

开发和验收时可以通过 `QIYU_MEMORY_DIR` 或 `--memory-dir` 覆盖记忆位置。界面不会收到 API Key 明文或真实记忆路径。

栖语没有账号系统、远端栖语后端、在线托管页面、云同步或多设备合并。Release 1 不迁移已经退役的网页版 MVP `localStorage` 数据。

## 开发与发布

开发环境需要符合仓库依赖约束的 Dart 与 Flutter SDK。从仓库根目录运行：

```powershell
# 分析、测试、构建、打包并冒烟验证完整发布链路。
& .\scripts\verify-release-baseline.ps1

# 单独构建可移动目录和 Windows 发布压缩包。
& .\scripts\build-windows-bundle.ps1
```

发布门禁覆盖纯 Dart 行为契约、Flutter 分析与 Widget 测试、Flutter Web 构建、Windows Host 分析与测试、安装生命周期测试、清单与敏感信息检查、预检和启动冒烟。整个过程不调用 Node.js 或 npm。

构建产物：

- `apps\qiyu_windows_host\build\windows-bundle\`
- `apps\qiyu_windows_host\build\qiyu-windows-x64-<version>.zip`

## 仓库结构

| 路径 | 用途 |
| --- | --- |
| `packages/qiyu_behavior_core` | 纯 Dart 行为、安全、DTO 与交付协议 |
| `apps/qiyu_flutter` | Flutter Web 界面 |
| `apps/qiyu_windows_host` | 回环 Host、Provider、凭据与 Markdown 持久化 |
| `contracts` | 当前 Dart 发布契约和冻结的旧迁移基线 |
| `docs` | 产品行为、架构、发布证据与运行文档 |

## 文档

- [工程行为规范](docs/product/behavior-spec.md)
- [Windows Release 1 基线](docs/engineering/windows-release-baseline.md)
- [Windows 本机 Web 架构](docs/engineering/windows-local-web-shell.md)
- [发布清单](docs/product/release-checklist.md)
- [栖语产品灵魂](栖语产品灵魂.md)
- [Agent 与贡献者指南](AGENTS.md)

## 当前范围

Release 1 只面向 Windows x64。iOS 与 Android 属于后续适配范围；移动端构建、云同步、远程托管和旧 `localStorage` 迁移明确不在本次发布内。

Bug 与功能建议请提交到 [GitHub Issues](https://github.com/jiangkaiqi2005/Qiyu/issues)。
