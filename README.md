# Qiyu (栖语)

> A local-first bedtime AI companion that remembers you.

[English](README.md) | [简体中文](README.zh-CN.md)

At the end of the day, some things still need to be said.

Qiyu is a bedtime AI companion. You can tell her about the small things that happened today. She remembers your conversations, so tomorrow does not start from zero.

She is **warm without flattering, intelligent without showing off, quiet without being distant.**

## What it feels like

- Say "I'm home," and a simple "mm" may be enough.
- Say "good night," and she closes the night instead of starting another topic.
- Come back tomorrow, and your conversations and memories are still there.
- As the relationship grows, shared history can naturally return to the conversation.

Qiyu does not try to make every reply perfect or turn every message into advice. Consistency matters more than sounding impressive.

## Windows quick start

No Node.js, Dart, or Flutter installation is required.

1. Extract `qiyu-windows-x64-<version>.zip`.
2. Run `install.cmd`.
3. Open **Qiyu** from the desktop or Start menu.
4. Start chatting, or connect your own OpenAI-compatible, Anthropic, or Ollama provider in Settings.

To uninstall, run `uninstall.cmd` from the installation directory. You can choose whether to keep or remove your conversations and memories.

## Privacy

Conversations and memories are kept on your computer as readable Markdown. Qiyu has no account system, cloud sync, or remote Qiyu backend. Provider API keys are stored by Windows and never exposed to the browser.

Qiyu can work without a configured model for basic local replies. If you choose a remote provider, messages are sent only to that provider. Ollama can keep model inference local.

## Development

```powershell
& .\scripts\verify-release-baseline.ps1
```

Release 1 targets Windows x64. iOS and Android are planned for later.

Technical details are in the [behavior specification](docs/product/behavior-spec.md), [Windows release baseline](docs/engineering/windows-release-baseline.md), and [contributor guide](AGENTS.md).

For bugs and feature requests, use [GitHub Issues](https://github.com/jiangkaiqi2005/Qiyu/issues).
