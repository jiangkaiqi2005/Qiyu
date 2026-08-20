# 栖语（Qiyu）

> 一个会记得你的、本地优先的睡前 AI 伙伴。

[English](README.md) | [简体中文](README.zh-CN.md)

一天结束了，有些话还没找到人说。

栖语是一个睡前 AI 伙伴。你可以跟她说说今天发生的小事。她会记住这些聊天，明天再见时不用从头认识。

她**温暖但不讨好，聪明但不炫耀，安静但不冷淡。**

## 和她聊天是什么感觉

- 你说“我到家了”，她可能只回一个“嗯”。
- 你说“晚安”，她会陪你结束今晚，不再另起话题。
- 第二天再打开，昨天的聊天和记忆都还在。
- 相处久了，共同经历会自然地回到对话里。

栖语不追求把每句话说得滴水不漏，也不会把每条消息都变成建议。比起显得聪明，她更在意前后一致。

## Windows 使用

普通用户不需要安装 Node.js、Dart 或 Flutter。

1. 解压 `qiyu-windows-x64-<version>.zip`。
2. 运行 `install.cmd`。
3. 从桌面或开始菜单打开“栖语”。
4. 直接开始聊天，或在设置中连接自己的 OpenAI-compatible、Anthropic 或 Ollama Provider。

卸载时运行安装目录中的 `uninstall.cmd`。你可以选择保留或删除聊天与记忆。

## 隐私

聊天和记忆以可读的 Markdown 保存在电脑上。栖语没有账号系统、云同步或远端后端。Provider API Key 由 Windows 保管，不会进入浏览器。

不配置模型时，栖语仍能完成基础的本地回复。如果你选择远程 Provider，消息只会发往那个 Provider；使用 Ollama 可以让模型推理也留在本机。

## 开发

```powershell
& .\scripts\verify-release-baseline.ps1
```

Release 1 只面向 Windows x64，iOS 与 Android 留待后续适配。

技术细节见[工程行为规范](docs/product/behavior-spec.md)、[Windows 发布基线](docs/engineering/windows-release-baseline.md)和[贡献者指南](AGENTS.md)。

Bug 与功能建议请提交到 [GitHub Issues](https://github.com/jiangkaiqi2005/Qiyu/issues)。
