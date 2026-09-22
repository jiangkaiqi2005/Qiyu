# Qiyu (栖语)

> At the end of the day, some things still need to be said.

**栖** (qī) — to rest, to roost, a bird returning to its nest.
**语** (yǔ) — to speak, to confide.
**Qiyu** — someone to talk to, in the moments you come to rest.

You can talk to her about anything — summarize what you did today, confide things you can only say to yourself, and more.

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

## Voice: talk to her, hear her talk

When you don't feel like typing before bed, just speak.

- On desktop: click the microphone next to the input box and start talking; click it again when you're done (the button turns into "done, turn into text"), and your words are sent as text.
- On Android: tap the microphone once to enter voice mode, press and hold the button to speak, and release to send. Don't want to send? Slide up to cancel.

Her replies can be read aloud too — tap the speaker icon next to a bubble, or turn on auto-read in Settings.

Text-to-speech is genuinely fun to play with — you can freely adjust the voice tone, speed, dialect, and more. Check the official docs for your chosen TTS model to see what it supports.

We recommend turning on voice readback.

Currently supported speech input:

- **OpenAI-compatible** (Whisper and other transcription services)
- **Volcengine Seed ASR** (real-time streaming recognition)
- **Qwen ASR** (Alibaba Cloud DashScope, default model `qwen3-asr-flash`; the newer `qwen-audio-3.0-asr-flash-filetrans` is not yet supported)
- **Custom service** (bring your own endpoint, with configurable auth and response parsing)

Currently supported text-to-speech:

- **OpenAI-compatible** (OpenAI TTS, SiliconFlow, etc.)
- **Volcengine seed-tts-2.0** (built-in dialect voice presets, adjustable speed)
- **Qwen TTS** (Alibaba Cloud DashScope, default model `qwen3-tts-flash`, free-form voice ID; the newer `qwen-audio-3.1-tts-next` is not yet supported)
- **Custom service** (bring your own endpoint; supports raw bytes, JSON field, or JSON-lines response formats)

You can pick the voice you like: tone, speed, and dialect are all configurable in Settings. The Volcengine option includes presets for Mandarin, Cantonese, Sichuan dialect, Northeastern dialect, and more — see the full [seed-tts-2.0 voice list](https://docs.volcengine.com/docs/6561/1257544).

Audio stays in memory only — never written to disk, never cached.

Speech input and readback each configure their own service and key — setting up the chat model does not set up voice; both are configured separately in Settings.

## Memory: she actually remembers you

Qiyu's memory system is built entirely on **local, readable Markdown files** — zero vector databases, zero graph databases, zero cloud sync. Everything lives on your own device, and you can open the folder to see exactly what she remembers. Storage is local; if you connect a model service in Settings, chat, daily finalization, memory recall, and Dream send the corresponding context to the provider you chose — without a configured model, the local rule engine takes over.

### Three-tier architecture

| Tier | Contents | Purpose |
|------|----------|---------|
| **Hot** | Daily state, long-term impressions, persona summary | Injected into each prompt under a character budget of about 3000; trimmed before injection when over |
| **Middle** | Monthly summaries, Dream drafts, full persona tree | Structured understanding |
| **Cold** | Daily episode summaries, raw session transcripts | Evidence and full records, never directly injected |

### PersonaTree: how she understands you

Qiyu builds a logical tree to understand you, with five branches: **identity facts, personality expression, values & principles, preferences & habits, boundaries**.

Every belief requires sufficient evidence to stabilize:

- Something you stated directly — becomes evidence on the first telling, and grows into a stable belief through daily finalization and the next Dream
- Personality and preferences — at least 2 dates, spanning ≥ 7 days
- Behavioral inferences — at least 3 dates, spanning ≥ 14 days

Say "you got that wrong": identity facts are retracted on the spot, and she won't argue back with old evidence; corrections about personality or preferences are applied at that day's finalization or the next Dream.

### Five-stage memory rhythm

Memory is organized rhythmically:

1. **Store** — Each conversation turn is appended to local session files
2. **Note** — After each reply, key facts are extracted into the day's episode summary
3. **Finalize** — At goodnight or day-change, gaps are filled, state packs and indexes updated
4. **Compress** — On the first conversation of a new month, last month's episodes are condensed
5. **Dream** — Triggered after goodnight when ≥ 3 days have passed: deep reorganization that distills growth arcs and shared history, adjusts the persona tree, passes four self-checks, and is silently adopted without disturbing you

### In-conversation recall

When the conversation touches on the past, the model issues a hidden action (`memory_recall`) to search memory indexes on demand and retrieve facts from specific dates. No permanent context occupation, no scoring, no hard-coded matching.

### When organizing happens

Daily finalization and Dream are local background tasks that run while the app is open: saying goodnight triggers the day's finalization, and Dream runs on a goodnight at least 3 days after the last one. Quitting the app immediately may interrupt an ongoing pass; the next launch or an idle moment picks it up again — nothing is organized after you shut the machine down.

When a night's organizing doesn't finish, a quiet line appears in the corner of the interface — "tonight's memory organizing didn't finish; it will catch up next time" — no popups, no interruptions.

If a memory file is ever corrupted, she isolates the damaged original into a local recovery area and shows a recovery report in the Memory Center: what was restored, what was only partially restored, and what is still pending — never a fake success.

### User control

The Memory Center has four layers — **recent days, long-term impressions, about you, and the two of us** — and every persona claim shows how many pieces of evidence back it, so you can see why she believes what she believes. In it you can:

- **Pause (freeze)** a memory: the content stays, but it is no longer injected into conversation and no longer takes part in automatic organizing; resume it any time
- **Ban** a topic: chat and organizing both avoid it. If you bring it up yourself, she responds to the present as usual — she won't dig up the old memory, and the ban is never lifted automatically
- **Delete** any memory entry: before deleting, she tells you the blast radius (which days' records, persona claims, and long-term impressions are affected). Deleting a memory does not delete the raw conversation — raw sessions are only cleared when you delete a session segment by hand in History
- **Correct** a memory: long-term impressions and daily entries can be edited directly, and the persona is corrected through conversation; after a correction she rebuilds the related indexes in the background, showing "organizing" until it settles

Memories that involve private information are masked by default and can be revealed temporarily (they re-mask after 20 seconds).

All three entries let you **change what she calls you**: at first meeting, in the Memory Center, or by simply saying "call me Lao Wang from now on" in chat — no need to wait for her to form a picture of you.

## Privacy

All conversations and memories are stored as readable Markdown on your own device, with settings in a few small readable files beside them (such as `provider.json`). No accounts, no cloud sync, no remote backend. API keys stay on your machine (on Windows they sit in plaintext in `provider.json`, so copying the `.qiyu` folder takes the key with it); they are only sent to the model provider you configured yourself for authentication, and they never enter a backup.

Without a configured model, only the local rule engine handles conversation, and memory recall and Dream do not run — configuring a model is strongly recommended. Once configured, daily finalization, Dream, and memory recall add extra model requests, billed by your provider.

## Quick start (Windows)

No development tools required — extract and run.

1. Extract `qiyu-windows-x64-<version>.zip`
2. Run the `install.cmd` inside
3. Open **Qiyu** from the desktop or Start menu
4. Start chatting, or connect a model in Settings

The first time you run it, Windows may pop up "Windows protected your PC." That's the usual notice for an unsigned installer: click **More info**, then **Run anyway**, and installation continues.

Where to get keys for the supported model services:

- **Volcengine Ark (Doubao)**: register on the Volcengine website, create an API Key in the Ark console, then choose the Volcengine Ark preset under Settings → model connection and paste it in.
- **Other common models** (DeepSeek, Qwen, Moonshot, GLM, etc.): apply for an API Key in each provider's own console and paste it in the same place.
- **Ollama**: runs on your own computer, fully local — no key needed.

Uninstalling is covered below under "Where your data lives, and how to back it up."

## Install (Android)

The Android app carries everything inside your phone. Conversations, memories, and settings all stay on that phone.

1. Download the installer from Qiyu's [releases page](https://github.com/jiangkaiqi2005/Qiyu/releases). The package is split by phone chip architecture, and the file name ends with its architecture: most phones want `arm64-v8a`; a few older phones want `armeabi-v7a`; `x86_64` is generally only for emulators on a computer. The wrong one simply won't install — pick the matching file and try again.
2. Open the file on your phone (or download it directly on the phone). When the system warns about "unknown sources" or asks whether to allow the installation, allow it.
3. Open **Qiyu** — at first meeting she asks what to call you.

## Where your data lives, and how to back it up

Qiyu has no cloud. There is exactly one copy of your data — yours:

- **Windows**: your conversations and memories live in the `C:\Users\<your name>\.qiyu` folder as readable Markdown text; your model connection settings live right beside them as a few small readable files (such as `provider.json`). Before switching computers or reinstalling, copying that whole folder takes your conversations, memories, and settings with you.
- **Android**: everything stays inside Qiyu's own private app space, unreadable by other apps; you can see the exact location under Settings → local data.

**Backup**: open Settings → local data → backup and restore, and export — you get a zip archive containing all your memory Markdown plus a manifest, which you can send to yourself. After switching phones or reinstalling, import from the same place: you preview the differences first, and on confirmation she takes a rollback snapshot before restoring. API keys and model credentials never enter the backup.

**Before you uninstall**: your conversations and memories have no other copy —

- On Windows, run `uninstall.cmd` from the installation directory. It asks whether to keep your data: keep, and everything stays where it is; delete, and everything is wiped.
- On Android, uninstalling the app — or clearing its data from the system settings — erases all conversations and memories. Export a backup first.

## Web search

When the conversation touches things that change — today's date, the weather outside, recent news — Qiyu searches the web on demand and weaves what she finds into her reply, so you don't have to look it up yourself.

This needs an AnySearch API Key under Settings → web search (apply on AnySearch's website). The key stays on your machine. Without it, chatting works as usual — she just won't search.

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

The host listens only on `127.0.0.1`; API keys never enter the browser. Model output is sanitized and checked against persona boundaries before delivery. Crisis, medical, legal, and financial inputs go to the model as usual; when no model is configured or the model does not respond, local fallback scripts take over (crisis inputs are given the 12356 mental-health hotline).

The Android app reuses the same interface and core, with the local service embedded right in the app — likewise with no cloud anywhere.

## Development

```powershell
& .\scripts\verify-release-baseline.ps1   # Full release gate
& .\scripts\build-windows-bundle.ps1      # Build Windows bundle
```

Release 1 targets Windows and Android; iOS and other platforms come later.

Technical details are in the [behavior specification](docs/product/behavior-spec.md), [release baseline](docs/engineering/windows-release-baseline.md), and [contributor guide](AGENTS.md).

For bugs and feature requests, use [GitHub Issues](https://github.com/jiangkaiqi2005/Qiyu/issues).
