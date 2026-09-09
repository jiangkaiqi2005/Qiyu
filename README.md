# Qiyu (栖语)

> At the end of the day, some things still need to be said.

**栖** (qī) — to rest, to roost, a bird returning to its nest.
**语** (yǔ) — to speak, to confide.
**Qiyu** — someone to talk to, in the moments you come to rest.

[English](README.md) | [简体中文](README.zh-CN.md)

---

## Who she is

Qiyu is a bedtime AI companion — you can talk to her about anything. She has her own preferences and judgments, and won't pretend to agree just to be pleasant. She can have emotions, and she can not know how to answer.

Of course, you don't have to wait until bedtime. Chat with her whenever you feel like it.

**Warm without flattering. Intelligent without showing off. Quiet without being distant.**

## What it feels like

- Say "I'm home," and a simple "mm" may be enough.
- Say "good night," and she closes the night instead of starting another topic.
- Come back tomorrow, and she naturally brings up something from last night.
- Over time, she teases you about staying up late and digs up last week's stories — but never jokes about what hurts.
- She never says "I understand how you feel" or "thank you for sharing" — no customer-service scripts.

The conversation arc is a diminuendo: `start → ease in → unfold → the deepest point → lighten → slow down → quiet`. By the end you feel like sleeping. That's the point.

## Voice: talk to her, hear her talk

When you don't feel like typing before bed, just hold the microphone and speak — Qiyu transcribes your words and sends them as text. Her replies can be read aloud too — tap the speaker icon next to a bubble, or turn on auto-read in Settings.

Currently supported speech input:

- **OpenAI-compatible** (Whisper and other transcription services)
- **Volcengine Seed ASR** (real-time streaming recognition)

Currently supported text-to-speech:

- **OpenAI-compatible** (OpenAI TTS, SiliconFlow, etc.)
- **Volcengine seed-tts-2.0** (built-in dialect voice presets, adjustable speed)

You can pick the voice you like: tone, speed, and dialect are all configurable in Settings. The Volcengine option includes presets for Mandarin, Cantonese, Sichuan dialect, Northeastern dialect, and more — see the full [seed-tts-2.0 voice list](https://docs.volcengine.com/docs/6561/1257544).

Audio stays in memory only — never written to disk, never cached.

## Memory: she actually remembers you

Qiyu's memory system is built entirely on **local, readable Markdown files** — zero vector databases, zero graph databases, zero remote services. You can open the folder and see exactly what she remembers.

### Three-tier architecture

| Tier | Contents | Purpose |
|------|----------|---------|
| **Hot** | Daily state, long-term impressions, persona summary | Injected into each prompt, capped at 2000–3000 tokens |
| **Middle** | Monthly summaries, Dream drafts, full persona tree | Structured understanding |
| **Cold** | Daily episode summaries, raw session transcripts | Evidence and full records, never directly injected |

### PersonaTree: how she understands you

Qiyu builds a logical tree to understand you, with five branches: **identity facts, personality expression, values & principles, preferences & habits, boundaries**.

Every belief requires sufficient evidence to stabilize:

- Something you stated directly — remembered after 1 occurrence
- Personality and preferences — at least 2 dates, spanning ≥ 7 days
- Behavioral inferences — at least 3 dates, spanning ≥ 14 days

Just say "you got that wrong," and she retracts it on the spot — she won't argue back with old evidence.

### Five-stage memory rhythm

Memory needs rhythm, not just piling up:

1. **Store** — Each conversation turn is appended to local session files
2. **Note** — After each reply, key facts are extracted into the day's episode summary
3. **Finalize** — At goodnight or day-change, gaps are filled, state packs and indexes updated
4. **Compress** — On the first conversation of a new month, last month's episodes are condensed
5. **Dream** — Triggered after goodnight when ≥ 3 days have passed: deep offline reorganization that distills growth arcs and shared history, adjusts the persona tree, passes four self-checks, and is silently adopted without disturbing you

### In-conversation recall

When the conversation touches on the past, the model issues a hidden action (`memory_recall`) to search memory indexes on demand — no permanent context occupation, no scoring, no hard-coded matching.

### User control

In the Memory Center, you can:

- **Freeze** a memory (kept but never brought up)
- **Ban** a topic (completely excluded from conversation)
- **Delete** any memory entry

## Privacy

All data is stored as readable Markdown on your computer. No accounts, no cloud sync, no remote backend. API keys are never known to anyone else.

Without a configured model, only the local rule engine handles conversation — configuring a model is strongly recommended.

## Quick start (Windows)

No Node.js, Dart, or Flutter installation required.

1. Extract `qiyu-windows-x64-<version>.zip`
2. Run `install.cmd`
3. Open **Qiyu** from the desktop or Start menu
4. Start chatting, or connect a provider in Settings

Supported providers:

- **OpenAI-compatible** (DeepSeek, Qwen, Moonshot, GLM, etc.)
- **Anthropic** native protocol
- **Ollama** (fully local offline inference)

To uninstall, run `uninstall.cmd` from the installation directory. You can choose to keep or remove your conversations and memories.

## Architecture

```
┌─────────────────────────────────┐
│  Flutter Web UI                 │  Dark iris theme · incremental display
│  apps/qiyu_flutter              │
├─────────────────────────────────┤
│  Dart Windows Host (127.0.0.1)  │  Session/CSRF protection · Markdown persistence
│  apps/qiyu_windows_host         │  Five-stage memory cadence · Provider adapters
├─────────────────────────────────┤
│  Behavior Core (pure Dart)      │  Safety classification · Output sanitization
│  packages/qiyu_behavior_core    │  Persona boundary checks · Local rule engine
└─────────────────────────────────┘
```

The host listens only on `127.0.0.1`; API keys never enter the browser. Model output is sanitized and checked against persona boundaries before delivery. Crisis, medical, legal, and financial inputs are classified locally without calling the provider.

## Development

```powershell
& .\scripts\verify-release-baseline.ps1   # Full release gate
& .\scripts\build-windows-bundle.ps1      # Build Windows bundle
```

Release 1 targets Windows x64. iOS and Android are planned for later.

Technical details are in the [behavior specification](docs/product/behavior-spec.md), [release baseline](docs/engineering/windows-release-baseline.md), and [contributor guide](AGENTS.md).

For bugs and feature requests, use [GitHub Issues](https://github.com/jiangkaiqi2005/Qiyu/issues).
