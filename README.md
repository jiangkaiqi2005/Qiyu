# Qiyu (栖语)

> A private, local-first AI companion for the end of the day.

[English](README.md) | [简体中文](README.zh-CN.md)

Qiyu is a bedtime companion that listens without sounding like customer support. It keeps conversations, memories, and relationship context on your Windows PC, so closing the browser or restarting the host does not reset who you are to each other.

It works without a configured model through a small local behavior engine. When you connect your own OpenAI-compatible, Anthropic, or Ollama provider, the Windows host sends the request on your behalf; the browser never receives the API key.

## Why Qiyu

Many hosted assistants optimize for complete answers inside a service-owned session. Qiyu is built around a different interaction and ownership model:

| Common hosted assistant pattern | Qiyu |
| --- | --- |
| Treats every message as a question | Can answer briefly, pause, or simply close the night |
| Conversation data lives in the service | Conversations and memory remain as local Markdown |
| Uses the service's model access | Works locally or uses a provider you configure |
| Identity is tied to an account | Has no Qiyu account, backend, or cloud sync |
| Optimizes for broadly helpful answers | Prioritizes a consistent personality over showing off |

The personality baseline is simple: **warm without flattering, intelligent without showing off, quiet without being distant.**

## Features

- **Local-first conversations**: sessions, episodes, long-term impressions, relationship state, and PersonaTree data are stored as Markdown on your PC.
- **Useful without a model**: bedtime closure and safety-sensitive replies remain available through the deterministic Dart behavior core.
- **Bring your own provider**: supports OpenAI-compatible APIs, Anthropic, and Ollama, with streaming, cancellation, timeout handling, and local fallback.
- **Memory with evidence**: conclusions can be traced back through summaries, days, and original sessions; memories can be corrected, frozen, banned, or deleted.
- **Nightly continuity**: end-of-day consolidation updates the state used by the next conversation. Dream may reorganize long-term memory after bedtime, no more than once every seven days.
- **Local security boundary**: the host binds only to `127.0.0.1` and protects its API with a host session, Origin checks, and CSRF validation.
- **Backup and recovery**: Markdown data can be exported, previewed before import, rolled back, and recovered from isolated corruption.

## Windows Quick Start

Regular users do not need Node.js, Dart, or Flutter.

1. Extract `qiyu-windows-x64-<version>.zip`.
2. Run `install.cmd` for a per-user installation.
3. Open **Qiyu** from the desktop or Start menu. The host starts on `127.0.0.1` and opens the app in your default browser.
4. Chat offline, or open Settings to configure an OpenAI-compatible, Anthropic, or Ollama provider.

Run `uninstall.cmd` from the installation directory to uninstall. It asks whether to keep or permanently remove conversations, Markdown memories, provider settings, and the saved API key.

> [!IMPORTANT]
> Local-first describes Qiyu's application and memory storage. Messages are sent to a remote service only when you explicitly configure and use a remote model provider. Ollama can keep model inference local.

## How It Works

```text
Flutter Web UI in the browser
          │
          │ protected loopback API
          ▼
Dart Windows Host on 127.0.0.1
    ├── QiyuBehaviorCore (behavior and safety)
    ├── Markdown memory, history, Dream, backup, recovery
    ├── Windows Credential Manager (API keys)
    └── Your provider (optional)
```

The browser is the interface, not the persistence layer. The Windows host owns local files, credentials, provider calls, and the validated delivery of replies.

## Data and Privacy

| Data | Default location |
| --- | --- |
| Conversations and Markdown memory | `%USERPROFILE%\.qiyu\memories` |
| Non-secret provider settings and runtime state | `%LOCALAPPDATA%\Qiyu` |
| Provider API key | Windows Credential Manager |

`QIYU_MEMORY_DIR` or `--memory-dir` can override the memory location for development and acceptance testing. The UI never receives a plaintext API key or the real memory path.

Qiyu has no account system, remote Qiyu backend, hosted web client, cloud sync, or multi-device merge. Release 1 does not migrate data from the retired browser MVP's `localStorage`.

## Development

Development requires Dart and Flutter versions compatible with the checked-in package constraints. From the repository root:

```powershell
# Analyze, test, build, package, and smoke-test the complete release path.
& .\scripts\verify-release-baseline.ps1

# Build the portable directory and Windows release archive.
& .\scripts\build-windows-bundle.ps1
```

The release gate covers the pure Dart behavior contracts, Flutter analysis and widget tests, Flutter Web build, Windows host analysis and tests, package lifecycle tests, manifest and secret checks, preflight, and launch smoke testing. It does not call Node.js or npm.

Build outputs:

- `apps\qiyu_windows_host\build\windows-bundle\`
- `apps\qiyu_windows_host\build\qiyu-windows-x64-<version>.zip`

## Repository Map

| Path | Purpose |
| --- | --- |
| `packages/qiyu_behavior_core` | Pure Dart behavior, safety, DTOs, and delivery contracts |
| `apps/qiyu_flutter` | Flutter Web interface |
| `apps/qiyu_windows_host` | Loopback host, providers, credentials, and Markdown persistence |
| `contracts` | Current Dart release fixtures and the frozen legacy migration baseline |
| `docs` | Product behavior, architecture, release evidence, and operational notes |

## Documentation

- [Behavior specification](docs/product/behavior-spec.md)
- [Windows Release 1 baseline](docs/engineering/windows-release-baseline.md)
- [Windows local Web architecture](docs/engineering/windows-local-web-shell.md)
- [Release checklist](docs/product/release-checklist.md)
- [Product soul (Chinese)](栖语产品灵魂.md)
- [Agent and contributor guide](AGENTS.md)

## Project Status

Release 1 targets Windows x64. iOS and Android are future adaptation work; mobile builds, cloud sync, remote hosting, and legacy `localStorage` migration are intentionally outside the current release.

For bugs and feature requests, use [GitHub Issues](https://github.com/jiangkaiqi2005/Qiyu/issues).
